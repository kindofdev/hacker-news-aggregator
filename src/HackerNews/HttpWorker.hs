{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module HackerNews.HttpWorker 
    ( topStories 
    , httpWorker
    ) where

import Control.Monad.Extra          ( forever )                      
import Control.Monad.STM            ( atomically )
import Control.Concurrent.STM.TChan ( readTChan, writeTChan )    
import Control.Exception            ( catch )
import Data.Text                    ( pack )
import Network.HTTP.Req
    ( (/:),
      defaultHttpConfig,
      https,
      jsonResponse,
      req,
      responseBody,
      runReq,
      GET(GET),
      HttpException,
      NoReqBody(NoReqBody) )

import HackerNews.Logger            ( logDebug ) 
import HackerNews.Types
    ( Env(..),
      Comment,
      Story,
      CommentId,
      StoryId,
      ItemReq(GetComment, GetStory),
      StoryIndex(..) )
   
httpWorker :: Env -> IO ()
httpWorker Env{..} = forever $ do
    itemReq <- atomically $ readTChan itemReqChan
    case itemReq of
        -- storyId might belong to either a story or a job. 
        -- storyIds collected from service /v0/topstories.json which return stories and jobs. 
        -- See docs: "Up to 500 top and new stories are at /v0/topstories (also contains jobs)"
        GetStory storyIndex storyId -> do  
            logDebug loggerChan $ "httpWorker - Processing GetStory req for storyId: " <> show storyId
            mstory    <- readStory storyId
            atomically $ writeTChan storyResChan $ (storyIndex, ) <$> mstory
            logDebug loggerChan $ "httpWorker - Processed GetStory req for storyId: " <> show storyId
        GetComment commentId        -> do  
            logDebug loggerChan $ "httpWorker - Processing GetComment req for storyId: " <> show commentId
            mcomment  <- readComment commentId
            atomically $ writeTChan commentResChan mcomment
            logDebug loggerChan $ "httpWorker - Processed GetComment req for storyId: " <> show commentId

topStories :: IO (Maybe [(StoryIndex, StoryId)])
topStories = do 
  mstories <- topStories' 
  return $ zip [StoryIndex 1 ..] <$> mstories

-- hacker-news topstories service return itemIds for stories and jobs
-- Return Nothing if an error occurs  
topStories' :: IO (Maybe [StoryId])
topStories' = tryMaybe $runReq defaultHttpConfig $ do 
    v <- req GET (https "hacker-news.firebaseio.com" /: "v0" /: "topstories.json") NoReqBody jsonResponse mempty
    return $ responseBody v

-- itemId might belong to a story or a job (caller gets itemId from a call to topStories)
-- In case parsing fails return Nothing indicating upstream that it is not a story. 
readStory :: StoryId -> IO (Maybe Story)
readStory id_ = tryMaybe $ runReq defaultHttpConfig $ do 
    let id' = pack $ show id_ <> ".json"
    v <- req GET (https "hacker-news.firebaseio.com" /: "v0" /: "item" /: id') NoReqBody jsonResponse mempty
    return $ responseBody v 

-- Note: it should always be a comment but HackerNews API every now and then return a null. 
-- It's pretty weird since the same execution a bit later with exactly same number of comments 
-- return a proper comment. The decision has been to return Nothing so that upstream aggregator
-- knows what has happened and cancel aggregation. Otherwise, it will miss a comment and then
-- will raise an error "blocked indefinitely in an STM transaction"     
readComment :: CommentId -> IO (Maybe Comment)
readComment id_ = tryMaybe $ runReq defaultHttpConfig $ do 
    let id' = pack $ show id_ <> ".json"
    v <- req GET (https "hacker-news.firebaseio.com" /: "v0" /: "item" /: id') NoReqBody jsonResponse mempty
    return $ responseBody v     

tryMaybe :: IO a -> IO (Maybe a)  -- Maybe this is not idiomatic using Aeson/Req
tryMaybe m = (Just <$> m) `catch` 
    \ (_ :: HttpException) -> do return Nothing



