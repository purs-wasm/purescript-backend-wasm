-- | A compact, hand-written binary codec for the middle IR (`MiddleEnd.IR`): the
-- | *body* of the per-module MIR cache file (the `.pmo`, "PureScript Module Object",
-- | of the incremental rebuild — ADR 0032 phase 4 / ADR 0021 *Future: incremental
-- | compilation cache*). Once a module's optimized output is a pure function of
-- | `(its corefn, its dependency summaries)` (ADR 0032), a rebuild can skip the ~2s
-- | middle-end for unchanged modules and reload their MIR instead — but only if reload
-- | is *much* cheaper than re-optimizing. The Argonaut-generic decoder was not
-- | (measured ≈ the corefn decode cost), so the format is a tagged tree: a one-byte tag
-- | per node, zigzag-LEB128 ints, IEEE-754 `Number`, length-prefixed UTF-8 strings, over
-- | a hand-rolled byte writer (`Serialize.Bytes`).
-- |
-- | This module owns only the MIR ⇆ bytes mapping. The `.pmo` file *header* — magic
-- | number, format version, and the cache key (the corefn ⊕ dependency-summary hashes)
-- | the header carries for validation — belongs to the cache layer that wraps this body,
-- | not here. A human-readable view of MIR is likewise elsewhere: the one-way
-- | `MiddleEnd.Print.printModule` (`--dump-mir`); there is no text parser to maintain.
module PureScript.Backend.Wasm.MiddleEnd.Serialize
  ( encode
  , decode
  ) where

import Prelude

import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Bifunctor (lmap)
import Data.Char (fromCharCode, toCharCode)
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Exception (error, message, throwException, try)
import Effect.Unsafe (unsafePerformEffect)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Bytes (Reader, Writer, finish, getInt, getNumber, getString, getU8, newReader, newWriter, putInt, putNumber, putString, putU8)
import PureScript.CoreFn (Binder(..), ConstructorType(..), Literal(..), Meta(..), Qualified(..))

-- | Serialize a module's optimized MIR to the `.pmo` body bytes. Pure and total: the
-- | same module always yields the same bytes (the internal `Effect` only drives the
-- | mutable byte buffer, never escapes). The cache layer prepends the file header
-- | (magic + version + cache key) to this.
encode :: M.Module -> Uint8Array
encode m = unsafePerformEffect do
  w <- newWriter
  putModule w m
  finish w

-- | Reload a module's MIR from `.pmo` body bytes (the header already stripped and
-- | validated by the cache layer), or report why the body could not be parsed
-- | (truncation / corruption). Pure: a malformed body is reflected in the `Either`, not
-- | thrown — so a damaged cache degrades to a miss and a recompute, never a wrong tree.
decode :: Uint8Array -> Either String M.Module
decode bytes = unsafePerformEffect $ map (lmap message) $ try do
  r <- newReader bytes
  getModule r

fail :: forall a. String -> Effect a
fail = throwException <<< error

-- Generic helpers ------------------------------------------------------------

putArray :: forall a. Writer -> (Writer -> a -> Effect Unit) -> Array a -> Effect Unit
putArray w put xs = putInt w (Array.length xs) *> traverse_ (put w) xs

getArray :: forall a. Reader -> (Reader -> Effect a) -> Effect (Array a)
getArray r get = do
  n <- getInt r
  if n <= 0 then pure []
  else traverse (\_ -> get r) (Array.range 1 n)

putMaybe :: forall a. Writer -> (Writer -> a -> Effect Unit) -> Maybe a -> Effect Unit
putMaybe w put = case _ of
  Nothing -> putU8 w 0
  Just a -> putU8 w 1 *> put w a

getMaybe :: forall a. Reader -> (Reader -> Effect a) -> Effect (Maybe a)
getMaybe r get = do
  t <- getU8 r
  if t == 0 then pure Nothing else Just <$> get r

putBool :: Writer -> Boolean -> Effect Unit
putBool w b = putU8 w (if b then 1 else 0)

getBool :: Reader -> Effect Boolean
getBool r = (_ /= 0) <$> getU8 r

putModuleName :: Writer -> Array String -> Effect Unit
putModuleName w = putArray w putString

getModuleName :: Reader -> Effect (Array String)
getModuleName r = getArray r getString

-- Leaf types reused from CoreFn ----------------------------------------------

putQualified :: forall a. Writer -> (Writer -> a -> Effect Unit) -> Qualified a -> Effect Unit
putQualified w put (Qualified mm a) = putMaybe w putModuleName mm *> put w a

