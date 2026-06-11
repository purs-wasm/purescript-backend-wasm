-- Regression/coverage for nested field patterns in record binders (e.g. `{ x: Just y }`):
-- a record-pattern field whose sub-binder is itself a constructor, a literal, another
-- record, or a constructor wrapping a record. The decision-tree compiler splices each
-- field's sub-binder back into the matrix, so these all reduce to the ordinary
-- constructor/literal/record specializations — this fixture pins that end-to-end.
module E2E.NestedRecordPat where

import Prelude

import Data.Maybe (Maybe(..))

-- (1) record field with a *constructor* sub-binder (the `{ x: Just y }` shape).
fieldJust :: Int -> Int
fieldJust n = case { x: Just n, y: 100 } of
  { x: Just v, y } -> v + y
  { x: Nothing, y } -> y - 1

-- (1b) the same pattern reaching the `Nothing` arm.
fieldNothing :: Int -> Int
fieldNothing n = case { x: noMaybe, y: n } of
  { x: Just v, y } -> v + y
  { x: Nothing, y } -> y + 1000

noMaybe :: Maybe Int
noMaybe = Nothing

-- (2) record field with a *literal* sub-binder (`{ tag: 0 }`).
fieldLit :: Int -> Int
fieldLit n = case { tag: n, val: 7 } of
  { tag: 0, val } -> val
  { tag: _, val } -> val + n

-- (3) *nested record* sub-binder (a record inside a record field).
fieldNestedRec :: Int -> Int
fieldNestedRec n = case { outer: { inner: n } } of
  { outer: { inner } } -> inner + 1

-- (4) a constructor sub-binder that itself wraps a record (`{ bx: Just { v } }`).
fieldJustRec :: Int -> Int
fieldJustRec n = case { bx: Just { v: n } } of
  { bx: Just { v } } -> v * 2
  { bx: Nothing } -> 0
