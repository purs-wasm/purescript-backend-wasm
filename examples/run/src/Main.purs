module Examples.Run.Main where

import Prelude

import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console as Console
import Effect.Dinner (Bill, DINNER, DinnerF(..), Food(..), _dinner, checkPlease, eat)
import Examples.Run.Effect.Talk (TALK, TalkF(..), _talk, speak)
import Fmt as Fmt
import Run (EFFECT, Run, Step(..), interpret, liftEffect, on, runAccumPure, runBaseEffect, send)
import Type.Row (type (+))

handleTalk :: forall r. TalkF ~> Run (EFFECT + r)
handleTalk = case _ of
  Speak str next -> do
    liftEffect $ Console.log str
    pure next
  Listen reply -> do
    pure (reply "Alice")

runTalk
  :: forall r
   . Run (EFFECT + TALK + r)
       ~> Run (EFFECT + r)
runTalk = interpret (on _talk handleTalk send)

type Tally = { stock :: Int, bill :: Bill }

handleDinner :: forall a. Tally -> DinnerF a -> Tuple Tally a
handleDinner tally = case _ of
  Eat _ reply
    | tally.stock > 0 ->
        let
          tally' = { stock: tally.stock - 1, bill: tally.bill + 1 }
        in
          Tuple tally' (reply true)
    | otherwise ->
        Tuple tally (reply false)
  CheckPlease reply ->
    Tuple tally (reply tally.bill)

runDinnerPure :: forall r a. Tally -> Run (DINNER + r) a -> Run r (Tuple Bill a)
runDinnerPure = runAccumPure
  (\tally -> on _dinner (Loop <<< handleDinner tally) Done)
  (\tally a -> Tuple tally.bill a)

type LovelyEvening r = (TALK + DINNER + r)

dinnerTime :: forall r. Run (LovelyEvening r) Unit
dinnerTime = do
  speak "I'm famished!"
  isThereMore <- eat Pizza
  if isThereMore then dinnerTime
  else do
    bill <- checkPlease
    speak $ Fmt.fmt @"${bill}!? Outrageous!" { bill: show bill }

main :: Effect (Tuple Bill Unit)
main = dinnerTime
  # runTalk
  # runDinnerPure { stock: 10, bill: 0 }
  # runBaseEffect