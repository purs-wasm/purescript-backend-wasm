module E2E.Shw where

import Prelude

-- show Int
showZero :: Int
showZero = if show 0 == "0" then 1 else 0

showPos :: Int
showPos = if show 42 == "42" then 1 else 0

showNegArg :: Int -> Int
showNegArg n = if show n == "-7" then 1 else 0

showMinArg :: Int -> Int
showMinArg n = if show n == "-2147483648" then 1 else 0

-- show Boolean (pure case in Data.Show)
showBoolT :: Int
showBoolT = if show true == "true" then 1 else 0

showBoolF :: Int
showBoolF = if show false == "false" then 1 else 0

-- show Char: plain, escaped quote/backslash, named control, non-ASCII (UTF-8)
showCharA :: Int
showCharA = if show 'a' == "'a'" then 1 else 0

showCharQuote :: Int
showCharQuote = if show '\'' == "'\\''" then 1 else 0

showCharBackslash :: Int
showCharBackslash = if show '\\' == "'\\\\'" then 1 else 0

showCharNewline :: Int
showCharNewline = if show '\n' == "'\\n'" then 1 else 0

showCharUnicode :: Int
showCharUnicode = if show 'あ' == "'あ'" then 1 else 0

-- show String: plain, escaped quote+backslash, named control
showStrHi :: Int
showStrHi = if show "hi" == "\"hi\"" then 1 else 0

showStrEsc :: Int
showStrEsc = if show "a\"b\\c" == "\"a\\\"b\\\\c\"" then 1 else 0

showStrNewline :: Int
showStrNewline = if show "x\ny" == "\"x\\ny\"" then 1 else 0

-- the \& separator: a \DDD escape followed by an ASCII digit
showStrAmp :: Int
showStrAmp = if show ("\x1" <> "5") == "\"\\1\\&5\"" then 1 else 0

-- show Array: ints, empty, and strings (element show via the closure)
showArrInts :: Int
showArrInts = if show [ 1, 2, 3 ] == "[1,2,3]" then 1 else 0

showArrEmpty :: Int
showArrEmpty = if show ([] :: Array Int) == "[]" then 1 else 0

showArrStr :: Int
showArrStr = if show [ "a", "b" ] == "[\"a\",\"b\"]" then 1 else 0

-- emoji: a String round-trips (UTF-8 bytes >= 0x80 pass through showString
-- untouched), including 4-byte astral sequences and ZWJ/variation selectors
showEmojiSmiley :: Int
showEmojiSmiley = if show "☺️" == "\"☺️\"" then 1 else 0

showEmojiFamily :: Int
showEmojiFamily = if show "👨‍👩‍👧‍👧" == "\"👨‍👩‍👧‍👧\"" then 1 else 0

-- a single BMP code point IS a valid Char (astral ones aren't — purs rejects them)
showBmpChar :: Int
showBmpChar = if show '☺' == "'☺'" then 1 else 0

-- show Number (Dragon4 shortest round-trip + ECMAScript formatting)
showNumZero :: Int
showNumZero = if show 0.0 == "0.0" then 1 else 0

showNumFrac :: Int
showNumFrac = if show 0.1 == "0.1" then 1 else 0

showNumInt :: Int
showNumInt = if show 100.0 == "100.0" then 1 else 0

showNumExpBig :: Int
showNumExpBig = if show 1.0e21 == "1e+21" then 1 else 0

showNumExpSmall :: Int
showNumExpSmall = if show 1.0e-7 == "1e-7" then 1 else 0
