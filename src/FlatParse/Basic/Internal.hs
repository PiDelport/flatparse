{-# language UnboxedTuples #-}

module FlatParse.Basic.Internal where

import FlatParse.Basic.Parser

import GHC.Exts
import GHC.Word
import GHC.ForeignPtr

import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B

--------------------------------------------------------------------------------

-- | Save the parsing state, then run a parser, then restore the state.
lookahead :: Parser e a -> Parser e a
lookahead (Parser f) = Parser \fp eob s ->
  case f fp eob s of
    OK# a _ -> OK# a s
    x       -> x
{-# inline lookahead #-}

--------------------------------------------------------------------------------

-- | Check that the input has at least the given number of bytes.
ensureBytes# :: Int -> Parser e ()
ensureBytes# (I# len) = Parser \fp eob s ->
  case len  <=# minusAddr# eob s of
    1# -> OK# () s
    _  -> Fail#
{-# inline ensureBytes# #-}

scanPartial64# :: Int -> Word -> Parser e ()
scanPartial64# (I# len) (W# w) = Parser \fp eob s ->
  case indexWordOffAddr# s 0# of
    w' -> case uncheckedIShiftL# (8# -# len) 3# of
      sh -> case uncheckedShiftL# w' sh of
        w' -> case uncheckedShiftRL# w' sh of
          w' -> case eqWord# w w' of
            1# -> OK# () (plusAddr# s len)
            _  -> Fail#
{-# inline scanPartial64# #-}

-- | Decrease the current input position by the given number of bytes.
setBack# :: Int -> Parser e ()
setBack# (I# i) = Parser \fp eob s ->
  OK# () (plusAddr# s (negateInt# i))
{-# inline setBack# #-}

--------------------------------------------------------------------------------
-- Helpers for common internal operations

-- | Assert for the given 'Int#' that @n >= 0@, and pass it on to the given
--   function.
--
-- Throws a runtime error if given a negative integer.
withPosInt# :: Int# -> (Int# -> a) -> a
withPosInt# n# f = case n# >=# 0# of
  1# -> f n#
  _  -> error "FlatParse.Basic.Internal.withPosInt#: negative integer"
{-# inline withPosInt# #-}

-- | Run the given parser only if we have not yet reached the end of the buffer.
withNotEob :: Parser e a -> Parser e a
withNotEob (Parser p) = Parser \fp eob s -> case eqAddr# eob s of
  1# -> Fail#
  _  -> p fp eob s
{-# inline withNotEob #-}

--------------------------------------------------------------------------------
-- Low level unboxed combinators

-- | Read @n@ bytes as a 'ByteString'. Fails if newer than @n@ bytes are
--   available.
--
-- Throws a runtime error if given a negative integer.
take# :: Int# -> Parser e B.ByteString
take# n# = withPosInt# n# takeUnsafe#
{-# inline take# #-}

-- | Read @n@ bytes as a 'ByteString'. Fails if newer than @n@ bytes are
--   available.
--
-- Undefined behaviour if given a negative integer.
takeUnsafe# :: Int# -> Parser e B.ByteString
takeUnsafe# n# = Parser \fp eob s -> case n# <=# minusAddr# eob s of
  1# -> OK# (B.PS (ForeignPtr s fp) 0 (I# n#)) (plusAddr# s n#)
  _  -> Fail#
{-# inline takeUnsafe# #-}

-- | Skip forward @n@ bytes and run the given parser. Fails if fewer than @n@
--   bytes are available.
--
-- Throws a runtime error if given a negative integer.
atSkip# :: Int# -> Parser e a -> Parser e a
atSkip# os# p = withPosInt# os# (\n# -> atSkipUnsafe# n# p)
{-# inline atSkip# #-}

-- | Skip forward @n@ bytes and run the given parser. Fails if fewer than @n@
--   bytes are available.
--
-- Undefined behaviour if given a negative integer.
atSkipUnsafe# :: Int# -> Parser e a -> Parser e a
atSkipUnsafe# os# (Parser p) = Parser \fp eob s -> case os# <=# minusAddr# eob s of
  1# -> p fp eob (plusAddr# s os#)
  _  -> Fail#
{-# inline atSkipUnsafe# #-}

-- | Skip forward @n@ bytes. Fails if fewer than @n@ bytes are available.
--
-- Throws a runtime error if given a negative integer.
skip# :: Int# -> Parser e ()
skip# os# = atSkip# os# (pure ())
{-# inline skip# #-}

--------------------------------------------------------------------------------
-- Low-level boxed combinators

-- | Read a null-terminated bytestring (a C-style string).
--
-- Consumes the null terminator.
getCString :: Parser e B.ByteString
getCString = Parser \fp eob s -> go' fp eob s
  where
    go' fp eob s0 = go 0# s0
      where
        go n# s = case eqAddr# eob s of
          1# -> Fail#
          _  ->
            let s' = plusAddr# s 1#
                w# = indexWord8OffAddr# s 0#
            in  if   W8# w# == 0x00
                then OK# (B.PS (ForeignPtr s0 fp) 0 (I# n#)) s'
                else go (n# +# 1#) s'
{-# inline getCString #-}

-- | Read a null-terminated bytestring (a C-style string), where the bytestring
--   is known to be null-terminated somewhere in the input.
--
-- Undefined behaviour if your bytestring isn't null-terminated somewhere.
-- You almost certainly want 'getCString' instead.
--
-- Fails on GHC versions older than 9.0, since we make use of the
-- 'cstringLength#' primop introduced in GHC 9.0, and we aren't very useful
-- without it.
--
-- Consumes the null terminator.
getCStringUnsafe :: Parser e B.ByteString
{-# inline getCStringUnsafe #-}
#if MIN_VERSION_base(4,15,0)
getCStringUnsafe = Parser \fp eob s ->
  case eqAddr# eob s of
    1# -> Fail#
    _  -> let n#  = cstringLength# s
              s'# = plusAddr# s (n# +# 1#)
           in OK# (B.PS (ForeignPtr s fp) 0 (I# n#)) s'#
#else
getCStringUnsafe = error "Flatparse.Basic.getCStringUnsafe: requires GHC 9.0 / base-4.15, not available on this compiler"
#endif
