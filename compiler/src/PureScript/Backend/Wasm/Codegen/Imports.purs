-- | The shared-runtime import surface (ADR 0010): the module name the generated
-- | code imports the `$rt.*` helpers from, the import declarations themselves, and
-- | the stable internal names every `B.call` site refers to. Keeping the names here
-- | (rather than re-typing the literal strings at each call) keeps the import
-- | declarations and the call sites in sync.
module PureScript.Backend.Wasm.Codegen.Imports
  ( runtimeModuleName
  , importRuntime
  , internStrName
  , counterGlobalName
  , projHelperName
  , recHasHelperName
  , recSetHelperName
  , recDeleteHelperName
  , internStrHelperName
  , strEqHelperName
  , strCmpHelperName
  , strConcatHelperName
  , strNewHelperName
  , strSetByteHelperName
  , arrayConcatHelperName
  , arrayNewHelperName
  , arraySetHelperName
  , intModHelperName
  , intDivHelperName
  , intDegreeHelperName
  , refNewHelperName
  , refReadHelperName
  , refWriteHelperName
  , refNewWithSelfHelperName
  , refModifyHelperName
  , forEHelperName
  , foreachEHelperName
  , whileEHelperName
  , untilEHelperName
  , applyCloHelperName
  ) where

import Prelude

import Binaryen as B
import Effect (Effect)
import PureScript.Backend.Wasm.Codegen.RuntimeTypes (Ctx)

-- | The module name under which generated code imports the shared runtime
-- | (ADR 0010). Satisfied by instantiating `runtime.wasm` (tests) or by
-- | `wasm-merge` (the single-file build).
runtimeModuleName :: String
runtimeModuleName = "rt"

-- | Declare the imports for the shared runtime helpers (now defined in
-- | `runtime.wat`, ADR 0010). The internal names (e.g. `$rt.strEq`) are unchanged,
-- | so existing `B.call` sites resolve to the imports transparently. The boundary
-- | uses only `eqref`/`i32` (ADR 0004), so no concrete GC type crosses it.
importRuntime :: Ctx -> Effect Unit
importRuntime ctx = do
  let imp name base params result = B.addFunctionImport ctx.mod name runtimeModuleName base (B.createType params) result
  imp projHelperName "proj" [ B.eqref, B.i32 ] B.eqref
  imp recHasHelperName "recHas" [ B.eqref, B.i32 ] B.i32
  imp recSetHelperName "recSet" [ B.eqref, B.i32, B.eqref ] B.eqref
  imp recDeleteHelperName "recDelete" [ B.eqref, B.i32 ] B.eqref
  -- runtime label-name → interned id: hashes the `$Str`'s bytes (ADR 0037 ④), the same
  -- hash the compiler assigns a static label, so a host field name resolves to the id its
  -- record uses. The emitted `$internStr` (and the marshalling glue) call this.
  imp internStrHelperName "internStrHash" [ B.eqref ] B.i32
  imp strEqHelperName "strEq" [ B.eqref, B.eqref ] B.i32
  imp strCmpHelperName "strCmp" [ B.eqref, B.eqref ] B.i32
  imp strConcatHelperName "strConcat" [ B.eqref, B.eqref ] B.eqref
  -- `Wasm.String` byte primitives (WasmBase, ADR 0030): `strNew n` allocates a zeroed byte
  -- string; `strSetByte` writes a byte in place and returns nothing (the intrinsic threads the
  -- string back, `Codegen.Prim`). `byteAt`/`byteLength` inline (`array.get`/`array.len`).
  imp strNewHelperName "strNew" [ B.i32 ] B.eqref
  imp strSetByteHelperName "strSetByte" [ B.eqref, B.i32, B.i32 ] B.none
  imp arrayConcatHelperName "arrayConcat" [ B.eqref, B.eqref ] B.eqref
  -- `Wasm.Array` build primitives (WasmBase, ADR 0026): `arrayNew n` allocates; `arraySet`
  -- writes in place and returns nothing (the intrinsic threads the array back, `Codegen.Prim`).
  imp arrayNewHelperName "arrayNew" [ B.i32 ] B.eqref
  imp arraySetHelperName "arraySet" [ B.eqref, B.i32, B.eqref ] B.none
  imp intModHelperName "intMod" [ B.i32, B.i32 ] B.i32
  imp intDivHelperName "intDiv" [ B.i32, B.i32 ] B.i32
  imp intDegreeHelperName "intDegree" [ B.i32 ] B.i32
  -- Effect.Ref / ST.STRef native cell ops (ADR 0017)
  imp refNewHelperName "refNew" [ B.eqref ] B.eqref
  imp refReadHelperName "refRead" [ B.eqref ] B.eqref
  imp refWriteHelperName "refWrite" [ B.eqref, B.eqref ] B.i32
  imp refNewWithSelfHelperName "refNewWithSelf" [ B.eqref ] B.eqref
  imp refModifyHelperName "refModify" [ B.eqref, B.eqref, B.i32, B.i32 ] B.eqref
  -- `effect` package control-flow primitives (ADR 0018)
  imp forEHelperName "forE" [ B.i32, B.i32, B.eqref ] B.i32
  imp foreachEHelperName "foreachE" [ B.eqref, B.eqref ] B.i32
  imp whileEHelperName "whileE" [ B.eqref, B.eqref ] B.i32
  imp untilEHelperName "untilE" [ B.eqref ] B.i32
  -- the closure-apply trampoline, reused by `runEffectFnN` (ADR 0018)
  imp applyCloHelperName "applyClo" [ B.eqref, B.eqref ] B.eqref

