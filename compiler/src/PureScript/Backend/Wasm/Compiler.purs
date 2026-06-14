-- | The public build facade: parse `corefn.json` sources and link a set of
-- | modules into one wasm binary (ADR 0009). This keeps the CLI (`purs-wasm`) free of
-- | the Argonaut / Binaryen / IR details — it only does file I/O and calls these.
module PureScript.Backend.Wasm.Compiler
  ( CompileOptions
  , CompiledModule
  , parseModule
  , linkModule
  , compileModules
  , compileModulesText
  , mirTrace
  ) where

import Prelude

import Binaryen as B
import Data.Argonaut.Decode (printJsonDecodeError)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..))
import Data.Maybe (Maybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (joinWith)
import Data.Traversable (traverse)
import Effect (Effect)
import Foreign.Object (Object)
import PureScript.Backend.Wasm.Codegen (buildModule)
import PureScript.Backend.Wasm.Externs (ForeignSig, ctorFieldReps, effectfulForeignAritiesFromSigs, effectfulForeignNamesFromSigs)
import PureScript.Backend.Wasm.Intrinsics (effectfulForeignNames)
import PureScript.Backend.Wasm.Lower (lowerModules)
import PureScript.Backend.Wasm.MiddleEnd (CacheInput, CacheWrite, noCache, optimizeProgramCached, optimizeProgramTrace)
import PureScript.CoreFn (Module, ModuleName)
import PureScript.CoreFn.FromJSON (decodeModule)
import PureScript.ExternsFile (ExternsFile)

-- | Parse a `corefn.json` source string into a `Module`, with failures rendered
-- | as a message.
parseModule :: String -> Either String Module
parseModule source = case jsonParser source of
  Left parseErr -> Left ("corefn parse error: " <> parseErr)
  Right json -> case decodeModule json of
    Left decodeErr -> Left ("corefn decode error: " <> printJsonDecodeError decodeErr)
    Right m -> Right m

-- | Build options. `optimize` runs Binaryen's optimizer (which also DCE-drops the
-- | non-root functions); turning it off (a debug build) keeps the wasm closer to
-- | the emitted IR — and is where source-map support will hang once CoreFn source
-- | spans are threaded through to Binaryen debug locations. `optimizeMir` toggles
-- | the middle-end (dictionary elimination); off builds an unoptimized baseline
-- | (lambda lifting still runs, since it is needed for constant-stack tail recursion).
type CompileOptions = { optimize :: Boolean, optimizeMir :: Boolean }

-- | The live result of `linkModule` (the "link" half of link/emit, ADR 0021): the built
-- | Binaryen module, the distinct user-foreign source modules to resolve (ADR 0014), and the
-- | CAF-init function (`Nothing` if none) whose run trigger — loader call vs wasm `start` — is
-- | the caller's packaging decision (ADR 0006). The caller emits and disposes `mod`.
type CompiledModule =
  { mod :: B.Module
  , foreignModules :: Array String
  , cafInit :: Maybe B.Function
  -- The incremental-cache misses produced by this link (ADR 0032 phase 4 / ADR 0034), for
  -- the caller to persist as `.pmi` + `.pmo` pairs. Empty unless a `CacheInput` with module
  -- source hashes was supplied; the caller owns the filesystem.
  , cacheWrites :: Array CacheWrite
  }

-- | Link the given modules into one validated Binaryen module and return the **live**
-- | artifact (the module, the foreign sources to resolve, the CAF-init function) — the
-- | "link" half of the link/emit split (ADR 0021). The caller owns packaging (resolve
-- | foreigns, decide the CAF-init trigger, `setStart`) and then **emits and disposes** the
-- | module. `roots` are the entry modules whose functions stay exported; everything else is
-- | internal and so removed by the optimizer's DCE (ADR 0009). Linking or validation
-- | failures come back as a message (and dispose the module). `foreignSigs` is the
-- | foreign-import calling conventions to resolve against — the caller merges any
-- | source-reconstructed signatures (ADR 0016) over the externs-derived ones, so private
-- | foreigns are covered. `externs` still supplies constructor field reps.
linkModule
  :: CompileOptions
  -> Array ModuleName
  -> Array Module
  -> Array ExternsFile
  -> Object ForeignSig
  -> CacheInput
  -> Effect (Either String CompiledModule)
