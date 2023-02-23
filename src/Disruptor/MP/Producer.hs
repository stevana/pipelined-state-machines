module Disruptor.MP.Producer where

import Control.Concurrent.Async

import Disruptor.MP.RingBuffer
import Disruptor.SequenceNumber

------------------------------------------------------------------------

data EventProducer s = EventProducer
  { epWorker       :: s -> IO s
  , epInitialState :: s
  }

newEventProducer :: RingBuffer e -> (s -> IO (e, s)) -> (s -> IO ()) -> s
                 -> IO (EventProducer s)
newEventProducer rb p backPressure s0 = do
  let go s = {-# SCC go #-} do
        mSnr <- tryNext rb
        case mSnr of
          None -> do
            {-# SCC backPresure #-} backPressure s
            go s
          Some snr -> do
            (e, s') <- {-# SCC p #-} p s
            set rb snr e
            publish rb snr
            go s'

  return (EventProducer go s0)

withEventProducer :: EventProducer s -> (Async s -> IO a) -> IO a
withEventProducer ep k = withAsync (epWorker ep (epInitialState ep)) $ \a -> do
  link a
  k a

withEventProducerOn :: Int -> EventProducer s -> (Async s -> IO a) -> IO a
withEventProducerOn capability ep k =
  withAsyncOn capability (epWorker ep (epInitialState ep)) $ \a -> do
    link a
    k a
