module Main where

import Control.Concurrent.MVar
import Control.Monad

import Disruptor.SP.Unboxed.Consumer
import Disruptor.SP.Unboxed.Producer
import Disruptor.SP.Unboxed.RingBuffer
import Disruptor.SequenceNumber
import Common

------------------------------------------------------------------------

main :: IO ()
main = spsc setup producer consumer
  where
    setup :: IO (RingBuffer Int)
    setup = newRingBuffer bUFFER_CAPACITY

    producer :: RingBuffer Int -> IO ()
    producer rb = go iTERATIONS
      where
        go :: Int -> IO ()
        go 0 = return ()
        go n = do
          mSnr <- tryNext rb
          case mSnr of
            Some snr -> do
              -- NOTE: Measuring transactions, which is useful for calculating
              -- latency, seriously slows down the benchmark.

              -- {-# SCC "transactions+1" #-} incrCounter_ 1 transactions
              set rb snr vALUE_TO_WRITE
              publish rb snr
              go (n - 1)
            None -> do
              -- threadDelay sLEEP_TIME
              go n

    consumer :: RingBuffer Int -> MVar () -> IO ()
    consumer rb consumerFinished = do
      let handler _s _n snr endOfBatch = do
            -- t' <- {-# SCC "transactions-1" #-} decrCounter 1 transactions
            -- measureInt_ t' histo
            when (endOfBatch && getSequenceNumber snr == fromIntegral (iTERATIONS - 1)) $
              putMVar consumerFinished ()
            return ()
      ec <- newEventConsumer rb handler () [] (Sleep sLEEP_TIME)
      setGatingSequences rb [ecSequenceNumber ec]
      ecWorker ec ()
