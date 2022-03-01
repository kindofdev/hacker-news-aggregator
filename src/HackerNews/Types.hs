{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# LANGUAGE OverloadedStrings           #-}
module HackerNews.Types where

import Control.Monad.Reader         ( MonadIO, unless, ReaderT(..), MonadReader )
import Control.Concurrent           ( MVar )
import Control.Concurrent.STM.TChan ( TChan )

import Data.Aeson
    ( FromJSON(parseJSON),
      (.!=),
      (.:),
      (.:?),
      withObject,
      Value(String) )


-- the monad --

newtype HackerNewsM a = HackerNewsM { run :: ReaderT Env IO a }
                      deriving (Functor, Applicative, Monad, MonadIO, MonadReader Env)

runHackerNewsM :: Env -> HackerNewsM a -> IO a
runHackerNewsM env m = runReaderT (run m) env


-- channels --

type ItemReqChan        = TChan ItemReq
type StoryResChan       = TChan (Maybe IndexedStory)
type CommentResChan     = TChan (Maybe Comment)
type ResultChan         = MVar Result
type LoggerChan         = TChan (LogLevel, String)

type IndexedStory  = (StoryIndex, Story)
newtype StoryIndex = StoryIndex Int
                     deriving (Eq, Show, Ord, Enum)

data ItemReq = GetStory StoryIndex StoryId
             | GetComment CommentId
             deriving (Eq, Show)

-- results --

type TopNames = [(Name, NumberOfComments)]

data Result = TopStoriesResult [Title]
            | AggregatorResult TopNames NumberOfComments
            deriving (Eq, Show)

-- data --

type StoryId          = Integer
type CommentId        = Integer
type Title            = String
type Name             = String
type NumberOfComments = Int

data Story = Story
    { sId            :: StoryId            -- id
    , sTitle         :: Title              -- title
    , sBy            :: Name               -- by
    , sTotalComments :: NumberOfComments   -- descendants 
    , sCommentIds    :: [CommentId]        -- kids, when the story doesn't have comments "kids" doesn't exist
    } deriving (Eq, Show, Ord)

instance FromJSON Story where
  parseJSON = withObject "item" $ \o -> do
    (String type') <- o .: "type"
    unless (type' == "story") $ fail "Story expected"
    id_            <- o .:  "id"
    title          <- o .:  "title"
    by             <- o .:  "by"
    descendants    <- o .:  "descendants"
    kids           <- o .:? "kids" .!= []
    return $ Story id_ title by descendants kids

data Comment = Comment
    { cId         :: CommentId    -- id
    , cBy         :: Name         -- by, when comment has been deleted "by" doesn't exist
    , cCommentIds :: [CommentId]  -- kids, when the comment doesn't have sub-comments "kids" doesn't exist
    , cDeleted    :: Bool         -- deleted, when the comment doesn't has been deleted "deleted" doesn't exist
    } deriving (Eq, Show)

instance FromJSON Comment where
  parseJSON = withObject "item" $ \o -> do
    (String type') <- o .: "type"
    unless (type' == "comment") $ fail "Comment expected"
    id_         <- o .:  "id"
    by          <- o .:? "by" .!= ""
    kids        <- o .:? "kids" .!= []
    deleted     <- o .:? "deleted" .!= False
    return $ Comment id_ by kids deleted

-- env --

type NumberOfStories   = Int
type NumberOfTopNames  = Int
type NumberOfWorkers   = Int
type ParallelismFactor = Int
type NumberOfCores     = Int

data LogLevel = DEBUG
              | INFO
              | WARN
              | ERROR
              | RESULT
              deriving (Eq, Show, Ord, Read)

data Env = Env
    { numberOfWorkers  :: NumberOfWorkers
    , numberOfStories  :: NumberOfStories
    , numberOfTopNames :: NumberOfTopNames
    , itemReqChan      :: ItemReqChan
    , storyResChan     :: StoryResChan
    , commentResChan   :: CommentResChan
    , loggerChan       :: LoggerChan
    , logLevel         :: LogLevel
    }
