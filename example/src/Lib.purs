module Lib where

foreign import addI :: Int -> Int -> Int

foreign import subI :: Int -> Int -> Int

foreign import mulI :: Int -> Int -> Int

foreign import eqI :: Int -> Int -> Boolean

incr :: Int -> Int
incr n = addI n 1

decr :: Int -> Int
decr n = n `subI` 1