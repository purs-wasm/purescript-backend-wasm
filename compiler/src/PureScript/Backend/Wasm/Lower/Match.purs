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
-- | literal patterns, array-literal patterns (switched on length, elements
-- | projected by index), variables, wildcards, as-patterns, and guards. Record
-- | *binders* are not handled here (the caller keeps its own record-pattern path).
-- |
-- | Guards: a guarded alternative whose pattern matches may still fail (when none
-- | of its guards hold), in which case matching falls through to the subsequent
-- | alternatives. In the decision tree the rows after a leaf are exactly those
-- | fallthrough candidates, in priority order, so a guarded leaf lowers to a chain
-- | of boolean tests whose final `else` is the compiled remainder of the matrix
-- | (or a trap, when nothing remains — a partial match).
module PureScript.Backend.Wasm.Lower.Match
  ( MatchOps
  , compileMatch
  ) where

import Prelude

import Data.Array as Array
import Data.Char (toCharCode)
import Data.Either (Either(..))
import Data.Foldable (foldl, foldr)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.Lower.IR (AnfExpr(..), Atom(..), Branch(..), LitBranch(..), LitPat(..), Rep(..), Rhs(..), Slot, VarRef(..))
import PureScript.Backend.Wasm.Lower.Types (CtorInfo, ctorSig)
import PureScript.Backend.Wasm.Intrinsics (Intrinsic(ArrayIndex, ArrayLength))
import PureScript.Backend.Wasm.Lower.Monad (Lower, LowerError(..), fresh, throw)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Qualified)
import PureScript.CoreFn as C

