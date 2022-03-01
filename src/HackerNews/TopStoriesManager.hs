{-# LANGUAGE RecordWildCards #-}
module HackerNews.TopStoriesManager 
    ( topStoriesManager
    ) where

import Control.Concurrent.STM.TChan ( dupTChan, readTChan, writeTChan )
import Control.Monad.Except         ( forM_, when, MonadIO(liftIO) )
import Control.Monad.Extra          ( loopM )               
import Control.Monad.Reader         ( MonadReader(ask) )         
import Control.Monad.STM            ( atomically )
import Data.Maybe                   ( isJust )                   
import Data.List                    ( sort )

import HackerNews.Logger ( logDebug, logInfo, logWarn )            
import HackerNews.Types
    ( Env(Env, httpConfig, logLevel, loggerChan, commentResChan,
          storyResChan, itemReqChan, numberOfTopNames, numberOfStories,
          numberOfWorkers),
      Story(sTitle),
      StoryId,
      Result(TopStoriesResult),
      ItemReq(GetStory),
      StoryIndex,
      IndexedStory,
      StoryResChan,
      HackerNewsM )
import HackerNews.HttpWorker        ( topStories )

type StoryIdsReserve = [(StoryIndex, StoryId)]

topStoriesManager :: HackerNewsM Result
topStoriesManager = do
    logInfo "topStoriesManager - Starting ..."
    Env{..}       <- ask

    storyResChanR <- liftIO $ atomically $ dupTChan storyResChan
    storyIds     <- topStories

    let (storyIdsToCheck, storyIdsReserve) = splitAt numberOfStories storyIds

    forM_ storyIdsToCheck $ \(index, itemId) -> liftIO $ atomically $ writeTChan itemReqChan $ GetStory index itemId 
    logDebug $ "topStoriesManager - Triggered initial requests GetStory: " <> show storyIdsToCheck
    logDebug $ "topStoriesManager - Keep a reserve of storyIds for the case when any of the storyIdsToCheck is not a story: " 
             <> show (take 30 storyIdsReserve)

    stories <- fmap snd . sort <$> collectStoryItems storyIdsReserve storyResChanR
    logDebug $ "topStoriesManager - Stories collected " <> show (length stories)

    logInfo "topStoriesManager - Done, returning results"
    return $ TopStoriesResult $ sTitle <$> stories

  where
    -- Note: This might have been implemented using 'StateT IO a' instead of loopM
    collectStoryItems :: StoryIdsReserve -> StoryResChan -> HackerNewsM [IndexedStory]
    collectStoryItems initialStoryIdsReserve storyResChanR = do 
        Env{..}       <- ask
        logDebug $ "storyIdsReserve init contains: " <> show initialStoryIdsReserve
        flip loopM (0, [], initialStoryIdsReserve) $ \(n, stories, storyIdsReserve) -> do
            mindexStory <- liftIO $ atomically $ readTChan storyResChanR
            logDebug $ "collectStoryItems - Checking item " <> show mindexStory

            let isStory           = isJust mindexStory
                idsQueueExhausted = null storyIdsReserve
                (n', stories')    = maybe (n, stories) (\(index, story) -> (n + 1, (index, story) : stories)) mindexStory
            
            storyIdsReserve' <- if isStory || idsQueueExhausted
                then do 
                    when idsQueueExhausted $ logWarn "collectStoryItems - storyIdsReserve exhausted"
                    return storyIdsReserve
                else do
                    logDebug $ "storyIdsReserve contains: " <> show storyIdsReserve
                    let (storyIndex_, storyId_) = head storyIdsReserve
                    liftIO $ atomically $ writeTChan itemReqChan $ GetStory storyIndex_ storyId_ 
                    logDebug $ "collectStoryItems - Extracted story from storyIdsReserve and triggered request GetStory: " 
                             <> show (storyId_, storyIndex_)

                    return $ tail storyIdsReserve

            return $ if n' == numberOfStories || idsQueueExhausted
                    then Right stories'
                    else Left (n', stories', storyIdsReserve')