getQualified :: forall a. Reader -> (Reader -> Effect a) -> Effect (Qualified a)
getQualified r get = Qualified <$> getMaybe r getModuleName <*> get r

putConstructorType :: Writer -> ConstructorType -> Effect Unit
putConstructorType w = case _ of
  ProductType -> putU8 w 0
  SumType -> putU8 w 1

getConstructorType :: Reader -> Effect ConstructorType
getConstructorType r = do
  t <- getU8 r
  case t of
    0 -> pure ProductType
    1 -> pure SumType
    _ -> fail "constructor-type tag"

putMeta :: Writer -> Meta -> Effect Unit
putMeta w = case _ of
  IsConstructor ct ids -> putU8 w 0 *> putConstructorType w ct *> putArray w putString ids
  IsNewtype -> putU8 w 1
  IsTypeClassConstructor -> putU8 w 2
  IsForeign -> putU8 w 3
  IsWhere -> putU8 w 4
  IsSyntheticApp -> putU8 w 5

getMeta :: Reader -> Effect Meta
getMeta r = do
  t <- getU8 r
  case t of
    0 -> IsConstructor <$> getConstructorType r <*> getArray r getString
    1 -> pure IsNewtype
    2 -> pure IsTypeClassConstructor
    3 -> pure IsForeign
    4 -> pure IsWhere
    5 -> pure IsSyntheticApp
    _ -> fail "meta tag"

putAnn :: Writer -> { span :: { start :: { line :: Int, column :: Int }, end :: { line :: Int, column :: Int } }, meta :: Maybe Meta } -> Effect Unit
putAnn w a = do
  putInt w a.span.start.line
  putInt w a.span.start.column
  putInt w a.span.end.line
  putInt w a.span.end.column
  putMaybe w putMeta a.meta

getAnn :: Reader -> Effect { span :: { start :: { line :: Int, column :: Int }, end :: { line :: Int, column :: Int } }, meta :: Maybe Meta }
getAnn r = do
  sl <- getInt r
  sc <- getInt r
  el <- getInt r
  ec <- getInt r
  meta <- getMaybe r getMeta
  pure { span: { start: { line: sl, column: sc }, end: { line: el, column: ec } }, meta }

