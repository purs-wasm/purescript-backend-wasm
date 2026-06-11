module Examples.Run.Effect.Talk where

import Prelude

import Run (Run)
import Run as Run
import Type.Proxy (Proxy(..))
import Type.Row (type (+))

data TalkF a
  = Speak String a
  | Listen (String -> a)

derive instance functorTalkF :: Functor TalkF

type TALK r = (talk :: TalkF | r)

_talk = Proxy :: Proxy "talk"

speak :: forall r. String -> Run (TALK + r) Unit
speak str = Run.lift _talk (Speak str unit)

listen :: forall r. Run (TALK + r) String
listen = Run.lift _talk (Listen identity)

