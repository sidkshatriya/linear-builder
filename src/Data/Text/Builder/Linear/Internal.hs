-- |
-- Copyright:   (c) 2022 Andrew Lelechenko
--              (c) 2023 Pierre Le Marre
-- Licence:     BSD3
-- Maintainer:  Andrew Lelechenko <andrew.lelechenko@gmail.com>
--
-- Internal routines for t'Buffer' manipulations.
module Data.Text.Builder.Linear.Internal (
  -- * Type
  Buffer,

  -- * Basic interface
  runBuffer,
  runBufferBS,
  dupBuffer,
  consumeBuffer,
  eraseBuffer,
  byteSizeOfBuffer,
  lengthOfBuffer,
  dropBuffer,
  takeBuffer,
  newEmptyBuffer,

  -- * Text concatenation
  appendBounded,
  appendExact,
  prependBounded,
  prependBounded',
  appendBounded',
  prependExact,
  (><),
) where

import Data.ByteString.Internal (ByteString (..))
import Data.Text qualified as T
import Data.Text.Array qualified as A
import Data.Text.Internal (Text (..))
import GHC.Exts (Int (..), Levity (..), RuntimeRep (..), TYPE, byteArrayContents#, plusAddr#, unsafeCoerce#)
import GHC.ForeignPtr (ForeignPtr (..), ForeignPtrContents (..))
import GHC.ST (ST (..), runST)

import Data.Text.Builder.Linear.Array

-- | Internally t'Buffer' is a mutable buffer.
-- If a client gets hold of a variable of type t'Buffer',
-- they'd be able to pass a mutable buffer to concurrent threads.
-- That's why API below is carefully designed to prevent such possibility:
-- clients always work with linear functions t'Buffer' ⊸ t'Buffer' instead
-- and run them on an empty t'Buffer' to extract results.
--
-- In terms of [@linear-base@](https://hackage.haskell.org/package/linear-base)
-- t'Buffer' is [@Consumable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Consumable)
-- (see 'consumeBuffer')
-- and [@Dupable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Dupable)
-- (see 'dupBuffer'),
-- but not [@Movable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Movable).
--
-- >>> :set -XOverloadedStrings -XLinearTypes
-- >>> import Data.Text.Builder.Linear.Buffer
-- >>> runBuffer (\b -> '!' .<| "foo" <| (b |> "bar" |>. '.'))
-- "!foobar."
--
-- Remember: this is a strict builder, so on contrary to "Data.Text.Lazy.Builder"
-- for optimal performance you should use strict left folds instead of lazy right ones.
--
-- t'Buffer' is an unlifted datatype,
-- so you can put it into an unboxed tuple @(# ..., ... #)@,
-- but not into @(..., ...)@.
data Buffer ∷ TYPE ('BoxedRep 'Unlifted) where
  Buffer ∷ {-# UNPACK #-} !Text → Buffer

-- | Unwrap t'Buffer', no-op.
-- Most likely, this is not the function you're looking for
-- and you need 'runBuffer' instead.
unBuffer ∷ Buffer ⊸ Text
unBuffer (Buffer x) = x

-- | Run a linear function on an empty t'Buffer', producing a strict t'Text'.
--
-- Be careful to write @runBuffer (\\b -> ...)@ instead of @runBuffer $ \\b -> ...@,
-- because current implementation of linear types lacks special support for '($)'.
-- Another option is to enable @{-# LANGUAGE BlockArguments #-}@
-- and write @runBuffer \\b -> ...@.
-- Alternatively, you can import
-- [@($)@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#v:-36-)
-- from [@linear-base@](https://hackage.haskell.org/package/linear-base).
--
-- 'runBuffer' is similar in spirit to mutable arrays API in
-- [@Data.Array.Mutable.Linear@](https://hackage.haskell.org/package/linear-base/docs/Data-Array-Mutable-Linear.html),
-- which provides functions like
-- [@fromList@](https://hackage.haskell.org/package/linear-base/docs/Data-Array-Mutable-Linear.html#v:fromList) ∷ @Movable@ @b@ ⇒ [@a@] → (@Array@ @a@ ⊸ @b@) ⊸ @b@.
-- Here the initial buffer is always empty and @b@ is t'Text'.
runBuffer ∷ (Buffer ⊸ Buffer) ⊸ Text
runBuffer f = unBuffer (shrinkBuffer (f (Buffer mempty)))
{-# NOINLINE runBuffer #-}

{-
  See https://github.com/Bodigrim/linear-builder/issues/19
  and https://github.com/tweag/linear-base/pull/187#discussion_r489081926
  for the discussion why NOINLINE here and below in 'runBufferBS' is necessary.
  Without it CSE (common subexpression elimination) can pull out t'Buffer's from
  different 'runBuffer's and share them, which is absolutely not what we want.
-}

-- | Same as 'runBuffer', but returning a UTF-8 encoded strict 'ByteString'.
runBufferBS ∷ (Buffer ⊸ Buffer) ⊸ ByteString
runBufferBS f = case shrinkBuffer (f (Buffer memptyPinned)) of
  Buffer (Text (A.ByteArray arr) (I# from) len) → BS fp len
    where
      addr# = byteArrayContents# arr `plusAddr#` from
      fp = ForeignPtr addr# (PlainPtr (unsafeCoerce# arr))
{-# NOINLINE runBufferBS #-}

shrinkBuffer ∷ Buffer ⊸ Buffer
shrinkBuffer (Buffer (Text arr from len)) = Buffer $ runST $ do
  arrM ← unsafeThaw arr
  A.shrinkM arrM (from + len)
  arr' ← A.unsafeFreeze arrM
  pure $ Text arr' from len

memptyPinned ∷ Text
memptyPinned = runST $ do
  marr ← A.newPinned 0
  arr ← A.unsafeFreeze marr
  pure $ Text arr 0 0

-- | Create an empty t'Buffer'.
--
-- The first t'Buffer' is the input and the second is a new empty t'Buffer'.
--
-- This function is needed in some situations, e.g. with
-- 'Data.Text.Builder.Linear.Buffer.justifyRight'. The following example creates
-- a utility function that justify a text and then append it to a buffer.
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XUnboxedTuples
-- >>> import Data.Text.Builder.Linear.Buffer
-- >>> import Data.Text (Text)
-- >>> :{
-- appendJustified :: Buffer %1 -> Text -> Buffer
-- appendJustified b t = case newEmptyBuffer b of
--   -- Note that we need to create a new buffer from the text, in order
--   -- to justify only the text and not the input buffer.
--   (# b', empty #) -> b' >< justifyRight 12 ' ' (empty |> t)
-- :}
--
-- >>> runBuffer (\b -> (b |> "Test:") `appendJustified` "AAA" `appendJustified` "BBBBBBB")
-- "Test:         AAA     BBBBBBB"
--
-- Note: a previous buffer is necessary in order to create an empty buffer with
-- the same characteristics.
newEmptyBuffer ∷ Buffer ⊸ (# Buffer, Buffer #)
newEmptyBuffer (Buffer t@(Text arr _ _)) =
  (# Buffer t, Buffer (if isPinned arr then memptyPinned else mempty) #)

-- | Duplicate builder. Feel free to process results in parallel threads.
-- Similar to
-- [@Dupable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Dupable)
-- from [@linear-base@](https://hackage.haskell.org/package/linear-base).
--
-- It is a bit tricky to use because of
-- <https://downloads.haskell.org/ghc/9.8.1/docs/users_guide/exts/linear_types.html#limitations current limitations>
-- of linear types with regards to @let@ and @where@. E. g., one cannot write
--
-- > let (# b1, b2 #) = dupBuffer b in ("foo" <| b1) >< (b2 |> "bar")
--
-- Instead write:
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XUnboxedTuples
-- >>> import Data.Text.Builder.Linear.Buffer
-- >>> runBuffer (\b -> case dupBuffer b of (# b1, b2 #) -> ("foo" <| b1) >< (b2 |> "bar"))
-- "foobar"
--
-- Note the unboxed tuple: t'Buffer' is an unlifted datatype,
-- so it cannot be put into @(..., ...)@.
dupBuffer ∷ Buffer ⊸ (# Buffer, Buffer #)
dupBuffer (Buffer x) = (# Buffer x, Buffer (T.copy x) #)

-- | Consume buffer linearly,
-- similar to
-- [@Consumable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Consumable)
-- from [@linear-base@](https://hackage.haskell.org/package/linear-base).
consumeBuffer ∷ Buffer ⊸ ()
consumeBuffer Buffer {} = ()

-- | Erase buffer's content, replacing it with an empty t'Text'.
eraseBuffer ∷ Buffer ⊸ Buffer
eraseBuffer (Buffer (Text arr _ _)) =
  Buffer (if isPinned arr then memptyPinned else mempty)

-- | Return buffer's size in __bytes__ (not in 'Char's).
-- This could be useful to implement a lazy builder atop of a strict one.
byteSizeOfBuffer ∷ Buffer ⊸ (# Buffer, Word #)
byteSizeOfBuffer (Buffer t@(Text _ _ len)) = (# Buffer t, fromIntegral len #)

-- | Return buffer's length in 'Char's (not in bytes).
-- This could be useful to implement @dropEndBuffer@ and @takeEndBuffer@, e. g.,
--
-- @
-- import Data.Unrestricted.Linear
--
-- dropEndBuffer :: Word -> Buffer %1 -> Buffer
-- dropEndBuffer n buf = case lengthOfBuffer buf of
--   (# buf', len #) -> case move len of
--     Ur len' -> takeBuffer (len' - n) buf'
-- @
lengthOfBuffer ∷ Buffer ⊸ (# Buffer, Word #)
lengthOfBuffer (Buffer t) = (# Buffer t, fromIntegral (T.length t) #)

-- | Slice t'Buffer' by dropping given number of 'Char's.
dropBuffer ∷ Word → Buffer ⊸ Buffer
dropBuffer nChar (Buffer t@(Text arr off len))
  | nByte <= 0 = Buffer (Text arr (off + len) 0)
  | otherwise = Buffer (Text arr (off + nByte) (len - nByte))
  where
    nByte = T.measureOff (fromIntegral nChar) t

-- | Slice t'Buffer' by taking given number of 'Char's.
takeBuffer ∷ Word → Buffer ⊸ Buffer
takeBuffer nChar (Buffer t@(Text arr off _))
  | nByte <= 0 = Buffer t
  | otherwise = Buffer (Text arr off nByte)
  where
    nByte = T.measureOff (fromIntegral nChar) t

-- | Low-level routine to append data of unknown size to a t'Buffer'.
appendBounded
  ∷ Int
  -- ^ Upper bound for the number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s Int)
  -- ^ Action, which writes bytes __starting__ from the given offset
  -- and returns an actual number of bytes written.
  → Buffer
  ⊸ Buffer
appendBounded maxSrcLen appender (Buffer (Text dst dstOff dstLen)) = Buffer $ runST $ do
  let dstFullLen = sizeofByteArray dst
      newFullLen = dstOff + 2 * (dstLen + maxSrcLen)
  newM ←
    if dstOff + dstLen + maxSrcLen <= dstFullLen
      then unsafeThaw dst
      else do
        tmpM ← (if isPinned dst then A.newPinned else A.new) newFullLen
        A.copyI dstLen tmpM dstOff dst dstOff
        pure tmpM
  srcLen ← appender newM (dstOff + dstLen)
  new ← A.unsafeFreeze newM
  pure $ Text new dstOff (dstLen + srcLen)
{-# INLINE appendBounded #-}

-- | Low-level routine to append data of unknown size to a t'Buffer', giving
-- the action the choice between two strategies.
--
-- See also: 'appendBounded'.
--
-- @since 0.1.3
appendBounded'
  ∷ Int
  -- ^ Upper bound for the number of bytes, written by an action
  → (∀ s x. ((A.MArray s → Int → ST s Int) → ST s x) → ((A.MArray s → Int → ST s Int) → ST s x) → ST s x)
  -- ^ Action, which appends bytes using one of the following strategies:
  --
  -- * writes bytes __starting__ from the given offset, using its first argument,
  -- * writes bytes __finishing__ before the given offset, using its second argument.
  --
  -- The function passed to either argument returns the actual number of bytes written.
  → Buffer
  ⊸ Buffer
appendBounded' maxSrcLen writer (Buffer (Text dst dstOff dstLen)) = Buffer $ runST $ do
  let dstFullLen = sizeofByteArray dst
      newFullLen = dstOff + 2 * (dstLen + maxSrcLen)
  newM ←
    if dstOff + dstLen + maxSrcLen <= dstFullLen
      then unsafeThaw dst
      else do
        tmpM ← (if isPinned dst then A.newPinned else A.new) newFullLen
        A.copyI dstLen tmpM dstOff dst dstOff
        pure tmpM
  let append = \appender → do
        count ← appender newM (dstOff + dstLen)
        pure (dstOff, count)
  -- Action that prepends then copies the result to the final destination, if necessary
  let prepend = \prepender → case dstLen of
        0 → do
          -- Buffer is empty: prepend to final destination
          count ← prepender newM maxSrcLen
          pure (maxSrcLen - count, count)
        _ → do
          -- Require extra buffer + copy to final destination
          let off'
                -- Reuse space before current data (no overlap)
                | dstOff >= maxSrcLen = dstOff
                -- Reuse space after current data (overlap)
                | otherwise = dstOff + dstLen + maxSrcLen
          count ← prepender newM off'
          -- Note: we rely on copyM allowing overlaps
          A.copyM newM (dstOff + dstLen) newM (off' - count) count
          pure (dstOff, count)
  (dstOff', srcLen) ← writer append prepend
  new ← A.unsafeFreeze newM
  pure $ Text new dstOff' (dstLen + srcLen)
{-# INLINE appendBounded' #-}

-- | Low-level routine to append data of known size to a t'Buffer'.
appendExact
  ∷ Int
  -- ^ Exact number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s ())
  -- ^ Action, which writes bytes __starting__ from the given offset
  → Buffer
  ⊸ Buffer
appendExact srcLen appender =
  appendBounded
    srcLen
    (\dst dstOff → appender dst dstOff >> pure srcLen)
{-# INLINE appendExact #-}

-- | Low-level routine to prepend data of unknown size to a t'Buffer'.
prependBounded
  ∷ Int
  -- ^ Upper bound for the number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s Int)
  -- ^ Action, which writes bytes __finishing__ before the given offset
  -- and returns an actual number of bytes written.
  → (∀ s. A.MArray s → Int → ST s Int)
  -- ^ Action, which writes bytes __starting__ from the given offset
  -- and returns an actual number of bytes written.
  → Buffer
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
      newM ← (if isPinned dst then A.newPinned else A.new) newFullLen
      srcLen ← appender newM newOff
      A.copyI dstLen newM (newOff + srcLen) dst dstOff
      new ← A.unsafeFreeze newM
      pure $ Text new newOff (dstLen + srcLen)
{-# INLINE prependBounded #-}

-- | Low-level routine to prepend data of unknown size to a t'Buffer'.
--
-- Contrary to 'prependBounded', only use a prepend action.
--
-- @since 0.1.3
prependBounded'
  ∷ Int
  -- ^ Upper bound for the number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s Int)
  -- ^ Action, which writes bytes __finishing__ before the given offset
  -- and returns an actual number of bytes written.
  → Buffer
  ⊸ Buffer
prependBounded' maxSrcLen prepender (Buffer (Text dst dstOff dstLen))
  | maxSrcLen <= dstOff = Buffer $ runST $ do
      newM ← unsafeThaw dst
      srcLen ← prepender newM dstOff
      new ← A.unsafeFreeze newM
      pure $ Text new (dstOff - srcLen) (srcLen + dstLen)
  | otherwise = Buffer $ runST $ do
      let dstFullLen = sizeofByteArray dst
          off = dstLen + 2 * maxSrcLen
          newFullLen = off + (dstFullLen - dstOff)
      newM ← (if isPinned dst then A.newPinned else A.new) newFullLen
      srcLen ← prepender newM off
      A.copyI dstLen newM off dst dstOff
      new ← A.unsafeFreeze newM
      pure $ Text new (off - srcLen) (dstLen + srcLen)
{-# INLINE prependBounded' #-}

-- | Low-level routine to append data of known size to a t'Buffer'.
prependExact
  ∷ Int
  -- ^ Exact number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s ())
  -- ^ Action, which writes bytes __starting__ from the given offset
  → Buffer
  ⊸ Buffer
prependExact srcLen appender =
  prependBounded
    srcLen
    (\dst dstOff → appender dst (dstOff - srcLen) >> pure srcLen)
    (\dst dstOff → appender dst dstOff >> pure srcLen)
{-# INLINE prependExact #-}

-- | Concatenate two t'Buffer's, potentially mutating both of them.
--
-- You likely need to use 'dupBuffer' to get hold on two builders at once:
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XUnboxedTuples
-- >>> import Data.Text.Builder.Linear.Buffer
-- >>> runBuffer (\b -> case dupBuffer b of (# b1, b2 #) -> ("foo" <| b1) >< (b2 |> "bar"))
-- "foobar"
(><) ∷ Buffer ⊸ Buffer ⊸ Buffer

infix 6 ><
Buffer (Text left leftOff leftLen) >< Buffer (Text right rightOff rightLen) = Buffer $ runST $ do
  let leftFullLen = sizeofByteArray left
      rightFullLen = sizeofByteArray right
      canCopyToLeft = leftOff + leftLen + rightLen <= leftFullLen
      canCopyToRight = leftLen <= rightOff
      shouldCopyToLeft = canCopyToLeft && (not canCopyToRight || leftLen >= rightLen)
  if shouldCopyToLeft
    then do
      newM ← unsafeThaw left
      A.copyI rightLen newM (leftOff + leftLen) right rightOff
      new ← A.unsafeFreeze newM
      pure $ Text new leftOff (leftLen + rightLen)
    else
      if canCopyToRight
        then do
          newM ← unsafeThaw right
          A.copyI leftLen newM (rightOff - leftLen) left leftOff
          new ← A.unsafeFreeze newM
          pure $ Text new (rightOff - leftLen) (leftLen + rightLen)
        else do
          let fullLen = leftOff + leftLen + rightLen + (rightFullLen - rightOff - rightLen)
          newM ← (if isPinned left || isPinned right then A.newPinned else A.new) fullLen
          A.copyI leftLen newM leftOff left leftOff
          A.copyI rightLen newM (leftOff + leftLen) right rightOff
          new ← A.unsafeFreeze newM
          pure $ Text new leftOff (leftLen + rightLen)
