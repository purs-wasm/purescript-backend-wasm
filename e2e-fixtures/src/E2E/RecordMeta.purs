-- | Record metaprogramming end-to-end (regression for the runtime label-interning fix):
-- |   * `RowToList` field iteration with `IsSymbol`/`reflectSymbol` + `unsafeGet`,
-- |   * adding a field whose name (`"total"`) is **not** a syntactic record label anywhere — so its
-- |     id is computed at runtime by hashing the name (`$rt.internStr`, ADR 0037 ④), the same hash
-- |     the compiler assigns a static label, so the added field interns consistently.
-- |
-- | Reads/iteration always worked; adding such a field used to trap (the old `internStr` if-chain
-- | ended in `unreachable`). The exposed functions are `Int`-typed so the host can drive them.
module E2E.RecordMeta where

import Prelude

import Data.Symbol (class IsSymbol, reflectSymbol)
import Prim.RowList (class RowToList, RowList, Cons, Nil)
import Record as Record
import Record.Unsafe (unsafeGet)
import Type.Proxy (Proxy(..))

-- | RowToList-driven fold: sum every (`Int`-typed) field of a record by walking its `RowList`,
-- | reading each field by its reflected label name.
class SumRecord (rl :: RowList Type) (r :: Row Type) where
  sumRecordImpl :: Proxy rl -> Record r -> Int

instance sumRecordNil :: SumRecord Nil r where
  sumRecordImpl _ _ = 0

instance sumRecordCons ::
  ( IsSymbol sym
  , SumRecord tail r
  ) =>
  SumRecord (Cons sym Int tail) r where
  sumRecordImpl _ rec =
    unsafeGet (reflectSymbol (Proxy :: Proxy sym)) rec
      + sumRecordImpl (Proxy :: Proxy tail) rec

sumRecord :: forall r rl. RowToList r rl => SumRecord rl r => Record r -> Int
sumRecord = sumRecordImpl (Proxy :: Proxy rl)

-- | RowList metaprogramming over existing fields. Expect 1 + 2 + 3 + 4 = 10.
sumFields :: Int -> Int
sumFields _ = sumRecord { a: 1, b: 2, c: 3, d: 4 }

-- | `Record.insert` adds a field whose name (`"total"`) is not a syntactic label anywhere — its id
-- | is minted at runtime — then `Record.get` reads it back. Expect 42.
insertField :: Int -> Int
insertField _ =
  let
    r = Record.insert (Proxy :: Proxy "total") 42 { a: 1, b: 2 }
  in
    Record.get (Proxy :: Proxy "total") r

-- | After inserting the dynamic field, the RowList fold sees the grown record (old + new fields).
-- | Expect 1 + 2 + 100 = 103.
insertThenSum :: Int -> Int
insertThenSum _ = sumRecord (Record.insert (Proxy :: Proxy "total") 100 { a: 1, b: 2 })
