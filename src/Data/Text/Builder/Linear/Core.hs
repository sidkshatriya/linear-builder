-- |
-- Copyright:   (c) 2022 Andrew Lelechenko
-- Licence:     BSD3
-- Maintainer:  Andrew Lelechenko <andrew.lelechenko@gmail.com>
--
-- Low-level routines for 'Buffer' manipulations.

module Data.Text.Builder.Linear.Core
  ( -- * Buffer
    Buffer
  , runBuffer
  , dupBuffer
  , appendBounded
  , appendExact
  , prependBounded
  , prependExact
  , (><)
  , liftText
  ) where

import qualified Data.Text as T
import Data.Text.Array (Array(..), MArray(..))
import qualified Data.Text.Array as A
import Data.Text.Internal (Text(..))
import GHC.Exts
import GHC.ST

-- | Internally 'Buffer' is a mutable buffer.
-- If a client gets hold of a variable of type 'Buffer',
-- they'd be able to pass a mutable buffer to concurrent threads.
-- That's why API below is carefully designed to prevent such possibility:
-- clients always work with linear functions 'Buffer' ⊸ 'Buffer' instead
-- and run them on an empty 'Buffer' to extract results.
--
-- >>> :set -XOverloadedStrings -XLinearTypes
-- >>> runBuffer (\b -> '!' .<| "foo" <| (b |> "bar" |>. '.'))
-- "!foobar."
--
-- Remember: this is a strict builder, so on contrary to 'Data.Text.Lazy.Builder.Buffer'
-- for optimal performance you should use strict left folds instead of lazy right ones.
--
#if MIN_VERSION_base(4,16,0)
data Buffer :: TYPE ('BoxedRep 'Unlifted) where
#else
data Buffer where
#endif
  Buffer :: {-# UNPACK #-} !Text -> Buffer

-- | Unwrap 'Buffer', no-op.
-- Most likely, this is not the function you're looking for
-- and you need 'runBuffer' instead.
unBuffer ∷ Buffer ⊸ Text
unBuffer (Buffer x) = x

-- | Run a linear function on an empty 'Buffer', producing 'Text'.
--
-- Be careful to write @runBuffer (\b -> ...)@ instead of @runBuffer $ \b -> ...@,
-- because current implementation of linear types lacks special support for '($)'.
-- Alternatively, you can import @Prelude.Linear.($)@ from @linear-base@.
--
runBuffer ∷ (Buffer ⊸ Buffer) ⊸ Text
runBuffer f = unBuffer (f (Buffer mempty))

-- | Duplicate builder. Feel free to process results in parallel threads.
--
-- It is a bit tricky to use because of
-- <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/linear_types.html#limitations current limitations>
-- of linear types with regards to @let@ and @where@. E. g., one cannot write
--
-- > let (# b1, b2 #) = dupBuffer b in ("foo" <| b1) >< (b2 |> "bar")
--
-- Instead write:
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XUnboxedTuples
-- >>> runBuffer (\b -> (\(# b1, b2 #) -> ("foo" <| b1) >< (b2 |> "bar")) (dupBuffer b))
-- "foobar"
--
dupBuffer ∷ Buffer ⊸ (# Buffer, Buffer #)
dupBuffer (Buffer x) = (# Buffer x, Buffer (T.copy x) #)

-- | Low-level routine to append data of unknown size to a 'Buffer'.
appendBounded
  :: Int
  -- ^ Upper bound for the number of bytes, written by an action
  -> (forall s. MArray s -> Int -> ST s Int)
  -- ^ Action, which writes bytes starting from the given offset
  -- and returns an actual number of bytes written.
  -> Buffer
  ⊸ Buffer
appendBounded maxSrcLen appender (Buffer (Text dst dstOff dstLen)) = Buffer $ runST $ do
  let dstFullLen = sizeofByteArray dst
      newFullLen = dstOff + 2 * (dstLen + maxSrcLen)
  newM ← if dstOff + dstLen + maxSrcLen <= dstFullLen
    then unsafeThaw dst
    else do
      tmpM ← A.new newFullLen
      A.copyI dstLen tmpM dstOff dst dstOff
      pure tmpM
  srcLen ← appender newM (dstOff + dstLen)
  new ← A.unsafeFreeze newM
  pure $ Text new dstOff (dstLen + srcLen)
{-# INLINE appendBounded #-}

-- | Low-level routine to append data of known size to a 'Buffer'.
appendExact
  :: Int
  -- ^ Exact number of bytes, written by an action
  -> (forall s. MArray s -> Int -> ST s ())
  -- ^ Action, which writes bytes starting from the given offset
  -> Buffer
  ⊸ Buffer
appendExact srcLen appender = appendBounded
  srcLen
  (\dst dstOff -> appender dst dstOff >> pure srcLen)
{-# INLINE appendExact #-}

-- | Low-level routine to prepend data of unknown size to a 'Buffer'.
prependBounded
  :: Int
  -- ^ Upper bound for the number of bytes, written by an action
  -> (forall s. MArray s -> Int -> ST s Int)
  -- ^ Action, which writes bytes finishing before the given offset
  -- and returns an actual number of bytes written.
  -> (forall s. MArray s -> Int -> ST s Int)
  -- ^ Action, which writes bytes starting from the given offset
  -- and returns an actual number of bytes written.
  -> Buffer
   ⊸ Buffer
prependBounded maxSrcLen prepender appender (Buffer (Text dst dstOff dstLen))
  | maxSrcLen <= dstOff = Buffer $ runST $ do
    newM ← unsafeThaw dst
    srcLen ← prepender newM dstOff
    new ← A.unsafeFreeze newM
    pure $ Text new (dstOff - srcLen) (srcLen + dstLen)
  | otherwise = Buffer $ runST $ do
    let dstFullLen = sizeofByteArray dst
        newOff = dstLen + maxSrcLen
        newFullLen = 2 * newOff + (dstFullLen - dstOff - dstLen)
    newM ← A.new newFullLen
    srcLen ← appender newM newOff
    A.copyI dstLen newM (newOff + srcLen) dst dstOff
    new ← A.unsafeFreeze newM
    pure $ Text new newOff (dstLen + srcLen)
{-# INLINE prependBounded #-}

-- | Low-level routine to append data of unknown size to a 'Buffer'.
prependExact
  :: Int
  -- ^ Exact number of bytes, written by an action
  -> (forall s. MArray s -> Int -> ST s ())
  -- ^ Action, which writes bytes finishing before the given offset
  -> Buffer
  ⊸ Buffer
prependExact srcLen appender = prependBounded
  srcLen
  (\dst dstOff -> appender dst (dstOff - srcLen) >> pure srcLen)
  (\dst dstOff -> appender dst dstOff >> pure srcLen)
{-# INLINE prependExact #-}

unsafeThaw ∷ Array → ST s (MArray s)
unsafeThaw (ByteArray a) = ST $ \s# →
  (# s#, MutableByteArray (unsafeCoerce# a) #)

sizeofByteArray :: Array -> Int
sizeofByteArray (ByteArray a) = I# (sizeofByteArray# a)

-- | Concatenate two 'Buffer's, potentially mutating both of them.
--
-- You likely need to use 'dupBuffer' to get hold on two builders at once:
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XUnboxedTuples
-- >>> runBuffer (\b -> (\(# b1, b2 #) -> ("foo" <| b1) >< (b2 |> "bar")) (dupBuffer b))
-- "foobar"
--
(><) ∷ Buffer ⊸ Buffer ⊸ Buffer
infix 6 ><
Buffer (Text left leftOff leftLen) >< Buffer (Text right rightOff rightLen) = Buffer $ runST $ do
  let leftFullLen = sizeofByteArray left
      rightFullLen = sizeofByteArray right
      canCopyToLeft = leftOff + leftLen + rightLen <= leftFullLen
      canCopyToRight = leftLen <= rightOff
      shouldCopyToLeft = canCopyToLeft && (not canCopyToRight || leftLen >= rightLen)
  if shouldCopyToLeft then do
    newM ← unsafeThaw left
    A.copyI rightLen newM (leftOff + leftLen) right rightOff
    new ← A.unsafeFreeze newM
    pure $ Text new leftOff (leftLen + rightLen)
  else if canCopyToRight then do
    newM ← unsafeThaw right
    A.copyI leftLen newM (rightOff - leftLen) left leftOff
    new ← A.unsafeFreeze newM
    pure $ Text new (rightOff - leftLen) (leftLen + rightLen)
  else do
    let fullLen = leftOff + leftLen + rightLen + (rightFullLen - rightOff - rightLen)
    newM ← A.new fullLen
    A.copyI leftLen newM leftOff left leftOff
    A.copyI rightLen newM (leftOff + leftLen) right rightOff
    new ← A.unsafeFreeze newM
    pure $ Text new leftOff (leftLen + rightLen)

-- | Lift a linear function on 'Text' to 'Buffer's.
-- This is not very useful at the moment, because @text@ does not provide
-- any linear functions at all.
liftText ∷ (Text ⊸ Text) → (Buffer ⊸ Buffer)
liftText f (Buffer x) = Buffer (f x)
