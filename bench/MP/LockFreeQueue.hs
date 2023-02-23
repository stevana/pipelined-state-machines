module Main where

import Control.Monad
import Data.Concurrent.Queue.MichaelScott
import Control.Concurrent.MVar

import Common

------------------------------------------------------------------------

main :: IO ()
main = mpsc setup producer consumer
  where
    setup = newQ

    producer q = replicateM_ iTERATIONS (pushL q vALUE_TO_WRITE)

    consumer q consumerFinished = do
      replicateM_ iTERATIONS $ do
        _i <- tryPopR q
        return ()
      putMVar consumerFinished ()
