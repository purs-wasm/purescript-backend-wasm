-- | Lower the CoreFn AST to the backend IR (`PureScript.Backend.Wasm.IR`), under
-- | the uniform `eqref` convention (ADR 0004) and eval/apply (ADR 0003). What the
-- | lowering does:
-- |
-- |   * **Lambda lifting / closure conversion.** A `C.Abs` is lifted to a
-- |     top-level code function `$codeN(closure, arg)`; its free local variables
-- |     are captured into the closure's environment, and the lifted body reads
-- |     them back as `EnvField`s. Lifted functions accumulate in the lowering
-- |     state and are appended to the program.
-- |
-- |   * **eval/apply application.** A known intrinsic / constructor / top-level
-- |     function applied to its exact arity is a direct primitive / allocation /
-- |     call. Otherwise — an unknown head (local closure or lambda), or a
-- |     partial or over-application of a known callable — it goes through
-- |     `RApply` (`call_ref`), eta-expanding the callable to a closure where
-- |     needed.
-- |
-- |   * **Recursion.** Top-level `Rec` groups compile as ordinary module
-- |     functions calling one another by name. A single-binding recursive `let`
-- |     recurs through the code function's own closure parameter (no knot-tying).
-- |     A mutually-recursive `let` group becomes a `LetRec`: the closures are
-- |     allocated first and their sibling-referencing environment slots are then
-- |     back-patched (knot-tying), since each refers to the others.
-- |
-- |   * **Pattern matching.** A `case` on constructors becomes a `Switch` on the
-- |     ADT tag; a `case` on literals (and the `case` an `if` desugars to) becomes
-- |     a `LitSwitch` of value-equality tests; a bare var/wildcard is a catch-all.
-- |
-- |   * **Records and type-class dictionaries.** Record literals become
-- |     label-id-keyed records (`RMkRecord`) and accessors a runtime label search
-- |     (`RProjLabel`); dictionaries are records, so their newtype constructors and
-- |     accessors are erased to the same (ADR 0007).
module PureScript.Backend.Wasm.Lower
  ( lowerModule
  , lowerModules
  , module ReExport
  ) where

import Prelude

import Control.Monad.State (gets, modify_, runStateT)
import Data.Array as Array
import Data.Char (toCharCode)
import Data.Either (Either(..))
import Data.Foldable (foldl, foldr)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.FreeVars (freeVars)
import PureScript.Backend.Wasm.Lower.Monad (Lower, LowerError(..), fresh, throw)
import PureScript.Backend.Wasm.Lower.Monad (LowerError(..)) as ReExport
import PureScript.Backend.Wasm.Intrinsics (foreignIntrinsic)
import PureScript.Backend.Wasm.IR (Atom(..), AnfExpr(..), Branch(..), FuncName(..), IRFunc, LitBranch(..), LitPat(..), Program, RecBind(..), Rep(..), Rhs(..), Slot(..), VarRef(..))
import PureScript.CoreFn (Bind(..), Module, Qualified(..))
import PureScript.CoreFn as C

type CtorInfo = { tag :: Int, arity :: Int }

-- | Read-only facts about the whole program being lowered. All name-keyed
-- | tables use the **module-qualified** name (`Module.ident`), so a reference can
-- | resolve a callee in any linked module, not just its own (ADR 0009). `labelIds`
-- | is interned once across every module so records built and projected in
-- | different modules agree on a label's id.
type ModuleInfo =
  { knownFuncs :: Object Int
  , ctors :: Object CtorInfo
  -- | Names of type-class dictionary constructors (decls tagged
  -- | `IsTypeClassConstructor`). They are newtype identities (`\x -> x`) wrapping
  -- | the dictionary record, so their application is erased (ADR 0007).
  , dictCtors :: Object Unit
  , labelIds :: Object Int
  }

-- | The local environment plus the module facts. `locals` maps a CoreFn
-- | identifier to the `Atom` it denotes (a local slot, or — inside a lifted code
-- | function — a captured `EnvField`).
type Env =
  { locals :: Object Atom
  , knownFuncs :: Object Int
  , ctors :: Object CtorInfo
  , moduleName :: Array String
  , dictCtors :: Object Unit
  , labelIds :: Object Int
  }

-- | The globally-unique key/name for a module-qualified top-level identifier:
-- | `Module.ident`. The same string is used as a symbol-table key and as the
-- | emitted wasm function name, so cross-module references line up (ADR 0009).
qualifiedKey :: Array String -> String -> String
qualifiedKey moduleName ident = joinWith "." moduleName <> "." <> ident

-- | The key for a `Qualified` reference. A `Nothing` module means a local, which
-- | is never a top-level key; callers guard against that, but we fall back to the
-- | bare name so the lookup simply misses.
qualifiedKeyOf :: Qualified String -> String
qualifiedKeyOf (Qualified mModule name) = case mModule of
  Just moduleName -> qualifiedKey moduleName name
  Nothing -> name

qualifiedFuncName :: Qualified String -> FuncName
qualifiedFuncName = FuncName <<< qualifiedKeyOf

-- | Flatten a curried application spine: `App (App f a) b` → `f` with `[a, b]`.
collectApp :: C.Expr -> { head :: C.Expr, args :: Array C.Expr }
collectApp = go []
  where
  go acc = case _ of
    C.App _ f a -> go (Array.cons a acc) f
    other -> { head: other, args: acc }

