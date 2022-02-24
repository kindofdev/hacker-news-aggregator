module HackerNews.Cli 
    ( parseArgsIO
    , InputParams (..) 
    ) where

import System.Environment (getArgs)
import Text.Read ( readEither )

import HackerNews.Types
    ( LogLevel,
      NumberOfCores,
      ParallelismFactor,
      NumberOfTopNames,
      NumberOfStories )

data InputParams = InputParams
    { ipNumberOfCores     :: NumberOfCores
    , ipParallelismFactor :: ParallelismFactor
    , ipNumberOfStories   :: NumberOfStories
    , ipNumberOfTopNames  :: NumberOfTopNames
    , ipLogLevel          :: LogLevel
    } deriving Show

parseArgsIO :: IO InputParams
parseArgsIO = do 
    args <- getArgs
    case parseArgs args of
        Left errorMsg -> fail errorMsg
        Right ip      -> return ip

-- cabal run cardashift-challenge -- 8 8 30 10 INFO
-- <numberOfCores> <parallelismFactor> <numberOfStories> <numberOfTopNames> <logLevel>
parseArgs :: [String] -> Either String InputParams
parseArgs [cores, k, stories, names, level] = do 
    cores'   <- readEither cores   :: Either String NumberOfCores
    k'       <- readEither k       :: Either String ParallelismFactor
    stories' <- readEither stories :: Either String NumberOfStories
    names'   <- readEither names   :: Either String NumberOfTopNames
    level'   <- readEither level   :: Either String LogLevel
    pure $ InputParams
        { ipNumberOfCores     = cores'
        , ipParallelismFactor = k'
        , ipNumberOfStories   = stories'
        , ipNumberOfTopNames  = names'
        , ipLogLevel          = level'
        }

parseArgs _ = error "The CLI args could not be parsed" 