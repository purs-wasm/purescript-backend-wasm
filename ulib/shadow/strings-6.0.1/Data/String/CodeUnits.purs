-- | ulib SHADOW of `strings`' `Data.String.CodeUnits` (ADR 0028 / 0030), targeting strings 6.0.1.
-- |
-- | The registry module's foreigns are JavaScript string operations over **UTF-16 code units**.
-- | This backend stores a `String` as **UTF-8 bytes** (`$Str`, ADR 0001) and a `Char` is a Unicode
-- | **code point** (ADR 0030), so here every foreign is reimplemented in PureScript over the
-- | byte-level `Wasm.String` primitives with **code-point** semantics (length / indices count code
-- | points, like Haskell `Data.Text`). The public interface is unchanged. The non-foreign helpers
-- | (`stripPrefix`, `charAt`, `indexOf`, …) are the upstream definitions verbatim; only `uncons` is
-- | rewritten to stay self-contained (the registry used `Data.String.Unsafe`).
-- |
-- | Divergence from the JS backend (documented, ADR 0030): a code point above U+FFFF counts as 1,
-- | not 2; substring search is byte-level (valid for UTF-8: it is self-synchronizing, so a match
-- | always lands on a code-point boundary) with the offset mapped back to a code-point index.
module Data.String.CodeUnits
  ( stripPrefix
  , stripSuffix
  , contains
  , singleton
  , fromCharArray
  , toCharArray
  , charAt
  , toChar
  , uncons
  , length
  , countPrefix
  , indexOf
  , indexOf'
  , lastIndexOf
  , lastIndexOf'
  , take
  , takeRight
  , takeWhile
  , drop
  , dropRight
  , dropWhile
  , slice
  , splitAt
  ) where

import Prelude

import Data.Maybe (Maybe(..), isJust)
import Data.String.Pattern (Pattern(..))
import Wasm.Array as WA
import Wasm.Char as WC
import Wasm.String as WS

-------------------------------------------------------------------------------
-- UTF-8 codec helpers (private). All arithmetic is ordinary `Prelude` `Int` (this
-- module sits above `Prelude`); `mod`/`div` are the Euclidean intrinsics, so on the
-- non-negative byte / code-point values here they are plain remainder / quotient.
-------------------------------------------------------------------------------

-- | The number of UTF-8 bytes a lead byte introduces (1-4), so the byte offset of the next code
-- | point is `o + byteLenOfLead (byteAt s o)` — used by the index↔offset walks that need no `cp`.
byteLenOfLead :: Int -> Int
byteLenOfLead b0
  | b0 < 0x80 = 1
  | b0 < 0xE0 = 2
  | b0 < 0xF0 = 3
  | otherwise = 4

-- | The byte offset just past the code point starting at byte offset `o`.
nextOffset :: String -> Int -> Int
nextOffset s o = o + byteLenOfLead (WS.byteAt s o)

-- | Decode the code point starting at byte offset `o` (which must be `< byteLength`), returning it
-- | and the next code point's byte offset. The 6-bit continuation payload of a byte `b` is
-- | `b `mod` 64`; the lead byte's payload is its low `7 - n` bits (`b0 `mod` 32/16/8`).
decodeAt :: String -> Int -> { cp :: Int, next :: Int }
decodeAt s o =
  let
    b0 = WS.byteAt s o
    cont k = WS.byteAt s (o + k) `mod` 64
  in
    if b0 < 0x80 then { cp: b0, next: o + 1 }
    else if b0 < 0xE0 then { cp: (b0 `mod` 32) * 64 + cont 1, next: o + 2 }
    else if b0 < 0xF0 then { cp: (b0 `mod` 16) * 4096 + cont 1 * 64 + cont 2, next: o + 3 }
    else { cp: (b0 `mod` 8) * 262144 + cont 1 * 4096 + cont 2 * 64 + cont 3, next: o + 4 }

-- | The number of UTF-8 bytes the code point `cp` encodes to.
utf8Len :: Int -> Int
utf8Len cp
  | cp < 0x80 = 1
  | cp < 0x800 = 2
  | cp < 0x10000 = 3
  | otherwise = 4

