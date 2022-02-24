{-# LANGUAGE RecordWildCards #-}
module HackerNews.TopStoriesManager 
    ( topStoriesManager
    ) where

import Control.Concurrent.STM.TChan ( dupTChan, readTChan, writeTChan )
import Control.Monad.Extra          ( forM_, when, loopM )            
import Control.Monad.STM            ( atomically )
import Data.Maybe                   ( isJust, isNothing, fromJust)
import Data.List                    ( sort )

import HackerNews.Logger            ( logDebug, logInfo, logWarn, logError )
import HackerNews.Types
    ( Env(..),
      Story(sTitle),
      StoryId,
      Result(TopStoriesResult),
      ItemReq(GetStory),
      StoryIndex,
      IndexedStory,
      StoryResChan )
import HackerNews.HttpWorker        ( topStories )

type StoryIdsReserve = [(StoryIndex, StoryId)]

topStoriesManager :: Env -> IO Result
topStoriesManager Env{..} = do
    storyResChanR <- atomically $ dupTChan storyResChan

    mstoryIds     <- topStories
    when (isNothing mstoryIds) $ do
        let errorMsg = "topStoriesManager - No stories obtained: Canceling execution"
        logError loggerChan errorMsg
        fail errorMsg

    let storyIds = fromJust mstoryIds -- safe
        (storyIdsToCheck, storyIdsReserve) = splitAt numberOfStories storyIds

    forM_ storyIdsToCheck $ \(index, itemId) -> atomically $ writeTChan itemReqChan $ GetStory index itemId 
    logDebug loggerChan $ 
        "topStoriesManager - Triggered initial requests GetStory: " <> show storyIdsToCheck
    logDebug loggerChan $ 
        "topStoriesManager - Keep a reserve of storyIds for the case when any of the storyIdsToCheck is not a story: " 
        <> show (take 30 storyIdsReserve)

    stories <- fmap snd . sort <$> collectStoryItems storyIdsReserve storyResChanR
    logDebug loggerChan $ "topStoriesManager - Stories collected " <> show (length stories)

    logInfo loggerChan "topStoriesManager - Done, returning results"
    return $ TopStoriesResult $ sTitle <$> stories

  where
    -- Note: This might have been implemented using 'StateT IO a' instead of loopM
    collectStoryItems :: StoryIdsReserve -> StoryResChan -> IO [IndexedStory]
    collectStoryItems initialStoryIdsReserve storyResChanR = do 
        logDebug loggerChan $ "storyIdsReserve init contains: " <> show initialStoryIdsReserve
        flip loopM (0, [], initialStoryIdsReserve) $ \(n, stories, storyIdsReserve) -> do
            mindexStory <- atomically $ readTChan storyResChanR
            logDebug loggerChan $ "collectStoryItems - Checking item " <> show mindexStory

            let isStory           = isJust mindexStory
                idsQueueExhausted = null storyIdsReserve
                (n', stories')    = maybe (n, stories) (\(index, story) -> (n + 1, (index, story) : stories)) mindexStory
            
            storyIdsReserve' <- if isStory || idsQueueExhausted
                then do 
                    when idsQueueExhausted $ logWarn loggerChan "collectStoryItems - storyIdsReserve exhausted"
                    return storyIdsReserve
                else do
                    logDebug loggerChan $ "storyIdsReserve contains: " <> show storyIdsReserve
                    let (storyIndex_, storyId_) = head storyIdsReserve
                    atomically $ writeTChan itemReqChan $ GetStory storyIndex_ storyId_ 
                    logDebug loggerChan $ 
                        "collectStoryItems - Extracted story from storyIdsReserve and triggered request GetStory: " 
                        <> show (storyId_, storyIndex_)

                    return $ tail storyIdsReserve

            return $ if n' == numberOfStories || idsQueueExhausted
                    then Right stories'
                    else Left (n', stories', storyIdsReserve')