-- | The lowering capabilities the decision-tree compiler needs, injected so this
-- | module stays independent of `Lower`. `env` is the lowering environment,
-- | threaded as pattern variables are bound.
type MatchOps env =
  { lowerBody :: env -> M.Expr -> Lower AnfExpr
  -- | Lower a (boolean) guard expression to an `Atom` and continue; the result is
  -- | the conditional built around that atom. (Concretely the caller's `lowerArg`.)
  , lowerCond :: env -> M.Expr -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
  , bindLocal :: String -> Atom -> env -> env
  , lookupCtor :: Qualified String -> Lower CtorInfo
  -- | Whether a constructor belongs to an enum-like type (all-nullary): its values
  -- | are `i31ref` tags, matched by reading the tag rather than a `$Data` switch.
  , isEnumCtor :: Qualified String -> Boolean
  -- | Intern a record label to its `i32` id, for projecting a record-pattern field.
  , internLabel :: String -> Lower Int
  }

-- | One clause row: the remaining column patterns, the variable bindings collected
-- | so far (from matched vars / as-patterns), and the result to run on success —
-- | either an unguarded body (`Right`) or a list of guarded results (`Left`).
type Clause =
  { pats :: Array C.Binder
  , binds :: Array (Tuple String Atom)
  , result :: Either (Array M.Guard) M.Expr
  }

-- | Compile `case occs… of alternatives…`, where `occs` are the already-lowered
-- | scrutinee atoms, into a decision tree.
compileMatch :: forall env. MatchOps env -> env -> Array Atom -> Array M.Alt -> Lower AnfExpr
compileMatch ops env occs alternatives = do
  rows <- traverse toRow alternatives
  compile ops env occs rows
  where
  toRow alt = pure { pats: map stripNewtype alt.binders, binds: [], result: alt.result }

compile :: forall env. MatchOps env -> env -> Array Atom -> Array Clause -> Lower AnfExpr
compile ops env occs rows0 = case Array.head rows of
  Nothing -> throw (UnsupportedExpr "non-exhaustive pattern match")
  Just row1 -> case selectColumn row1.pats of
    Nothing -> matchRow ops env occs row1 (Array.drop 1 rows)
    Just col -> case Array.index occs col of
      Nothing -> throw (UnsupportedExpr "pattern match: column out of range")
      Just occ -> case columnKind rows col of
        KArray -> compileArray ops env occs rows col occ
        KScalar -> compileLit ops env occs rows col occ
        KCtor -> compileCtor ops env occs rows col occ
        KRecord -> compileRecord ops env occs rows col occ
  where
  -- An *unguarded* all-irrefutable row matches everything unconditionally, so rows
  -- after it are unreachable and dropped. A guarded one is not a catch-all (its
  -- guards may all fail), so it never truncates the matrix.
  -- Strip as-patterns first (bind each `name@` to its column's occurrence, leaving the
  -- inner binder), so column selection and specialization never see a `NamedBinder`.
  peeled = map (peelNamed occs) rows0
  rows = case Array.findIndex isCatchAll peeled of
    Just i -> Array.take (i + 1) peeled
    Nothing -> peeled
  isCatchAll r = isUnguarded r && Array.all (not <<< isRefutable) r.pats

-- | Every column of the first row is irrefutable: bind the variables and run the
-- | result. (No `Let`s are needed — irrefutable binders name existing occurrences.)
-- | `rest` is the matrix to fall through to if this row is guarded and its guards
-- | all fail.
matchRow :: forall env. MatchOps env -> env -> Array Atom -> Clause -> Array Clause -> Lower AnfExpr
matchRow ops env occs row rest = do
  let env1 = foldl (\e (Tuple n a) -> ops.bindLocal n a e) env row.binds
  env2 <- bindCols ops env1 (Array.zip occs row.pats)
  case row.result of
    Right body -> ops.lowerBody env2 body
    Left guards -> do
      -- the guards see the row's bindings (`env2`); the fallthrough re-matches the
      -- remaining clauses against the original occurrences (`env`).
      fallthrough <-
        if Array.null rest then pure Nothing
        else Just <$> compile ops env occs rest
      chain <- guardChain ops env2 guards fallthrough
      case chain of
        Just e -> pure e
        -- `Left` always carries at least one guard, so this is unreachable.
        Nothing -> throw (UnsupportedExpr "guarded alternative with no guards")

-- | Build a boolean-test chain `if g1 then e1 else if g2 … else <fallthrough>`.
-- | With no fallthrough the final `else` is absent, so an all-guards-fail value
-- | traps at runtime (a partial match), mirroring `Switch _ _ Nothing`.
guardChain :: forall env. MatchOps env -> env -> Array M.Guard -> Maybe AnfExpr -> Lower (Maybe AnfExpr)
guardChain ops env guards fallthrough = case Array.uncons guards of
  Nothing -> pure fallthrough
  Just { head: g, tail } -> map Just $
    ops.lowerCond env g.guard \cond -> do
      thenE <- ops.lowerBody env g.expression
      elseE <- guardChain ops env tail fallthrough
      pure (LitSwitch cond [ LitBranch (PBoolean true) thenE ] elseE)

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
  -- An enum-like column (all-nullary type) is an `i31ref` tag: read it and switch on
  -- it as a literal, with no field projection (the constructors carry no fields).
  case Array.head ctors of
    Just c | ops.isEnumCtor c -> do
      tagSlot <- fresh
      branches <- traverse enumBranch ctors
      dflt <- defaultMatrix ops env occs rows col occ
      pure (Let tagSlot I32 (REnumTag occ) (LitSwitch (AVar (Local tagSlot)) branches dflt))
    _ -> do
      branches <- traverse ctorBranch ctors
      dflt <- defaultMatrix ops env occs rows col occ
      pure (Switch occ branches dflt)
  where
  enumBranch ctorName = do
    info <- ops.lookupCtor ctorName
    let specialized = Array.mapMaybe (specializeCtor occ col ctorName 0) rows
    inner <- compile ops env (removeAt col occs) specialized
    pure (LitBranch (PInt info.tag) inner)
  ctorBranch ctorName = do
    info <- ops.lookupCtor ctorName
    let specialized = Array.mapMaybe (specializeCtor occ col ctorName info.arity) rows
    fieldSlots <- traverse (const fresh) (Array.replicate info.arity unit)
    let fieldOccs = map (AVar <<< Local) fieldSlots
    inner <- compile ops env (spliceAt col fieldOccs occs) specialized
    pure (Branch info.tag (wrapFieldLets occ (ctorSig info) fieldSlots inner))

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

-- | Switch on the *length* of an array-literal column. A PureScript array pattern
-- | `[p0 … pk]` matches arrays of exactly that length, binding each element. We
-- | read the length (`ArrayLength`), `LitSwitch` on it, and inside each branch
-- | project the elements (`ArrayIndex`) into fresh occurrences with the sub-binders
-- | spliced in (analogous to `compileCtor`, but keyed on length rather than tag).
compileArray :: forall env. MatchOps env -> env -> Array Atom -> Array Clause -> Int -> Atom -> Lower AnfExpr
compileArray ops env occs rows col occ = do
  let lengths = Array.nubEq (Array.mapMaybe (\r -> arrayLenOf =<< Array.index r.pats col) rows)
  lenSlot <- fresh
  branches <- traverse lenBranch lengths
  dflt <- defaultMatrix ops env occs rows col occ
  pure
    ( Let lenSlot Boxed (RPrim ArrayLength [ occ ])
        (LitSwitch (AVar (Local lenSlot)) branches dflt)
    )
  where
  lenBranch len = do
    elemSlots <- traverse (const fresh) (Array.replicate len unit)
    let elemOccs = map (AVar <<< Local) elemSlots
    let specialized = Array.mapMaybe (specializeArray occ col len) rows
    inner <- compile ops env (spliceAt col elemOccs occs) specialized
    pure (LitBranch (PInt len) (wrapElemLets occ elemSlots inner))

-- | Decompose a record-pattern column. A record is a product — it always matches —
-- | so there is no switch and no default: project the fields any row mentions (by label,
-- | via `RProjLabel`) into fresh occurrences and splice each row's sub-binders in (a row
-- | not mentioning a projected label gets a wildcard there). Analogous to `compileCtor`,
-- | but single-branch (no tag) and keyed on labels rather than positions.
compileRecord :: forall env. MatchOps env -> env -> Array Atom -> Array Clause -> Int -> Atom -> Lower AnfExpr
compileRecord ops env occs rows col occ = do
  let labels = Array.nub (rows >>= recLabels col)
  fieldSlots <- traverse (const fresh) labels
  let fieldOccs = map (AVar <<< Local) fieldSlots
  let specialized = Array.mapMaybe (specializeRecord occ col labels) rows
  inner <- compile ops env (spliceAt col fieldOccs occs) specialized
  wrapRecordLets ops occ (Array.zip labels fieldSlots) inner