-- | Write `cp`'s UTF-8 bytes into `s` starting at byte offset `o` (the bytes must fit), returning
-- | the threaded string. `Wasm.String.unsafeSetByte` mutates in place and returns the string, so
-- | nesting the calls writes all the bytes and yields the final string.
putCp :: String -> Int -> Int -> String
putCp s o cp =
  if cp < 0x80 then set s o cp
  else if cp < 0x800 then
    set (set s o (0xC0 + cp `div` 64)) (o + 1) (0x80 + cp `mod` 64)
  else if cp < 0x10000 then
    set (set (set s o (0xE0 + cp `div` 4096)) (o + 1) (0x80 + (cp `div` 64) `mod` 64)) (o + 2) (0x80 + cp `mod` 64)
  else
    set (set (set (set s o (0xF0 + cp `div` 262144)) (o + 1) (0x80 + (cp `div` 4096) `mod` 64)) (o + 2) (0x80 + (cp `div` 64) `mod` 64)) (o + 3) (0x80 + cp `mod` 64)
  where
  set = WS.unsafeSetByte

-- | The byte offset of the `i`-th code point, clamped: `i <= 0` → `0`, `i >= length` → `byteLength`.
byteOffsetOfCp :: String -> Int -> Int
byteOffsetOfCp s i = go 0 0
  where
  n = WS.byteLength s
  go o k = if k >= i || o >= n then o else go (nextOffset s o) (k + 1)

-- | The code-point index of the byte offset `b` (assumed a code-point boundary, which a UTF-8
-- | substring match always is) — the number of code points before it.
cpIndexOfByteOffset :: String -> Int -> Int
cpIndexOfByteOffset s b = go 0 0
  where
  go o k = if o >= b then k else go (nextOffset s o) (k + 1)

-- | Copy the bytes `[from, to)` of `s` into a fresh string (empty if `to <= from`).
sliceBytes :: String -> Int -> Int -> String
sliceBytes s from to =
  if to <= from then WS.unsafeNew 0
  else go from 0 (WS.unsafeNew (to - from))
  where
  go i j out = if i >= to then out else go (i + 1) (j + 1) (WS.unsafeSetByte out j (WS.byteAt s i))

-- | The first byte offset `>= from` at which `needle`'s bytes occur in `hay`, or `-1`. UTF-8 is
-- | self-synchronizing, so a byte match of a valid needle always begins on a code-point boundary.
byteIndexOf :: String -> String -> Int -> Int
byteIndexOf hay needle from = go from
  where
  hn = WS.byteLength hay
  nn = WS.byteLength needle
  matchAt i j = if j >= nn then true else if WS.byteAt hay (i + j) == WS.byteAt needle j then matchAt i (j + 1) else false
  go i = if i + nn > hn then -1 else if matchAt i 0 then i else go (i + 1)

-- | The last byte offset `<= fromByte` at which `needle` occurs in `hay`, or `-1`.
byteLastIndexOf :: String -> String -> Int -> Int
byteLastIndexOf hay needle fromByte = go (min fromByte (hn - nn))
  where
  hn = WS.byteLength hay
  nn = WS.byteLength needle
  matchAt i j = if j >= nn then true else if WS.byteAt hay (i + j) == WS.byteAt needle j then matchAt i (j + 1) else false
  go i = if i < 0 then -1 else if matchAt i 0 then i else go (i - 1)

-------------------------------------------------------------------------------
-- `stripPrefix`, `stripSuffix`, and `contains` are CodeUnit/CodePoint agnostic
-- as they are based on patterns rather than lengths/indices, but they need to
-- be defined in here to avoid a circular module dependency
-------------------------------------------------------------------------------

-- | If the string starts with the given prefix, return the portion of the
-- | string left after removing it, as a `Just` value. Otherwise, return `Nothing`.
-- |
-- | ```purescript
-- | stripPrefix (Pattern "http:") "http://purescript.org" == Just "//purescript.org"
-- | stripPrefix (Pattern "http:") "https://purescript.org" == Nothing
-- | ```
stripPrefix :: Pattern -> String -> Maybe String
stripPrefix (Pattern prefix) str =
  let
    { before, after } = splitAt (length prefix) str
  in
    if before == prefix then Just after else Nothing

