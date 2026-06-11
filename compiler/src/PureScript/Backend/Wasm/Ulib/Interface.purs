-- | The public *interface* of a module, distilled from its externs' export list, plus a
-- | diff over two such interfaces. This is what `ulib-tooling check` (ADR 0028) uses to
-- | tell whether a ulib shadow is a drop-in for the registry module it shadows: a shadow is
-- | compatible iff it exports at least every public name the registry module does (it may
-- | export *more* — that is harmless to a consumer expecting the registry surface).
-- |
-- | The interface is the set of exported names only (values, operators, types and their
-- | exported data constructors, classes), not their types. An export-name diff catches the
-- | common breaking change (a value/constructor added or removed across a version) without
-- | the fragility of comparing desugared `Type` ASTs; deeper type-level comparison is left
-- | for later (it would need name-insensitive type equality). See ADR 0028.
module PureScript.Backend.Wasm.Ulib.Interface
  ( Interface
  , interfaceOf
  , InterfaceDiff
  , diffInterface
  , compatible
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import PureScript.ExternsFile (ExternsFile(..))
import PureScript.ExternsFile.Declarations (DeclarationRef(..))
import PureScript.ExternsFile.Names (Ident(..), OpName(..), ProperName(..))

-- | A module's public surface: a set of tagged export names. The tag (`"value "`,
-- | `"ctor "`, …) keeps namespaces apart so a value and a type of the same name never
-- | collide, and makes a diff entry self-describing when rendered.
type Interface = Set String

-- | Distil the interface from an externs file's export list (`efExports`). Re-exports and
-- | instance/module refs are not part of a module's own value/type surface, so they are
-- | dropped; a `TypeRef` contributes both the type name and one entry per exported data
-- | constructor (so dropping a constructor in a shadow is caught).
interfaceOf :: ExternsFile -> Interface
interfaceOf (ExternsFile _ _ exports _ _ _ _ _) =
  Set.fromFoldable (exports >>= tag)
  where
  tag = case _ of
    ValueRef _ (Ident n) -> [ "value " <> n ]
    ValueOpRef _ (OpName n) -> [ "op " <> n ]
    TypeOpRef _ (OpName n) -> [ "typeop " <> n ]
    TypeClassRef _ (ProperName n) -> [ "class " <> n ]
    TypeRef _ (ProperName n) ctors ->
      [ "type " <> n ] <> case ctors of
        -- `Nothing` = all constructors exported but the externs did not enumerate them; we
        -- record only the type, so an abstract-type shadow is not flagged for missing ctors.
        Nothing -> []
        Just cs -> map (\(ProperName c) -> "ctor " <> n <> "." <> c) cs
    _ -> []

-- | `missing` = names the registry module exports that the shadow does NOT — these break a
-- | consumer (the shadow is not a drop-in). `extra` = names only the shadow exports — a
-- | superset, harmless to a registry-surface consumer but surfaced for transparency. Both
-- | are sorted (Set's ascending order) for stable output.
type InterfaceDiff = { missing :: Array String, extra :: Array String }

-- | Diff a shadow interface against the registry one it is meant to replace.
diffInterface :: Interface -> Interface -> InterfaceDiff
diffInterface registry shadow =
  { missing: Set.toUnfoldable (Set.difference registry shadow)
  , extra: Set.toUnfoldable (Set.difference shadow registry)
  }

-- | A shadow is compatible iff nothing the registry exports is missing from it.
compatible :: InterfaceDiff -> Boolean
compatible d = Array.null d.missing