-- | Peel leading lambdas into the parameter idents (outermost first) and body.
peelAbs :: C.Expr -> { params :: Array String, body :: C.Expr }
peelAbs = go []
  where
  go acc = case _ of
    C.Abs _ p b -> go (Array.snoc acc p) b
    body -> { params: acc, body }

resolveLocal :: Env -> String -> Lower Atom
resolveLocal env ident = case Object.lookup ident env.locals of
  Just atom -> pure atom
  Nothing -> throw (UnknownVariable ident)

-- | Bind an `Rhs` to a fresh slot (always `Boxed` under ADR 0004) and continue
-- | with the atom naming its result.
bindRhs :: Rhs -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
bindRhs rhs k = do
  slot <- fresh
  rest <- k (AVar (Local slot))
  pure (Let slot Boxed rhs rest)

-- | A zero source annotation for synthesised CoreFn nodes.
synthAnn :: C.Ann
synthAnn = { meta: Nothing, span: { start: origin, end: origin } }
  where
  origin = { line: 0, column: 0 }

-- | Eta-expand a callable reference (a function / intrinsic / constructor) of
-- | the given arity into `\x0 .. x(n-1) -> callable x0 .. x(n-1)`, so a
-- | non-saturated use can be lowered as a closure through the ordinary lambda
-- | lifting. The synthesised body is always a *saturated* application, so this
-- | does not recurse back into the non-saturated case.
etaExpand :: C.Expr -> Int -> C.Expr
etaExpand callable arity = foldr (C.Abs synthAnn) saturatedBody params
  where
  params = (\i -> "$x" <> show i) <$> Array.range 0 (arity - 1)
  saturatedBody = foldl (\f p -> C.App synthAnn f (C.Var synthAnn (Qualified Nothing p))) callable params

-- | Reduce an expression to a trivial `Atom`, threading any computation into
-- | `Let`s that wrap the continuation `k`.
lowerArg :: Env -> C.Expr -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerArg env expr k = case expr of
  C.Literal _ (C.LitInt n) -> k (ALitInt n)
  C.Literal _ (C.LitNumber n) -> k (ALitNumber n)
  -- A `Char` shares `Int`'s representation; carry its code point.
  C.Literal _ (C.LitChar c) -> k (ALitInt (toCharCode c))
  C.Literal _ (C.LitBoolean b) -> k (ALitBoolean b)
  C.Literal _ (C.LitString s) -> k (ALitString s)
  C.Literal _ (C.LitArray elements) -> lowerArgs env elements \atoms -> bindRhs (RMkArray atoms) k
  -- A record literal (and so a type-class dictionary, after its newtype
  -- constructor is erased) becomes a label-id-keyed record (ADR 0001 / 0007).
  C.Literal _ (C.LitObject fields) -> lowerRecord env fields k
  -- `Prim.undefined` is the dummy argument applied to a superclass thunk; the
  -- thunk ignores it, so any boxed value will do.
  C.Var _ (Qualified (Just [ "Prim" ]) "undefined") -> k (ALitInt 0)
  C.Var _ (Qualified Nothing ident) -> resolveLocal env ident >>= k
  -- A bare reference to a known callable becomes a closure value (eta-expanded);
  -- a nullary constructor is built directly; a nullary top-level value (a CAF —
  -- e.g. an instance dictionary) is *called* to produce its value.
  -- A defined top-level binding (constructor or function/CAF) shadows the
  -- intrinsic table: instance names like `topInt` collide with foreign idents
  -- (`Data.Bounded.topInt`), but real foreigns have no decl body so they are
  -- never `ctors`/`knownFuncs` — so `foreignIntrinsic` is only the fallback.
  C.Var _ q@(Qualified (Just _) ident)
    | Just info <- Object.lookup (qualifiedKeyOf q) env.ctors ->
        if info.arity == 0 then bindRhs (RMkData info.tag []) k
        else lowerArg env (etaExpand expr info.arity) k
    | Just arity <- Object.lookup (qualifiedKeyOf q) env.knownFuncs ->
        if arity == 0 then bindRhs (RCallKnown (qualifiedFuncName q) []) k
        else lowerArg env (etaExpand expr arity) k
    -- A nullary foreign (e.g. `Data.Bounded.topInt`) is a constant value, not a
    -- callable, so it materializes directly rather than eta-expanding.
    | Just (Tuple intr arity) <- foreignIntrinsic ident ->
        if arity == 0 then bindRhs (RPrim intr []) k
        else lowerArg env (etaExpand expr arity) k
    | otherwise -> throw (UnsupportedExpr ("unapplied top-level reference: " <> qualifiedKeyOf q))
  C.Accessor _ label record -> lowerArg env record \recAtom -> do
    labelId <- internLabel env label
    bindRhs (RProjLabel recAtom labelId) k
  C.ObjectUpdate _ record copyFields updates -> lowerObjectUpdate env record copyFields updates k
  -- A `let` in argument position (e.g. purs's `let v = p in v { … }` for a record
  -- update): bind the groups, then reduce the body to an atom for `k`.
  C.Let _ binds body -> lowerCoreLetK env binds body \env' body' -> lowerArg env' body' k
  C.App _ _ _ -> lowerApp env (collectApp expr) k
  C.Abs _ param body -> do
    { codeName, captures } <- liftLambda Nothing env param body
    bindRhs (RMkClosure codeName captures) k
  _ -> throw (UnsupportedExpr "unsupported expression in argument position")