-- | If the string ends with the given suffix, return the portion of the
-- | string left after removing it, as a `Just` value. Otherwise, return
-- | `Nothing`.
-- |
-- | ```purescript
-- | stripSuffix (Pattern ".exe") "psc.exe" == Just "psc"
-- | stripSuffix (Pattern ".exe") "psc" == Nothing
-- | ```
stripSuffix :: Pattern -> String -> Maybe String
stripSuffix (Pattern suffix) str =
  let
    { before, after } = splitAt (length str - length suffix) str
  in
    if after == suffix then Just before else Nothing

-- | Checks whether the pattern appears in the given string.
-- |
-- | ```purescript
-- | contains (Pattern "needle") "haystack with needle" == true
-- | contains (Pattern "needle") "haystack" == false
-- | ```
contains :: Pattern -> String -> Boolean
contains pat = isJust <<< indexOf pat

-------------------------------------------------------------------------------
-- all functions past this point are CodeUnit specific
-------------------------------------------------------------------------------

-- | Returns a string of length `1` containing the given character.
singleton :: Char -> String
singleton c = putCp (WS.unsafeNew (utf8Len cp)) 0 cp
  where
  cp = WC.toCodePoint c

-- | Converts an array of characters into a string.
fromCharArray :: Array Char -> String
fromCharArray arr = build 0 0 (WS.unsafeNew total)
  where
  m = WA.length arr
  cpAt k = WC.toCodePoint (WA.unsafeIndex arr k)
  total = sumLen 0 0
  sumLen k acc = if k >= m then acc else sumLen (k + 1) (acc + utf8Len (cpAt k))
  build k o out = if k >= m then out else build (k + 1) (o + utf8Len (cpAt k)) (putCp out o (cpAt k))

-- | Converts the string into an array of characters.
toCharArray :: String -> Array Char
toCharArray s = build 0 0 (WA.unsafeNew (length s))
  where
  n = WS.byteLength s
  build o k out =
    if o >= n then out
    else
      let
        d = decodeAt s o
      in
        build d.next (k + 1) (WA.unsafeSet out k (WC.fromCodePoint d.cp))

-- | Returns the character at the given index, if the index is within bounds.
charAt :: Int -> String -> Maybe Char
charAt = _charAt Just Nothing

_charAt :: (forall a. a -> Maybe a) -> (forall a. Maybe a) -> Int -> String -> Maybe Char
_charAt just nothing i s =
  if i < 0 then nothing else go 0 0
  where
  n = WS.byteLength s
  go o k =
    if o >= n then nothing
    else
      let
        d = decodeAt s o
      in
        if k == i then just (WC.fromCodePoint d.cp) else go d.next (k + 1)

-- | Converts the string to a character, if the length of the string is
-- | exactly `1`.
toChar :: String -> Maybe Char
toChar = _toChar Just Nothing

_toChar :: (forall a. a -> Maybe a) -> (forall a. Maybe a) -> String -> Maybe Char
_toChar just nothing s =
  if WS.byteLength s == 0 then nothing
  else
    let
      d = decodeAt s 0
    in
      if d.next == WS.byteLength s then just (WC.fromCodePoint d.cp) else nothing

-- | Returns the first character and the rest of the string,
-- | if the string is not empty.
uncons :: String -> Maybe { head :: Char, tail :: String }
uncons s = case charAt 0 s of
  Nothing -> Nothing
  Just h -> Just { head: h, tail: drop 1 s }

-- | Returns the number of characters the string is composed of.
length :: String -> Int
length s = go 0 0
  where
  n = WS.byteLength s
  go o k = if o >= n then k else go (nextOffset s o) (k + 1)

-- | Returns the number of contiguous characters at the beginning
-- | of the string for which the predicate holds.
countPrefix :: (Char -> Boolean) -> String -> Int
countPrefix p s = go 0 0
  where
  n = WS.byteLength s
  go o k =
    if o >= n then k
    else
      let
        d = decodeAt s o
      in
        if p (WC.fromCodePoint d.cp) then go d.next (k + 1) else k

