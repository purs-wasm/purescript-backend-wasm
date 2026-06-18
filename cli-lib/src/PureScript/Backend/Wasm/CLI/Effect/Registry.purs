-- | An abstract "read from the PureScript registry" effect, in the shape of registry-dev's
-- | `Registry`/`PackageSets` effects (domain operations as constructors; the *how* lives in the
-- | interpreter). `ulib compat` needs exactly one read — the compilers a published package version
-- | was tested against — so that is the only operation here. Modelling it abstractly (rather than
-- | calling `spago registry info` inline) buys two things:
-- |
-- |   * testability — a stub interpreter returns canned compiler lists, so `ulib compat`'s
-- |     regenerate path is unit-testable without the network or a `spago` on PATH;
-- |   * portability — the registry source (today: `spago`, layered over `PROC`) is swappable, the
-- |     same way path ops are abstracted behind the `Filesystem` effect for the WASI self-host goal.
-- |
-- | A query failure (offline, no `spago`) is returned as `Left <message>` rather than thrown:
-- | `ulib compat` treats it as non-fatal and falls back to the prior pin, so — unlike registry-dev,
-- | which threads errors through a separate `EXCEPT` — the failure is part of the result value.
module PureScript.Backend.Wasm.CLI.Effect.Registry
  ( RegistryF(..)
  , REGISTRY
  , _registry
  , interpret
  , supportedCompilers
  , spagoHandler
  ) where

import Prelude

import Data.Argonaut.Core (Json, toArray, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either, hush)
import Data.Maybe (Maybe, fromMaybe)
import Data.String (Pattern(..))
import Data.String as Str
import Foreign.Object as FO
import PureScript.Backend.Wasm.CLI.Effect.Process (PROC, execFileCapture)
import Run (Run)
import Run as Run
import Type.Proxy (Proxy(..))
import Type.Row (type (+))

-- | The registry-read algebra. `SupportedCompilers <package> <version>` yields the `compilers`
-- | list that version was published-tested against (`Left` on a query failure).
data RegistryF a = SupportedCompilers String String (Either String (Array String) -> a)

derive instance functorRegistryF :: Functor RegistryF

type REGISTRY r = (registry :: RegistryF | r)

_registry :: Proxy "registry"
_registry = Proxy

interpret :: forall r a. (RegistryF ~> Run r) -> Run (REGISTRY + r) a -> Run r a
interpret h = Run.interpret (Run.on _registry h Run.send)

-- | The compilers the given package version was published-tested against, or `Left` if the registry
-- | could not be queried (the caller decides whether that is fatal).
-- |
-- | `Either` rather than `EXCEPT`: a query failure here is *recoverable* (`ulib compat` falls back
-- | to the prior pin), so it should stay an ordinary value the caller pattern-matches — not a
-- | short-circuit that aborts the whole `Run`. Reserve `EXCEPT` for genuinely fatal errors.
supportedCompilers :: forall r. String -> String -> Run (REGISTRY + r) (Either String (Array String))
supportedCompilers package version = Run.lift _registry (SupportedCompilers package version identity)

-- | The production interpreter: ask `spago registry info <package> --json` and read the version's
-- | `compilers` list out of the payload. Layered over `PROC` (the only platform-native dependency,
-- | itself abstract), so this module stays Node-agnostic. A capture failure (offline / no `spago`)
-- | propagates as `Left`; a present-but-shapeless payload yields `Right []` (no compilers recorded),
-- | matching the prototype's `?? []`.
spagoHandler :: forall r. RegistryF ~> Run (PROC + r)
spagoHandler = case _ of
  SupportedCompilers package version reply -> do
    result <- execFileCapture "spago" [ "registry", "info", package, "--json" ]
    pure (reply (compilersOf version <$> result))

-- | The `compilers` list a `spago registry info --json` payload records for `version`. The CLI
-- | prints a log preamble before the JSON, so we slice to the first `{`.
compilersOf :: String -> String -> Array String
compilersOf version out = fromMaybe [] do
  json <- hush (jsonParser (dropToFirstBrace out))
  arr <- field "published" json >>= field version >>= field "compilers" >>= toArray
  pure (Array.mapMaybe toString arr)

field :: String -> Json -> Maybe Json
field k j = toObject j >>= FO.lookup k

dropToFirstBrace :: String -> String
dropToFirstBrace s = fromMaybe s (flip Str.drop s <$> Str.indexOf (Pattern "{") s)
