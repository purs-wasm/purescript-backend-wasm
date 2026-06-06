module Examples.Metatheory.Syntax.Types where

data Keyword
  = KW_let
  | KW_letrec
  | KW_and
  | KW_in
  | KW_if
  | KW_then
  | KW_else
  | KW_fun

newtype Ident = Ident String

data Token
  = TokLeftParens
  | TokRightParens
  | TokLeftBrace
  | TokRightBrace
  | TokLeftBracket
  | TokRightBracket
  | TokRightArrow
  | TokForall
  | TokDot
  | TokColon
  | TokReserved Keyword
  | TokInt String Int
  | TokBool String Boolean
  | TokIdent String Ident
  | TokOperator String

type SourcePos =
  { ln :: Int
  , col :: Int
  }

type SourceSpan = { from :: SourcePos, to :: SourcePos }

type SourcePhrase a = { it :: a, at :: SourceSpan }

type SourceToken = SourcePhrase Token

