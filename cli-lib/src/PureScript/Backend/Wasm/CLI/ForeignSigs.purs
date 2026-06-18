-- | Reconstruct the foreign calling-convention signatures the compiler/loader need, as the union
-- | of three sources (precedence ulib > externs > source): the modules' externs (`foreignSigs`),
-- | the `.purs` source for *private* `*Impl` foreigns externs omit (ADR 0016), and the curated
-- | `ulib/<M>/foreign.wat` export signatures (ADR 0012, authoritative for the polymorphic foreigns
-- | the merged provider satisfies). Keyed by `Module.ident`.
module PureScript.Backend.Wasm.CLI.ForeignSigs
  ( buildForeignSigs
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), maybe)
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Externs (foreignSigs)
import PureScript.Backend.Wasm.Lower.IR (ForeignImport)
import PureScript.Backend.Wasm.SourceForeigns (parseForeignSigs)
import PureScript.Backend.Wasm.Ulib (parseUlibSigs)
import PureScript.CoreFn (ModuleName)
import PureScript.ExternsFile (ExternsFile)
import PureScript.Backend.Wasm.CLI.Effect (FS, FilePath, exists, joinPath, readText)
import PureScript.Backend.Wasm.CLI.Module (printModname)
import Run (Run)
import Type.Row (type (+))

-- | Module name → its `.purs` source path, parsed from spago's `cache-db.json` (ADR 0016).
foreign import cacheDbSourcesImpl :: String -> Object String

-- | Only a module's `name` and `foreignNames` are consulted, so the incremental (`--cache`) path
-- | can pass these (cheaply extracted from corefn text) without decoding a cache hit (ADR 0034).
buildForeignSigs
  :: forall r s
   . FilePath
  -> FilePath
  -> Array ExternsFile
  -> Array { name :: ModuleName, foreignNames :: Array String | s }
  -> Run (FS + r) (Object ForeignImport)
buildForeignSigs input libPath externs modules = do
  let externsSigs = foreignSigs externs
  -- externs win over source (`Object.union` is left-biased): externs types are already desugared
  -- by `purs`, so they are authoritative for *exported* foreigns; source fills only the private
  -- foreigns externs omit (ADR 0016). We parse a module's source only when its CoreFn names a
  -- foreign externs do NOT cover, so the common all-exported-foreigns module never pays the cost.
  sourcePaths <- maybe Object.empty cacheDbSourcesImpl <$> (readText =<< joinPath [ input, "cache-db.json" ])
  srcSigsByMod <- for modules \m -> do
    let mn = printModname m.name
    let hasPrivate = Array.any (\base -> not (Object.member (mn <> "." <> base) externsSigs)) m.foreignNames
    case Tuple hasPrivate (Object.lookup mn sourcePaths) of
      Tuple true (Just path) -> maybe Object.empty parseForeignSigs <$> readText path
      _ -> pure Object.empty
  let srcSigs = Array.foldl Object.union Object.empty srcSigsByMod
  -- ulib (ADR 0031 §6.1): for a module with no project-local provider, read the kept foreign's
  -- export signatures from the lib's `$LIB/<M>/foreign.wat` (shipped beside `foreign.wasm` at
  -- install) — the wasm export is the source of truth for the calling convention, covering the
  -- polymorphic / unboxed-`Int` `*Impl` foreigns whose marshalling externs cannot reconstruct (e.g.
  -- `Data.Array.rangeImpl`'s `(param i32)`); overrides externs/source. Reading from the lib (not the
  -- ulib source tree) keeps the build self-contained for the lib-override flow (the planned
  -- `ulib upgrade` command, ADR 0031 §5, is not yet implemented).
  ulibSigsByMod <- for modules \m -> do
    let mn = printModname m.name
    projWasm <- exists =<< joinPath [ input, mn, "foreign.wasm" ]
    projWat <- exists =<< joinPath [ input, mn, "foreign.wat" ]
    if projWasm || projWat then pure Object.empty
    else do
      libWat <- joinPath [ libPath, mn, "foreign.wat" ]
      has <- exists libWat
      if has then maybe Object.empty (parseUlibSigs mn) <$> readText libWat
      else pure Object.empty
  let ulibSigs = Array.foldl Object.union Object.empty ulibSigsByMod
  pure (Object.union ulibSigs (Object.union externsSigs srcSigs))