recLabels :: Int -> Clause -> Array String
recLabels col r = case Array.index r.pats col of
  Just (C.LiteralBinder _ (C.LitObject kvs)) -> map (\(Tuple l _) -> l) kvs
  _ -> []

-- | Wrap a body in the `Let`s that project a matched record pattern's fields by label.
wrapRecordLets :: forall env. MatchOps env -> Atom -> Array (Tuple String Slot) -> AnfExpr -> Lower AnfExpr
wrapRecordLets ops occ pairs inner = case Array.uncons pairs of
  Nothing -> pure inner
  Just { head: Tuple label slot, tail } -> do
    labelId <- ops.internLabel label
    rest <- wrapRecordLets ops occ tail inner
    pure (Let slot Boxed (RProjLabel occ labelId) rest)

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

-- specialize a row for an array-literal column of length `len` (splice the element
-- sub-binders), or treat a var/wildcard as `len` wildcards, else drop the row.
specializeArray :: Atom -> Int -> Int -> Clause -> Maybe Clause
specializeArray occ col len row = case Array.index row.pats col of
  Just (C.LiteralBinder _ (C.LitArray subs))
    | Array.length subs == len -> Just (row { pats = spliceAt col (map stripNewtype subs) row.pats })
    | otherwise -> Nothing
  Just (C.VarBinder _ name) ->
    Just (row { pats = spliceAt col (wildcards len) row.pats, binds = Array.snoc row.binds (Tuple name occ) })
  Just (C.NullBinder _) ->
    Just (row { pats = spliceAt col (wildcards len) row.pats })
  _ -> Nothing

-- specialize a row for a record-pattern column over the projected `labels` (splice each
-- field's sub-binder, a wildcard where the row's record omits that label), or treat a
-- var/wildcard as `|labels|` wildcards, else drop the row.
specializeRecord :: Atom -> Int -> Array String -> Clause -> Maybe Clause
specializeRecord occ col labels row = case Array.index row.pats col of
  Just (C.LiteralBinder _ (C.LitObject kvs)) ->
    let
      subs = map (\l -> stripNewtype (fromMaybe (C.NullBinder synthAnn) (lookupField l kvs))) labels
    in
      Just (row { pats = spliceAt col subs row.pats })
  Just (C.VarBinder _ name) ->
    Just (row { pats = spliceAt col (wildcards (Array.length labels)) row.pats, binds = Array.snoc row.binds (Tuple name occ) })
  Just (C.NullBinder _) ->
    Just (row { pats = spliceAt col (wildcards (Array.length labels)) row.pats })
  _ -> Nothing
  where
  lookupField l = Array.findMap (\(Tuple k b) -> if k == l then Just b else Nothing)

defaultRow :: Atom -> Int -> Clause -> Maybe Clause
defaultRow occ col row = case Array.index row.pats col of
  Just (C.VarBinder _ name) -> Just (row { pats = removeAt col row.pats, binds = Array.snoc row.binds (Tuple name occ) })
  Just (C.NullBinder _) -> Just (row { pats = removeAt col row.pats })
  _ -> Nothing

