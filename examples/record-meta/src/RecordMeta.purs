module Examples.RecordMeta where

import Prelude

import Effect (Effect)
import Effect.Console (logShow)
import Record.Studio (keys, shrink, (//))

type Person = { name :: String, age :: Int }

alice :: Person
alice = { name: "Alice", age: 15 }

nameAndProfile :: { name :: String, bio :: String }
nameAndProfile = shrink $ alice // { bio: "Seven-Colored Puppeteer" }

main :: Effect Unit
main = do
  logShow alice
  logShow nameAndProfile
  logShow $ keys nameAndProfile