-- | The shared record/dictionary projection helper.
projHelperName :: String
projHelperName = "$rt.proj"

-- | `Record.Unsafe` string-keyed record helpers (defined in `runtime.wat`): test
-- | for a label id, and rebuild the record with a label id set / deleted.
recHasHelperName :: String
recHasHelperName = "$rt.recHas"

recSetHelperName :: String
recSetHelperName = "$rt.recSet"

recDeleteHelperName :: String
recDeleteHelperName = "$rt.recDelete"

-- | Runtime label-name → interned id (defined in `runtime.wat`): hashes the `$Str`'s
-- | UTF-8 bytes with the same hash the compiler assigns a static label (`Lower.LabelHash`,
-- | ADR 0037 ④), so a host field name resolves to the id its record stores. Hashing is
-- | total, so there is no separate dynamic-name table — a name introduced via record
-- | metaprogramming hashes the same as a syntactic label.
internStrHelperName :: String
internStrHelperName = "$rt.internStr"

-- | The emitted thin wrapper that exposes the runtime `internStr` hash under a local
-- | name (and, when a record crosses the host boundary, as the `internStr` export the
-- | marshalling glue calls — `runtime/marshal.js`). Internal call sites (`Codegen.Prim`'s
-- | string-keyed record access, `modifyImpl`) call it. (Named here so the record
-- | intrinsics and the emitter agree.)
internStrName :: String
internStrName = "$internStr"

-- | The mutable global backing the test-only effectful counter (`incrCtr`/`readCtr`).
counterGlobalName :: String
counterGlobalName = "$ctr"

-- | The shared string byte-equality helper: returns `i32` `1`/`0`.
strEqHelperName :: String
strEqHelperName = "$rt.strEq"

-- | The shared lexicographic string comparison helper: returns `i32` `-1`/`0`/`1`.
strCmpHelperName :: String
strCmpHelperName = "$rt.strCmp"

-- | The shared string concatenation helper.
strConcatHelperName :: String
strConcatHelperName = "$rt.strConcat"

-- | `Wasm.String` byte builders (ADR 0030): allocate a zeroed `$Str` / write a byte in place.
strNewHelperName :: String
strNewHelperName = "$rt.strNew"

strSetByteHelperName :: String
strSetByteHelperName = "$rt.strSetByte"

-- | The shared array concatenation helper.
arrayConcatHelperName :: String
arrayConcatHelperName = "$rt.arrayConcat"

arrayNewHelperName :: String
arrayNewHelperName = "$rt.arrayNew"

arraySetHelperName :: String
arraySetHelperName = "$rt.arraySet"

-- | The shared Euclidean `Int` division/remainder/degree helpers.
intModHelperName :: String
intModHelperName = "$rt.intMod"

intDivHelperName :: String
intDivHelperName = "$rt.intDiv"

intDegreeHelperName :: String
intDegreeHelperName = "$rt.intDegree"

-- | `Effect.Ref` / `Control.Monad.ST` native mutable-cell ops (defined in
-- | `runtime.wat`, ADR 0017). `refWrite` returns the `Unit` `i32` `0`; `refModify`
-- | takes the interned `state`/`value` label ids resolved at lowering.
refNewHelperName :: String
refNewHelperName = "$rt.refNew"

refReadHelperName :: String
refReadHelperName = "$rt.refRead"

refWriteHelperName :: String
refWriteHelperName = "$rt.refWrite"

refNewWithSelfHelperName :: String
refNewWithSelfHelperName = "$rt.refNewWithSelf"

refModifyHelperName :: String
refModifyHelperName = "$rt.refModify"

-- | `effect` package control-flow primitives (defined in `runtime.wat`, ADR 0018).
forEHelperName :: String
forEHelperName = "$rt.forE"

foreachEHelperName :: String
foreachEHelperName = "$rt.foreachE"

whileEHelperName :: String
whileEHelperName = "$rt.whileE"

untilEHelperName :: String
untilEHelperName = "$rt.untilE"

-- | The runtime closure-apply trampoline (`$callClo1`, exported as `applyClo`), reused by
-- | `runEffectFnN` to apply the uncurried function's arguments one at a time (ADR 0018).
applyCloHelperName :: String
applyCloHelperName = "$callClo1"
