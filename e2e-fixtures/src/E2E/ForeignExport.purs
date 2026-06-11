-- e2e fixture (ADR 0031 phase 5): wasm **export** marshalling (ADR 0014) and export arity through the
-- generated loader — a Boolean export (i31 <-> JS boolean), a Number export (raw f64 ABI), nullary
-- value bindings (Int / marshalled String, exposed as the value itself), and a point-free
-- (partially-applied) export called as a 1-ary function. (Covers the legacy `Example.FFIExport` /
-- `Example.PointFree` non-record cases; Record export marshalling is the deferred gap.)
module E2E.ForeignExport where

import Prelude

isPos :: Int -> Boolean
isPos n = n > 0

half :: Number -> Number
half x = x / 2.0

answer :: Int
answer = 42

greeting :: String
greeting = "hi"

addTen :: Int -> Int
addTen = add 10
