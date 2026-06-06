-- | Shared parsing of `ulib/<Module>/foreign.wat` export signatures (ADR 0012). A ulib
-- | foreign's wasm export signature is the source of truth for its calling convention, so
-- | both the `bin` linker and the e2e harness derive `ForeignSig`s from it the same way:
-- | scan each `(func (export "name") (param T)… (result T))` line, mapping `i32`/`f64` to
-- | `MI32`/`MF64` and anything else (`eqref`, …) to `MOpaque`.
module PureScript.Backend.Wasm.Ulib
  ( parseUlibSigs
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), maybe)
import Data.String (Pattern(..))
import Data.String as Str
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (ForeignImport, MarshalKind(..))

-- | Parse a `ulib/<Module>/foreign.wat`'s exported foreign signatures into `ForeignSig`s
-- | keyed by qualified name (`Module.base`). `mn` is the owning module name.
parseUlibSigs :: String -> String -> Object ForeignImport
parseUlibSigs mn watText =
  Object.fromFoldable (Array.mapMaybe sigOfLine (Str.split (Pattern "\n") watText))
  where
  sigOfLine line
    | Str.contains (Pattern "(func") line && Str.contains (Pattern "(export \"") line =
        case between "(export \"" "\"" line of
          Just base -> Just (Tuple (mn <> "." <> base) { moduleName: mn, base, params: paramsOf line, result: resultOf line })
          Nothing -> Nothing
    | otherwise = Nothing

  between open close s = do
    i <- Str.indexOf (Pattern open) s
    let rest = Str.drop (i + Str.length open) s
    j <- Str.indexOf (Pattern close) rest
    pure (Str.take j rest)

  paramsOf line = Array.mapMaybe paramKind (Array.drop 1 (Str.split (Pattern "(param") line))
  paramKind seg = do
    j <- Str.indexOf (Pattern ")") seg
    kindOf <$> lastWord (Str.take j seg)

  resultOf line = case between "(result " ")" line of
    Just inside -> maybe MOpaque kindOf (lastWord inside)
    Nothing -> MOpaque

  lastWord s = Array.last (Array.filter (_ /= "") (Str.split (Pattern " ") (Str.trim s)))

  kindOf t = case t of
    "i32" -> MI32
    "f64" -> MF64
    _ -> MOpaque
