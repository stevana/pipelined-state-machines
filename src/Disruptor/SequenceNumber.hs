{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Disruptor.SequenceNumber where

import Data.Bits (countLeadingZeros, finiteBitSize, unsafeShiftR, (.&.))
import Data.Int (Int64)

------------------------------------------------------------------------

newtype SequenceNumber = SequenceNumber { getSequenceNumber :: Int64 }
  deriving newtype (Num, Eq, Ord, Real, Enum, Integral, Show, Bounded)
-- ^ NOTE: `(maxBound :: Int64) == 9223372036854775807` so if we write 10M events
-- per second (`10_000_000*60*60*24*365 == 315360000000000) then it would take
-- us `9223372036854775807 / 315360000000000 == 29247.1208677536` years before
-- we overflow.

-- > quickCheck $ \(Positive i) j -> let capacity = 2^i in
--     j `mod` capacity == j Data.Bits..&. (capacity - 1)
index :: Int64 -> SequenceNumber -> Int
index capacity (SequenceNumber i) = fromIntegral (i .&. indexMask)
  where
    indexMask = capacity - 1
{-# INLINE index #-}

availabilityFlag :: Int64 -> SequenceNumber -> Int
availabilityFlag capacity (SequenceNumber i) =
  fromIntegral (i `unsafeShiftR` indexShift)
  where
    indexShift = logBase2 capacity
{-# INLINE availabilityFlag #-}

-- Taken from:
-- https://hackage.haskell.org/package/base-4.15.0.0/docs/Data-Bits.html#v:countLeadingZeros
logBase2 :: Int64 -> Int
logBase2 i = finiteBitSize i - 1 - countLeadingZeros i
{-# INLINE logBase2 #-}

data MaybeSequenceNumber = None | Some {-# UNPACK #-} !SequenceNumber
  deriving (Eq, Show)
-- ^ TODO: compare with: https://hackage.haskell.org/package/unpacked-maybe-text-0.1.0.0/docs/src/Data.Maybe.Unpacked.Text.Short.html#MaybeShortText
