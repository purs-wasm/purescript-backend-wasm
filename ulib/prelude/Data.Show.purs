-- | ulib SHADOW of `prelude`'s `Data.Show` (ADR 0028 / 0030), targeting prelude 6.0.2.
-- |
-- | `showIntImpl` / `showCharImpl` / `showStringImpl` / `showArrayImpl` are reimplemented in
-- | PureScript over the byte-level `Wasm.String` / `Wasm.Char` / `Wasm.Array` primitives, so they
-- | run standalone on wasm and the element-`show` of `showArrayImpl` *specializes* (ADR 0027). The
-- | escaping matches `prelude`'s reference JS (`\a\b\f\n\r\t\v`, `\NNN` decimal with a `\&`
-- | separator before a following digit). `showStringImpl` escapes only ASCII bytes in
-- | `[\0-\x1F\x7F"\\]` and passes every other byte through, so multi-byte UTF-8 is preserved.
-- |
-- | `showNumberImpl` is KEPT foreign: `Number` → shortest round-trip string needs a Ryu/Grisu-class
-- | algorithm (the ~220-line hand-written `ulib/Data.Show/foreign.wat` provides it). The public
-- | interface is unchanged. As a sub-`Prelude` module it cannot `import Prelude` (cycle), so it
-- | imports the specific operator modules directly.
module Data.Show
  ( class Show
  , show
  , class ShowRecordFields
  , showRecordFields
  ) where

import Data.Semigroup ((<>))
import Data.Symbol (class IsSymbol, reflectSymbol)
import Data.Unit (Unit)
import Data.Void (Void, absurd)
import Prim.Row (class Nub)
import Prim.RowList as RL
import Record.Unsafe (unsafeGet)
import Type.Proxy (Proxy(..))
import Wasm.Array as WA
import Wasm.Char as WC
import Wasm.Int as WI
import Wasm.String as WS

-- | The `Show` type class represents those types which can be converted into
-- | a human-readable `String` representation.
class Show a where
  show :: a -> String

instance showUnit :: Show Unit where
  show _ = "unit"

instance showBoolean :: Show Boolean where
  show true = "true"
  show false = "false"

instance showInt :: Show Int where
  show = showIntImpl

instance showNumber :: Show Number where
  show = showNumberImpl

instance showChar :: Show Char where
  show = showCharImpl

instance showString :: Show String where
  show = showStringImpl

instance showArray :: Show a => Show (Array a) where
  show = showArrayImpl show

instance showProxy :: Show (Proxy a) where
  show _ = "Proxy"

instance showVoid :: Show Void where
  show = absurd

instance showRecord ::
  ( Nub rs rs
  , RL.RowToList rs ls
  , ShowRecordFields ls rs
  ) =>
  Show (Record rs) where
  show record = "{" <> showRecordFields (Proxy :: Proxy ls) record <> "}"

-- | A class for records where all fields have `Show` instances, used to
-- | implement the `Show` instance for records.
class ShowRecordFields :: RL.RowList Type -> Row Type -> Constraint
class ShowRecordFields rowlist row where
  showRecordFields :: Proxy rowlist -> Record row -> String

instance showRecordFieldsNil :: ShowRecordFields RL.Nil row where
  showRecordFields _ _ = ""
else instance showRecordFieldsConsNil ::
  ( IsSymbol key
  , Show focus
  ) =>
  ShowRecordFields (RL.Cons key focus RL.Nil) row where
  showRecordFields _ record = " " <> key <> ": " <> show focus <> " "
    where
    key = reflectSymbol (Proxy :: Proxy key)
    focus = unsafeGet key record :: focus
else instance showRecordFieldsCons ::
  ( IsSymbol key
  , ShowRecordFields rowlistTail row
  , Show focus
  ) =>
  ShowRecordFields (RL.Cons key focus rowlistTail) row where
  showRecordFields _ record = " " <> key <> ": " <> show focus <> "," <> tail
    where
    key = reflectSymbol (Proxy :: Proxy key)
    focus = unsafeGet key record :: focus
    tail = showRecordFields (Proxy :: Proxy rowlistTail) record

-------------------------------------------------------------------------------
-- ulib shadow implementations (UTF-8, code-point semantics; ADR 0030). String building uses `<>`
-- (`StrConcat`); show is not a hot path, so its O(n²) accumulation is acceptable.
-------------------------------------------------------------------------------

-- | A one-byte string of the raw byte `b` (an ASCII char, or one byte of a UTF-8 sequence).
put1 :: Int -> String
put1 b = WS.unsafeSetByte (WS.unsafeNew 1) 0 b

