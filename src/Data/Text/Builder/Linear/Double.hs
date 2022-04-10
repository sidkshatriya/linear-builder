-- |
-- Copyright:   (c) 2022 Andrew Lelechenko
-- Licence:     BSD3
-- Maintainer:  Andrew Lelechenko <andrew.lelechenko@gmail.com>

module Data.Text.Builder.Linear.Double
  ( (|>%)
  , (%<|)
  ) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Builder.Internal as BBI
import qualified Data.Text.Array as A
import Data.Word
import GHC.Exts
import GHC.ForeignPtr
import GHC.IO
import GHC.Ptr
import GHC.ST

import Data.Text.Builder.Linear.Core

-- | Append double.
(|>%) :: Buffer ⊸ Double -> Buffer
infixl 6 |>%
buffer |>% x = appendBounded
  maxDblLen
  (\dst dstOff -> unsafeAppendDouble dst dstOff x)
  buffer

-- | Prepend double
(%<|) :: Double -> Buffer ⊸ Buffer
infixr 6 %<|
x %<| buffer = prependBounded
  maxDblLen
  (\dst dstOff -> unsafePrependDouble dst dstOff x)
  (\dst dstOff -> unsafeAppendDouble dst dstOff x)
  buffer

unsafeAppendDouble :: A.MArray s -> Int -> Double -> ST s Int
unsafeAppendDouble dst !dstOff !x = do
  let (fp, !srcLen) = runDoubleBuilder x
  unsafeIOToST $ unsafeWithForeignPtr fp $ \(Ptr addr#) ->
    unsafeSTToIO $ A.copyFromPointer dst dstOff (Ptr addr#) srcLen
  pure srcLen

unsafePrependDouble :: A.MArray s -> Int -> Double -> ST s Int
unsafePrependDouble dst !dstOff !x = do
  let (fp, !srcLen) = runDoubleBuilder x
  unsafeIOToST $ unsafeWithForeignPtr fp $ \(Ptr addr#) ->
    unsafeSTToIO $ A.copyFromPointer dst (dstOff - srcLen) (Ptr addr#) srcLen
  pure srcLen

runDoubleBuilder :: Double -> (ForeignPtr Word8, Int)
runDoubleBuilder =
  unsafeDupablePerformIO . buildStepToFirstChunk . BBI.runBuilder . BB.doubleDec
{-# INLINE runDoubleBuilder #-}

buildStepToFirstChunk :: BBI.BuildStep a -> IO (ForeignPtr Word8, Int)
buildStepToFirstChunk = \step -> BBI.newBuffer maxDblLen >>= fill step
  where
    fill !step (BBI.Buffer fpbuf br) = do
      let doneH op' _ = pure $ (fpbuf, op' `minusPtr` unsafeForeignPtrToPtr fpbuf)
          fullH _ _ nextStep = BBI.newBuffer maxDblLen >>= fill nextStep
      res <- BBI.fillWithBuildStep step doneH fullH undefined br
      touchForeignPtr fpbuf
      return res

maxDblLen :: Int
maxDblLen = 23 -- length (show (- pi * 1746e300 :: Double))