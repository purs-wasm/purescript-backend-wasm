-- | End-to-end coverage of **point-free top-level definitions**. A binding like
-- | `incFromTen = plus 10` has no lambda, so the backend compiles it to a *nullary*
-- | function returning a closure — its compiled arity is less than its type arity.
-- | The export wrapper recovers the full type arity by calling the nullary function
-- | and applying the remaining argument(s) to the returned closure, so a JS/host
-- | caller sees a normal n-ary function (it would otherwise trap with `illegal cast`
-- | trying to read the closure as the result). Driven through the same generic
-- | export-marshalling harness as `Test.E2E.FFIExport` (externs → manifest → call).
module Test.E2E.PointFree (spec) where

import Prelude

import Data.Either (Either(..))
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign (Foreign)
import Node.Cbor (decodeFirst)
import Node.FS.Sync (readFile)
import PureScript.ExternsFile (ExternsFile)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import Test.E2E.Wasm (callExportJson, exportManifestOf, instantiateForeignStr)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

foreign import noImports :: Foreign

decodeExterns :: String -> Aff (Either _ ExternsFile)
decodeExterns path = do
  buf <- liftEffect (readFile path)
  fgn <- decodeFirst buf
  pure (runDecoder decoder fgn)

roots :: Array (Array String)
roots = [ [ "Example", "PointFree" ] ]

withExports :: ((String -> String -> Aff String) -> Aff Unit) -> Aff Unit
withExports k =
  decodeExterns "compiler/test/fixtures/Example.PointFree.externs.cbor" >>= case _ of
    Left err -> fail (show err)
    Right ef -> do
      inst <- liftEffect
        ( instantiateForeignStr [ ef ] noImports roots
            [ "compiler/test/fixtures/Example.PointFree.corefn.json"
            , "compiler/test/fixtures/Data.Semiring.corefn.json"
            ]
        )
      let manifest = exportManifestOf [ ef ] roots
      k (\name args -> liftEffect (callExportJson inst manifest name args))

spec :: Spec Unit
spec = describe "Test.E2E.PointFree (point-free top-level export arity)" do
  -- `incFromTen = plus 10` : compiled arity 0, type arity 1 — the wrapper eta-applies
  it "calls a point-free (partially-applied) export as a 1-ary function" $ withExports \call -> do
    call "incFromTen" "[5]" >>= (_ `shouldEqual` "15")
    call "incFromTen" "[0]" >>= (_ `shouldEqual` "10")
  -- a point-free binding used internally (saturated) is also fine, and exported normally
  it "calls a function that uses a point-free binding internally" $ withExports \call ->
    call "twiceInc" "[5]" >>= (_ `shouldEqual` "25")
  -- a genuine CAF still marshals out as a value (called with no args)
  it "evaluates a nullary value binding (CAF)" $ withExports \call ->
    call "answer" "[]" >>= (_ `shouldEqual` "42")