-- | Lower a left-to-right list of operands to atoms, then continue.
lowerArgs :: Env -> Array C.Expr -> (Array Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerArgs env args k = case Array.uncons args of
  Nothing -> k []
  Just { head: e, tail } -> lowerArg env e \a -> lowerArgs env tail \as -> k (Array.cons a as)

-- | The interned `i32` id of a record/dictionary label.
internLabel :: Env -> String -> Lower Int
internLabel env label = case Object.lookup label env.labelIds of
  Just labelId -> pure labelId
  Nothing -> throw (UnsupportedExpr ("unknown record label: " <> label))

-- | Lower a record literal's fields (left-to-right) to `(labelId, atom)` pairs.
lowerFields :: Env -> Array (Tuple String C.Expr) -> (Array (Tuple Int Atom) -> Lower AnfExpr) -> Lower AnfExpr
lowerFields env fields k = case Array.uncons fields of
  Nothing -> k []
  Just { head: Tuple label e, tail } -> do
    labelId <- internLabel env label
    lowerArg env e \a -> lowerFields env tail \rest -> k (Array.cons (Tuple labelId a) rest)

-- | Lower a record literal to an `RMkRecord`, its `(labelId, value)` pairs sorted
-- | by id for a canonical layout (ADR 0001 / 0007).
lowerRecord :: Env -> Array (Tuple String C.Expr) -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerRecord env fields k =
  lowerFields env fields \pairs -> bindRhs (RMkRecord (Array.sortWith fst pairs)) k

-- | Lower a record update `record { l = v, … }` into a freshly-built record: the
-- | updated fields take their new values, and the untouched fields (`copyFields`,
-- | which lists exactly the other labels for a monomorphic record) are projected
-- | out of the original. A polymorphic update (`copyFields = Nothing`, an open
-- | row whose extra fields are unknown) needs a runtime copy and is not yet
-- | supported.
lowerObjectUpdate
  :: Env -> C.Expr -> Maybe (Array String) -> Array (Tuple String C.Expr) -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerObjectUpdate env record copyFields updates k = case copyFields of
  Nothing -> throw (UnsupportedExpr "polymorphic record update (open row) is not yet supported")
  Just untouched ->
    lowerArg env record \recAtom ->
      lowerCopied recAtom untouched \copied ->
        lowerUpdated updates \updated ->
          bindRhs (RMkRecord (Array.sortWith fst (copied <> updated))) k
  where
  lowerCopied recAtom labels kk = case Array.uncons labels of
    Nothing -> kk []
    Just { head: label, tail } -> do
      labelId <- internLabel env label
      bindRhs (RProjLabel recAtom labelId) \atom ->
        lowerCopied recAtom tail \rest -> kk (Array.cons (Tuple labelId atom) rest)
  lowerUpdated ups kk = case Array.uncons ups of
    Nothing -> kk []
    Just { head: Tuple label expr, tail } -> do
      labelId <- internLabel env label
      lowerArg env expr \atom ->
        lowerUpdated tail \rest -> kk (Array.cons (Tuple labelId atom) rest)

-- | Lower an application spine. A known intrinsic / constructor / top-level
-- | function dispatches on how the argument count compares to its arity:
-- | saturated → a direct primitive / allocation / call; under-applied → a
-- | partial application (eta-expand to a closure, apply what we have);
-- | over-applied → call saturated, then apply the rest through the result.
-- | Any other head (a local closure value or a lambda) is an `RApply` chain.
lowerApp :: Env -> { head :: C.Expr, args :: Array C.Expr } -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerApp env { head, args } k = case head of
  -- A dictionary constructor is a newtype identity wrapping its record, so the
  -- application `C$Dict rec` erases to `rec` (ADR 0007).
  C.Var _ q@(Qualified (Just _) _)
    | Object.member (qualifiedKeyOf q) env.dictCtors -> case args of
        [ rec ] -> lowerArg env rec k
        _ -> throw (UnsupportedExpr "dictionary constructor must take exactly one record")
  -- See `lowerArg`: a defined binding (ctor/knownFunc) shadows the intrinsic
  -- table, so `foreignIntrinsic` is the fallback (foreigns have no decl body).
  C.Var _ q@(Qualified (Just _) ident)
    | Just info <- Object.lookup (qualifiedKeyOf q) env.ctors -> applyArity info.arity (RMkData info.tag)
    | Just arity <- Object.lookup (qualifiedKeyOf q) env.knownFuncs -> applyArity arity (RCallKnown (qualifiedFuncName q))
    | Just (Tuple intr arity) <- foreignIntrinsic ident -> applyArity arity (RPrim intr)
    | otherwise -> throw (UnsupportedExpr ("unknown callee: " <> qualifiedKeyOf q))
  _ ->
    lowerArg env head \fAtom ->
      lowerArgs env args \atoms ->
        applyChain fAtom atoms k
  where
  applyArity arity makeRhs =
    let
      n = Array.length args
    in
      if n == arity then lowerArgs env args \atoms -> bindRhs (makeRhs atoms) k
      else if n < arity then
        lowerArg env (etaExpand head arity) \fAtom ->
          lowerArgs env args \atoms ->
            applyChain fAtom atoms k
      else
        lowerArgs env (Array.take arity args) \saturating ->
          bindRhs (makeRhs saturating) \result ->
            lowerArgs env (Array.drop arity args) \extra ->
              applyChain result extra k

-- | Apply a closure atom to a list of argument atoms one at a time, each a
-- | single-argument `RApply` whose result feeds the next (arity-1 closures).
applyChain :: Atom -> Array Atom -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
applyChain f args k = case Array.uncons args of
  Nothing -> k f
  Just { head: a, tail } -> bindRhs (RApply f a) \r -> applyChain r tail k

-- | Lift a `C.Abs` to a top-level code function and return its name plus the
-- | atoms to capture (the lambda's free locals, resolved in the current scope).
-- |
-- | `self` names a binding the lambda may recursively refer to (a `let rec`).
-- | Rather than capturing it — which would need knot-tying, since the closure
-- | is not yet built — the self reference resolves to the code function's own
-- | closure parameter (local 0), and is therefore excluded from the captures.
liftLambda :: Maybe String -> Env -> String -> C.Expr -> Lower { codeName :: FuncName, captures :: Array Atom }
liftLambda self env param body = do
  let allFrees = freeVars [ param ] body
  let
    frees = case self of
      Just name -> Array.filter (_ /= name) allFrees
      Nothing -> allFrees
  captures <- traverse (resolveLocal env) frees
  n <- gets _.nextCode
  modify_ _ { nextCode = n + 1 }
  let codeName = funcName env.moduleName ("$code" <> show n)
  -- The code function's locals: slot 0 = the closure (also the recursive self
  -- reference), slot 1 = the argument; captured frees are read positionally from
  -- the closure environment.
  let
    selfLocal = case self of
      Just name -> [ Tuple name (AVar (Local (Slot 0))) ]
      Nothing -> []
    codeLocals = Object.fromFoldable
      ( selfLocal
          <> [ Tuple param (AVar (Local (Slot 1))) ]
          <> Array.mapWithIndex (\i f -> Tuple f (AVar (EnvField i))) frees
      )
  let codeEnv = env { locals = codeLocals }
  saved <- gets _.slot
  modify_ _ { slot = 2 }
  codeAnfExpr <- lowerTail codeEnv body
  codeCount <- gets _.slot
  modify_ _ { slot = saved }
  modify_ \s -> s
    { lifted = Array.snoc s.lifted
        { name: codeName
        , params: [ CloRef, Boxed ] -- (ref $Clo), then the eqref argument
        , result: Boxed
        , body: codeAnfExpr
        , export: Nothing
        , localCount: codeCount
        }
    }
  pure { codeName, captures }

-- | Lower an expression in tail position to a complete `AnfExpr`.
lowerTail :: Env -> C.Expr -> Lower AnfExpr
lowerTail env = case _ of
  C.Case _ scrutinees alternatives -> lowerCase env scrutinees alternatives
  C.Let _ binds body -> lowerCoreLet env binds body
  expr -> lowerArg env expr \atom -> pure (Return atom)

-- | A CoreFn `let`: bind each group, extending the local environment, then
-- | lower the body. `NonRec` groups bind directly. A single-binding `Rec` group
-- | is self-recursion — lifted with the recursive name bound to the closure's
-- | own parameter (see `liftLambda`). A multi-binding `Rec` group is mutual
-- | recursion, compiled to a `LetRec` whose closures are allocated first and then
-- | back-patched to refer to one another (knot-tying).
lowerCoreLet :: Env -> Array Bind -> C.Expr -> Lower AnfExpr
lowerCoreLet env binds body = lowerCoreLetK env binds body lowerTail

-- | The general form of `lowerCoreLet`: bind the groups, then hand the extended
-- | environment and body to `finish`. A `let` in tail position finishes with
-- | `lowerTail`; a `let` in argument position (e.g. the `let v = p in v { … }`
-- | purs emits for a record update) finishes by reducing the body to an `Atom`.
lowerCoreLetK :: Env -> Array Bind -> C.Expr -> (Env -> C.Expr -> Lower AnfExpr) -> Lower AnfExpr
lowerCoreLetK env binds body finish = case Array.uncons binds of
  Nothing -> finish env body
  Just { head: NonRec _ ident e, tail } ->
    lowerArg env e \atom ->
      lowerCoreLetK (env { locals = Object.insert ident atom env.locals }) tail body finish
  Just { head: Rec recBinds, tail } -> case recBinds of
    [ { ident, expr: C.Abs _ param recBody } ] -> do
      { codeName, captures } <- liftLambda (Just ident) env param recBody
      bindRhs (RMkClosure codeName captures) \fAtom ->
        lowerCoreLetK (env { locals = Object.insert ident fAtom env.locals }) tail body finish
    _ -> do
      -- Mutual recursion: pre-allocate a slot per binding so each member's
      -- closure can refer to its siblings (as forward references resolved by the
      -- `LetRec` knot-tying), then lift each member's body.
      slots <- traverse (const fresh) recBinds
      let
        bound = Array.zip recBinds slots
        env' = env
          { locals = foldl (\m (Tuple rb s) -> Object.insert rb.ident (AVar (Local s)) m) env.locals bound }
      recBindsIR <- traverse (lowerRecBind env') bound
      rest <- lowerCoreLetK env' tail body finish
      pure (LetRec recBindsIR rest)

-- | Lower one member of a mutually-recursive `let` group, given its
-- | pre-allocated slot. Captures are resolved in an environment where every
-- | group member is already bound to its slot, so sibling references become
-- | forward references for the `LetRec` to patch.
lowerRecBind :: Env -> Tuple C.RecBinding Slot -> Lower RecBind
lowerRecBind env (Tuple rb slot) = case rb.expr of
  C.Abs _ param recBody -> do
    { codeName, captures } <- liftLambda Nothing env param recBody
    pure (RecBind slot codeName captures)
  _ -> throw (UnsupportedExpr "a recursive let binding must be a function")

-- | Compile a `case` into a `Switch` on the scrutinee's constructor tag.
-- |
-- | A single-alternative match on a **newtype** constructor (in particular the
-- | `\dict -> case dict of C$Dict v -> …` a type-class method accessor unwraps to)
-- | carries no runtime tag — the newtype is erased — so it lowers transparently:
-- | the sub-binder is bound directly to the scrutinee, with no `Switch`.
lowerCase :: Env -> Array C.Expr -> Array C.CaseAlternative -> Lower AnfExpr
lowerCase env scrutinees alternatives = case scrutinees of
  [ scrutinee ]
    | Just { var, body } <- newtypeAlternative alternatives ->
        lowerArg env scrutinee \scrutAtom ->
          lowerTail (bindNewtypeVar env var scrutAtom) body
  -- A record pattern (`\{ x, y } -> …`) is a single destructuring alternative
  -- that always matches: bind each field's sub-binder to a label projection.
  [ scrutinee ]
    | Just { fields, body } <- recordPatternAlternative alternatives ->
        lowerArg env scrutinee \scrutAtom -> bindRecordFields env scrutAtom fields body
  [ scrutinee ] ->
    lowerArg env scrutinee \scrutAtom -> case caseKind alternatives of
      KConstructor -> do
        { branches, dflt } <- lowerCtorAlternatives env scrutAtom alternatives
        pure (Switch scrutAtom branches dflt)
      KLiteral -> do
        { branches, dflt } <- lowerLitAlternatives env scrutAtom alternatives
        pure (LitSwitch scrutAtom branches dflt)
      KCatchAll -> lowerCatchAll env scrutAtom alternatives
  _ -> throw (UnsupportedExpr "only a single case scrutinee is supported")

-- | How a single-scrutinee `case` matches: on constructor tags, on literal
-- | values, or a bare catch-all (`x ->` / `_ ->`). Determined by the binders.
data CaseKind = KConstructor | KLiteral | KCatchAll

caseKind :: Array C.CaseAlternative -> CaseKind
caseKind alternatives =
  if Array.any (firstBinder isCtorBinder) alternatives then KConstructor
  else if Array.any (firstBinder isLitBinder) alternatives then KLiteral
  else KCatchAll
  where
  firstBinder p alt = case Array.head alt.binders of
    Just b -> p b
    Nothing -> false
  isCtorBinder = case _ of
    C.ConstructorBinder _ _ _ _ -> true
    _ -> false
  isLitBinder = case _ of
    C.LiteralBinder _ _ -> true
    _ -> false

-- | Recognise a single record-pattern alternative `{ l: b, … } -> body` (a
-- | `LiteralBinder` of an object literal). Records are products, so it is the
-- | only alternative and always matches.
recordPatternAlternative :: Array C.CaseAlternative -> Maybe { fields :: Array (Tuple String C.Binder), body :: C.Expr }
recordPatternAlternative = case _ of
  [ { binders: [ C.LiteralBinder _ (C.LitObject fields) ], result: Right body } ] -> Just { fields, body }
  _ -> Nothing

-- | Bind a record pattern's fields, each to a label projection out of the
-- | scrutinee, then lower the body.
bindRecordFields :: Env -> Atom -> Array (Tuple String C.Binder) -> C.Expr -> Lower AnfExpr
bindRecordFields env scrutAtom fields body = case Array.uncons fields of
  Nothing -> lowerTail env body
  Just { head: Tuple label subBinder, tail } -> case subBinder of
    C.NullBinder _ -> bindRecordFields env scrutAtom tail body
    C.VarBinder _ name -> do
      labelId <- internLabel env label
      slot <- fresh
      let env' = env { locals = Object.insert name (AVar (Local slot)) env.locals }
      rest <- bindRecordFields env' scrutAtom tail body
      pure (Let slot Boxed (RProjLabel scrutAtom labelId) rest)
    _ -> throw (UnsupportedBinder "record pattern field: only var / wildcard sub-binders")

-- | Lower literal-pattern alternatives into `LitBranch`es plus the catch-all
-- | default. A var/wildcard binder is the default (binding the scrutinee for a
-- | `VarBinder`); alternatives after it are unreachable and dropped.
lowerLitAlternatives
  :: Env -> Atom -> Array C.CaseAlternative -> Lower { branches :: Array LitBranch, dflt :: Maybe AnfExpr }
lowerLitAlternatives env scrutAtom = go
  where
  go alternatives = case Array.uncons alternatives of
    Nothing -> pure { branches: [], dflt: Nothing }
    Just { head: alt, tail } -> case alt.result of
      Left _ -> throw GuardedCaseUnsupported
      Right body -> case alt.binders of
        [ C.LiteralBinder _ lit ] -> do
          pat <- litPat lit
          bodyIR <- lowerTail env body
          rest <- go tail
          pure (rest { branches = Array.cons (LitBranch pat bodyIR) rest.branches })
        [ C.NullBinder _ ] -> do
          d <- lowerTail env body
          pure { branches: [], dflt: Just d }
        [ C.VarBinder _ name ] -> do
          d <- lowerTail (env { locals = Object.insert name scrutAtom env.locals }) body
          pure { branches: [], dflt: Just d }
        _ -> throw (UnsupportedBinder "literal match: expected a literal or catch-all binder")

-- | A bare catch-all `case` (no constructor or literal patterns): bind the
-- | scrutinee if the binder names it, then lower the body.
lowerCatchAll :: Env -> Atom -> Array C.CaseAlternative -> Lower AnfExpr
lowerCatchAll env scrutAtom alternatives = case Array.head alternatives of
  Just { binders: [ binder ], result: Right body } -> case binder of
    C.NullBinder _ -> lowerTail env body
    C.VarBinder _ name -> lowerTail (env { locals = Object.insert name scrutAtom env.locals }) body
    _ -> throw (UnsupportedBinder "catch-all match expects a var or wildcard binder")
  _ -> throw (UnsupportedBinder "unsupported catch-all alternative")

litPat :: C.Literal C.Binder -> Lower LitPat
litPat = case _ of
  C.LitInt n -> pure (PInt n)
  C.LitChar c -> pure (PInt (toCharCode c))
  C.LitBoolean b -> pure (PBoolean b)
  C.LitNumber n -> pure (PNumber n)
  C.LitString s -> pure (PString s)
  _ -> throw (UnsupportedBinder "literal pattern: only Int / Char / Boolean / Number / String")

-- | Recognise a single, unguarded alternative whose binder is a newtype
-- | constructor with one var / wildcard sub-binder, returning the bound name (if
-- | any) and the body. Newtype-ness is the `IsNewtype` meta the CoreFn binder
-- | carries.
newtypeAlternative :: Array C.CaseAlternative -> Maybe { var :: Maybe String, body :: C.Expr }
newtypeAlternative = case _ of
  [ { binders: [ C.ConstructorBinder ann _ _ subBinders ], result: Right body } ]
    | ann.meta == Just C.IsNewtype -> case subBinders of
        [ C.VarBinder _ name ] -> Just { var: Just name, body }
        [ C.NullBinder _ ] -> Just { var: Nothing, body }
        _ -> Nothing
  _ -> Nothing

bindNewtypeVar :: Env -> Maybe String -> Atom -> Env
bindNewtypeVar env var scrutAtom = case var of
  Just name -> env { locals = Object.insert name scrutAtom env.locals }
  Nothing -> env

-- | Lower constructor-match alternatives into `Branch`es plus the catch-all
-- | default. Each `ConstructorBinder` becomes a `Branch` (its sub-binders bound as
-- | field projections in the body); a trailing var/wildcard binder is the default
-- | (`case x of Ctor -> …; _ -> …`), binding the scrutinee for a `VarBinder`.
lowerCtorAlternatives
  :: Env -> Atom -> Array C.CaseAlternative -> Lower { branches :: Array Branch, dflt :: Maybe AnfExpr }
lowerCtorAlternatives env scrutAtom = go
  where
  go alternatives = case Array.uncons alternatives of
    Nothing -> pure { branches: [], dflt: Nothing }
    Just { head: alt, tail } -> case alt.result of
      Left _ -> throw GuardedCaseUnsupported
      Right body -> case alt.binders of
        [ C.ConstructorBinder _ _ ctorNameQ subBinders ] -> do
          info <- requireCtor env (qualifiedKeyOf ctorNameQ)
          branchBody <- bindFields env scrutAtom 0 subBinders body
          rest <- go tail
          pure (rest { branches = Array.cons (Branch info.tag branchBody) rest.branches })
        [ C.NullBinder _ ] -> do
          d <- lowerTail env body
          pure { branches: [], dflt: Just d }
        [ C.VarBinder _ name ] -> do
          d <- lowerTail (env { locals = Object.insert name scrutAtom env.locals }) body
          pure { branches: [], dflt: Just d }
        _ -> throw (UnsupportedBinder "case alternative: expected a constructor or catch-all binder")

-- | Bind a constructor's sub-binders to its fields by position.
bindFields :: Env -> Atom -> Int -> Array C.Binder -> C.Expr -> Lower AnfExpr
bindFields env scrutAtom index subBinders body = case Array.uncons subBinders of
  Nothing -> lowerTail env body
  Just { head: b, tail } -> case b of
    C.NullBinder _ -> bindFields env scrutAtom (index + 1) tail body
    C.VarBinder _ name -> do
      slot <- fresh
      let env' = env { locals = Object.insert name (AVar (Local slot)) env.locals }
      rest <- bindFields env' scrutAtom (index + 1) tail body
      pure (Let slot Boxed (RProjField scrutAtom index) rest)
    _ -> throw (UnsupportedBinder "constructor sub-binders must be var or wildcard")

requireCtor :: Env -> String -> Lower CtorInfo
requireCtor env ctorName = case Object.lookup ctorName env.ctors of
  Just info -> pure info
  Nothing -> throw (UnknownConstructor ctorName)

-- | Qualify a top-level identifier into a globally-unique wasm function name.
funcName :: Array String -> String -> FuncName
funcName moduleName ident = FuncName (qualifiedKey moduleName ident)

-- | Lower one top-level function definition to an `IRFunc` (eqref convention),
-- | given its module and whether that module is a link root (only roots' names
-- | are exported; everything else is internal and so DCE-eligible — ADR 0009).
lowerTopFunc :: ModuleInfo -> Array String -> Boolean -> Tuple String C.Expr -> Lower IRFunc
lowerTopFunc info moduleName isRoot (Tuple ident expr) = do
  let { params, body } = peelAbs expr
  let locals = Object.fromFoldable (Array.mapWithIndex (\i p -> Tuple p (AVar (Local (Slot i)))) params)
  let
    env =
      { locals
      , knownFuncs: info.knownFuncs
      , ctors: info.ctors
      , moduleName
      , dictCtors: info.dictCtors
      , labelIds: info.labelIds
      }
  modify_ _ { slot = Array.length params }
  block <- lowerTail env body
  count <- gets _.slot
  pure
    { name: funcName moduleName ident
    , params: const Boxed <$> params
    , result: Boxed
    , body: block
    , export: if isRoot then Just ident else Nothing
    , localCount: count
    }

-- | Collect the data constructors of every module, keyed by qualified name and
-- | assigning each a 0-based tag within its (qualified) type.
collectCtors :: Array Module -> Object CtorInfo
collectCtors modules = (foldl perModule { counts: Object.empty, out: Object.empty } modules).out
  where
  perModule acc m = foldl (step m.name) acc (Array.mapMaybe ctorOf m.decls)
  ctorOf = case _ of
    NonRec _ _ (C.Constructor _ typeName ctorName fieldNames) ->
      Just { typeName, ctorName, arity: Array.length fieldNames }
    _ -> Nothing
  step moduleName { counts, out } { typeName, ctorName, arity } =
    let
      typeKey = qualifiedKey moduleName typeName
      tag = fromMaybe 0 (Object.lookup typeKey counts)
    in
      { counts: Object.insert typeKey (tag + 1) counts
      , out: Object.insert (qualifiedKey moduleName ctorName) { tag, arity } out
      }

-- | Flatten the top-level binding groups into `(ident, expr)` pairs. A `Rec`
-- | group is mutual recursion between top-level functions; since each becomes a
-- | module function called by name (`RCallKnown`), the recursion needs no
-- | special handling beyond compiling every member.
topLevelBindings :: Array Bind -> Array (Tuple String C.Expr)
topLevelBindings = (_ >>= flatten)
  where
  flatten = case _ of
    NonRec _ ident expr -> [ Tuple ident expr ]
    Rec rs -> map (\r -> Tuple r.ident r.expr) rs

-- | Every module's non-constructor top-level functions, keyed by qualified name
-- | and mapped to arity. Dictionary constructors are excluded: they are newtype
-- | identities, erased at their use sites rather than emitted (ADR 0007).
collectFuncs :: Object Unit -> Array Module -> Object Int
collectFuncs dictCtors modules = Object.fromFoldable (modules >>= moduleFuncs)
  where
  moduleFuncs m = Array.mapMaybe (keep m.name) (topLevelBindings m.decls)
  keep moduleName (Tuple ident expr)
    | isConstructor expr || Object.member (qualifiedKey moduleName ident) dictCtors = Nothing
    | otherwise = Just (Tuple (qualifiedKey moduleName ident) (Array.length (peelAbs expr).params))

-- | One module's definitions that become wasm functions: every binding (including
-- | `Rec`-group members) that is neither a data constructor nor a (newtype-erased)
-- | dictionary constructor.
functionDecls :: Object Unit -> Module -> Array (Tuple String C.Expr)
functionDecls dictCtors m =
  Array.filter
    (\(Tuple ident expr) -> not (isConstructor expr) && not (Object.member (qualifiedKey m.name ident) dictCtors))
    (topLevelBindings m.decls)

isConstructor :: C.Expr -> Boolean
isConstructor = case _ of
  C.Constructor _ _ _ _ -> true
  _ -> false

-- | Every module's type-class dictionary constructors (decls tagged
-- | `IsTypeClassConstructor`), keyed by qualified name. Each is a newtype identity
-- | (`\x -> x`) wrapping the dictionary record, so its applications are erased
-- | (ADR 0007).
collectDictCtors :: Array Module -> Object Unit
collectDictCtors modules = Object.fromFoldable (modules >>= moduleDictCtors)
  where
  moduleDictCtors m = Array.mapMaybe (dictCtorOf m.name) m.decls
  dictCtorOf moduleName = case _ of
    NonRec ann ident _ | ann.meta == Just C.IsTypeClassConstructor -> Just (Tuple (qualifiedKey moduleName ident) unit)
    _ -> Nothing

