{-# LANGUAGE FlexibleContexts #-}

module Main where

import Control.Concurrent.MVar
import Control.Monad
import Data.RingBuffer
import Data.Vector (Vector)

import Common

------------------------------------------------------------------------

main :: IO ()
main = spsc setup producer consumer
  where
    setup :: IO (RingBuffer Vector Int) -- NOTE: `IOVector` doesn't work?!
    setup = new bUFFER_CAPACITY

    producer rb = replicateM_ iTERATIONS (append vALUE_TO_WRITE rb)

    consumer rb consumerFinished = do
      replicateM_ iTERATIONS $ do
        _i <- latest rb 1
        return ()
      putMVar consumerFinished ()