putLiteral :: forall a. Writer -> (Writer -> a -> Effect Unit) -> Literal a -> Effect Unit
putLiteral w put = case _ of
  LitInt n -> putU8 w 0 *> putInt w n
  LitNumber x -> putU8 w 1 *> putNumber w x
  LitString s -> putU8 w 2 *> putString w s
  LitChar c -> putU8 w 3 *> putInt w (toCharCode c)
  LitBoolean b -> putU8 w 4 *> putBool w b
  LitArray xs -> putU8 w 5 *> putArray w put xs
  LitObject kvs -> putU8 w 6 *> putArray w (\w' (Tuple k v) -> putString w' k *> put w' v) kvs

getLiteral :: forall a. Reader -> (Reader -> Effect a) -> Effect (Literal a)
getLiteral r get = do
  t <- getU8 r
  case t of
    0 -> LitInt <$> getInt r
    1 -> LitNumber <$> getNumber r
    2 -> LitString <$> getString r
    3 -> do
      code <- getInt r
      case fromCharCode code of
        Just c -> pure (LitChar c)
        Nothing -> fail "char code out of range"
    4 -> LitBoolean <$> getBool r
    5 -> LitArray <$> getArray r get
    6 -> LitObject <$> getArray r (\r' -> Tuple <$> getString r' <*> get r')
    _ -> fail "literal tag"

putBinder :: Writer -> Binder -> Effect Unit
putBinder w = case _ of
  NullBinder ann -> putU8 w 0 *> putAnn w ann
  LiteralBinder ann lit -> putU8 w 1 *> putAnn w ann *> putLiteral w putBinder lit
  VarBinder ann ident -> putU8 w 2 *> putAnn w ann *> putString w ident
  ConstructorBinder ann tn cn subs ->
    putU8 w 3 *> putAnn w ann *> putQualified w putString tn *> putQualified w putString cn *> putArray w putBinder subs
  NamedBinder ann nm b -> putU8 w 4 *> putAnn w ann *> putString w nm *> putBinder w b

getBinder :: Reader -> Effect Binder
getBinder r = do
  t <- getU8 r
  case t of
    0 -> NullBinder <$> getAnn r
    1 -> LiteralBinder <$> getAnn r <*> getLiteral r getBinder
    2 -> VarBinder <$> getAnn r <*> getString r
    3 -> ConstructorBinder <$> getAnn r <*> getQualified r getString <*> getQualified r getString <*> getArray r getBinder
    4 -> NamedBinder <$> getAnn r <*> getString r <*> getBinder r
    _ -> fail "binder tag"

-- MIR proper -----------------------------------------------------------------

putExpr :: Writer -> M.Expr -> Effect Unit
putExpr w = case _ of
  M.Lit lit -> putU8 w 0 *> putLiteral w putExpr lit
  M.Var q -> putU8 w 1 *> putQualified w putString q
  M.Abs params body -> putU8 w 2 *> putArray w putString params *> putExpr w body
  M.App head args -> putU8 w 3 *> putExpr w head *> putArray w putExpr args
  M.Constructor tn cn fields -> putU8 w 4 *> putString w tn *> putString w cn *> putArray w putString fields
  M.Accessor label e -> putU8 w 5 *> putString w label *> putExpr w e
  M.Update e mLabels updates ->
    putU8 w 6 *> putExpr w e *> putMaybe w (\w' ls -> putArray w' putString ls) mLabels
      *> putArray w (\w' (Tuple k v) -> putString w' k *> putExpr w' v) updates
  M.Case scruts alts -> putU8 w 7 *> putArray w putExpr scruts *> putArray w putAlt alts
  M.Let binds body -> putU8 w 8 *> putArray w putBind binds *> putExpr w body
  M.Perform e -> putU8 w 9 *> putExpr w e

getExpr :: Reader -> Effect M.Expr
getExpr r = do
  t <- getU8 r
  case t of
    0 -> M.Lit <$> getLiteral r getExpr
    1 -> M.Var <$> getQualified r getString
    2 -> M.Abs <$> getArray r getString <*> getExpr r
    3 -> M.App <$> getExpr r <*> getArray r getExpr
    4 -> M.Constructor <$> getString r <*> getString r <*> getArray r getString
    5 -> M.Accessor <$> getString r <*> getExpr r
    6 -> M.Update <$> getExpr r <*> getMaybe r (\r' -> getArray r' getString)
      <*> getArray r (\r' -> Tuple <$> getString r' <*> getExpr r')
    7 -> M.Case <$> getArray r getExpr <*> getArray r getAlt
    8 -> M.Let <$> getArray r getBind <*> getExpr r
    9 -> M.Perform <$> getExpr r
    _ -> fail "expr tag"

putAlt :: Writer -> M.Alt -> Effect Unit
putAlt w alt = do
  putArray w putBinder alt.binders
  case alt.result of
    Left guards -> putU8 w 0 *> putArray w putGuard guards
    Right e -> putU8 w 1 *> putExpr w e

getAlt :: Reader -> Effect M.Alt
getAlt r = do
  binders <- getArray r getBinder
  t <- getU8 r
  result <- case t of
    0 -> Left <$> getArray r getGuard
    1 -> Right <$> getExpr r
    _ -> fail "alt result tag"
  pure { binders, result }

putGuard :: Writer -> M.Guard -> Effect Unit
putGuard w g = putExpr w g.guard *> putExpr w g.expression

getGuard :: Reader -> Effect M.Guard
getGuard r = do
  guard <- getExpr r
  expression <- getExpr r
  pure { guard, expression }

putBind :: Writer -> M.Bind -> Effect Unit
putBind w = case _ of
  M.NonRec meta ident e -> putU8 w 0 *> putMaybe w putMeta meta *> putString w ident *> putExpr w e
  M.Rec rs -> putU8 w 1 *> putArray w putRec rs

getBind :: Reader -> Effect M.Bind
getBind r = do
  t <- getU8 r
  case t of
    0 -> M.NonRec <$> getMaybe r getMeta <*> getString r <*> getExpr r
    1 -> M.Rec <$> getArray r getRec
    _ -> fail "bind tag"

putRec :: Writer -> M.RecBinding -> Effect Unit
putRec w rb = putMaybe w putMeta rb.meta *> putString w rb.ident *> putExpr w rb.expr

getRec :: Reader -> Effect M.RecBinding
getRec r = do
  meta <- getMaybe r getMeta
  ident <- getString r
  expr <- getExpr r
  pure { meta, ident, expr }

putModule :: Writer -> M.Module -> Effect Unit
putModule w m = putModuleName w m.name *> putArray w putBind m.decls

getModule :: Reader -> Effect M.Module
getModule r = do
  name <- getModuleName r
  decls <- getArray r getBind
  pure { name, decls }