-- | Strip as-patterns (`name@inner`) from a row's columns: bind each `name` to its
-- | column's occurrence and replace the column with `inner` (recursively, for a nested
-- | `a@b@…`). Run once at the top of `compile`, so the column readers (`columnKind` /
-- | `ctorOf` / …) and the `specialize*` / `defaultRow` functions — which only understand
-- | `Constructor` / `Literal` / `Var` / `Null` — never encounter a `NamedBinder` (which
-- | they would otherwise drop, silently failing the alternative).
peelNamed :: Array Atom -> Clause -> Clause
peelNamed occs row
  | Array.null row.pats = row
  | otherwise = foldl peelCol row (Array.range 0 (Array.length row.pats - 1))
      where
      peelCol r i = case Array.index occs i, Array.index r.pats i of
        Just occ, Just (C.NamedBinder _ name inner) ->
          peelCol (r { pats = fromMaybe r.pats (Array.updateAt i inner r.pats), binds = Array.snoc r.binds (Tuple name occ) }) i
        _, _ -> r

-- | The leftmost refutable column of a row, or `Nothing` if all are irrefutable.
selectColumn :: Array C.Binder -> Maybe Int
selectColumn = Array.findIndex isRefutable

isUnguarded :: Clause -> Boolean
isUnguarded r = case r.result of
  Right _ -> true
  Left _ -> false

isRefutable :: C.Binder -> Boolean
isRefutable = case _ of
  C.NullBinder _ -> false
  C.VarBinder _ _ -> false
  C.NamedBinder _ _ b -> isRefutable b
  C.ConstructorBinder _ _ _ _ -> true
  C.LiteralBinder _ _ -> true

-- | What a refutable column tests on, deciding which compiler handles it. A
-- | well-typed column is homogeneous; the kind is read off its first refutable
-- | binder (array literals are distinguished from scalar literals because they
-- | switch on length + project elements rather than compare by value).
data ColKind
  = KCtor
  | KScalar
  | KArray
  | KRecord

columnKind :: Array Clause -> Int -> ColKind
columnKind rows col = case Array.findMap rowKind rows of
  Just k -> k
  Nothing -> KCtor
  where
  rowKind r = binderKind =<< Array.index r.pats col
  binderKind = case _ of
    C.LiteralBinder _ (C.LitArray _) -> Just KArray
    C.LiteralBinder _ (C.LitObject _) -> Just KRecord
    C.LiteralBinder _ _ -> Just KScalar
    C.ConstructorBinder _ _ _ _ -> Just KCtor
    _ -> Nothing

ctorOf :: C.Binder -> Maybe (Qualified String)
ctorOf = case _ of
  C.ConstructorBinder _ _ name _ -> Just name
  _ -> Nothing

arrayLenOf :: C.Binder -> Maybe Int
arrayLenOf = case _ of
  C.LiteralBinder _ (C.LitArray subs) -> Just (Array.length subs)
  _ -> Nothing

litOf :: C.Binder -> Maybe (C.Literal C.Binder)
litOf = case _ of
  C.LiteralBinder _ lit -> Just lit
  _ -> Nothing

-- | Erase newtype constructors: a newtype carries no runtime tag, so `NT b`
-- | matches transparently as `b` on the same occurrence. Recurse through an
-- | as-pattern's inner binder too (`x@(NT b)` → `x@b`): `peelNamed` later strips the
-- | `NamedBinder` and exposes that inner binder as a column without re-stripping it, so
-- | a newtype left under a `NamedBinder` here would reach `requireCtor` as an
-- | unregistered constructor.
stripNewtype :: C.Binder -> C.Binder
stripNewtype = case _ of
  C.ConstructorBinder ann _ _ subs
    | ann.meta == Just C.IsNewtype, [ sub ] <- subs -> stripNewtype sub
  C.NamedBinder ann name b -> C.NamedBinder ann name (stripNewtype b)
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
-- Each field is read at its own representation (the slot rep and the projection
-- agree), from the constructor's `$Data_<sig>` struct.
wrapFieldLets :: Atom -> Array Rep -> Array Slot -> AnfExpr -> AnfExpr
wrapFieldLets occ sig fieldSlots body =
  foldr (\(Tuple idx slot) acc -> Let slot (fieldRep idx) (RProjField occ sig idx) acc) body
    (Array.mapWithIndex Tuple fieldSlots)
  where
  fieldRep idx = fromMaybe Boxed (Array.index sig idx)

-- wrap a branch body in the `Let`s that project a matched array pattern's elements
-- (by index, via the `ArrayIndex` prim).
wrapElemLets :: Atom -> Array Slot -> AnfExpr -> AnfExpr
wrapElemLets occ elemSlots body =
  foldr (\(Tuple idx slot) acc -> Let slot Boxed (RPrim ArrayIndex [ occ, ALitInt idx ]) acc) body
    (Array.mapWithIndex Tuple elemSlots)
