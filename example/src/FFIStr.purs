-- | A fixture exercising String FFI marshalling (ADR 0014, L2): string literals are
-- | passed to JS foreigns and a JS-string result comes back into wasm. Returns Int
-- | (the i32 export ABI can't carry a String yet), so both marshalling directions
-- | are tested without a String-typed export.
module Example.FFIStr where

foreign import strLength :: String -> Int
foreign import shout :: String -> String

-- String *input* marshalling: "hello" ($Str) → JS "hello" → length 5
hello :: Int -> Int
hello _ = strLength "hello"

-- String *output* marshalling too: shout "hi" → JS "HI" → $Str → length 2
shoutLen :: Int -> Int
shoutLen _ = strLength (shout "hi")
