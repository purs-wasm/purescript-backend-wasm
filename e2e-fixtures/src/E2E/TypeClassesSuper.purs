module E2E.TypeClassesSuper where

class Base a where
  baseOp :: a -> Int

class Base a <= Derived a where
  derivedOp :: a -> Int

-- A class with TWO superclasses, to see multi-superclass layout/order
class (Base a, Derived a) <= Top a where
  topOp :: a -> Int

instance baseInt :: Base Int where
  baseOp x = x

instance derivedInt :: Derived Int where
  derivedOp x = x

instance topInt :: Top Int where
  topOp x = x

-- inside a Derived constraint, call a Base method => must reach the superclass dict
useBaseViaDerived :: forall a. Derived a => a -> Int
useBaseViaDerived x = baseOp x

-- inside a Top constraint, call a Base method => two levels up
useBaseViaTop :: forall a. Top a => a -> Int
useBaseViaTop x = baseOp x

-- monomorphic (Int) entry points: purs inserts the instance dictionaries, so
-- these exercise superclass access end to end through the host i32 interface
viaDerivedOf :: Int -> Int
viaDerivedOf n = useBaseViaDerived n

viaTopOf :: Int -> Int
viaTopOf n = useBaseViaTop n
