module Examples.Metatheory.Syntax.Parser (parseProgram) where

import Prelude

import Control.Alt (class Alt, (<|>))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldr)
import Data.Function.Uncurried (Fn2, Fn3, mkFn2, mkFn3, runFn2, runFn3)
import Data.Maybe (Maybe(..))
import Examples.Metatheory.Primitive (Primitive(..))
import Examples.Metatheory.Syntax (Constant(..), Expr(..), Type_(..), Var(..))
import Examples.Metatheory.Syntax.Lexer (lex)
import Examples.Metatheory.Syntax.Types (Ident(..), Keyword(..), SourceToken, Token(..))

-- The parser monad ----------------------------------------------------------------
--
-- An uncurried, CPS-encoded parser (the fast representation `purescript-parsing` uses
-- internally), deliberately NOT built on `transformers`' `StateT`/`ExceptT`: a parser is
-- a function of the state and a success / failure continuation. `Data.Function.Uncurried`
-- (`Fn3`/`Fn2`) keeps the continuations uncurried for speed. The `forall r` answer type
-- makes it a proper monad.

type PState = { toks :: Array SourceToken, pos :: Int }

newtype Parser a = Parser
  (forall r. Fn3 PState (Fn2 PState a r) (Fn2 PState String r) r)

-- Unwrap lazily: the projection is forced only when the parser actually *runs* (inside
-- the continuation closures below), never while a parser value is being built. This is
-- what lets mutually-recursive parsers be plain top-level values without tripping
-- PureScript's strict recursive-binding check (no `defer` needed at each use site).
unParser :: forall a r. Parser a -> Fn3 PState (Fn2 PState a r) (Fn2 PState String r) r
unParser (Parser p) = p

instance functorParser :: Functor Parser where
  map f pa = Parser
    (mkFn3 \s ok err -> runFn3 (unParser pa) s (mkFn2 \s1 a -> runFn2 ok s1 (f a)) err)

instance applyParser :: Apply Parser where
  apply pf pa = Parser
    ( mkFn3 \s ok err ->
        runFn3 (unParser pf) s
          (mkFn2 \s1 f -> runFn3 (unParser pa) s1 (mkFn2 \s2 a -> runFn2 ok s2 (f a)) err)
          err
    )

instance applicativeParser :: Applicative Parser where
  pure a = Parser (mkFn3 \s ok _ -> runFn2 ok s a)

instance bindParser :: Bind Parser where
  bind pa f = Parser
    ( mkFn3 \s ok err ->
        runFn3 (unParser pa) s (mkFn2 \s1 a -> runFn3 (unParser (f a)) s1 ok err) err
    )

instance monadParser :: Monad Parser

-- on failure of the left parser, retry the right one from the *original* state
-- (full backtracking — adequate for this small grammar)
instance altParser :: Alt Parser where
  alt pa pb = Parser
    (mkFn3 \s ok err -> runFn3 (unParser pa) s ok (mkFn2 \_ _ -> runFn3 (unParser pb) s ok err))

runParser :: forall a. Parser a -> Array SourceToken -> Either String a
runParser pa toks =
  runFn3 (unParser pa) { toks, pos: 0 } (mkFn2 \_ a -> Right a) (mkFn2 \_ msg -> Left msg)

-- primitive combinators ----------------------------------------------------------

fail :: forall a. String -> Parser a
fail msg = Parser (mkFn3 \s _ err -> runFn2 err s msg)

