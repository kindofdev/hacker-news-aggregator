module HackerNews.Utils
    ( withAsyncMany 
    , tupleToList
    ) where

import Control.Concurrent.Async ( withAsync, Async )     

withAsyncMany :: [IO t] -> ([Async t] -> IO b) -> IO b
withAsyncMany []     f = f []
withAsyncMany (t:ts) f = withAsync t $ \a -> withAsyncMany ts (f . (a:))

tupleToList :: (a, a) -> [a]
tupleToList (x, y) = [x, y]