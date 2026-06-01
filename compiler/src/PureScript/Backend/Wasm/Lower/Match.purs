-- | Compile a general (multi-scrutinee, multi-alternative) CoreFn `case` into a
-- | **decision tree** of `Switch` / `LitSwitch` nodes — the classic column-wise
-- | pattern-match compilation (Maranget, "Compiling Pattern Matching to Good
-- | Decision Trees"; cf. Grain's `matchcomp`).
-- |
-- | This is a self-contained leaf: it depends only on CoreFn, the IR, and the
-- | lowering monad. The lowering-specific operations it needs (lowering a matched
-- | body, binding a pattern variable, resolving a constructor's tag/arity) are
-- | injected via `MatchOps`, so it never imports `Lower` and there is no cycle.
-- |
-- | Scope: constructor patterns (newtype constructors are erased — they carry no
-- | tag — so they are transparently unwrapped onto the same occurrence), scalar
-- | literal patterns, variables, wildcards, and as-patterns. Guards and record /
-- | array *binders* are not handled here (the caller keeps its own paths / errors).
module PureScript.Backend.Wasm.Lower.Match
  ( MatchOps
  , compileMatch
  ) where

import Prelude

import Data.Array as Array
import Data.Char (toCharCode)
import Data.Either (Either(..))
import Data.Foldable (foldl, foldr)
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.IR (AnfExpr(..), Atom(..), Branch(..), LitBranch(..), LitPat(..), Rep(..), Rhs(..), Slot, VarRef(..))
import PureScript.Backend.Wasm.Lower.Monad (Lower, LowerError(..), fresh, throw)
import PureScript.CoreFn (Qualified)
import PureScript.CoreFn as C

-- | The lowering capabilities the decision-tree compiler needs, injected so this
-- | module stays independent of `Lower`. `env` is the lowering environment,
-- | threaded as pattern variables are bound.
type MatchOps env =
  { lowerBody :: env -> C.Expr -> Lower AnfExpr
  , bindLocal :: String -> Atom -> env -> env
  , lookupCtor :: Qualified String -> Lower { tag :: Int, arity :: Int }
  }

-- | One clause row: the remaining column patterns, the variable bindings collected
-- | so far (from matched vars / as-patterns), and the body to run on success.
type Clause =
  { pats :: Array C.Binder
  , binds :: Array (Tuple String Atom)
  , body :: C.Expr
  }

-- | Compile `case occs… of alternatives…`, where `occs` are the already-lowered
-- | scrutinee atoms, into a decision tree.
compileMatch :: forall env. MatchOps env -> env -> Array Atom -> Array C.CaseAlternative -> Lower AnfExpr
compileMatch ops env occs alternatives = do
  rows <- traverse toRow alternatives
  compile ops env occs rows
  where
  toRow alt = case alt.result of
    Left _ -> throw GuardedCaseUnsupported
    Right body -> pure { pats: map stripNewtype alt.binders, binds: [], body }

compile :: forall env. MatchOps env -> env -> Array Atom -> Array Clause -> Lower AnfExpr
compile ops env occs rows0 = case Array.head rows of
  Nothing -> throw (UnsupportedExpr "non-exhaustive pattern match")
  Just row1 -> case selectColumn row1.pats of
    Nothing -> matchRow ops env occs row1
    Just col -> case Array.index occs col of
      Nothing -> throw (UnsupportedExpr "pattern match: column out of range")
      Just occ ->
        if columnIsLiteral rows col then compileLit ops env occs rows col occ
        else compileCtor ops env occs rows col occ
  where
  -- An all-irrefutable row (a catch-all) matches everything, so any rows after it
  -- are unreachable and dropped.
  rows = case Array.findIndex (Array.all (not <<< isRefutable) <<< _.pats) rows0 of
    Just i -> Array.take (i + 1) rows0
    Nothing -> rows0

-- | Every column of the first row is irrefutable: bind the variables and run the
-- | body. (No `Let`s are needed — irrefutable binders name existing occurrences.)
matchRow :: forall env. MatchOps env -> env -> Array Atom -> Clause -> Lower AnfExpr
matchRow ops env occs row = do
  let env1 = foldl (\e (Tuple n a) -> ops.bindLocal n a e) env row.binds
  env2 <- bindCols ops env1 (Array.zip occs row.pats)
  ops.lowerBody env2 row.body

bindCols :: forall env. MatchOps env -> env -> Array (Tuple Atom C.Binder) -> Lower env
bindCols ops env cols = case Array.uncons cols of
  Nothing -> pure env
  Just { head: Tuple occ b, tail } -> do
    env' <- bindIrref ops env occ b
    bindCols ops env' tail

bindIrref :: forall env. MatchOps env -> env -> Atom -> C.Binder -> Lower env
bindIrref ops env occ = case _ of
  C.NullBinder _ -> pure env
  C.VarBinder _ name -> pure (ops.bindLocal name occ env)
  C.NamedBinder _ name b -> bindIrref ops (ops.bindLocal name occ env) occ b
  _ -> throw (UnsupportedBinder "expected an irrefutable binder")

-- | Switch on a constructor column: one `Branch` per distinct constructor (its
-- | fields projected into the branch as fresh `Let`s), plus the default matrix.
compileCtor :: forall env. MatchOps env -> env -> Array Atom -> Array Clause -> Int -> Atom -> Lower AnfExpr
compileCtor ops env occs rows col occ = do
  let ctors = Array.nubEq (Array.mapMaybe (\r -> ctorOf =<< Array.index r.pats col) rows)
  branches <- traverse ctorBranch ctors
  dflt <- defaultMatrix ops env occs rows col occ
  pure (Switch occ branches dflt)
  where
  ctorBranch ctorName = do
    info <- ops.lookupCtor ctorName
    let specialized = Array.mapMaybe (specializeCtor occ col ctorName info.arity) rows
    fieldSlots <- traverse (const fresh) (Array.replicate info.arity unit)
    let fieldOccs = map (AVar <<< Local) fieldSlots
    inner <- compile ops env (spliceAt col fieldOccs occs) specialized
    pure (Branch info.tag (wrapFieldLets occ fieldSlots inner))

-- | Switch on a scalar-literal column: one `LitBranch` per distinct literal, plus
-- | the default matrix (literal matches always carry a catch-all).
compileLit :: forall env. MatchOps env -> env -> Array Atom -> Array Clause -> Int -> Atom -> Lower AnfExpr
compileLit ops env occs rows col occ = do
  allLits <- traverse litPat (Array.mapMaybe (\r -> litOf =<< Array.index r.pats col) rows)
  branches <- traverse litBranch (Array.nubEq allLits)
  dflt <- defaultMatrix ops env occs rows col occ
  pure (LitSwitch occ branches dflt)
  where
  litBranch pat = do
    let specialized = Array.mapMaybe (specializeLit col pat) rows
    inner <- compile ops env (removeAt col occs) specialized
    pure (LitBranch pat inner)

-- | The default matrix: rows whose column `col` is a wildcard (a var binds the
-- | whole occurrence), with that column removed. `Nothing` when empty (unreachable).
defaultMatrix :: forall env. MatchOps env -> env -> Array Atom -> Array Clause -> Int -> Atom -> Lower (Maybe AnfExpr)
defaultMatrix ops env occs rows col occ =
  case Array.mapMaybe (defaultRow occ col) rows of
    [] -> pure Nothing
    rest -> Just <$> compile ops env (removeAt col occs) rest

-- specialize a row for constructor `ctorName`/`arity` at column `col`, or drop it.
specializeCtor :: Atom -> Int -> Qualified String -> Int -> Clause -> Maybe Clause
specializeCtor occ col ctorName arity row = case Array.index row.pats col of
  Just (C.ConstructorBinder _ _ name subs)
    -- sub-binders enter the matrix here, so strip their newtype wrappers too
    | name == ctorName -> Just (row { pats = spliceAt col (map stripNewtype subs) row.pats })
    | otherwise -> Nothing
  Just (C.VarBinder _ name) ->
    Just (row { pats = spliceAt col (wildcards arity) row.pats, binds = Array.snoc row.binds (Tuple name occ) })
  Just (C.NullBinder _) ->
    Just (row { pats = spliceAt col (wildcards arity) row.pats })
  _ -> Nothing

specializeLit :: Int -> LitPat -> Clause -> Maybe Clause
specializeLit col pat row = case Array.index row.pats col of
  Just (C.LiteralBinder _ lit) | litMatches pat lit -> Just (row { pats = removeAt col row.pats })
  _ -> Nothing

defaultRow :: Atom -> Int -> Clause -> Maybe Clause
defaultRow occ col row = case Array.index row.pats col of
  Just (C.VarBinder _ name) -> Just (row { pats = removeAt col row.pats, binds = Array.snoc row.binds (Tuple name occ) })
  Just (C.NullBinder _) -> Just (row { pats = removeAt col row.pats })
  _ -> Nothing

-- | The leftmost refutable column of a row, or `Nothing` if all are irrefutable.
selectColumn :: Array C.Binder -> Maybe Int
selectColumn = Array.findIndex isRefutable

isRefutable :: C.Binder -> Boolean
isRefutable = case _ of
  C.NullBinder _ -> false
  C.VarBinder _ _ -> false
  C.NamedBinder _ _ b -> isRefutable b
  C.ConstructorBinder _ _ _ _ -> true
  C.LiteralBinder _ _ -> true

columnIsLiteral :: Array Clause -> Int -> Boolean
columnIsLiteral rows col = Array.any isLit rows
  where
  isLit r = case Array.index r.pats col of
    Just (C.LiteralBinder _ _) -> true
    _ -> false

ctorOf :: C.Binder -> Maybe (Qualified String)
ctorOf = case _ of
  C.ConstructorBinder _ _ name _ -> Just name
  _ -> Nothing

litOf :: C.Binder -> Maybe (C.Literal C.Binder)
litOf = case _ of
  C.LiteralBinder _ lit -> Just lit
  _ -> Nothing

-- | Erase newtype constructors: a newtype carries no runtime tag, so `NT b`
-- | matches transparently as `b` on the same occurrence.
stripNewtype :: C.Binder -> C.Binder
stripNewtype = case _ of
  C.ConstructorBinder ann _ _ subs
    | ann.meta == Just C.IsNewtype, [ sub ] <- subs -> stripNewtype sub
  other -> other

litPat :: C.Literal C.Binder -> Lower LitPat
litPat = case _ of
  C.LitInt n -> pure (PInt n)
  C.LitChar c -> pure (PInt (toCharCode c))
  C.LitBoolean b -> pure (PBoolean b)
  C.LitNumber n -> pure (PNumber n)
  C.LitString s -> pure (PString s)
  _ -> throw (UnsupportedBinder "pattern match: only scalar literal binders are supported")

litMatches :: LitPat -> C.Literal C.Binder -> Boolean
litMatches pat lit = case pat, lit of
  PInt n, C.LitInt m -> n == m
  PInt n, C.LitChar c -> n == toCharCode c
  PBoolean a, C.LitBoolean b -> a == b
  PNumber a, C.LitNumber b -> a == b
  PString a, C.LitString b -> a == b
  _, _ -> false

wildcards :: Int -> Array C.Binder
wildcards n = Array.replicate n (C.NullBinder synthAnn)

synthAnn :: C.Ann
synthAnn = { meta: Nothing, span: { start: origin, end: origin } }
  where
  origin = { line: 0, column: 0 }

-- replace the element at `col` with `newElems` (splice); used for both occurrences
-- and pattern columns so they stay aligned.
spliceAt :: forall a. Int -> Array a -> Array a -> Array a
spliceAt col newElems arr = Array.take col arr <> newElems <> Array.drop (col + 1) arr

removeAt :: forall a. Int -> Array a -> Array a
removeAt col arr = Array.take col arr <> Array.drop (col + 1) arr

-- wrap a branch body in the `Let`s that project the matched constructor's fields.
wrapFieldLets :: Atom -> Array Slot -> AnfExpr -> AnfExpr
wrapFieldLets occ fieldSlots body =
  foldr (\(Tuple idx slot) acc -> Let slot Boxed (RProjField occ idx) acc) body
    (Array.mapWithIndex Tuple fieldSlots)
