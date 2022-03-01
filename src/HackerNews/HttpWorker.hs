{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module HackerNews.HttpWorker 
    ( topStories 
    , httpWorker
    ) where

import Control.Concurrent.STM.TChan ( readTChan, writeTChan )    
import Control.Monad.Except
    ( forever,
      when,
      MonadIO(liftIO),
      MonadError(catchError, throwError) )
import Control.Monad.Reader         ( MonadReader(ask) )
import Control.Monad.STM            ( atomically )
import Data.Maybe
import Data.Text                    ( pack )
import Network.HTTP.Req
    ( (/:),
      https,
      jsonResponse,
      req,
      responseBody,
      GET(GET),
      NoReqBody(NoReqBody) )

import HackerNews.Logger ( logDebug, logWarn )            
import HackerNews.Types
    ( Env(Env, httpConfig, logLevel, loggerChan, commentResChan,
          storyResChan, itemReqChan, numberOfTopNames, numberOfStories,
          numberOfWorkers),
      Comment,
      Story,
      CommentId,
      StoryId,
      ItemReq(GetComment, GetStory),
      StoryIndex(..),
      HackerNewsM,
      Error(NotFoundStories) )
   
httpWorker :: HackerNewsM ()
httpWorker = forever $ do
    Env{..}  <- ask
    itemReq <- liftIO $ atomically $ readTChan itemReqChan
    case itemReq of
        -- storyId might belong to either a story or a job. 
        -- storyIds collected from service /v0/topstories.json which return stories and jobs. 
        -- See docs: "Up to 500 top and new stories are at /v0/topstories (also contains jobs)"
        GetStory storyIndex storyId -> do  
            logDebug $ "httpWorker - Processing GetStory req for storyId: " <> show storyId
            mstory <- readStory storyId
            liftIO $ atomically $ writeTChan storyResChan $ (storyIndex, ) <$> mstory
            logDebug $ "httpWorker - Processed GetStory req for storyId: " <> show storyId
        GetComment commentId        -> do  
            logDebug $ "httpWorker - Processing GetComment req for commentId: " <> show commentId
            mcomment <- readComment commentId
            when (isNothing mcomment) $ do
                logWarn $ "httpWorker - Comment null with commentId: " <> show commentId 

            liftIO $ atomically $ writeTChan commentResChan mcomment
            logDebug $ "httpWorker - Processed GetComment req for commentId: " <> show commentId

topStories :: HackerNewsM [(StoryIndex, StoryId)]
topStories = flip catchError (\_ -> throwError NotFoundStories) $ zip [StoryIndex 1 ..] <$> do 
    v <- req GET (https "hacker-news.firebaseio.com" /: "v0" /: "topstories.json") NoReqBody jsonResponse mempty
    return $ responseBody v

-- itemId might belong to a story or a job (caller gets itemId from a call to topStories)
-- In case parsing fails return Nothing indicating upstream that it is not a story. 
readStory :: StoryId -> HackerNewsM (Maybe Story) 
readStory id_ = flip catchError (\_ -> return Nothing) $ Just <$> do 
    let id' = pack $ show id_ <> ".json"
    v <- req GET (https "hacker-news.firebaseio.com" /: "v0" /: "item" /: id') NoReqBody jsonResponse mempty
    return $ responseBody v 

-- Note: it should always be a comment but HackerNews API every now and then returns a null. 
-- It's pretty weird since the same execution a bit later with exactly same number of comments 
-- return a proper comment. For cases where HN API returns null, we return Nothing. 
readComment :: CommentId -> HackerNewsM (Maybe Comment) 
readComment id_ = flip catchError (\_ -> return Nothing) $ Just <$> do 
    let id' = pack $ show id_ <> ".json"
    v <- req GET (https "hacker-news.firebaseio.com" /: "v0" /: "item" /: id') NoReqBody jsonResponse mempty
    return $ responseBody v     
