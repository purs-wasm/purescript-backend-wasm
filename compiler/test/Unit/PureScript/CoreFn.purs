module Test.Unit.PureScript.CoreFn where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (JsonDecodeError, printJsonDecodeError)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..), replaceAll)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class (liftEffect)
import PureScript.CoreFn (Ann, Bind(..), Binder(..), ConstructorType(..), Expr(..), Literal(..), Meta(..), Qualified(..))
import PureScript.CoreFn.FromJSON (decodeBind, decodeBinder, decodeExpr, decodeModule)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

foreign import readFixture :: String -> Effect String

-- | The zero annotation that `@` expands to in the JSON fixtures below.
ann0 :: Ann
ann0 = { span: { start: { line: 0, column: 0 }, end: { line: 0, column: 0 } }, meta: Nothing }

-- | Replace each `@` placeholder with a zero-span, no-meta `annotation` field.
-- | Keeps the JSON fixtures readable instead of repeating the annotation.
withAnn :: String -> String
withAnn = replaceAll (Pattern "@")
  (Replacement """"annotation":{"meta":null,"sourceSpan":{"start":[0,0],"end":[0,0]}}""")

-- | Run a decoder over a JSON string, flattening parse + decode errors.
run :: forall a. (Json -> Either JsonDecodeError a) -> String -> Either String a
run decode source = case jsonParser source of
  Left parseErr -> Left ("parse error: " <> parseErr)
  Right json -> case decode json of
    Left decodeErr -> Left (printJsonDecodeError decodeErr)
    Right value -> Right value

expr :: String -> Either String Expr
expr = run decodeExpr <<< withAnn

