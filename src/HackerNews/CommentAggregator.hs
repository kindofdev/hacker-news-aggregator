{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module HackerNews.CommentAggregator 
    ( commentAggregator ) where

import Control.Concurrent.STM.TChan ( dupTChan, readTChan, writeTChan )
import Control.Monad.Except         ( MonadIO(liftIO) )         
import Control.Monad.Extra          ( forM_, loopM )                                          
import Control.Monad.Reader         ( MonadReader(ask) )         
import Control.Monad.STM            ( atomically )                        
import qualified Data.Bifunctor     as Bi
import Data.List                    ( unfoldr )     
import Data.Ord                     ( Down(..) )                       
import Data.PSQueue                 ( PSQ )                   
import qualified Data.PSQueue       as PSQ
import Text.Format                  ( format )         

import HackerNews.Logger            ( logDebug, logInfo )            
import HackerNews.Types
    ( Comment(Comment, cCommentIds, cBy),
      Env(Env, httpConfig, logLevel, loggerChan, commentResChan,
          storyResChan, itemReqChan, numberOfTopNames, numberOfStories,
          numberOfHttpClients),
      HackerNewsM,
      ItemReq(GetComment),
      Name,
      NumberOfComments,
      Result(AggregatorResult),
      Story(Story, sCommentIds, sId) )

commentAggregator :: HackerNewsM Result
commentAggregator = do 
    logInfo "commentAggregator - Starting ..."
    (topNames, totalComments) <- getTopNamesAndTotalComments
    logInfo "commentAggregator - Aggregation done"
    return $ AggregatorResult topNames totalComments

-- Note: This might have been implemented using 'StateT IO a' instead of loopM
getTopNamesAndTotalComments :: HackerNewsM ([(Name, NumberOfComments)], NumberOfComments) 
getTopNamesAndTotalComments = do
    Env{..}                  <- ask
    numberOfTopLevelComments <- collectTopLevelCommentsFromStories
    flip loopM (initialAggQueue, numberOfTopLevelComments, numberOfTopLevelComments) $ \(aggQueue, pendingCommentsAcc, commentsAcc) -> do
        logDebug $ 
            format "getTopNamesAndTotalComments - initial: aggQueue size: {0}, pendingCommentsAcc: {1}, commentsAcc: {2}" 
            [show (PSQ.size aggQueue), show pendingCommentsAcc, show commentsAcc]

        -- Read a comment. 
        -- Note: There's something wrong on HackerNews API. Sometimes it returns a NULL value as a comment 
        -- for a valid comment. See a detail explanation in HackerNews.HttpWorker.readComment
        mcomment <- liftIO $ atomically $ readTChan commentResChan
        logDebug $ "getTopNamesAndTotalComments - Processing comment: " <> show mcomment 

        -- Update state  
        let subCommentIds       = maybe [] cCommentIds mcomment
            commentsAcc'        = succ commentsAcc
            aggQueue'           = maybe aggQueue (\Comment{cBy} -> updateAggQueue cBy aggQueue) mcomment
            pendingCommentsAcc' = pendingCommentsAcc + length subCommentIds - 1 

        -- Trigger request GetComment to get the info about comments kids
        forM_ subCommentIds $ \id_ -> do 
            liftIO $ atomically $ writeTChan itemReqChan $ GetComment id_ 
            logDebug $ "getTopNamesAndTotalComments - Triggered request GetComment: " <> show id_

        if pendingCommentsAcc' == 0 
            then do 
                logInfo $ "getTopNamesAndTotalComments - Number of stories processed: " <> show numberOfStories 
                logInfo $ "getTopNamesAndTotalComments - Number of comments processed: " <> show commentsAcc'
                logInfo $ "getTopNamesAndTotalComments - Number of unique users in comments: " <> show (PSQ.size aggQueue)
                return $ Right (takeTopNames numberOfTopNames aggQueue, commentsAcc')
            else do
                logDebug $ 
                    format "getTopNamesAndTotalComments - initial: aggQueue size: {0}, pendingCommentsAcc: {1}, commentsAcc: {2}" 
                    [show (PSQ.size aggQueue'), show pendingCommentsAcc', show commentsAcc']
                return $ Left (aggQueue', pendingCommentsAcc', commentsAcc')

collectTopLevelCommentsFromStories :: HackerNewsM NumberOfComments
collectTopLevelCommentsFromStories = do
    Env{..}       <- ask
    storyResChanR <- liftIO $ atomically $ dupTChan storyResChan
    flip loopM (0, 0) $ \(storiesProcessedAcc, commentsAcc) -> do 
        mstory  <- liftIO $ atomically $ readTChan storyResChanR
        case mstory of 
            Nothing                      -> return $ Left (storiesProcessedAcc, commentsAcc) 
            Just (_, Story{sCommentIds, sId}) -> do
                forM_ sCommentIds $ liftIO . atomically . writeTChan itemReqChan . GetComment
                logDebug $ format "collectTopLevelCommentsFromStories - Collected and triggered {0} top-level comments from story {1}" 
                            [show sCommentIds, show sId]
                
                let storiesProcessedAcc' = succ storiesProcessedAcc
                    commentsAcc'         = commentsAcc + length sCommentIds

                if storiesProcessedAcc' == numberOfStories
                    then do
                        logInfo $ 
                            format "collectTopLevelCommentsFromStories - Collected {0} top level comments from the top {1} stories" 
                            [show commentsAcc', show numberOfStories]
                        return $ Right commentsAcc' 
                    else return $ Left (storiesProcessedAcc', commentsAcc')
    

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
          