-- | Unit tests for `ulibInstallCmd` against the in-memory interpreter: the command's job is to
-- | invoke `ulib-install.sh` with the right resolved paths (or skip when the lib is already
-- | present). We assert the recorded `execFile` calls rather than touching disk. (`validate`/
-- | `check` lean on `Effect` — CBOR decode, throwing — so they fall to the differential harness;
-- | their pure pieces, `splitPkgVer`/`majorMinor` and the interface diff, are tested elsewhere.)
module Test.Unit.PursWasm.CLI.Ulib (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), fst)
import PursWasm.CLI.Ulib (ulibInstallCmd)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Unit.PursWasm.CLI.Effect.Memory (emptyWorld, runMem, worldOfText)

-- The install-script invocation the command builds from `cliRoot` + the defaults: the script
-- beside the CLI, the lib/shadow/wasm-base dirs relative to `<cli>/..`, `purs` on PATH, and the
-- `.spago/p` package-set sources. (The in-memory `joinPath` keeps `..` and drops `.`/empty.)
defaultInvoke :: Tuple String (Array String)
defaultInvoke =
  Tuple "sh"
    [ "cli/ulib-install.sh"
    , "cli/../lib"
    , "cli/../ulib/shadow"
    , "cli/../wasm-base/src"
    , "purs"
    , ".spago/p"
    ]

spec :: Spec Unit
spec = describe "PursWasm.CLI.Ulib.ulibInstallCmd" do

  it "invokes ulib-install.sh with the resolved default paths when no lib is present" do
    let opt = { libPath: Nothing, purs: Nothing, force: false }
    let world = fst (runMem emptyWorld (ulibInstallCmd "cli" opt))
    world.execs `shouldEqual` [ defaultInvoke ]

  it "skips (no exec) when the lib is already present and --force is not given" do
    let opt = { libPath: Nothing, purs: Nothing, force: false }
    -- a single file under the default lib path makes `exists` report it present
    let world0 = worldOfText [ Tuple "cli/../lib/arrays-7.3.0/Data.Array/corefn.json" "{}" ]
    let world = fst (runMem world0 (ulibInstallCmd "cli" opt))
    world.execs `shouldEqual` []

  it "with --force, removes the present lib then recompiles" do
    let opt = { libPath: Nothing, purs: Nothing, force: true }
    let world0 = worldOfText [ Tuple "cli/../lib/arrays-7.3.0/Data.Array/corefn.json" "{}" ]
    let world = fst (runMem world0 (ulibInstallCmd "cli" opt))
    world.execs `shouldEqual`
      [ Tuple "rm" [ "-rf", "cli/../lib" ]
      , defaultInvoke
      ]

  it "honours an explicit --lib-path and --purs" do
    let opt = { libPath: Just "out/mylib", purs: Just "/usr/bin/purs", force: false }
    let world = fst (runMem emptyWorld (ulibInstallCmd "cli" opt))
    world.execs `shouldEqual`
      [ Tuple "sh"
          [ "cli/ulib-install.sh"
          , "out/mylib"
          , "cli/../ulib/shadow"
          , "cli/../wasm-base/src"
          , "/usr/bin/purs"
          , ".spago/p"
          ]
      ]
