{-# LANGUAGE RecordWildCards #-}
module Main where

import Control.Concurrent.Async     ( cancel, waitAny, withAsync, Async )     
import Control.Concurrent.STM.TChan ( newBroadcastTChanIO, newTChanIO )
import Control.Exception.Safe       ( handleAny )
import Control.Monad                ( replicateM, forM_ )                
import GHC.IO.Encoding              ( setLocaleEncoding, utf8 )
import Text.Format                  ( format )

import HackerNews.Cli               ( InputParams (..), parseArgsIO )
import HackerNews.CommentAggregator ( commentAggregator )
import HackerNews.HttpWorker        ( httpWorker )
import HackerNews.Logger            ( logger, logInfo, logResult )
import HackerNews.TopStoriesManager ( topStoriesManager )
import HackerNews.Types
    ( Env(..),
      Result(..),
      LoggerChan,
      CommentResChan,
      StoryResChan,
      ItemReqChan )

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

    withAsync (logger env) $ \ loggerA -> do 
        withAsync (topStoriesManager env) $ \ storiesManagerA -> do
            withAsync (commentAggregator env) $ \ commentAggA -> do
                withAsyncMany (replicateM numberOfWorkers httpWorker env) $ \ workersA -> do
                    logInfo loggerChan "Running ..."
                    collectResults env [storiesManagerA, commentAggA]
                    logInfo loggerChan "DONE" 
                    forM_ workersA cancel
                    cancel loggerA

collectResults :: Env -> [Async Result] -> IO ()
collectResults env resultsA 
    | null resultsA = return ()
    | otherwise     = do
        (resultA, result) <- waitAny resultsA
        printResult env result
        collectResults env $ filter (/= resultA) resultsA

printResult :: Env -> Result -> IO ()
printResult Env{..} result = case result of 
    TopStoriesResult titles -> do
        logResult loggerChan separator
        logResult loggerChan $ format "TOP {0} HACKER NEWS STORIES" [show numberOfStories]
        logResult loggerChan separator
        forM_ titles (logResult loggerChan)
        logResult loggerChan separator
        
    AggregatorResult topNames numberOfComments -> do
        logResult loggerChan separator
        logResult loggerChan $ format "TOTAL NUMBER OF COMMENTS FOR THE TOP {0} STORIES" [show numberOfStories]
        logResult loggerChan separator
        logResult loggerChan $ show numberOfComments
        logResult loggerChan separator
        logResult loggerChan $ format "TOP {0} COMMENTER NAMES FOR THE TOP {1} STORIES" [show numberOfTopNames, show numberOfStories]
        logResult loggerChan separator
        forM_ topNames (logResult loggerChan . show)
        logResult loggerChan separator

separator :: String 
separator = replicate 90 '-'
