module Examples.Metatheory.Syntax.Lexer (lex) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.String.CodeUnits as SCU
import Examples.Metatheory.Syntax.Types
  ( Ident(..)
  , Keyword(..)
  , SourcePos
  , SourceToken
  , Token(..)
  )

-- | Tokenise a source string into position-annotated tokens (`SourceToken`), or report
-- | the first lexical error with its line/column. Hand-written scanner (no parser
-- | combinator dependency, to keep the example wasm-compilable).
lex :: String -> Either String (Array SourceToken)
lex src = go { ln: 1, col: 1 } (SCU.toCharArray src) []
  where
  go :: SourcePos -> Array Char -> Array SourceToken -> Either String (Array SourceToken)
  go pos cs acc = case Array.uncons cs of
    Nothing -> Right (Array.reverse acc)
    Just { head: c, tail }
      | c == '\n' -> go { ln: pos.ln + 1, col: 1 } tail acc
      | isSpace c -> go (adv pos 1) tail acc
      | c == '(' -> emit pos acc TokLeftParens 1 tail
      | c == ')' -> emit pos acc TokRightParens 1 tail
      | c == '[' -> emit pos acc TokLeftBracket 1 tail
      | c == ']' -> emit pos acc TokRightBracket 1 tail
      | c == '{' -> emit pos acc TokLeftBrace 1 tail
      | c == '}' -> emit pos acc TokRightBrace 1 tail
      | c == '.' -> emit pos acc TokDot 1 tail
      | c == ':' -> emit pos acc TokColon 1 tail
      | c == '∀' -> emit pos acc TokForall 1 tail
      | c == '→' -> emit pos acc TokRightArrow 1 tail
      | c == '+' -> emit pos acc (TokOperator "+") 1 tail
      | c == '*' -> emit pos acc (TokOperator "*") 1 tail
      | c == '-' -> case Array.head tail of
          Just '>' -> emit pos acc TokRightArrow 2 (Array.drop 1 tail)
          _ -> emit pos acc (TokOperator "-") 1 tail
      | c == '=' -> case Array.head tail of
          Just '=' -> emit pos acc (TokOperator "==") 2 (Array.drop 1 tail)
          _ -> emit pos acc (TokOperator "=") 1 tail
      | isDigit c ->
          let
            sp = Array.span isDigit cs
            raw = SCU.fromCharArray sp.init
          in
            case Int.fromString raw of
              Just n -> emit pos acc (TokInt raw n) (Array.length sp.init) sp.rest
              Nothing -> Left (errAt pos ("invalid integer literal: " <> raw))
      | isIdentStart c ->
          let
            sp = Array.span isIdentRest cs
            raw = SCU.fromCharArray sp.init
          in
            emit pos acc (classify raw) (Array.length sp.init) sp.rest
      | otherwise -> Left (errAt pos ("unexpected character: " <> SCU.singleton c))

  emit :: SourcePos -> Array SourceToken -> Token -> Int -> Array Char -> Either String (Array SourceToken)
  emit pos acc tok len rest =
    let
      toPos = adv pos len
    in
      go toPos rest (Array.cons { it: tok, at: { from: pos, to: toPos } } acc)

  adv :: SourcePos -> Int -> SourcePos
  adv pos n = { ln: pos.ln, col: pos.col + n }

  errAt :: SourcePos -> String -> String
  errAt pos m = "lex error at line " <> show pos.ln <> ", column " <> show pos.col <> ": " <> m

  classify :: String -> Token
  classify raw = case raw of
    "let" -> TokReserved KW_let
    "letrec" -> TokReserved KW_letrec
    "and" -> TokReserved KW_and
    "in" -> TokReserved KW_in
    "if" -> TokReserved KW_if
    "then" -> TokReserved KW_then
    "else" -> TokReserved KW_else
    "fun" -> TokReserved KW_fun
    "forall" -> TokForall
    "true" -> TokBool raw true
    "false" -> TokBool raw false
    _ -> TokIdent raw (Ident raw)

isSpace :: Char -> Boolean
isSpace c = c == ' ' || c == '\t' || c == '\r'

isDigit :: Char -> Boolean
isDigit c = c >= '0' && c <= '9'

-- identifiers start lowercase (ASCII or Greek, e.g. `α`) per the README grammar, and
-- continue with alphanumerics, `'` and `_`.
isIdentStart :: Char -> Boolean
isIdentStart c = isLowerAscii c || isGreekLower c || c == '_'

isIdentRest :: Char -> Boolean
isIdentRest c = isLowerAscii c || isUpperAscii c || isDigit c || isGreekLower c || c == '\'' || c == '_'

isLowerAscii :: Char -> Boolean
isLowerAscii c = c >= 'a' && c <= 'z'

isUpperAscii :: Char -> Boolean
isUpperAscii c = c >= 'A' && c <= 'Z'

isGreekLower :: Char -> Boolean
isGreekLower c = c >= 'α' && c <= 'ω'