-- | Intern every record/dictionary label across all modules to a unique `i32` id,
-- | assigned by sorted label order so the mapping is deterministic and shared:
-- | records built in one module and projected in another agree on a label's id.
collectLabels :: Array Module -> Object Int
collectLabels modules =
  Object.fromFoldable
    (Array.mapWithIndex (\i l -> Tuple l i) (Array.sort (Array.nub (modules >>= \m -> m.decls >>= bindLabels))))
  where
  bindLabels = case _ of
    NonRec _ _ e -> exprLabels e
    Rec rs -> rs >>= \r -> exprLabels r.expr
  exprLabels = case _ of
    C.Literal _ (C.LitObject kvs) -> kvs >>= \(Tuple l v) -> Array.cons l (exprLabels v)
    C.Literal _ (C.LitArray es) -> es >>= exprLabels
    C.Literal _ _ -> []
    C.Constructor _ _ _ _ -> []
    C.Accessor _ l e -> Array.cons l (exprLabels e)
    C.ObjectUpdate _ e copyFields kvs ->
      exprLabels e <> fromMaybe [] copyFields <> (kvs >>= \(Tuple l v) -> Array.cons l (exprLabels v))
    C.Abs _ _ b -> exprLabels b
    C.App _ f a -> exprLabels f <> exprLabels a
    C.Var _ _ -> []
    C.Case _ ss alts -> (ss >>= exprLabels) <> (alts >>= altLabels)
    C.Let _ binds b -> (binds >>= bindLabels) <> exprLabels b
  altLabels alt =
    (alt.binders >>= binderLabels)
      <> case alt.result of
        Right e -> exprLabels e
        Left guards -> guards >>= \g -> exprLabels g.guard <> exprLabels g.expression
  -- the labels a record pattern (`{ l: … }`) projects, recursing into nested binders
  binderLabels = case _ of
    C.LiteralBinder _ (C.LitObject fields) -> fields >>= \(Tuple l b) -> Array.cons l (binderLabels b)
    C.LiteralBinder _ (C.LitArray bs) -> bs >>= binderLabels
    C.ConstructorBinder _ _ _ bs -> bs >>= binderLabels
    C.NamedBinder _ _ b -> binderLabels b
    _ -> []

