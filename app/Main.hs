{-# LANGUAGE RecordWildCards #-}
module Main where

import Control.Concurrent.Async       ( cancel, waitAny, withAsync, Async )     
import Control.Concurrent.STM.TChan   ( newBroadcastTChanIO, newTChanIO )
import Control.Exception.Safe         ( handleAny )
import Control.Monad                  ( forM_ , void)                             
import Control.Monad.Reader           ( MonadIO(liftIO), MonadReader(ask) )
import GHC.IO.Encoding                ( setLocaleEncoding, utf8 )
import Network.HTTP.Req               ( defaultHttpConfig )
import Text.Format                    ( format )
  
import HackerNews.Cli                 ( InputParams (..), parseArgsIO )
import HackerNews.CommentAggregator   ( commentAggregator )
import HackerNews.HttpClient          ( httpClient )
import HackerNews.Logger              ( logger, logError, logResult )            
import HackerNews.TopStoriesCollector ( topStoriesCollector ) 
import HackerNews.Types

import HackerNews.Utils                ( withAsyncMany )

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

    let numberOfHttpClients = ipNumberOfCores * ipParallelismFactor :: Int
        env = Env 
            { numberOfHttpClients = numberOfHttpClients
            , numberOfStories     = ipNumberOfStories
            , numberOfTopNames    = ipNumberOfTopNames
            , itemReqChan         = itemReqChan
            , storyResChan        = storyResChan   
            , commentResChan      = commentResChan
            , loggerChan          = loggerChan
            , logLevel            = ipLogLevel
            , httpConfig          = defaultHttpConfig
            }  

    withAsync (runHackerNewsM env logger) $ \ loggerA -> do 
        withAsync (runHackerNewsM env topStoriesCollector) $ \ storiesManagerA -> do
            withAsync (runHackerNewsM env commentAggregator) $ \ commentAggA -> do
                withAsyncMany (replicate numberOfHttpClients (runHackerNewsM env httpClient)) $ \ httpClientsA -> do
                    void $ runHackerNewsM env $ collectResults [storiesManagerA, commentAggA]
                    forM_ httpClientsA cancel
                    cancel loggerA

collectResults :: [Async (Either Error Result)] -> HackerNewsM ()
collectResults resultsA = do
    case resultsA of 
        [] -> return ()
        _  -> do (resultA, result) <- liftIO $ waitAny resultsA
                 printResult result
                 collectResults $ filter (/= resultA) resultsA

printResult :: Either Error Result -> HackerNewsM ()
printResult result = do 
    Env{..} <- ask
    case result of 
        Right (TopStoriesResult titles)                    -> do
            logResult separator
            logResult $ format "TOP {0} HACKER NEWS STORIES" [show numberOfStories]
            logResult separator
            forM_ titles logResult
            logResult separator
            
        Right (AggregatorResult topNames numberOfComments) -> do
            logResult separator
            logResult $ format "TOTAL NUMBER OF COMMENTS FOR THE TOP {0} STORIES" [show numberOfStories]
            logResult separator
            logResult $ show numberOfComments
            logResult separator
            logResult $ format "TOP {0} COMMENTER NAMES FOR THE TOP {1} STORIES" [show numberOfTopNames, show numberOfStories]
            logResult separator
            forM_ topNames (logResult . show)
            logResult separator
        Left error_                                        -> do  
            logError $ "Main - A managed error ocurred: " <> show error_

separator :: String 
separator = replicate 90 '-'
