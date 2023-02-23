{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

-- Inspired by:
--   * https://github.com/jberryman/unagi-chan/blob/master/src/Data/Atomics/Counter/Fat.hs
--   * https://hackage.haskell.org/package/atomic-primops-0.8.4/docs/src/Data.Atomics.Counter.html
--   * https://hackage.haskell.org/package/unboxed-ref-0.4.0.0/docs/src/Data-STRef-Unboxed-Internal.html#STRefU
--   * https://hackage.haskell.org/package/ghc-8.10.2/docs/src/FastMutInt.html#FastMutInt

module Disruptor.AtomicCounterPadded
    ( AtomicCounter()
    , newCounter
    , incrCounter
    , incrCounter_
    , getAndIncrCounter
    , decrCounter
    , decrCounter_
    , readCounter
    , casCounter
    ) where

import Data.Bits (finiteBitSize)
import GHC.Exts
import GHC.Types

------------------------------------------------------------------------

data AtomicCounter = AtomicCounter !(MutableByteArray# RealWorld)

sIZEOF_CACHELINE :: Int
sIZEOF_CACHELINE = 64
{-# INLINE sIZEOF_CACHELINE #-}
-- ^ TODO: See
-- https://github.com/NickStrupat/CacheLineSize/blob/93a57c094f71a2796714f7a28d74dd8776149193/CacheLineSize.c
-- for how to get the cache line size on Windows, MacOS and Linux.

-- | Create a new atomic counter padded with 64-bytes (an x86 cache line) to try
-- to avoid false sharing.
newCounter :: Int -> IO AtomicCounter
newCounter (I# n) = IO $ \s ->
  case newAlignedPinnedByteArray# size alignment s of
    (# s', arr #) -> case writeIntArray# arr 0# n s' of
      s'' -> (# s'', AtomicCounter arr #)
  where
    !(I# size)      = finiteBitSize (0 :: Int)
    !(I# alignment) = sIZEOF_CACHELINE
{-# INLINE newCounter #-}

incrCounter :: Int -> AtomicCounter -> IO Int
incrCounter (I# incr) (AtomicCounter arr) = IO $ \s ->
  case fetchAddIntArray# arr 0# incr s of
    (# s', i #) -> (# s', I# (i +# incr) #)
{-# INLINE incrCounter #-}

getAndIncrCounter :: Int -> AtomicCounter -> IO Int
getAndIncrCounter (I# incr) (AtomicCounter arr) = IO $ \s ->
  case fetchAddIntArray# arr 0# incr s of
    (# s', i #) -> (# s', I# i #)
{-# INLINE getAndIncrCounter #-}

incrCounter_ :: Int -> AtomicCounter -> IO ()
incrCounter_ (I# incr) (AtomicCounter arr) = IO $ \s ->
  case fetchAddIntArray# arr 0# incr s of
    (# s', _i #) -> (# s', () #)
{-# INLINE incrCounter_ #-}

decrCounter :: Int -> AtomicCounter -> IO Int
decrCounter (I# decr) (AtomicCounter arr) = IO $ \s ->
  case fetchSubIntArray# arr 0# decr s of
    (# s', i #) -> (# s', I# (i -# decr) #)
{-# INLINE decrCounter #-}

decrCounter_ :: Int -> AtomicCounter -> IO ()
decrCounter_ (I# decr) (AtomicCounter arr) = IO $ \s ->
  case fetchSubIntArray# arr 0# decr s of
    (# s', _i #) -> (# s', () #)
{-# INLINE decrCounter_ #-}

readCounter :: AtomicCounter -> IO Int
readCounter (AtomicCounter arr) = IO $ \s ->
  case readIntArray# arr 0# s of
    (# s', i #) -> (# s', I# i #)
{-# INLINE readCounter #-}

casCounter :: AtomicCounter -> Int -> Int -> IO Bool
casCounter (AtomicCounter arr) (I# old) (I# new) = IO $ \s ->
  case casIntArray# arr 0# old new s of
    (# s', before #) -> case before ==# old of
      1# -> (# s', True #)
      0# -> (# s', False #)
{-# INLINE casCounter #-}
