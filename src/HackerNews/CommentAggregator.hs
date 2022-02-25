{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

module HackerNews.CommentAggregator 
    ( commentAggregator ) where

import Control.Concurrent.STM.TChan ( dupTChan, readTChan, writeTChan )
import Control.Monad.Extra          ( forM_, when, loopM )                   
import Control.Monad.STM            ( atomically )                        
import qualified Data.Bifunctor     as Bi
import Data.List                    ( unfoldr )     
import Data.Maybe                   ( fromJust, isNothing )                  
import Data.Ord                     ( Down(..) )                       
import Data.PSQueue                 ( PSQ )                   
import qualified Data.PSQueue       as PSQ
import Text.Format                  ( format )                  

import HackerNews.Logger            ( logDebug, logInfo, logError )
import HackerNews.Types
    ( Env(..),
      Comment(Comment, cDeleted, cCommentIds, cBy, cId),
      Story(Story, sCommentIds, sTotalComments, sBy, sTitle, sId),
      NumberOfComments,
      NumberOfStories,
      Name,
      Result(AggregatorResult),
      ItemReq(GetComment),
      StoryResChan 
    )

commentAggregator :: Env -> IO Result
commentAggregator Env{..} = do 
    storyResChanR             <- atomically $ dupTChan storyResChan
    (topNames, totalComments) <- processComments storyResChanR
    
    logInfo loggerChan "commentAggregator - Aggregation done"
    return $ AggregatorResult topNames totalComments
  where
    processCommentsFromStory :: StoryResChan -> IO (NumberOfStories, NumberOfComments) 
    processCommentsFromStory storyResChanR = do
        mstory <- atomically $ readTChan storyResChanR
        case mstory of 
            Nothing             -> return (0, 0) 
            Just (_, Story{..}) -> do
                forM_ sCommentIds $ atomically . writeTChan itemReqChan . GetComment
                logDebug loggerChan $
                    format "commentAggregator - Triggered {0} GetComment requests for story {1}" 
                    [show sCommentIds, show sId]

                forM_ sCommentIds $ \cId -> 
                    logDebug loggerChan $ "commentAggregator (from story) - Triggered request GetComment: " <> show cId    
                    
                return $ (1, length sCommentIds)
    
    -- Note: This might have been implemented using 'StateT IO a' instead of loopM
    processComments :: StoryResChan -> IO ([(Name, NumberOfComments)], NumberOfComments)
    processComments storyResChanR  = 
        flip loopM (initialAggQueue, 0, 0, 0) $ \(aggQueue, storiesProcessedAcc, pendingCommentsAcc, commentsAcc) -> do
            logDebug loggerChan $ 
                format "commentAggregator - initial storiesProcessedAcc: {0}, pendingCommentsAcc: {1}, commentsAcc: {2}" 
                [show storiesProcessedAcc, show pendingCommentsAcc, show commentsAcc]
            
            -- Story processing: Get first level comments of top stories and trigger GetComment request to get info about them   
            (storyProcessed, commentsInStory) <- if storiesProcessedAcc < numberOfStories 
                then processCommentsFromStory storyResChanR
                else return (0, 0)

            -- Read a comment. 
            -- Note: There's something wrong on HackerNews API. Sometimes it returns a NULL value as a comment 
            -- for a valid comment. See a detail explanation in HackerNews.HttpWorker.readComment  
            mcomment <- atomically $ readTChan commentResChan

            when (isNothing mcomment) $ do 
                let errorMsg = "commentAggregator - HackerNews API error : HN returned a NULL value for a comment request"
                logError loggerChan errorMsg
                logError loggerChan "commentAggregator - Canceling execution"
                fail errorMsg
            
            let Comment{..} = fromJust mcomment -- safe
            logDebug loggerChan $ "commentAggregator - Processing comment: " <> show cId 
            
            -- Trigger request GetComment to get the info about comments kids
            forM_ cCommentIds $ \id_ -> do 
                atomically $ writeTChan itemReqChan $ GetComment id_ 
                logDebug loggerChan $ "commentAggregator - Triggered request GetComment: " <> show id_
              
            -- Update state  
            let storiesProcessedAcc' = storiesProcessedAcc + storyProcessed
                commentsAcc'         = succ commentsAcc
                aggQueue'            = updateAggQueue cBy aggQueue
                pendingCommentsAcc'  = pendingCommentsAcc + length cCommentIds + commentsInStory - 1 
            
            if pendingCommentsAcc' == 0 
                then do 
                    when (storiesProcessedAcc' /= numberOfStories) $ 
                        fail $  "This should not happen: potential bug" 
                        <> show aggQueue' 
                        <> show storiesProcessedAcc' 
                        <> show pendingCommentsAcc' 
                        <> show commentsAcc'

                    logInfo loggerChan $ "Number of stories processed: " <> show storiesProcessedAcc'
                    logInfo loggerChan $ "Number of comments processed: " <> show commentsAcc'
                    logInfo loggerChan $ "Number of unique users in comments: " <> show (PSQ.size aggQueue)
                    logInfo loggerChan "processComments - Aggregation done :)"
                    return $ Right (takeTopNames numberOfTopNames aggQueue, commentsAcc')
                else do
                    logDebug loggerChan $ 
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
          