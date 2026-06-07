-- | End-to-end test of a real **host effectful foreign** (ADR 0015): `record :: Int ->
-- | Effect Unit` (JS `n => () => spy.push(n)`). `runRec` performs `record 1` then
-- | `record 2` in an `unsafePerformEffect do`-block; the whole chain is verified —
-- | externs (`Effect` result → `MEffect`) → effectful-foreign purity (runs preserved,
-- | not dropped) → `Perform` lowered to a host call → marshalling glue runs the thunk on
-- | the JS side. The spy records the order and count of the actual runs.
module Test.E2E.HostEff (spec) where

import Prelude

import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign (Foreign)
import Node.Cbor (decodeFirst)
import Node.FS.Sync (readFile)
import PureScript.ExternsFile (ExternsFile)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import Test.E2E.Wasm (callI32x0, callI32x1, instantiateForeignStr)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

foreign import recordImports :: Foreign
foreign import resetSpy :: Effect Unit
foreign import readSpy :: Effect String

decodeExterns :: String -> Aff (Either _ ExternsFile)
decodeExterns path = do
  buf <- liftEffect (readFile path)
  fgn <- decodeFirst buf
  pure (runDecoder decoder fgn)

spec :: Spec Unit
spec = describe "Test.E2E.HostEff (host effectful FFI, ADR 0015)" do
  it "performs host effects in order, each exactly once (record 1; record 2)" do
    decodeExterns "compiler/test/fixtures/HostEff.externs.cbor" >>= case _ of
      Left err -> fail (show err)
      Right ef -> do
        inst <- liftEffect
          ( instantiateForeignStr [ ef ] recordImports
              [ [ "HostEff" ] ]
              [ "compiler/test/fixtures/HostEff.corefn.json"
              , "compiler/test/fixtures/Effect.corefn.json"
              , "compiler/test/fixtures/Effect.Unsafe.corefn.json"
              , "compiler/test/fixtures/Control.Applicative.corefn.json"
              , "compiler/test/fixtures/Control.Apply.corefn.json"
              , "compiler/test/fixtures/Control.Bind.corefn.json"
              , "compiler/test/fixtures/Control.Monad.corefn.json"
              , "compiler/test/fixtures/Data.Functor.corefn.json"
              , "compiler/test/fixtures/Data.Semiring.corefn.json"
              , "compiler/test/fixtures/Data.Unit.corefn.json"
              , "compiler/test/fixtures/Data.Function.corefn.json"
              ]
          )
        -- ADR 0006 / 0015: merely loading the module (instantiation runs the CAF-init
        -- `start`) must NOT perform any top-level `Effect` — `mainEff`/`deadEff` stay
        -- deferred thunks, never eager-initialised, so the spy is empty at load.
        liftEffect readSpy >>= (_ `shouldEqual` "")
        liftEffect resetSpy
        r <- liftEffect (callI32x1 inst "runRec" 0)
        r `shouldEqual` 0
        -- the spy must have seen exactly [1, 2] — effects ran, in order, not dropped
        trace <- liftEffect readSpy
        trace `shouldEqual` "1,2"
        -- the real Hello World: `greet` performs a host `console.log "Hello, World!"`
        -- through the whole pipeline (visible in the test output)
        liftEffect (callI32x1 inst "greet" 0) >>= (_ `shouldEqual` 0)
        -- a NULLARY host effect (`tick :: Effect Int`, JS `() => 99`): the foreign is the
        -- thunk itself — the glue must not pre-call it (regression for `r is not a function`)
        liftEffect (callI32x1 inst "getTick" 0) >>= (_ `shouldEqual` 99)
        -- a top-level `Effect Unit` export performs only when CALLED, exactly once;
        -- `deadEff` is never called, so its `record 99` never fires (helloworld's `sub`).
        liftEffect resetSpy
        liftEffect (callI32x0 inst "mainEff") >>= (_ `shouldEqual` 0)
        liftEffect readSpy >>= (_ `shouldEqual` "7")
