{-# LANGUAGE RecordWildCards #-}
module HackerNews.Logger 
    (  logger
    , logDebug
    , logInfo
    , logWarn
    , logError
    , logResult
    ) where

import Control.Concurrent.STM.TChan ( readTChan, writeTChan ) 
import Control.Monad                ( forever, when )                
import Control.Monad.STM            ( atomically )
import Text.Format                  (format)

import HackerNews.Types
    ( Env(..), LogLevel(RESULT, DEBUG, INFO, WARN, ERROR), LoggerChan )

logger :: Env -> IO ()
logger Env{..} = forever $ do 
    (level, str) <- atomically $ readTChan loggerChan
    when (level >= logLevel) $ putStrLn str 

logDebug :: LoggerChan -> String -> IO ()
logDebug loggerChan str = atomically $ writeTChan loggerChan (DEBUG, format "[{0}] {1}" [show DEBUG, str])

logInfo :: LoggerChan -> String -> IO ()
logInfo loggerChan str = atomically $ writeTChan loggerChan (INFO, format "[{0}] {1}" [show INFO, str])

logWarn :: LoggerChan -> String -> IO ()
logWarn loggerChan str = atomically $ writeTChan loggerChan (WARN, format "[{0}] {1}" [show WARN, str])

logError :: LoggerChan -> String -> IO ()
logError loggerChan str = atomically $ writeTChan loggerChan (ERROR, format "[{0}] {1}" [show ERROR, str])

logResult :: LoggerChan -> String -> IO ()
logResult loggerChan str = atomically $ writeTChan loggerChan (RESULT, format "[{0}] {1}" [show RESULT, str])
