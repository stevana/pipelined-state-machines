{-# LANGUAGE ExistentialQuantification #-} -- XXX

module Disruptor.MP.Consumer where

import Control.Concurrent.Async
import Control.Concurrent
import Control.Concurrent.STM -- XXX
import Data.IORef

import Disruptor.SequenceNumber
import Disruptor.MP.RingBuffer

------------------------------------------------------------------------

data EventConsumer s = EventConsumer
  { ecSequenceNumber :: {-# UNPACK #-} !(IORef SequenceNumber)
  , ecWorker         :: s -> IO s
  , ecInitialState   :: s
  }

-- NOTE: The `SequenceNumber` can be used for sharding, e.g. one handler handles
-- even and another handles odd numbers.
type EventHandler s e = s -> e -> SequenceNumber -> EndOfBatch -> IO s
type EndOfBatch = Bool

data SequenceBarrier e
  = RingBufferBarrier (RingBuffer e)
  | forall s. EventConsumerBarrier (EventConsumer s)

data WaitStrategy = Sleep Int

withEventConsumer :: EventConsumer s -> (Async s -> IO a) -> IO a
withEventConsumer ec k = withAsync (ecWorker ec (ecInitialState ec)) $ \a -> do
  link a
  k a

withEventConsumerOn :: Int -> EventConsumer s -> (Async s -> IO a) -> IO a
withEventConsumerOn capability ec k =
  withAsyncOn capability (ecWorker ec (ecInitialState ec)) $ \a -> do
    link a
    k a

newEventConsumer :: RingBuffer e -> EventHandler s e -> s -> [SequenceBarrier e]
                 -> WaitStrategy -> IO (EventConsumer s)
newEventConsumer rb handler s0 _barriers ws = do
  snrRef <- newIORef (-1)

  let go s = {-# SCC go #-} do
        mySnr <- readIORef snrRef
        bSnr <- waitFor mySnr rb ws -- XXX: barriers
        -- XXX: what if handler throws exception? https://youtu.be/eTeWxZvlCZ8?t=2271
        s' <- {-# SCC go' #-} go' (mySnr + 1) bSnr s
        writeIORef snrRef bSnr
        go s'
        where
          go' lo hi s | lo >  hi = return s
                      | lo <= hi = do
            e <- get rb lo
            s' <- {-# SCC handler #-} handler s e lo (lo == hi)
            go' (lo + 1) hi s'

  return (EventConsumer snrRef go s0)

waitFor :: SequenceNumber -> RingBuffer e -> WaitStrategy -> IO SequenceNumber
waitFor consumed rb (Sleep n) = go
  where
    go = do
      claimedSequence <- getCursor rb
      if consumed < claimedSequence
      -- `claimedSequence` may be much higher than the the capacity of the ring
      -- buffer, so we need to guarantee that every consumer makes batches that
      -- are at most `rbCapacity rb` big.
      then return (min claimedSequence (consumed + fromIntegral (rbCapacity rb)))
      else do
        -- NOTE: Removing the sleep seems to cause non-termination... XXX: Why
        -- though? the consumer should be running on its own thread?
        -- yield
        threadDelay n
        go -- SPIN
        --
        -- XXX: Other wait strategies could be implemented here, e.g. we could
        -- try to recurse immediately here, and if there's no work after a
        -- couple of tries go into a takeMTVar sleep waiting for a producer to
        -- wake us up.
{-# INLINE waitFor #-}
