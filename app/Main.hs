{-# LANGUAGE RecordWildCards #-}
module Main where

import Control.Concurrent.Async     ( cancel, waitAny, withAsync, Async )     
import Control.Concurrent.STM.TChan ( newBroadcastTChanIO, newTChanIO )
import Control.Exception.Safe       ( handleAny )
import Control.Monad ( forM_ )                             
import Control.Monad.Reader ( MonadIO(liftIO), MonadReader(ask) )
import GHC.IO.Encoding              ( setLocaleEncoding, utf8 )
import Text.Format                  ( format )

import HackerNews.Cli               ( InputParams (..), parseArgsIO )
import HackerNews.CommentAggregator ( commentAggregator )
import HackerNews.HttpWorker        ( httpWorker )
import HackerNews.Logger            ( logger, logInfo, logResult )
import HackerNews.TopStoriesManager ( topStoriesManager )
import HackerNews.Types
    ( CommentResChan,
      Env(Env, logLevel, loggerChan, commentResChan, storyResChan,
          itemReqChan, numberOfTopNames, numberOfStories, numberOfWorkers),
      HackerNewsM,
      ItemReqChan,
      LoggerChan,
      Result(..),
      StoryResChan,
      runHackerNewsM )

import HackerNews.Utils ( withAsyncMany )

main :: IO ()   
main = handleAny (\ex -> putStrLn $ "Oops, an exception ocurred: " <> show ex) $ do 
    setLocaleEncoding utf8

    InputParams{..} <- parseArgsIO

    -- Writers: topStoriesManager + commentAggregator
    -- Readers: httpWorkers (working in parallel, broadcast not needed)
    itemReqChan    <- newTChanIO          :: IO ItemReqChan

    -- Writers: httpWorkers
    -- Readers: topStoriesManager + commentAggregator (both need to read every message => Broadcast channel)
    storyResChan   <- newBroadcastTChanIO :: IO StoryResChan 

    -- Writers: httpWorkers
    -- Reader: commentAggregator 
    commentResChan <- newTChanIO          :: IO CommentResChan

    -- Writers: all 
    -- Reader: logger 
    loggerChan     <- newTChanIO          :: IO LoggerChan

    let numberOfWorkers = ipNumberOfCores * ipParallelismFactor :: Int
        env = Env 
            { numberOfWorkers     = numberOfWorkers
            , numberOfStories     = ipNumberOfStories
            , numberOfTopNames    = ipNumberOfTopNames
            , itemReqChan         = itemReqChan
            , storyResChan        = storyResChan   
            , commentResChan      = commentResChan
            , loggerChan          = loggerChan
            , logLevel            = ipLogLevel
            }  

    withAsync (runHackerNewsM env logger) $ \ loggerA -> do 
        withAsync (runHackerNewsM env topStoriesManager) $ \ storiesManagerA -> do
            withAsync (runHackerNewsM env commentAggregator) $ \ commentAggA -> do
                withAsyncMany (replicate numberOfWorkers (runHackerNewsM env httpWorker)) $ \ workersA -> do
                    runHackerNewsM env $ logInfo "Running ..."
                    runHackerNewsM env $ collectResults [storiesManagerA, commentAggA]
                    runHackerNewsM env $ logInfo "DONE" 
                    forM_ workersA cancel
                    cancel loggerA

collectResults :: [Async Result] -> HackerNewsM ()
collectResults resultsA = do
    case resultsA of 
        [] -> return ()
        _  -> do (resultA, result) <- liftIO $ waitAny resultsA
                 printResult result
                 collectResults $ filter (/= resultA) resultsA

printResult :: Result -> HackerNewsM ()
printResult result = do 
    Env{..} <- ask
    case result of 
        TopStoriesResult titles -> do
            logResult separator
            logResult $ format "TOP {0} HACKER NEWS STORIES" [show numberOfStories]
            logResult separator
            forM_ titles logResult
            logResult separator
            
        AggregatorResult topNames numberOfComments -> do
            logResult separator
            logResult $ format "TOTAL NUMBER OF COMMENTS FOR THE TOP {0} STORIES" [show numberOfStories]
            logResult separator
            logResult $ show numberOfComments
            logResult separator
            logResult $ format "TOP {0} COMMENTER NAMES FOR THE TOP {1} STORIES" [show numberOfTopNames, show numberOfStories]
            logResult separator
            forM_ topNames (logResult . show)
            logResult separator

separator :: String 
separator = replicate 90 '-'