-- | Returns the index of the first occurrence of the pattern in the
-- | given string. Returns `Nothing` if there is no match.
indexOf :: Pattern -> String -> Maybe Int
indexOf = _indexOf Just Nothing

_indexOf :: (forall a. a -> Maybe a) -> (forall a. Maybe a) -> Pattern -> String -> Maybe Int
_indexOf just nothing (Pattern x) s =
  let
    bi = byteIndexOf s x 0
  in
    if bi < 0 then nothing else just (cpIndexOfByteOffset s bi)

-- | Returns the index of the first occurrence of the pattern in the
-- | given string, starting at the specified index. Returns `Nothing` if there is
-- | no match.
indexOf' :: Pattern -> Int -> String -> Maybe Int
indexOf' = _indexOfStartingAt Just Nothing

_indexOfStartingAt :: (forall a. a -> Maybe a) -> (forall a. Maybe a) -> Pattern -> Int -> String -> Maybe Int
_indexOfStartingAt just nothing (Pattern x) startAt s =
  if startAt < 0 || startAt > length s then nothing
  else
    let
      bi = byteIndexOf s x (byteOffsetOfCp s startAt)
    in
      if bi < 0 then nothing else just (cpIndexOfByteOffset s bi)

-- | Returns the index of the last occurrence of the pattern in the
-- | given string. Returns `Nothing` if there is no match.
lastIndexOf :: Pattern -> String -> Maybe Int
lastIndexOf = _lastIndexOf Just Nothing

_lastIndexOf :: (forall a. a -> Maybe a) -> (forall a. Maybe a) -> Pattern -> String -> Maybe Int
_lastIndexOf just nothing (Pattern x) s =
  let
    bi = byteLastIndexOf s x (WS.byteLength s)
  in
    if bi < 0 then nothing else just (cpIndexOfByteOffset s bi)

-- | Returns the index of the last occurrence of the pattern in the
-- | given string, starting at the specified index and searching
-- | backwards towards the beginning of the string.
lastIndexOf' :: Pattern -> Int -> String -> Maybe Int
lastIndexOf' = _lastIndexOfStartingAt Just Nothing

_lastIndexOfStartingAt :: (forall a. a -> Maybe a) -> (forall a. Maybe a) -> Pattern -> Int -> String -> Maybe Int
_lastIndexOfStartingAt just nothing (Pattern x) startAt s =
  let
    bi = byteLastIndexOf s x (byteOffsetOfCp s (max 0 startAt))
  in
    if bi < 0 then nothing else just (cpIndexOfByteOffset s bi)

-- | Returns the first `n` characters of the string.
take :: Int -> String -> String
take n s = sliceBytes s 0 (byteOffsetOfCp s n)

-- | Returns the last `n` characters of the string.
takeRight :: Int -> String -> String
takeRight i s = drop (length s - i) s

-- | Returns the longest prefix (possibly empty) of characters that satisfy
-- | the predicate.
takeWhile :: (Char -> Boolean) -> String -> String
takeWhile p s = take (countPrefix p s) s

-- | Returns the string without the first `n` characters.
drop :: Int -> String -> String
drop n s = sliceBytes s (byteOffsetOfCp s n) (WS.byteLength s)

-- | Returns the string without the last `n` characters.
dropRight :: Int -> String -> String
dropRight i s = take (length s - i) s

-- | Returns the suffix remaining after `takeWhile`.
dropWhile :: (Char -> Boolean) -> String -> String
dropWhile p s = drop (countPrefix p s) s

-- | Returns the substring at indices `[begin, end)`. If either index is negative, it is normalised
-- | to `length s - index`. `""` is returned if either index is out of bounds or `begin > end`.
slice :: Int -> Int -> String -> String
slice b e s =
  let
    len = length s
    norm i = if i < 0 then len + i else i
  in
    sliceBytes s (byteOffsetOfCp s (norm b)) (byteOffsetOfCp s (norm e))

-- | Splits a string into two substrings, where `before` contains the
-- | characters up to (but not including) the given index, and `after` contains
-- | the rest of the string, from that index on.
splitAt :: Int -> String -> { before :: String, after :: String }
splitAt i s = { before: take i s, after: drop i s }
