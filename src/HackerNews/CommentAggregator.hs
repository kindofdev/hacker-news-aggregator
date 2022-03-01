{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module HackerNews.CommentAggregator 
    ( commentAggregator ) where

import Control.Concurrent.STM.TChan ( dupTChan, readTChan, writeTChan )
import Control.Monad.Except         ( MonadIO(liftIO), MonadError(throwError) )
import Control.Monad.Extra          ( forM_, when, loopM )                                     
import Control.Monad.Reader         ( MonadReader(ask) )         
import Control.Monad.STM            ( atomically )                        
import qualified Data.Bifunctor     as Bi
import Data.List                    ( unfoldr )     
import Data.Maybe                                  
import Data.Ord                     ( Down(..) )                       
import Data.PSQueue                 ( PSQ )                   
import qualified Data.PSQueue       as PSQ
import Text.Format                  ( format )         

import HackerNews.Logger            ( logDebug, logInfo, logError )
import HackerNews.Types



commentAggregator :: HackerNewsM Result
commentAggregator = do 
    logInfo "commentAggregator - Starting ..."
    Env{..}                   <- ask
    storyResChanR             <- liftIO $ atomically $ dupTChan storyResChan
    (topNames, totalComments) <- processComments storyResChanR
    
    logInfo "commentAggregator - Aggregation done"
    return $ AggregatorResult topNames totalComments
  where
    processCommentsFromStory :: StoryResChan -> HackerNewsM (NumberOfStories, NumberOfComments) 
    processCommentsFromStory storyResChanR = do
        Env{..} <- ask
        mstory  <- liftIO $ atomically $ readTChan storyResChanR
        case mstory of 
            Nothing             -> return (0, 0) 
            Just (_, Story{..}) -> do
                forM_ sCommentIds $ liftIO . atomically . writeTChan itemReqChan . GetComment
                logDebug $ format "commentAggregator - Triggered {0} GetComment requests for story {1}" 
                           [show sCommentIds, show sId]

                forM_ sCommentIds $ \cId -> 
                    logDebug $ "commentAggregator (from story) - Triggered request GetComment: " <> show cId    
                    
                return (1, length sCommentIds)
    
    -- Note: This might have been implemented using 'StateT IO a' instead of loopM
    processComments :: StoryResChan -> HackerNewsM ([(Name, NumberOfComments)], NumberOfComments)  -- TODO change name 
    processComments storyResChanR  = do
        Env{..} <- ask
        flip loopM (initialAggQueue, 0, 0, 0) $ \(aggQueue, storiesProcessedAcc, pendingCommentsAcc, commentsAcc) -> do
            logDebug $ 
                format "commentAggregator - initial storiesProcessedAcc: {0}, pendingCommentsAcc: {1}, commentsAcc: {2}" 
                [show storiesProcessedAcc, show pendingCommentsAcc, show commentsAcc]
            
            -- Story processing: Get first level comments of top stories and trigger GetComment request to get info about them   
            (storyProcessed, commentsInStory) <- if storiesProcessedAcc < numberOfStories 
                then processCommentsFromStory storyResChanR
                else return (0, 0)

            -- Read a comment. 
            -- Note: There's something wrong on HackerNews API. Sometimes it returns a NULL value as a comment 
            -- for a valid comment. See a detail explanation in HackerNews.HttpWorker.readComment  
            mcomment <- liftIO $ atomically $ readTChan commentResChan
            logDebug $ "commentAggregator - Processing comment: " <> show mcomment 

            -- Update state  
            let commentsAcc'         = if isJust mcomment then succ commentsAcc else commentsAcc
                subCommentIds        = maybe [] cCommentIds mcomment
                aggQueue'            = maybe aggQueue (\Comment{cBy} -> updateAggQueue cBy aggQueue) mcomment
                pendingCommentsAcc'  = pendingCommentsAcc + length subCommentIds + commentsInStory - 1 
                storiesProcessedAcc' = storiesProcessedAcc + storyProcessed 

            -- Trigger request GetComment to get the info about comments kids
            forM_ subCommentIds $ \id_ -> do 
                liftIO $ atomically $ writeTChan itemReqChan $ GetComment id_ 
                logDebug $ "commentAggregator - Triggered request GetComment: " <> show id_

            if pendingCommentsAcc' == 0 
                then do 
                    when (storiesProcessedAcc' /= numberOfStories) $ do
                        logError $ "commentAggregator - This should not happen: potential bug"
                            <> show aggQueue' 
                            <> show storiesProcessedAcc' 
                            <> show pendingCommentsAcc' 
                            <> show commentsAcc'
                        throwError $ ShouldNeverHappen "storiesProcessedAcc' /= numberOfStories" 

                    logInfo $ "Number of stories processed: " <> show storiesProcessedAcc'
                    logInfo $ "Number of comments processed: " <> show commentsAcc'
                    logInfo $ "Number of unique users in comments: " <> show (PSQ.size aggQueue)
                    logInfo "processComments - Aggregation done :)"
                    return $ Right (takeTopNames numberOfTopNames aggQueue, commentsAcc')
                else do
                    logDebug $ 
                        format "commentAggregator - final storiesProcessedAcc: {0}, pendingCommentsAcc: {1}, commentsAcc: {2}" 
                        [show storiesProcessedAcc', show pendingCommentsAcc', show commentsAcc']

                    return $ Left (aggQueue', storiesProcessedAcc', pendingCommentsAcc', commentsAcc')

-- queue -- 

type NumberOfCommentsCounter = Down NumberOfComments
type AggQueue = PSQ Name NumberOfCommentsCounter

initialAggQueue :: AggQueue
initialAggQueue = PSQ.empty

updateAggQueue :: Name -> AggQueue -> AggQueue
updateAggQueue = PSQ.alter f 
    where f Nothing         = Just (Down 1)
          f (Just (Down n)) = Just $ Down (n + 1)

takeTopNames :: Int -> AggQueue -> [(Name, NumberOfComments)]
takeTopNames n aggQueue = take n $ filter deleted $ getDown' . toTuple <$> unfoldr PSQ.minView aggQueue
    where toTuple binding   = (PSQ.key binding, PSQ.prio binding)
          getDown'          = Bi.second getDown
          deleted (name, _) = name /= ""         -- comment with name (by) "" indicates a comment deleted or anonymous (not sure)  
          