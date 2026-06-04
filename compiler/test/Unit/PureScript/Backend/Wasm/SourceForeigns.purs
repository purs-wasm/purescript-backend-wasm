-- | Unit tests for `SourceForeigns.parseForeignSigs` (ADR 0016): foreign-import value
-- | declarations are extracted from `.purs` source with the right `MarshalKind`s,
-- | including **private** (non-exported) foreigns that externs would omit, and `foreign
-- | import data`/kind declarations are skipped.
module Test.Unit.PureScript.Backend.Wasm.SourceForeigns (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String (joinWith)
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (MarshalKind(..))
import PureScript.Backend.Wasm.SourceForeigns (parseForeignSigs)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- a module `M` (explicit export list `(pub)`, so `secret`/`*Impl` are private) wrapping
-- the given foreign-import lines
moduleSrc :: Array String -> String
moduleSrc lines = joinWith "\n"
  ( [ "module M (pub) where"
    , "import Prelude"
    , "import Effect (Effect)"
    , "pub :: Int -> Int"
    , "pub x = x"
    ] <> lines
  )

sigOf :: Array String -> String -> Maybe { params :: Array MarshalKind, result :: MarshalKind }
sigOf lines key = map (\s -> { params: s.params, result: s.result }) (Object.lookup key (parseForeignSigs (moduleSrc lines)))

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.SourceForeigns.parseForeignSigs" do

  it "reads a scalar + Effect foreign (Int -> Effect Unit)" do
    sigOf [ "foreign import f :: Int -> Effect Unit" ] "M.f"
      `shouldEqual` Just { params: [ MI32 ], result: MEffect MOpaque }

  it "reads String / Number / Boolean / Char scalars" do
    sigOf [ "foreign import g :: String -> Number -> Boolean -> Char" ] "M.g"
      `shouldEqual` Just { params: [ MStr, MF64, MBool ], result: MI32 }

  it "reads Array and Record kinds (recursively)" do
    sigOf [ "foreign import h :: Array Int -> { name :: String, age :: Int } -> Int" ] "M.h"
      `shouldEqual` Just
        { params: [ MArray MI32, MRecord [ Tuple "name" MStr, Tuple "age" MI32 ] ]
        , result: MI32
        }

  it "reads a nullary Effect foreign (no value params)" do
    sigOf [ "foreign import tick :: Effect Int" ] "M.tick"
      `shouldEqual` Just { params: [], result: MEffect MI32 }

  it "reads a higher-order foreign (function param → MFunc)" do
    sigOf [ "foreign import hof :: (Int -> Int) -> Int -> Int" ] "M.hof"
      `shouldEqual` Just { params: [ MFunc MI32 MI32, MI32 ], result: MI32 }

  it "peels forall; unknown types are opaque" do
    sigOf [ "foreign import poly :: forall a. a -> a" ] "M.poly"
      `shouldEqual` Just { params: [ MOpaque ], result: MOpaque }

  it "captures a PRIVATE (non-exported) foreign — the case externs miss" do
    -- `secret` is not in the module's export list, so it is absent from externs; source has it
    (Object.member "M.secret" (parseForeignSigs (moduleSrc [ "foreign import secret :: Int -> Int" ])))
      `shouldEqual` true

  it "skips `foreign import data` (not a value foreign)" do
    (Object.member "M.Opaque" (parseForeignSigs (moduleSrc [ "foreign import data Opaque :: Type" ])))
      `shouldEqual` false
