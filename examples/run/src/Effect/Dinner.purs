module Effect.Dinner where

import Prelude

import Run (Run)
import Run as Run
import Type.Proxy (Proxy(..))
import Type.Row (type (+))

type IsThereMore = Boolean
type Bill = Int

data Food = Pizza | Chizburger

data DinnerF a
  = Eat Food (IsThereMore -> a)
  | CheckPlease (Bill -> a)

derive instance functorDinnerF :: Functor DinnerF

type DINNER r = (dinner :: DinnerF | r)

_dinner = Proxy :: Proxy "dinner"

eat :: forall r. Food -> Run (DINNER + r) IsThereMore
eat food = Run.lift _dinner (Eat food identity)

checkPlease :: forall r. Run (DINNER + r) Bill
checkPlease = Run.lift _dinner (CheckPlease identity)

