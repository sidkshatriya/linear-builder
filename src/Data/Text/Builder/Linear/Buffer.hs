-- |
-- Copyright:   (c) 2022 Andrew Lelechenko
--              (c) 2023 Pierre Le Marre
-- Licence:     BSD3
-- Maintainer:  Andrew Lelechenko <andrew.lelechenko@gmail.com>
--
-- t'Buffer' for strict t'Text', based on linear types.
module Data.Text.Builder.Linear.Buffer (
  -- * Type
  Buffer,

  -- * Basic interface
  runBuffer,
  runBufferBS,
  dupBuffer,
  consumeBuffer,
  eraseBuffer,
  foldlIntoBuffer,
  newEmptyBuffer,
  (><),

  -- * Single character
  (|>.),
  (.<|),

  -- * Multiple characters

  -- ** Character replication
  prependChars,
  appendChars,

  -- ** Text
  (|>),
  (<|),
  (|>…),
  (…<|),

  -- ** Raw 'Addr#'
  (|>#),
  ( #<| ), -- NOTE: extra spaces required because of -XUnboxedTuples
  (<|#),

  -- * Padding
  justifyLeft,
  justifyRight,
  center,

  -- * Number formatting

  -- ** Decimal

  -- *** Bounded numbers
  (|>$),
  ($<|),

  -- *** Unbounded numbers
  (|>$$),
  ($$<|),

  -- ** Hexadecimal

  -- *** Lower-case
  (|>&),
  (&<|),

  -- *** Upper-case and padding
  -- $custom_hexadecimal

  -- ** Double
  (|>%),
  (%<|),
) where

import Data.Text.Array qualified as A
import Data.Text.Internal (Text (..))
import GHC.Exts (Addr#, Int (..), Ptr (..), cstringLength#, setByteArray#)
import GHC.ST (ST (..))

import Data.Text.Builder.Linear.Char
import Data.Text.Builder.Linear.Core
import Data.Text.Builder.Linear.Dec.Bounded
import Data.Text.Builder.Linear.Dec.Unbounded
import Data.Text.Builder.Linear.Double
import Data.Text.Builder.Linear.Hex

-- | Append t'Text' suffix to a t'Buffer' by mutating it.
-- If a suffix is statically known, consider using '(|>#)' for optimal performance.
--
-- >>> :set -XOverloadedStrings -XLinearTypes
-- >>> runBuffer (\b -> b |> "foo" |> "bar")
-- "foobar"
(|>) ∷ Buffer ⊸ Text → Buffer

infixl 6 |>
buffer |> (Text src srcOff srcLen) =
  appendExact
    srcLen
    (\dst dstOff → A.copyI srcLen dst dstOff src srcOff)
    buffer

-- | Prepend t'Text' prefix to a t'Buffer' by mutating it.
-- If a prefix is statically known, consider using '(#<|)' for optimal performance.
--
-- >>> :set -XOverloadedStrings -XLinearTypes
-- >>> runBuffer (\b -> "foo" <| "bar" <| b)
-- "foobar"
(<|) ∷ Text → Buffer ⊸ Buffer

infixr 6 <|
Text src srcOff srcLen <| buffer =
  prependExact
    srcLen
    (\dst dstOff → A.copyI srcLen dst dstOff src srcOff)
    buffer

-- | Append a null-terminated UTF-8 string
-- to a t'Buffer' by mutating it. E. g.,
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XMagicHash
-- >>> runBuffer (\b -> b |># "foo"# |># "bar"#)
-- "foobar"
--
-- The literal string must not contain zero bytes @\\NUL@ and must be a valid UTF-8,
-- these conditions are not checked.
(|>#) ∷ Buffer ⊸ Addr# → Buffer

infixl 6 |>#
buffer |># addr# =
  appendExact
    srcLen
    (\dst dstOff → A.copyFromPointer dst dstOff (Ptr addr#) srcLen)
    buffer
  where
    srcLen = I# (cstringLength# addr#)

-- | Prepend a null-terminated UTF-8 string
-- to a t'Buffer' by mutating it. E. g.,
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XMagicHash
-- >>> runBuffer (\b -> "foo"# #<| "bar"# #<| b)
-- "foobar"
--
-- The literal string must not contain zero bytes @\\NUL@ and must be a valid UTF-8,
-- these conditions are not checked.
--
-- /Note:/ When the syntactic extensions @UnboxedTuples@ or @UnboxedSums@ are
-- enabled, extra spaces are required when using parentheses: i.e. use @( '#<|' )@
-- instead of @('#<|')@. See the GHC User Guide chapter
-- “<https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/primitives.html#unboxed-tuples Unboxed types and primitive operations>”
-- for further information.
( #<| ) ∷ Addr# → Buffer ⊸ Buffer

infixr 6 #<|, <|#
addr# #<| buffer =
  prependExact
    srcLen
    (\dst dstOff → A.copyFromPointer dst dstOff (Ptr addr#) srcLen)
    buffer
  where
    srcLen = I# (cstringLength# addr#)

-- | Alias for @'(#<|)'@.
{-# DEPRECATED (<|#) "Use '(#<|)' instead" #-}
(<|#) ∷ Addr# → Buffer ⊸ Buffer
(<|#) = ( #<| ) -- NOTE: extra spaces required because of -XUnboxedTuples
{-# INLINE (<|#) #-}

-- | Append given number of spaces.
(|>…) ∷ Buffer ⊸ Word → Buffer

infixr 6 |>…
buf |>… 0 = buf
buffer |>… (fromIntegral → spaces@(I# spaces#)) =
  appendExact
    spaces
    ( \(A.MutableByteArray dst#) (I# dstOff#) →
        ST
          ( \s# →
              (# setByteArray# dst# dstOff# spaces# 32# s#, () #)
          )
    )
    buffer

-- | Prepend given number of spaces.
(…<|) ∷ Word → Buffer ⊸ Buffer

infixr 6 …<|
0 …<| buf = buf
(fromIntegral → spaces@(I# spaces#)) …<| buffer =
  prependExact
    spaces
    ( \(A.MutableByteArray dst#) (I# dstOff#) →
        ST
          ( \s# →
              (# setByteArray# dst# dstOff# spaces# 32# s#, () #)
          )
    )
    buffer

-- | This is just a normal 'Data.List.foldl'', but with a linear arrow
-- and unlifted accumulator.
foldlIntoBuffer ∷ ∀ a. (Buffer ⊸ a → Buffer) → Buffer ⊸ [a] → Buffer
foldlIntoBuffer f = go
  where
    go ∷ Buffer ⊸ [a] → Buffer
    go !acc [] = acc
    go !acc (x : xs) = go (f acc x) xs

-- $custom_hexadecimal
--
-- Note that neither /upper/ case nor padded hexadecimal formatting is provided.
-- This package provides a minimal API with utility functions only for common cases.
-- For other use cases, please adapt the code of this package, e.g. as shown in
-- the [Unicode code point example](https://github.com/Bodigrim/linear-builder/blob/master/examples/src/Examples/Unicode.hs).
