-- | Reconstruct the foreign calling-convention signatures the compiler/loader need, as the union
-- | of three sources (later overriding earlier): the modules' externs (`foreignSigs`), the
-- | `.purs` source for *private* `*Impl` foreigns externs omit (ADR 0016), and the curated
-- | `ulib/<M>/foreign.wat` export signatures (ADR 0012, authoritative for the polymorphic foreigns
-- | the merged provider satisfies). Keyed by `Module.ident`.
module PursWasm.CLI.Build.ForeignSigs
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
import PureScript.CoreFn (Module)
import PureScript.ExternsFile (ExternsFile)
import PursWasm.CLI.Build.Paths (ulibDir)
import PursWasm.CLI.Effect (FS, FilePath, exists, joinPath, readText)
import PursWasm.CLI.Module (printModname)
import Run (Run)
import Type.Row (type (+))

-- | Module name → its `.purs` source path, parsed from spago's `cache-db.json` (ADR 0016).
foreign import cacheDbSourcesImpl :: String -> Object String

buildForeignSigs
  :: forall r
   . FilePath
  -> Array ExternsFile
  -> Array Module
  -> Run (FS + r) (Object ForeignImport)
buildForeignSigs input externs modules = do
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
  -- ulib (ADR 0012): for a module with no project-local provider, read `ulib/<M>/foreign.wat`'s
  -- export signatures (the wasm export is the source of truth) — this covers polymorphic `*Impl`
  -- foreigns whose arity externs cannot reconstruct, and overrides externs/source.
  ulibSigsByMod <- for modules \m -> do
    let mn = printModname m.name
    projWasm <- exists =<< joinPath [ input, mn, "foreign.wasm" ]
    projWat <- exists =<< joinPath [ input, mn, "foreign.wat" ]
    if projWasm || projWat then pure Object.empty
    else do
      ulibWat <- joinPath [ ulibDir, mn, "foreign.wat" ]
      has <- exists ulibWat
      if has then maybe Object.empty (parseUlibSigs mn) <$> readText ulibWat
      else pure Object.empty
  let ulibSigs = Array.foldl Object.union Object.empty ulibSigsByMod
  pure (Object.union ulibSigs (Object.union externsSigs srcSigs))
