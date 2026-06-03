-- | Unit tests for the externs → field-representation bridge: that a constructor's
-- | concrete scalar fields (`Int`/`Number`/`Char`) are read out of the externs as
-- | unboxed reps, and everything else stays boxed. Anchored to a real
-- | `externs.cbor` (purs 0.15.16) for `Bench.Main`, whose `IntList`/`Tree`/`TreeQ`
-- | mix concrete-`Int` and recursive fields.
module Test.Unit.PureScript.Backend.Wasm.Externs (spec) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign.Object as Object
import Node.Cbor (decodeFirst)
import Node.FS.Sync (readFile)
import PureScript.Backend.Wasm.Externs (ctorFieldReps, foreignSigs)
import PureScript.Backend.Wasm.Lower.IR (MarshalKind(..), Rep(..))
import PureScript.ExternsFile (ExternsFile)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

decodeExterns :: String -> Aff (Either String ExternsFile)
decodeExterns path = do
  buf <- liftEffect (readFile path)
  fgn <- decodeFirst buf
  pure case runDecoder decoder fgn of
    Left err -> Left (show err)
    Right ef -> Right ef

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.Externs (field reps)" do
  it "reads unboxed reps for concrete scalar constructor fields" do
    decodeExterns "compiler/test/fixtures/Bench.Main.externs.cbor" >>= case _ of
      Left err -> fail err
      Right ef -> do
        let reps = ctorFieldReps [ ef ]
        -- Cons Int IntList → [i32, boxed]; Node Int Tree Tree → [i32, boxed, boxed]
        Object.lookup "Bench.Main.Cons" reps `shouldEqual` Just [ I32, Boxed ]
        Object.lookup "Bench.Main.Node" reps `shouldEqual` Just [ I32, Boxed, Boxed ]
        -- QCons Tree TreeQ has no scalar field → all boxed
        Object.lookup "Bench.Main.QCons" reps `shouldEqual` Just [ Boxed, Boxed ]
        -- nullary constructors have no fields
        Object.lookup "Bench.Main.Nil" reps `shouldEqual` Just []
        Object.lookup "Bench.Main.Leaf" reps `shouldEqual` Just []

  it "reads a top-level value's scalar calling convention (foreign-import ABI)" do
    decodeExterns "compiler/test/fixtures/Bench.Main.externs.cbor" >>= case _ of
      Left err -> fail err
      Right ef ->
        -- `fib :: Int -> Int` → an `i32`-in, `i32`-out host-import signature (the
        -- same extraction a scalar `foreign import` uses; ADR 0014)
        Object.lookup "Bench.Main.fib" (foreignSigs [ ef ])
          `shouldEqual` Just { moduleName: "Bench.Main", base: "fib", params: [ MI32 ], result: MI32 }

  it "boxes a polymorphic / non-scalar signature (peeling forall, multi-arg)" do
    decodeExterns "compiler/test/fixtures/Data.Maybe.externs.cbor" >>= case _ of
      Left err -> fail err
      Right ef ->
        -- `fromMaybe :: forall a. a -> Maybe a -> a` → after peeling the `forall`,
        -- two opaque params (`a`, `Maybe a`) and an opaque result (nothing is a
        -- concrete scalar/String, so nothing unboxes or marshals)
        Object.lookup "Data.Maybe.fromMaybe" (foreignSigs [ ef ])
          `shouldEqual` Just { moduleName: "Data.Maybe", base: "fromMaybe", params: [ MOpaque, MOpaque ], result: MOpaque }

  -- Edge cases the manual `example/FFI` run never exercises: mixed scalar reps and
  -- their order, nullary constants, `Char` vs `Int`, `String` (marshalled), type
  -- variables, `Boolean` (opaque), and a constraint (a leading dictionary param).
  it "extracts diverse calling conventions (mixed / nullary / Char / String / poly / Boolean / constraint)" do
    decodeExterns "compiler/test/fixtures/Example.Foreigns.externs.cbor" >>= case _ of
      Left err -> fail err
      Right ef -> do
        let
          sigs = foreignSigs [ ef ]
          sig n params result = Object.lookup ("Example.Foreigns." <> n) sigs
            `shouldEqual` Just { moduleName: "Example.Foreigns", base: n, params, result }
        sig "addOne" [ MI32 ] MI32 -- scalar i32
        sig "scale" [ MI32, MF64 ] MF64 -- mixed reps, in order (Int -> Number -> Number)
        sig "maxInt" [] MI32 -- nullary constant
        sig "toChar" [ MI32 ] MI32 -- Char is i32
        sig "shout" [ MStr ] MStr -- String is marshalled
        sig "identityF" [ MOpaque ] MOpaque -- forall peeled; a type var is opaque
        sig "flag" [] MOpaque -- Boolean is not scalar-unboxed → opaque (nullary)
        sig "showIt" [ MOpaque, MOpaque ] MStr -- constraint = leading opaque dict param; result String marshalled
