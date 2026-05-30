module Test.Unit.PureScript.ExternsFile where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Node.Cbor (decodeFirst)
import Node.FS.Sync (readFile)
import PureScript.ExternsFile (ExternsFile(..), identOfExternsDeclaration)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (DecodeError, runDecoder)
import PureScript.ExternsFile.Names (Ident(..), ModuleName(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

-- | Read and decode a real `externs.cbor` fixture (purs 0.15.16 output).
decodeExterns :: String -> Aff (Either DecodeError ExternsFile)
decodeExterns path = do
  buf <- liftEffect (readFile path)
  fgn <- decodeFirst buf
  pure (runDecoder decoder fgn)

spec :: Spec Unit
spec = describe "PureScript.ExternsFile (decoder)" do
  it "decodes Data.Void.externs.cbor (real purs 0.15.16 output)" do
    decodeExterns "compiler/test/fixtures/Data.Void.externs.cbor" >>= case _ of
      Left err -> fail (show err)
      Right (ExternsFile version moduleName _exports _imports _fixities _typeFixities decls _ss) -> do
        moduleName `shouldEqual` ModuleName "Data.Void"
        version `shouldEqual` "0.15.16"
        (Array.length decls > 0) `shouldEqual` true
        -- Data.Void exports the value `absurd`.
        Array.elem (Ident "absurd") (map identOfExternsDeclaration decls) `shouldEqual` true

  it "decodes Data.Unit.externs.cbor (real purs 0.15.16 output)" do
    decodeExterns "compiler/test/fixtures/Data.Unit.externs.cbor" >>= case _ of
      Left err -> fail (show err)
      Right (ExternsFile _version moduleName _exports _imports _fixities _typeFixities decls _ss) -> do
        moduleName `shouldEqual` ModuleName "Data.Unit"
        (Array.length decls > 0) `shouldEqual` true

  -- A richer module: type classes, instances, and polymorphic types exercise
  -- the recursive Type / Constraint / EDClass / EDInstance decoder paths.
  it "decodes Data.Maybe.externs.cbor (classes, instances, polymorphic types)" do
    decodeExterns "compiler/test/fixtures/Data.Maybe.externs.cbor" >>= case _ of
      Left err -> fail (show err)
      Right (ExternsFile _version moduleName _exports _imports _fixities _typeFixities decls _ss) -> do
        moduleName `shouldEqual` ModuleName "Data.Maybe"
        Array.elem (Ident "fromMaybe") (map identOfExternsDeclaration decls) `shouldEqual` true