-- | The module-qualified names of the top-level bindings an expression references
-- | (`Qualified (Just module) ident` `Var`s), used for reachability.
qualifiedRefs :: C.Expr -> Array String
qualifiedRefs = go
  where
  go = case _ of
    C.Var _ (Qualified (Just m) ident) -> [ qualifiedKey m ident ]
    C.Var _ _ -> []
    C.Literal _ (C.LitArray es) -> es >>= go
    C.Literal _ (C.LitObject kvs) -> kvs >>= \(Tuple _ v) -> go v
    C.Literal _ _ -> []
    C.Constructor _ _ _ _ -> []
    C.Accessor _ _ e -> go e
    C.ObjectUpdate _ e _ kvs -> go e <> (kvs >>= \(Tuple _ v) -> go v)
    C.Abs _ _ b -> go b
    C.App _ f a -> go f <> go a
    C.Case _ ss alts -> (ss >>= go) <> (alts >>= altRefs)
    C.Let _ binds b -> (binds >>= bindRefs) <> go b
  altRefs alt = case alt.result of
    Right e -> go e
    Left guards -> guards >>= \g -> go g.guard <> go g.expression
  bindRefs = case _ of
    NonRec _ _ e -> go e
    Rec rs -> rs >>= \r -> go r.expr

-- | The set of function keys reachable from `roots`, following references through
-- | the `functions` table (a worklist closure). References to things outside the
-- | table — foreign primitives, data/dictionary constructors — are not followed,
-- | since those are not lowered as functions. This is the tree-shaking that lets a
-- | few `Prelude` functions be lowered without dragging in (and failing on) the
-- | rest of a module (ADR 0009).
reachableFunctions :: Object C.Expr -> Array String -> Object Unit
reachableFunctions functions roots = go (Object.fromFoldable (map (\k -> Tuple k unit) roots)) roots
  where
  go seen frontier = case Array.uncons frontier of
    Nothing -> seen
    Just { head: key, tail } -> case Object.lookup key functions of
      Nothing -> go seen tail
      Just expr ->
        let
          fresh = Array.filter (\k -> Object.member k functions && not (Object.member k seen))
            (Array.nub (qualifiedRefs expr))
        in
          go (foldl (\s k -> Object.insert k unit s) seen fresh) (tail <> fresh)

