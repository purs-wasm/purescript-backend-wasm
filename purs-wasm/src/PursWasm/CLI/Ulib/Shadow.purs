-- | ulib lib scan (ADR 0028 / 0031): map each bundled-lib module to its shadow `corefn.json` and
-- | kept-foreign `foreign.wasm` candidate paths. The build's `Manifest.resolveModuleSet` (manifest +
-- | lock) then decides, per module, whether to take the lib corefn over the registry one.
module PursWasm.CLI.Ulib.Shadow
  ( Shadow
  , loadShadowMap
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import PursWasm.CLI.Effect (FS, FilePath, exists, joinPath, readDir)
import PursWasm.CLI.Ulib.Manifest (isLibModuleDir)
import Run (Run)
import Type.Row (type (+))

-- | A lib entry for a registry module: candidate paths for its shadow `corefn.json` and its
-- | kept-foreign `foreign.wasm` (ADR 0031 — either may be absent: a wat-only module has no corefn,
-- | a foreign-free shadow has no foreign.wasm). Existence is checked by the caller. The version is
-- | no longer stored — it lives in the manifest, and the build's `resolveModuleSet` drives resolution.
type Shadow = { corefn :: FilePath, foreignWasm :: FilePath }

-- | Scan the (flat, ADR 0031 §2.2) lib: each `<lib>/<Module>/` holds a shadow `corefn.json` and/or a
-- | kept-foreign `foreign.wasm`. Returns a `Module name -> Shadow` map; an absent lib → empty.
loadShadowMap :: forall r. FilePath -> Run (FS + r) (Map String Shadow)
loadShadowMap libPath = do
  present <- exists libPath
  if not present then pure Map.empty
  else readDir libPath >>= case _ of
    Nothing -> pure Map.empty
    -- the lib root also holds self-describing files (`ulib-manifest.json`, `_header.wat`, ADR 0031) —
    -- `isLibModuleDir` filters those out so only module dirs are scanned.
    Just ms -> Map.fromFoldable <$> for (Array.filter isLibModuleDir ms) \m -> do
      corefn <- joinPath [ libPath, m, "corefn.json" ]
      foreignWasm <- joinPath [ libPath, m, "foreign.wasm" ]
      pure (Tuple m { corefn, foreignWasm })
