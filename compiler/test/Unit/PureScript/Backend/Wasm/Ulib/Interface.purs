-- | Unit tests for the ulib interface diff (ADR 0028): `interfaceOf` distils the right
-- | tagged names from an externs export list (values/ops/types+ctors/classes, dropping
-- | re-exports and instance/module refs), and `diffInterface`/`compatible` classify a
-- | shadow as drop-in iff it omits nothing the registry module exports.
module Test.Unit.PureScript.Backend.Wasm.Ulib.Interface (spec) where

import Prelude

import Data.Set as Set
import PureScript.Backend.Wasm.Ulib.Interface (compatible, diffInterface, interfaceOf)
import PureScript.ExternsFile (ExternsFile(..))
import PureScript.ExternsFile.Declarations (DeclarationRef(..), ExportSource(..))
import PureScript.ExternsFile.Names (Ident(..), ModuleName(..), NameSource(..), OpName(..), ProperName(..))
import PureScript.ExternsFile.SourcePos (SourcePos(..), SourceSpan(..))
import Data.Maybe (Maybe(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

sp :: SourceSpan
sp = SourceSpan "" (SourcePos 0 0) (SourcePos 0 0)

-- an externs file whose only populated field is its export list
externsExporting :: Array DeclarationRef -> ExternsFile
externsExporting refs = ExternsFile "0" (ModuleName "M") refs [] [] [] [] sp

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.Ulib.Interface" do

  describe "interfaceOf" do
    it "tags values, value-ops, type-ops and classes by namespace" do
      interfaceOf
        ( externsExporting
            [ ValueRef sp (Ident "map")
            , ValueOpRef sp (OpName "<$>")
            , TypeOpRef sp (OpName "~>")
            , TypeClassRef sp (ProperName "Functor")
            ]
        )
        `shouldEqual` Set.fromFoldable [ "value map", "op <$>", "typeop ~>", "class Functor" ]

    it "expands an exported type into the type plus one entry per data constructor" do
      interfaceOf
        ( externsExporting
            [ TypeRef sp (ProperName "Maybe") (Just [ ProperName "Nothing", ProperName "Just" ]) ]
        )
        `shouldEqual` Set.fromFoldable [ "type Maybe", "ctor Maybe.Nothing", "ctor Maybe.Just" ]

    it "records only the type name when its constructors are not enumerated (abstract)" do
      interfaceOf (externsExporting [ TypeRef sp (ProperName "Map") Nothing ])
        `shouldEqual` Set.singleton "type Map"

    it "drops re-exports, instance refs and module refs (not a module's own surface)" do
      interfaceOf
        ( externsExporting
            [ ValueRef sp (Ident "keep")
            , TypeInstanceRef sp (Ident "fooInstance") UserNamed
            , ModuleRef sp (ModuleName "Other")
            , ReExportRef sp (ExportSource Nothing (ModuleName "Src")) (ValueRef sp (Ident "viaReExport"))
            ]
        )
        `shouldEqual` Set.singleton "value keep"

  describe "diffInterface / compatible" do
    it "reports nothing missing/extra for identical interfaces (drop-in)" do
      let i = interfaceOf (externsExporting [ ValueRef sp (Ident "a"), ValueRef sp (Ident "b") ])
      let d = diffInterface i i
      d.missing `shouldEqual` []
      d.extra `shouldEqual` []
      compatible d `shouldEqual` true

    it "flags a name the registry exports but the shadow drops as missing (not drop-in)" do
      let registry = interfaceOf (externsExporting [ ValueRef sp (Ident "a"), ValueRef sp (Ident "b") ])
      let shadow = interfaceOf (externsExporting [ ValueRef sp (Ident "a") ])
      let d = diffInterface registry shadow
      d.missing `shouldEqual` [ "value b" ]
      d.extra `shouldEqual` []
      compatible d `shouldEqual` false

    it "allows a shadow that only adds names (extra, still drop-in)" do
      let registry = interfaceOf (externsExporting [ ValueRef sp (Ident "a") ])
      let shadow = interfaceOf (externsExporting [ ValueRef sp (Ident "a"), ValueRef sp (Ident "b") ])
      let d = diffInterface registry shadow
      d.missing `shouldEqual` []
      d.extra `shouldEqual` [ "value b" ]
      compatible d `shouldEqual` true