-- | Encode a single code point as its UTF-8 string.
cpStr :: Int -> String
cpStr cp =
  if WI.lt cp 0x80 then put1 cp
  else if WI.lt cp 0x800 then put2 (WI.add 0xC0 (WI.div cp 64)) (cont cp)
  else if WI.lt cp 0x10000 then put3 (WI.add 0xE0 (WI.div cp 4096)) (WI.add 0x80 (WI.mod (WI.div cp 64) 64)) (cont cp)
  else put4 (WI.add 0xF0 (WI.div cp 262144)) (WI.add 0x80 (WI.mod (WI.div cp 4096) 64)) (WI.add 0x80 (WI.mod (WI.div cp 64) 64)) (cont cp)
  where
  cont x = WI.add 0x80 (WI.mod x 64)
  put2 a b = WS.unsafeSetByte (WS.unsafeSetByte (WS.unsafeNew 2) 0 a) 1 b
  put3 a b c = WS.unsafeSetByte (WS.unsafeSetByte (WS.unsafeSetByte (WS.unsafeNew 3) 0 a) 1 b) 2 c
  put4 a b c d = WS.unsafeSetByte (WS.unsafeSetByte (WS.unsafeSetByte (WS.unsafeSetByte (WS.unsafeNew 4) 0 a) 1 b) 2 c) 3 d

-- | The named C-style escape (`\a`/`\b`/…) for a control byte, or `fallback` for any other.
ctrlEscape :: Int -> String -> String
ctrlEscape b fallback =
  if WI.eq b 0x07 then "\\a"
  else if WI.eq b 0x08 then "\\b"
  else if WI.eq b 0x0C then "\\f"
  else if WI.eq b 0x0A then "\\n"
  else if WI.eq b 0x0D then "\\r"
  else if WI.eq b 0x09 then "\\t"
  else if WI.eq b 0x0B then "\\v"
  else fallback

-- | A byte `< 0x20` or `== 0x7F` — a control character needing an escape.
isCtrl :: Int -> Boolean
isCtrl b = if WI.lt b 0x20 then true else WI.eq b 0x7F

showIntImpl :: Int -> String
showIntImpl n =
  if WI.eq n 0 then "0"
  else if WI.eq n minInt then "-2147483648"
  else if WI.lt n 0 then "-" <> digits (WI.sub 0 n)
  else digits n
  where
  -- `-2147483648` cannot be written literally (the magnitude overflows `Int`, and unary `-` is
  -- `Data.Ring.negate`, not imported here); build it as `-(maxInt) - 1`.
  minInt = WI.sub (WI.sub 0 2147483647) 1
  digits m = go m ""
  go m acc = if WI.eq m 0 then acc else go (WI.div m 10) (put1 (WI.add 48 (WI.mod m 10)) <> acc)

showCharImpl :: Char -> String
showCharImpl c =
  if isCtrl code then "'" <> ctrlEscape code ("\\" <> showIntImpl code) <> "'"
  else if WI.eq code 0x27 then quoted
  else if WI.eq code 0x5C then quoted
  else "'" <> cpStr code <> "'"
  where
  code = WC.toCodePoint c
  quoted = "'\\" <> cpStr code <> "'"

showStringImpl :: String -> String
showStringImpl s = "\"" <> go 0 "" <> "\""
  where
  n = WS.byteLength s
  go i acc = if WI.lt i n then go (WI.add i 1) (acc <> render i) else acc
  render i =
    let
      b = WS.byteAt s i
    in
      if WI.eq b 0x22 then "\\\""
      else if WI.eq b 0x5C then "\\\\"
      else if isCtrl b then ctrlEscape b ("\\" <> showIntImpl b <> amp (WI.add i 1))
      else put1 b
  -- a digit immediately after a `\NNN` escape needs a `\&` separator (Haskell convention)
  amp k = if WI.lt k n then (if isDigit (WS.byteAt s k) then "\\&" else "") else ""
  isDigit bb = if WI.lt bb 0x30 then false else if WI.lt 0x39 bb then false else true

showArrayImpl :: forall a. (a -> String) -> Array a -> String
showArrayImpl f xs = "[" <> go 0 "" <> "]"
  where
  m = WA.length xs
  go i acc =
    if WI.lt i m then go (WI.add i 1) (if WI.eq i 0 then f (WA.unsafeIndex xs i) else acc <> "," <> f (WA.unsafeIndex xs i))
    else acc

-- | `Number` → string (kept foreign — shortest round-trip needs a Ryu/Grisu-class algorithm).
foreign import showNumberImpl :: Number -> String