-- | Build a parser from a thunk; the thunk is forced only when the parser runs. Used to
-- | guard a recursive reference so a self-recursive parser value is accepted as a plain
-- | binding (the reference sits under the `\_ ->`, not in the binding's own WHNF).
defer :: forall a. (Unit -> Parser a) -> Parser a
defer f = Parser (mkFn3 \s ok err -> runFn3 (unParser (f unit)) s ok err)

posOf :: PState -> String
posOf s = case Array.index s.toks s.pos of
  Just st -> "line " <> show st.at.from.ln <> ", column " <> show st.at.from.col
  Nothing -> "end of input"

peek :: Parser (Maybe Token)
peek = Parser (mkFn3 \s ok _ -> runFn2 ok s (map _.it (Array.index s.toks s.pos)))

-- consume the current token iff `f` accepts it (no input consumed on rejection, so
-- `<|>` can backtrack cleanly); failures carry the source position
satisfy :: forall a. String -> (Token -> Maybe a) -> Parser a
satisfy what f = Parser
  ( mkFn3 \s ok err ->
      case Array.index s.toks s.pos of
        Just st -> case f st.it of
          Just a -> runFn2 ok (s { pos = s.pos + 1 }) a
          Nothing -> runFn2 err s ("expected " <> what <> " at " <> posOf s)
        Nothing -> runFn2 err s ("expected " <> what <> " at end of input")
  )

anyToken :: Parser Token
anyToken = satisfy "a token" Just

eof :: Parser Unit
eof = Parser
  ( mkFn3 \s ok err ->
      case Array.index s.toks s.pos of
        Nothing -> runFn2 ok s unit
        Just _ -> runFn2 err s ("expected end of input at " <> posOf s)
  )

-- zero/one-or-more (the parsed item must consume input, so these always terminate)
many :: forall a. Parser a -> Parser (Array a)
many p = some p <|> pure []

some :: forall a. Parser a -> Parser (Array a)
some p = do
  x <- p
  xs <- many p
  pure (Array.cons x xs)

-- left-associative infix chain
chainl1 :: forall a. Parser a -> Parser (a -> a -> a) -> Parser a
chainl1 p op = p >>= rest
  where
  rest acc = (op >>= \f -> p >>= \y -> rest (f acc y)) <|> pure acc

-- token matchers -----------------------------------------------------------------

-- match a token that carries no payload, by a predicate on the token
punct :: String -> (Token -> Boolean) -> Parser Unit
punct what p = satisfy what (\t -> if p t then Just unit else Nothing)

tFun :: Parser Unit
tFun = punct "'fun'" case _ of
  TokReserved KW_fun -> true
  _ -> false

tLet :: Parser Unit
tLet = punct "'let'" case _ of
  TokReserved KW_let -> true
  _ -> false

tIn :: Parser Unit
tIn = punct "'in'" case _ of
  TokReserved KW_in -> true
  _ -> false

tIf :: Parser Unit
tIf = punct "'if'" case _ of
  TokReserved KW_if -> true
  _ -> false

tThen :: Parser Unit
tThen = punct "'then'" case _ of
  TokReserved KW_then -> true
  _ -> false

tElse :: Parser Unit
tElse = punct "'else'" case _ of
  TokReserved KW_else -> true
  _ -> false

tLParen :: Parser Unit
tLParen = punct "'('" case _ of
  TokLeftParens -> true
  _ -> false

tRParen :: Parser Unit
tRParen = punct "')'" case _ of
  TokRightParens -> true
  _ -> false

tLBracket :: Parser Unit
tLBracket = punct "'['" case _ of
  TokLeftBracket -> true
  _ -> false

tRBracket :: Parser Unit
tRBracket = punct "']'" case _ of
  TokRightBracket -> true
  _ -> false

tArrow :: Parser Unit
tArrow = punct "'->'" case _ of
  TokRightArrow -> true
  _ -> false

tDot :: Parser Unit
tDot = punct "'.'" case _ of
  TokDot -> true
  _ -> false

tColon :: Parser Unit
tColon = punct "':'" case _ of
  TokColon -> true
  _ -> false

op :: String -> Parser Unit
op s = punct ("'" <> s <> "'") case _ of
  TokOperator o -> o == s
  _ -> false

ident :: Parser String
ident = satisfy "an identifier" case _ of
  TokIdent _ (Ident n) -> Just n
  _ -> Nothing

-- grammar ------------------------------------------------------------------------

data Binder = TermBinder Var Type_ | TypeBinder Var

-- | Parse a complete program (a single term) from source.
parseProgram :: String -> Either String Expr
parseProgram src = lex src >>= runParser (parseExpr <* eof)

parseExpr :: Parser Expr
parseExpr = peek >>= case _ of
  Just (TokReserved KW_fun) -> parseFun
  Just (TokReserved KW_let) -> parseLet
  Just (TokReserved KW_if) -> parseIf
  _ -> parseEq

-- precedence: `*` > `+`/`-` > `==`, application tighter than all (README). Each level is
-- wrapped in `defer` so its leading reference to the next level is guarded (PureScript
-- otherwise rejects the mutually-recursive value group).
parseEq :: Parser Expr
parseEq = defer \_ -> chainl1 parseAddSub (op "==" $> \a b -> ExprPrim PrimEqInt [ a, b ])

parseAddSub :: Parser Expr
parseAddSub = defer \_ -> chainl1 parseMul
  ((op "+" $> \a b -> ExprPrim PrimAdd [ a, b ]) <|> (op "-" $> \a b -> ExprPrim PrimSub [ a, b ]))

parseMul :: Parser Expr
parseMul = defer \_ -> chainl1 parseApp (op "*" $> \a b -> ExprPrim PrimMul [ a, b ])

-- application (and type application `e [T]`), left-associative
parseApp :: Parser Expr
parseApp = defer \_ -> parseAtom >>= rest
  where
  rest acc =
    (tLBracket *> parseType >>= \t -> tRBracket *> rest (ExprTyApp acc t))
      <|> (parseAtom >>= \a -> rest (ExprApp acc a))
      <|> pure acc

parseAtom :: Parser Expr
parseAtom = peek >>= case _ of
  Just (TokInt _ n) -> anyToken $> ExprLit (CstInt n)
  Just (TokBool _ b) -> anyToken $> ExprLit (CstBool b)
  Just (TokIdent _ (Ident x)) -> anyToken $> ExprVar (Var x)
  Just TokLeftParens -> anyToken *> parseExpr <* tRParen
  _ -> fail "expected an expression"

-- `fun (x:T) (α:*) … -> body` — one head `fun` binds a curried run of term/type binders
parseFun :: Parser Expr
parseFun = do
  tFun
  bs <- some parseBinder
  tArrow
  body <- parseExpr
  pure (foldr applyBinder body bs)
  where
  applyBinder (TermBinder v t) acc = ExprAbs v t acc
  applyBinder (TypeBinder v) acc = ExprTyAbs v acc

-- a binder is `(v : T)` (term) or `(v : *)` (type variable of kind *)
parseBinder :: Parser Binder
parseBinder = do
  tLParen
  v <- ident
  tColon
  b <- (op "*" $> TypeBinder (Var v)) <|> (parseType <#> TermBinder (Var v))
  tRParen
  pure b

parseLet :: Parser Expr
parseLet = do
  tLet
  v <- ident
  op "="
  e1 <- parseExpr
  tIn
  e2 <- parseExpr
  pure (ExprLet (Var v) e1 e2)

parseIf :: Parser Expr
parseIf = do
  tIf
  c <- parseExpr
  tThen
  a <- parseExpr
  tElse
  b <- parseExpr
  pure (ExprIf c a b)

-- types: arrow is right-associative; `int`/`bool` are reserved type constants
parseType :: Parser Type_
parseType = defer \_ -> do
  t1 <- parseTypeAtom
  (tArrow *> (parseType <#> \t2 -> TyArr t1 t2)) <|> pure t1

parseTypeAtom :: Parser Type_
parseTypeAtom = peek >>= case _ of
  Just (TokIdent _ (Ident "int")) -> anyToken $> TyInt
  Just (TokIdent _ (Ident "bool")) -> anyToken $> TyBool
  Just (TokIdent _ (Ident a)) -> anyToken $> TyVar (Var a)
  Just TokForall -> do
    _ <- anyToken
    v <- ident
    tDot
    t <- parseType
    pure (TyPi (Var v) t)
  Just TokLeftParens -> anyToken *> parseType <* tRParen
  _ -> fail "expected a type"