linkModule opts roots modules externs foreignSigs' cache =
  case lowered of
    Left err -> pure (Left ("linking failed: " <> show err))
    Right program -> do
      built <- buildModule program
      when opts.optimize (B.optimize built.mod)
      ok <- B.validate built.mod
      if not ok then do
        wat <- B.emitText built.mod
        B.dispose built.mod
        pure (Left ("emitted module failed validation:\n" <> wat))
      else pure (Right { mod: built.mod, foreignModules: built.foreignModules, cafInit: built.cafInit, cacheWrites: optimized.writes })
  where
  -- Prune to the modules transitively imported by the entry roots BEFORE optimizing — the
  -- input dir holds the whole dependency build (often hundreds of modules), but optimizing
  -- them all is wasted work and overflows the optimizer's stack on a real closure (ADR 0009;
  -- the function-level reachability DCE in `lowerModules` runs afterwards over this set).
  reachable = reachableModules roots modules
  -- every CoreFn-declared foreign name (qualified); lets lowering fall back to an
  -- all-opaque host import when a foreign has no reconstructed signature (ADR 0016)
  foreignNames = Set.fromFoldable (reachable >>= \m -> map (\base -> joinWith "." m.name <> "." <> base) m.foreignNames)
  -- the effectful-foreign set/arities (intrinsics ∪ those declared by the sigs) that the
  -- optimizer must preserve `Perform`s for; the same pair `mirTrace` uses (ADR 0015).
  effSet = Set.union effectfulForeignNames (effectfulForeignNamesFromSigs foreignSigs')
  effArities = effectfulForeignAritiesFromSigs foreignSigs'
  optimized = optimizeProgramCached opts.optimizeMir effSet effArities cache reachable
  lowered = lowerModules opts.optimizeMir (ctorFieldReps externs) foreignSigs' foreignNames roots optimized.modules

-- | The modules transitively reachable from `roots` through CoreFn imports (a fixpoint over
-- | each kept module's import list). Used to drop unreached dependency modules before the
-- | middle-end runs.
reachableModules :: Array ModuleName -> Array Module -> Array Module
reachableModules roots modules = Array.filter (\m -> Set.member (joinWith "." m.name) keep) modules
  where
  keep = fixpoint (Set.fromFoldable (map (joinWith ".") roots))

  fixpoint :: Set String -> Set String
  fixpoint seen =
    let
      next = Array.foldl addImports seen modules
    in
      if Set.size next == Set.size seen then seen else fixpoint next
  addImports seen m
    | Set.member (joinWith "." m.name) seen =
        Set.union seen (Set.fromFoldable (map (\i -> joinWith "." i.moduleName) m.imports))
    | otherwise = seen

-- | Link the given modules into one wasm and return its binary bytes. `externs`
-- | supplies type information for type-directed lowering (front B); pass `[]` to
-- | build without it (everything stays boxed). This is the whole-program convenience that
-- | runs CAF init via the wasm `start` section (suitable for a self-contained build with no
-- | re-entrant JS foreigns); the CLI uses `linkModule` directly so packaging can decide the
-- | CAF-init trigger (ADR 0006 / 0021).
compileModules :: CompileOptions -> Array ModuleName -> Array Module -> Array ExternsFile -> Object ForeignSig -> Effect (Either String Uint8Array)
compileModules opts roots modules externs sigs =
  linkModule opts roots modules externs sigs noCache >>= traverse (emitAndDispose B.emitBinary)

-- | Link the given modules into one wasm and return its WAT (text) form.
compileModulesText :: CompileOptions -> Array ModuleName -> Array Module -> Array ExternsFile -> Object ForeignSig -> Effect (Either String String)
compileModulesText opts roots modules externs sigs =
  linkModule opts roots modules externs sigs noCache >>= traverse (emitAndDispose B.emitText)

-- | Run CAF init via the wasm `start` section, then emit and dispose the module — the
-- | self-contained path (`compileModules`/`compileModulesText`). The CLI instead emits via
-- | `linkModule` so it can route CAF init through the loader (ADR 0006 / 0021).
emitAndDispose :: forall a. (B.Module -> Effect a) -> CompiledModule -> Effect a
emitAndDispose emit built = do
  maybe (pure unit) (B.setStart built.mod) built.cafInit
  out <- emit built.mod
  B.dispose built.mod
  pure out

-- | Trace the named module's middle IR (MIR) — its form after specialization and after it
-- | is optimized (simplify → impurify → simplify) — the `--dump-mir` companion to the
-- | normal build, using the *same* effectful-foreign set/arities so the trace matches the
-- | real pipeline. `target` is a dotted module name (e.g. `Examples.EffRef.Main`).
mirTrace :: CompileOptions -> Array Module -> Object ForeignSig -> String -> String
mirTrace opts modules foreignSigs' target =
  joinWith "\n\n" (optimizeProgramTrace opts.optimizeMir effSet effArities target modules)
  where
  effSet = Set.union effectfulForeignNames (effectfulForeignNamesFromSigs foreignSigs')
  effArities = effectfulForeignAritiesFromSigs foreignSigs'
