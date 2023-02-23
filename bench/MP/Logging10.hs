{-# LANGUAGE NumericUnderscores #-}

module Main where

import Control.Concurrent
import Control.Monad (when)
import Data.ByteString.Char8 (ByteString)
import Data.ByteString.Builder
import qualified Data.ByteString.Char8 as BS
import System.IO


import Disruptor.MP
import Common hiding (nUMBER_OF_PRODUCERS, iTERATIONS)

------------------------------------------------------------------------

iTERATIONS = 1_000_000

nUMBER_OF_PRODUCERS :: Int
nUMBER_OF_PRODUCERS = 10

lOG_MESSAGE :: ByteString
lOG_MESSAGE = BS.pack "some random string to log\n"

lOG_FILE :: FilePath
lOG_FILE = "/tmp/pipelined-state-machines-bench-mp-logger10.log"

data Buffer = Buffer
  { bufferCapacity :: !Int
  , bufferSize     :: !Int
  , buffer         :: !Builder
  }

newBuffer :: Int -> Buffer
newBuffer capacity = Buffer capacity 0 (byteString (BS.pack ""))

hasCapacityBuffer :: ByteString -> Buffer -> Bool
hasCapacityBuffer bs buf = bufferSize buf + BS.length bs <= bufferCapacity buf

appendBuffer :: ByteString -> Buffer -> Buffer
appendBuffer bs buf =
  buf { bufferSize = bufferSize buf + BS.length bs
      , buffer     = buffer buf <> byteString bs
      }

flushBuffer :: Buffer -> Handle -> IO Buffer
flushBuffer buf h = do
  hPutBuilder h (buffer buf)
  return (newBuffer (bufferCapacity buf))

main :: IO ()
main = m10psc setup producer consumer
  where
    setup = do
      cleanup lOG_FILE
      newRingBuffer bUFFER_CAPACITY

    producer :: RingBuffer ByteString -> IO ()
    producer rb = go iTERATIONS
      where
        go :: Int -> IO ()
        go 0 = return ()
        go n = do
          mSnr <- tryNext rb
          case mSnr of
            Some snr -> do
              set rb snr lOG_MESSAGE
              publish rb snr
              go (n - 1)
            None ->
              -- NOTE: No sleep needed here.
              go n

    consumer :: RingBuffer ByteString -> MVar () -> IO Buffer
    consumer rb consumerFinished = do
      h <- openFile lOG_FILE WriteMode
      hSetBinaryMode h True
      hSetBuffering h (BlockBuffering (Just 4096))
      let handler buf bs snr endOfBatch = do
            buf' <- if hasCapacityBuffer bs buf -- XXX: we can probably do
                                                -- better here by only flushing
                                                -- at `endOfBatch`?
            then return (appendBuffer bs buf)
            else do
              buf' <- flushBuffer buf h
              return (appendBuffer bs buf')
            when (endOfBatch &&
                  getSequenceNumber snr ==
                  fromIntegral (iTERATIONS * nUMBER_OF_PRODUCERS - 1)) $ do
              flushBuffer buf' h
              hFlush h
              putMVar consumerFinished ()
            return buf'
      ec <- newEventConsumer rb handler (newBuffer bUFFER_CAPACITY) [] (Sleep sLEEP_TIME)
      setGatingSequences rb [ecSequenceNumber ec]
      ecWorker ec (ecInitialState ec)