spec :: Spec Unit
spec = describe "PureScript.CoreFn.FromJSON" do
  describe "real compiler output" do
    it "decodes the Sample.corefn.json fixture produced by purs 0.15.16" do
      source <- liftEffect (readFixture "compiler/test/fixtures/Sample.corefn.json")
      case run decodeModule source of
        Left err -> fail err
        Right m -> do
          m.name `shouldEqual` [ "Sample" ]
          Array.elem "main" m.exports `shouldEqual` true
          Array.elem "nativeAdd" m.foreignNames `shouldEqual` true
          (Array.length m.decls > 0) `shouldEqual` true

  describe "expressions" do
    it "decodes a qualified Var" do
      expr """{@,"type":"Var","value":{"identifier":"map","moduleName":["Data","Functor"]}}"""
        `shouldEqual` Right (Var ann0 (Qualified (Just [ "Data", "Functor" ]) "map"))

    it "decodes a local Var (no moduleName)" do
      expr """{@,"type":"Var","value":{"identifier":"x","sourcePos":[1,5]}}"""
        `shouldEqual` Right (Var ann0 (Qualified Nothing "x"))

    it "decodes Abs" do
      expr """{@,"type":"Abs","argument":"x","body":{@,"type":"Var","value":{"identifier":"x","sourcePos":[0,0]}}}"""
        `shouldEqual` Right (Abs ann0 "x" (Var ann0 (Qualified Nothing "x")))

    it "decodes App" do
      expr """{@,"type":"App","abstraction":{@,"type":"Var","value":{"identifier":"f","sourcePos":[0,0]}},"argument":{@,"type":"Var","value":{"identifier":"x","sourcePos":[0,0]}}}"""
        `shouldEqual` Right (App ann0 (Var ann0 (Qualified Nothing "f")) (Var ann0 (Qualified Nothing "x")))

    it "decodes Accessor" do
      expr """{@,"type":"Accessor","fieldName":"x","expression":{@,"type":"Var","value":{"identifier":"p","sourcePos":[0,0]}}}"""
        `shouldEqual` Right (Accessor ann0 "x" (Var ann0 (Qualified Nothing "p")))

    it "decodes Constructor" do
      expr """{@,"type":"Constructor","typeName":"Maybe","constructorName":"Just","fieldNames":["value0"]}"""
        `shouldEqual` Right (Constructor ann0 "Maybe" "Just" [ "value0" ])

    it "decodes ObjectUpdate with a copy list" do
      expr """{@,"type":"ObjectUpdate","copy":["y"],"expression":{@,"type":"Var","value":{"identifier":"p","sourcePos":[0,0]}},"updates":[["x",{@,"type":"Var","value":{"identifier":"v","sourcePos":[0,0]}}]]}"""
        `shouldEqual` Right
          ( ObjectUpdate ann0
              (Var ann0 (Qualified Nothing "p"))
              (Just [ "y" ])
              [ Tuple "x" (Var ann0 (Qualified Nothing "v")) ]
          )

    it "decodes ObjectUpdate with copy: null" do
      expr """{@,"type":"ObjectUpdate","copy":null,"expression":{@,"type":"Var","value":{"identifier":"p","sourcePos":[0,0]}},"updates":[]}"""
        `shouldEqual` Right (ObjectUpdate ann0 (Var ann0 (Qualified Nothing "p")) Nothing [])

    it "decodes Let" do
      expr """{@,"type":"Let","binds":[{@,"bindType":"NonRec","identifier":"y","expression":{@,"type":"Var","value":{"identifier":"x","sourcePos":[0,0]}}}],"expression":{@,"type":"Var","value":{"identifier":"y","sourcePos":[0,0]}}}"""
        `shouldEqual` Right
          ( Let ann0
              [ NonRec ann0 "y" (Var ann0 (Qualified Nothing "x")) ]
              (Var ann0 (Qualified Nothing "y"))
          )

    it "decodes an unguarded Case" do
      expr """{@,"type":"Case","caseExpressions":[{@,"type":"Var","value":{"identifier":"n","sourcePos":[0,0]}}],"caseAlternatives":[{"binders":[{@,"binderType":"NullBinder"}],"isGuarded":false,"expression":{@,"type":"Var","value":{"identifier":"r","sourcePos":[0,0]}}}]}"""
        `shouldEqual` Right
          ( Case ann0
              [ Var ann0 (Qualified Nothing "n") ]
              [ { binders: [ NullBinder ann0 ], result: Right (Var ann0 (Qualified Nothing "r")) } ]
          )

    it "decodes a guarded Case" do
      expr """{@,"type":"Case","caseExpressions":[{@,"type":"Var","value":{"identifier":"n","sourcePos":[0,0]}}],"caseAlternatives":[{"binders":[{@,"binderType":"VarBinder","identifier":"m"}],"isGuarded":true,"expressions":[{"guard":{@,"type":"Var","value":{"identifier":"g","sourcePos":[0,0]}},"expression":{@,"type":"Var","value":{"identifier":"e","sourcePos":[0,0]}}}]}]}"""
        `shouldEqual` Right
          ( Case ann0
              [ Var ann0 (Qualified Nothing "n") ]
              [ { binders: [ VarBinder ann0 "m" ]
                , result: Left [ { guard: Var ann0 (Qualified Nothing "g"), expression: Var ann0 (Qualified Nothing "e") } ]
                }
              ]
          )

  describe "literals" do
    it "decodes IntLiteral" do
      expr """{@,"type":"Literal","value":{"literalType":"IntLiteral","value":42}}"""
        `shouldEqual` Right (Literal ann0 (LitInt 42))
    it "decodes NumberLiteral" do
      expr """{@,"type":"Literal","value":{"literalType":"NumberLiteral","value":3.14}}"""
        `shouldEqual` Right (Literal ann0 (LitNumber 3.14))
    it "decodes StringLiteral" do
      expr """{@,"type":"Literal","value":{"literalType":"StringLiteral","value":"hi"}}"""
        `shouldEqual` Right (Literal ann0 (LitString "hi"))
    it "decodes CharLiteral" do
      expr """{@,"type":"Literal","value":{"literalType":"CharLiteral","value":"z"}}"""
        `shouldEqual` Right (Literal ann0 (LitChar 'z'))
    it "decodes BooleanLiteral" do
      expr """{@,"type":"Literal","value":{"literalType":"BooleanLiteral","value":true}}"""
        `shouldEqual` Right (Literal ann0 (LitBoolean true))
    it "decodes ArrayLiteral" do
      expr """{@,"type":"Literal","value":{"literalType":"ArrayLiteral","value":[{@,"type":"Literal","value":{"literalType":"IntLiteral","value":1}}]}}"""
        `shouldEqual` Right (Literal ann0 (LitArray [ Literal ann0 (LitInt 1) ]))
    it "decodes ObjectLiteral" do
      expr """{@,"type":"Literal","value":{"literalType":"ObjectLiteral","value":[["k",{@,"type":"Literal","value":{"literalType":"IntLiteral","value":1}}]]}}"""
        `shouldEqual` Right (Literal ann0 (LitObject [ Tuple "k" (Literal ann0 (LitInt 1)) ]))

  describe "binders" do
    let binder = run decodeBinder <<< withAnn
    it "decodes NullBinder" do
      binder """{@,"binderType":"NullBinder"}"""
        `shouldEqual` Right (NullBinder ann0)
    it "decodes VarBinder" do
      binder """{@,"binderType":"VarBinder","identifier":"x"}"""
        `shouldEqual` Right (VarBinder ann0 "x")
    it "decodes NamedBinder" do
      binder """{@,"binderType":"NamedBinder","identifier":"whole","binder":{@,"binderType":"NullBinder"}}"""
        `shouldEqual` Right (NamedBinder ann0 "whole" (NullBinder ann0))
    it "decodes LiteralBinder" do
      binder """{@,"binderType":"LiteralBinder","literal":{"literalType":"IntLiteral","value":0}}"""
        `shouldEqual` Right (LiteralBinder ann0 (LitInt 0))
    it "decodes ConstructorBinder with qualified names" do
      binder """{@,"binderType":"ConstructorBinder","typeName":{"identifier":"Maybe","moduleName":["Data","Maybe"]},"constructorName":{"identifier":"Just","moduleName":["Data","Maybe"]},"binders":[{@,"binderType":"NullBinder"}]}"""
        `shouldEqual` Right
          ( ConstructorBinder ann0
              (Qualified (Just [ "Data", "Maybe" ]) "Maybe")
              (Qualified (Just [ "Data", "Maybe" ]) "Just")
              [ NullBinder ann0 ]
          )

  describe "binds & metadata" do
    let bindOf = run decodeBind <<< withAnn
    it "decodes a Rec binding group" do
      bindOf """{"bindType":"Rec","binds":[{@,"identifier":"go","expression":{@,"type":"Var","value":{"identifier":"x","sourcePos":[0,0]}}}]}"""
        `shouldEqual` Right (Rec [ { ann: ann0, ident: "go", expr: Var ann0 (Qualified Nothing "x") } ])

    it "decodes IsConstructor (SumType) metadata on a node" do
      run decodeExpr """{"annotation":{"sourceSpan":{"start":[0,0],"end":[0,0]},"meta":{"metaType":"IsConstructor","constructorType":"SumType","identifiers":["a","b"]}},"type":"Constructor","typeName":"T","constructorName":"C","fieldNames":["a","b"]}"""
        `shouldEqual` Right
          ( Constructor
              (ann0 { meta = Just (IsConstructor SumType [ "a", "b" ]) })
              "T"
              "C"
              [ "a", "b" ]
          )

    it "decodes IsNewtype metadata" do
      run decodeExpr """{"annotation":{"sourceSpan":{"start":[0,0],"end":[0,0]},"meta":{"metaType":"IsNewtype"}},"type":"Var","value":{"identifier":"w","sourcePos":[0,0]}}"""
        `shouldEqual` Right (Var (ann0 { meta = Just IsNewtype }) (Qualified Nothing "w"))

  describe "errors" do
    it "rejects an unknown expression type" do
      case expr """{@,"type":"Bogus"}""" of
        Left _ -> pure unit
        Right _ -> fail "expected decoding to fail on unknown expression type"
