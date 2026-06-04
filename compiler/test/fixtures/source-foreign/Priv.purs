-- Test fixture for ADR 0016 (private-foreign reconstruction). `secretImpl` is NOT in the
-- export list, so it is absent from externs and resolves only via source reconstruction.
module Priv (triple) where

foreign import secretImpl :: Int -> Int

triple :: Int -> Int
triple n = secretImpl n
