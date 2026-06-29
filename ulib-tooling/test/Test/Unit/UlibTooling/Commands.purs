-- | Unit tests for `ulibInstallCmd` against the in-memory interpreter: the command's job is to
-- | invoke `ulib-install.sh` with the right resolved paths (or skip when the lib is already
-- | present), and to resolve the lib path by the precedence `-L` flag > `$PURS_WASM_LIB` > default.
-- | We assert the recorded `execFile` calls rather than touching disk. (`check` leans on `Effect` —
-- | CBOR decode, throwing — so its pure pieces and the interface diff are tested elsewhere.)
module Test.Unit.UlibTooling.Commands (spec) where

import Prelude

import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), fst)
import PureScript.Backend.Wasm.CLI.Paths (wasmAsBin)
import UlibTooling.Commands (ulibInstallCmd)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Unit.UlibTooling.Effect.Memory (emptyWorld, runMem, worldOfText)

-- The install-script invocation the command builds from `cliRoot` + the defaults (ADR 0031): assets
-- live under `cliRoot` (the repo root) — the script in `ulib-tooling/`, the lib/ulib dirs as
-- siblings, `purs` on PATH, the `ulib-manifest.json` (the version source), the `wasm-as` from the
-- resolved binaryen bin dir, and the `.spago/p` package-set sources (WasmBase comes in there too,
-- as the resolved `wasm-base` package). (The in-memory `joinPath` drops `.`/empty.)
defaultInvoke :: Tuple String (Array String)
defaultInvoke =
  Tuple "sh"
    [ "cli/ulib-tooling/ulib-install.sh"
    , "cli/lib"
    , "cli/ulib"
    , "purs"
    , "cli/ulib/ulib-manifest.json"
    , wasmAsBin "bin"
    , ".spago/p"
    ]

-- | The same invocation but with the lib path replaced — for the `-L` / `$PURS_WASM_LIB` cases.
invokeWithLib :: String -> Tuple String (Array String)
invokeWithLib lib =
  Tuple "sh"
    [ "cli/ulib-tooling/ulib-install.sh", lib, "cli/ulib", "purs", "cli/ulib/ulib-manifest.json", wasmAsBin "bin", ".spago/p" ]

spec :: Spec Unit
spec = describe "UlibTooling.Commands.ulibInstallCmd" do

  it "invokes ulib-install.sh with the resolved default paths when no lib is present" do
    let opt = { libPath: Nothing, purs: Nothing, force: false }
    let world = fst (runMem emptyWorld (ulibInstallCmd "cli" "bin" opt))
    world.execs `shouldEqual` [ defaultInvoke ]

  it "resolves the lib path from $PURS_WASM_LIB when set and no -L is given" do
    let opt = { libPath: Nothing, purs: Nothing, force: false }
    let world0 = emptyWorld { env = Map.singleton "PURS_WASM_LIB" "/opt/ulib" }
    let world = fst (runMem world0 (ulibInstallCmd "cli" "bin" opt))
    world.execs `shouldEqual` [ invokeWithLib "/opt/ulib" ]

  it "lets an explicit -L override $PURS_WASM_LIB" do
    let opt = { libPath: Just "out/mylib", purs: Nothing, force: false }
    let world0 = emptyWorld { env = Map.singleton "PURS_WASM_LIB" "/opt/ulib" }
    let world = fst (runMem world0 (ulibInstallCmd "cli" "bin" opt))
    world.execs `shouldEqual` [ invokeWithLib "out/mylib" ]

  it "skips (no exec) when the lib is already present and --force is not given" do
    let opt = { libPath: Nothing, purs: Nothing, force: false }
    -- a single file under the default lib path makes `exists` report it present
    let world0 = worldOfText [ Tuple "cli/lib/arrays-7.3.0/Data.Array/corefn.json" "{}" ]
    let world = fst (runMem world0 (ulibInstallCmd "cli" "bin" opt))
    world.execs `shouldEqual` []

  it "with --force, removes the present lib then recompiles" do
    let opt = { libPath: Nothing, purs: Nothing, force: true }
    let world0 = worldOfText [ Tuple "cli/lib/arrays-7.3.0/Data.Array/corefn.json" "{}" ]
    let world = fst (runMem world0 (ulibInstallCmd "cli" "bin" opt))
    world.execs `shouldEqual`
      [ Tuple "rm" [ "-rf", "cli/lib" ]
      , defaultInvoke
      ]

  it "honours an explicit --lib-path and --purs" do
    let opt = { libPath: Just "out/mylib", purs: Just "/usr/bin/purs", force: false }
    let world = fst (runMem emptyWorld (ulibInstallCmd "cli" "bin" opt))
    world.execs `shouldEqual`
      [ Tuple "sh"
          [ "cli/ulib-tooling/ulib-install.sh"
          , "out/mylib"
          , "cli/ulib"
          , "/usr/bin/purs"
          , "cli/ulib/ulib-manifest.json"
          , wasmAsBin "bin"
          , ".spago/p"
          ]
      ]
