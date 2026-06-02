-- | The boxed-`eqref` value convention (ADR 0004): boxing/unboxing per
-- | representation, and the translation of a trivial `Atom` to the wasm expression
-- | that produces its value. These are the leaf operations the statement / record /
-- | intrinsic generators build on.
module PureScript.Backend.Wasm.Codegen.Value
  ( boxInt
  , unboxIntExpr
  , unboxIntAtom
  , boxNum
  , unboxNumExpr
  , boxBool
  , unboxBoolExpr
  , genAtom
  , localType
  , utf8Bytes
  , strBytes
  ) where

import Prelude

import Binaryen as B
import Data.Array as Array
import Data.Enum (fromEnum)
import Data.Int.Bits (and, shr)
import Data.Maybe (Maybe(..))
import Data.String.CodePoints (toCodePointArray)
import Data.Traversable (traverse)
import Effect (Effect)
import PureScript.Backend.Wasm.Codegen.RuntimeTypes (Ctx, repType)
import PureScript.Backend.Wasm.IR (Atom(..), Slot(..), VarRef(..))

-- | The `(ref $Bytes)` byte array of a `String` atom (`ref.cast $Str` then
-- | `struct.get 0`).
strBytes :: Ctx -> Atom -> Effect B.Expression
strBytes ctx atom = do
  s <- genAtom ctx atom >>= \e -> B.refCast ctx.mod e ctx.rt.refStr
  B.structGet ctx.mod 0 s ctx.rt.refBytes false

-- | Encode a `String` to its UTF-8 bytes (the elements of a `$Bytes` literal).
utf8Bytes :: String -> Array Int
utf8Bytes = toCodePointArray >=> (encode <<< fromEnum)
  where
  encode cp
    | cp < 0x80 = [ cp ]
    | cp < 0x800 =
        [ 0xC0 + shr cp 6, cont cp 0 ]
    | cp < 0x10000 =
        [ 0xE0 + shr cp 12, cont cp 6, cont cp 0 ]
    | otherwise =
        [ 0xF0 + shr cp 18, cont cp 12, cont cp 6, cont cp 0 ]
  cont cp n = 0x80 + (and (shr cp n) 0x3F)

-- | Box an `i32` expression into an `eqref` (`struct.new $Int`).
boxInt :: Ctx -> B.Expression -> Effect B.Expression
boxInt ctx e = B.structNew ctx.mod ctx.rt.intHt [ e ]

-- | Unbox an `eqref` expression to `i32` (`ref.cast` then `struct.get 0`).
unboxIntExpr :: Ctx -> B.Expression -> Effect B.Expression
unboxIntExpr ctx e = do
  c <- B.refCast ctx.mod e ctx.rt.refInt
  B.structGet ctx.mod 0 c B.i32 false

-- | Unbox an `Atom` (generated, then unboxed) to its `i32`.
unboxIntAtom :: Ctx -> Atom -> Effect B.Expression
unboxIntAtom ctx atom = genAtom ctx atom >>= unboxIntExpr ctx

-- | Box an `f64` expression into an `eqref` (`struct.new $Num`).
boxNum :: Ctx -> B.Expression -> Effect B.Expression
boxNum ctx e = B.structNew ctx.mod ctx.rt.numHt [ e ]

-- | Unbox an `eqref` expression to `f64` (`ref.cast $Num` then `struct.get 0`).
unboxNumExpr :: Ctx -> B.Expression -> Effect B.Expression
unboxNumExpr ctx e = do
  c <- B.refCast ctx.mod e ctx.rt.refNum
  B.structGet ctx.mod 0 c B.f64 false

-- | Box a `Boolean` as an `i31ref` (`true` = 1, `false` = 0; ADR 0001).
boxBool :: Ctx -> Boolean -> Effect B.Expression
boxBool ctx b = B.i32Const ctx.mod (if b then 1 else 0) >>= B.i31New ctx.mod

-- | Unbox an `eqref` known to hold an `i31` Boolean to its `i32` (`ref.cast`
-- | `i31ref` then `i31.get_s`).
unboxBoolExpr :: Ctx -> B.Expression -> Effect B.Expression
unboxBoolExpr ctx e = do
  c <- B.refCast ctx.mod e B.i31ref
  B.i31GetS ctx.mod c

-- | The wasm type of local `i` in the current function: a parameter takes its
-- | declared representation (local 0 of a code function is `(ref $Clo)`), while
-- | `Let`-bound locals are always `eqref`.
localType :: Ctx -> Int -> B.Type
localType ctx i = case Array.index ctx.params i of
  Just rep -> repType ctx rep
  Nothing -> B.eqref

genAtom :: Ctx -> Atom -> Effect B.Expression
genAtom ctx = case _ of
  ALitInt n -> B.i32Const ctx.mod n >>= boxInt ctx
  ALitNumber n -> B.f64Const ctx.mod n >>= boxNum ctx
  ALitBoolean b -> boxBool ctx b
  ALitString s -> do
    byteEs <- traverse (B.i32Const ctx.mod) (utf8Bytes s)
    bytes <- B.arrayNewFixed ctx.mod ctx.rt.bytesHt byteEs
    B.structNew ctx.mod ctx.rt.strHt [ bytes ]
  AVar (Local (Slot index)) -> B.localGet ctx.mod index (localType ctx index)
  -- A captured variable: read the env array from the closure (local 0, the only
  -- `(ref $Clo)`-typed local — `EnvField` appears only in lifted code functions)
  -- and index into it.
  AVar (EnvField i) -> do
    clo <- B.localGet ctx.mod 0 ctx.rt.refClo
    env <- B.structGet ctx.mod 1 clo ctx.rt.refVals false
    idx <- B.i32Const ctx.mod i
    B.arrayGet ctx.mod env idx B.eqref false