-- | Link and lower several decoded CoreFn modules into one backend IR `Program`
-- | (one wasm; ADR 0009). Symbol tables are built across **all** modules and keyed
-- | by qualified name, so cross-module references resolve. Only functions
-- | **reachable** from the `roots` modules are lowered (so a `Prelude` module's
-- | unused — and possibly unsupported — instances are never visited); the roots'
-- | own functions are exported, the rest are internal.
lowerModules :: Array (Array String) -> Array Module -> Either LowerError Program
lowerModules roots modules = do
  let
    dictCtors = collectDictCtors modules
    info =
      { knownFuncs: collectFuncs dictCtors modules
      , ctors: collectCtors modules
      , dictCtors
      , labelIds: collectLabels modules
      }
    entries = modules >>= \m ->
      let
        isRoot = Array.elem m.name roots
      in
        functionDecls dictCtors m <#> \(Tuple ident expr) ->
          { key: qualifiedKey m.name ident, moduleName: m.name, ident, expr, isRoot }
    functions = Object.fromFoldable (entries <#> \e -> Tuple e.key e.expr)
    rootKeys = Array.mapMaybe (\e -> if e.isRoot then Just e.key else Nothing) entries
    reachable = reachableFunctions functions rootKeys
    toLower = Array.filter (\e -> Object.member e.key reachable) entries
  Tuple funcs st <- runStateT
    (traverse (\e -> lowerTopFunc info e.moduleName e.isRoot (Tuple e.ident e.expr)) toLower)
    { slot: 0, lifted: [], nextCode: 0 }
  pure { funcs: funcs <> st.lifted }

-- | Lower a single decoded CoreFn module to a backend IR `Program`, exporting its
-- | top-level functions (the single-module case of `lowerModules`).
lowerModule :: Module -> Either LowerError Program
lowerModule m = lowerModules [ m.name ] [ m ]
