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
import Control.Monad.Reader         ( MonadIO(liftIO), asks )
          
import Control.Monad.STM            ( atomically )
import Text.Format                  (format)

import HackerNews.Types
    ( Env(logLevel, loggerChan),
      HackerNewsM,
      LogLevel(RESULT, DEBUG, INFO, WARN, ERROR) )

logger :: HackerNewsM ()
logger = forever $ do 
    loggerChan'  <- asks loggerChan
    logLevel'    <- asks logLevel 
    (level, str) <- liftIO $ atomically $ readTChan loggerChan'
    when (level >= logLevel') $ liftIO $ putStrLn str 

logDebug :: String -> HackerNewsM ()
logDebug str = do 
    loggerChan' <- asks loggerChan
    liftIO $ atomically $ writeTChan loggerChan' (DEBUG, format "[{0}] {1}" [show DEBUG, str])

logInfo :: String -> HackerNewsM ()
logInfo str = do 
    loggerChan' <- asks loggerChan
    liftIO $ atomically $ writeTChan loggerChan' (INFO, format "[{0}] {1}" [show INFO, str])

logWarn :: String -> HackerNewsM ()
logWarn str = do 
    loggerChan' <- asks loggerChan
    liftIO $ atomically $ writeTChan loggerChan' (WARN, format "[{0}] {1}" [show WARN, str])

logError :: String -> HackerNewsM ()
logError str = do 
    loggerChan' <- asks loggerChan
    liftIO $ atomically $ writeTChan loggerChan' (ERROR, format "[{0}] {1}" [show ERROR, str])

logResult :: String -> HackerNewsM ()
logResult str = do 
    loggerChan' <- asks loggerChan
    liftIO $ atomically $ writeTChan loggerChan' (RESULT, format "[{0}] {1}" [show RESULT, str])              
