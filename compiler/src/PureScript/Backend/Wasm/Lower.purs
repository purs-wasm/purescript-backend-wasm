-- | Lower the MIR (`PureScript.Backend.Wasm.MiddleEnd.IR`) to the backend IR
-- | (`PureScript.Backend.Wasm.Lower.IR`), under the uniform `eqref` convention
-- | (ADR 0004) and eval/apply (ADR 0003). What the lowering does:
-- |
-- |   * **Lambda lifting / closure conversion.** A lambda is lifted to a top-level
-- |     code function `$codeN(closure, arg)`; its free local variables are captured
-- |     into the closure's environment, and the lifted body reads them back as
-- |     `EnvField`s. The MIR groups a lambda's parameters into one list, but closures
-- |     are arity-1 (ADR 0003), so a multi-parameter lambda peels one parameter at a
-- |     time into a chain of single-argument closures. Lifted functions accumulate in
-- |     the lowering state and are appended to the program.
-- |
-- |   * **eval/apply application.** A known intrinsic / constructor / top-level
-- |     function applied to its exact arity is a direct primitive / allocation /
-- |     call. Otherwise — an unknown head (local closure or lambda), or a partial or
-- |     over-application of a known callable — it goes through `RApply` (`call_ref`),
-- |     eta-expanding the callable to a closure where needed.
-- |
-- |   * **Recursion.** Top-level `Rec` groups compile as ordinary module functions
-- |     calling one another by name. A single-binding recursive `let` recurs through
-- |     the code function's own closure parameter (no knot-tying). A
-- |     mutually-recursive `let` group becomes a `LetRec`: the closures are allocated
-- |     first and their sibling-referencing environment slots are then back-patched.
-- |
-- |   * **Pattern matching.** A `case` on constructors becomes a `Switch` on the ADT
-- |     tag; a `case` on literals (and the `case` an `if` desugars to) becomes a
-- |     `LitSwitch` of value-equality tests; a bare var/wildcard is a catch-all.
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
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), maybe)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Intrinsics (foreignIntrinsic)
import PureScript.Backend.Wasm.Lower.Collect (collectCtors, collectDictCtors, collectEnumCtors, collectFuncs, collectLabels, functionDecls, reachableFunctions)
import PureScript.Backend.Wasm.Lower.Env (Env)
import PureScript.Backend.Wasm.Lower.IR (Atom(..), AnfExpr(..), ForeignImport, FuncName(..), IRFunc, MarshalKind(..), Program, RecBind(..), Rep(..), Rhs(..), Slot(..), VarRef(..))
import PureScript.Backend.Wasm.Lower.Match (MatchOps, compileMatch)
import PureScript.Backend.Wasm.Lower.Monad (Lower, LowerError(..), fresh, throw)
import PureScript.Backend.Wasm.Lower.Monad (LowerError(..)) as ReExport
import PureScript.Backend.Wasm.Lower.Types (CtorInfo, ModuleInfo, ctorSig, peelAbs, qualifiedFuncName, qualifiedKey, qualifiedKeyOf)
import PureScript.Backend.Wasm.Lower.Unbox (assignProgramReps)
import PureScript.Backend.Wasm.MiddleEnd.FreeVars (freeVars)
import PureScript.Backend.Wasm.MiddleEnd.IR (Bind(..), Module)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Binder(..), Literal(..), Qualified(..))

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

-- | Re-wrap the residual parameters of a partially-peeled lambda (`[]` means the
-- | body is reached, with no lambda left).
reAbs :: Array String -> M.Expr -> M.Expr
reAbs params body = if Array.null params then body else M.Abs params body

-- | Eta-expand a callable reference (a function / intrinsic / constructor) of the
-- | given arity into `\x0 … x(n-1) -> callable(x0, …, x(n-1))`, so a non-saturated
-- | use can be lowered as a closure through the ordinary lambda lifting. The
-- | synthesised body is a *saturated* application, so this does not recurse back
-- | into the non-saturated case.
etaExpand :: M.Expr -> Int -> M.Expr
etaExpand callable arity = M.Abs params (M.App callable (map localVar params))
  where
  params = (\i -> "$x" <> show i) <$> Array.range 0 (arity - 1)
  localVar p = M.Var (Qualified Nothing p)

-- | Reduce an expression to a trivial `Atom`, threading any computation into
-- | `Let`s that wrap the continuation `k`.
-- | Whether `e` is (an application of) a host foreign whose result is `Effect _` — so a
-- | `Perform e` is run by the host call itself (the JS glue performs the thunk), and the
-- | operand lowers directly to `RCallForeign` without an extra unit application (ADR 0015).
isEffectForeignApp :: Env -> M.Expr -> Boolean
isEffectForeignApp env = case _ of
  M.App (M.Var q) _ -> isEff q
  M.Var q -> isEff q
  _ -> false
  where
  isEff q = case Object.lookup (qualifiedKeyOf q) env.foreignSigs of
    Just sig -> case sig.result of
      MEffect _ -> true
      _ -> false
    Nothing -> false

lowerArg :: Env -> M.Expr -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerArg env expr k = case expr of
  M.Lit (LitInt n) -> k (ALitInt n)
  M.Lit (LitNumber n) -> k (ALitNumber n)
  -- A `Char` shares `Int`'s representation; carry its code point.
  M.Lit (LitChar c) -> k (ALitInt (toCharCode c))
  M.Lit (LitBoolean b) -> k (ALitBoolean b)
  M.Lit (LitString s) -> k (ALitString s)
  M.Lit (LitArray elements) -> lowerArgs env elements \atoms -> bindRhs (RMkArray atoms) k
  -- A record literal (and so a type-class dictionary, after its newtype
  -- constructor is erased) becomes a label-id-keyed record (ADR 0001 / 0007).
  M.Lit (LitObject fields) -> lowerRecord env fields k
  -- `Prim.undefined` is the dummy argument applied to a superclass thunk; the
  -- thunk ignores it, so any boxed value will do.
  M.Var (Qualified (Just [ "Prim" ]) "undefined") -> k (ALitInt 0)
  M.Var (Qualified Nothing ident) -> resolveLocal env ident >>= k
  -- A bare reference to a known callable becomes a closure value (eta-expanded);
  -- a nullary constructor is built directly; a nullary top-level value (a CAF —
  -- e.g. an instance dictionary) is *called* to produce its value.
  -- A defined top-level binding (constructor or function/CAF) shadows the
  -- intrinsic table: instance names like `topInt` collide with foreign idents
  -- (`Data.Bounded.topInt`), but real foreigns have no decl body so they are
  -- never `ctors`/`knownFuncs` — so `foreignIntrinsic` is only the fallback.
  M.Var q@(Qualified (Just _) ident)
    | Just info <- Object.lookup (qualifiedKeyOf q) env.ctors ->
        if info.arity == 0 then
          if Object.member (qualifiedKeyOf q) env.enumCtors then bindRhs (RMkEnum info.tag) k
          else bindRhs (RMkData info.tag (ctorSig info) []) k
        else lowerArg env (etaExpand expr info.arity) k
    | Just arity <- Object.lookup (qualifiedKeyOf q) env.knownFuncs ->
        if arity == 0 then bindRhs (RCallKnown (qualifiedFuncName q) []) k
        else lowerArg env (etaExpand expr arity) k
    -- Unapplied `unsafeCoerce`: eta-expand to `\x -> unsafeCoerce x`, which reduces
    -- (via the erasure in `lowerApp`) to the identity closure `\x -> x`.
    | ident == "unsafeCoerce" -> lowerArg env (etaExpand expr 1) k
    -- A nullary foreign (e.g. `Data.Bounded.topInt`) is a constant value, not a
    -- callable, so it materializes directly rather than eta-expanding.
    | Just (Tuple intr arity) <- foreignIntrinsic ident ->
        if arity == 0 then bindRhs (RPrim intr []) k
        else lowerArg env (etaExpand expr arity) k
    -- a `foreign import` with no intrinsic: a wasm host import (ADR 0014). A nullary
    -- foreign is a constant value, materialized directly; otherwise eta-expand.
    | Just sig <- Object.lookup (qualifiedKeyOf q) env.foreignSigs ->
        if Array.null sig.params then bindRhs (RCallForeign sig []) k
        else lowerArg env (etaExpand expr (Array.length sig.params)) k
    | otherwise -> throw (UnsupportedExpr ("unapplied top-level reference: " <> qualifiedKeyOf q))
  M.Accessor label record -> lowerArg env record \recAtom -> do
    labelId <- internLabel env label
    bindRhs (RProjLabel recAtom labelId) k
  M.Update record copyFields updates -> lowerObjectUpdate env record copyFields updates k
  -- A `let` in argument position (e.g. purs's `let v = p in v { … }` for a record
  -- update): bind the groups, then reduce the body to an atom for `k`.
  M.Let binds body -> lowerCoreLetK env binds body \env' body' -> lowerArg env' body' k
  M.App head args -> lowerApp env { head, args } k
  -- run an `Effect` (ADR 0015). When the operand is a host effectful foreign (`log
  -- "x"`), the host call IS the perform — the JS glue runs the returned thunk (`()`),
  -- so lower the operand directly (→ `RCallForeign`) WITHOUT applying a unit. Any other
  -- surviving `Perform` is a thunk, run by applying it to a unit. (The pure-`Effect`
  -- collapse removes most `Perform`s in the simplifier.)
  M.Perform e
    | isEffectForeignApp env e -> lowerArg env e k
    | otherwise -> lowerApp env { head: e, args: [ M.Lit (LitInt 0) ] } k
  -- An (uncurried) lambda lowers to a closure; closures are arity-1, so a
  -- multi-parameter lambda peels one parameter and the rest stay an inner lambda.
  M.Abs params body -> case Array.uncons params of
    Nothing -> lowerArg env body k
    Just { head: param, tail } -> do
      { codeName, captures } <- liftLambda Nothing env param (reAbs tail body)
      bindRhs (RMkClosure codeName captures) k
  -- A `case` in argument position (e.g. `(if c then a else b) + d`): lower it so
  -- each branch's result flows into `k` — the continuation is duplicated into every
  -- branch (commuting conversion), the same trick the `M.Let` case above uses.
  M.Case scrutinees alternatives ->
    lowerCaseK env scrutinees alternatives \env' body -> lowerArg env' body k
  M.Constructor _ _ _ -> throw (UnsupportedExpr "a bare constructor declaration is not an expression")

-- | Lower a left-to-right list of operands to atoms, then continue.
lowerArgs :: Env -> Array M.Expr -> (Array Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerArgs env args k = case Array.uncons args of
  Nothing -> k []
  Just { head: e, tail } -> lowerArg env e \a -> lowerArgs env tail \as -> k (Array.cons a as)

-- | The interned `i32` id of a record/dictionary label.
internLabel :: Env -> String -> Lower Int
internLabel env label = case Object.lookup label env.labelIds of
  Just labelId -> pure labelId
  Nothing -> throw (UnsupportedExpr ("unknown record label: " <> label))

-- | Lower a record literal's fields (left-to-right) to `(labelId, atom)` pairs.
lowerFields :: Env -> Array (Tuple String M.Expr) -> (Array (Tuple Int Atom) -> Lower AnfExpr) -> Lower AnfExpr
lowerFields env fields k = case Array.uncons fields of
  Nothing -> k []
  Just { head: Tuple label e, tail } -> do
    labelId <- internLabel env label
    lowerArg env e \a -> lowerFields env tail \rest -> k (Array.cons (Tuple labelId a) rest)

-- | Lower a record literal to an `RMkRecord`, its `(labelId, value)` pairs sorted
-- | by id for a canonical layout (ADR 0001 / 0007).
lowerRecord :: Env -> Array (Tuple String M.Expr) -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerRecord env fields k =
  lowerFields env fields \pairs -> bindRhs (RMkRecord (Array.sortWith fst pairs)) k

-- | Lower a record update `record { l = v, … }` into a freshly-built record: the
-- | updated fields take their new values, and the untouched fields (`copyFields`,
-- | which lists exactly the other labels for a monomorphic record) are projected
-- | out of the original. A polymorphic update (`copyFields = Nothing`, an open
-- | row whose extra fields are unknown) needs a runtime copy and is not yet
-- | supported.
lowerObjectUpdate
  :: Env -> M.Expr -> Maybe (Array String) -> Array (Tuple String M.Expr) -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
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

-- | Lower an application. A known intrinsic / constructor / top-level function
-- | dispatches on how the argument count compares to its arity: saturated → a
-- | direct primitive / allocation / call; under-applied → a partial application
-- | (eta-expand to a closure, apply what we have); over-applied → call saturated,
-- | then apply the rest through the result. Any other head (a local closure value
-- | or a lambda) is an `RApply` chain.
lowerApp :: Env -> { head :: M.Expr, args :: Array M.Expr } -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerApp env { head, args } k = case head of
  -- A dictionary constructor is a newtype identity wrapping its record, so the
  -- application `C$Dict rec` erases to `rec` (ADR 0007).
  M.Var q@(Qualified (Just _) _)
    | Object.member (qualifiedKeyOf q) env.dictCtors -> case args of
        [ rec ] -> lowerArg env rec k
        _ -> throw (UnsupportedExpr "dictionary constructor must take exactly one record")
  -- See `lowerArg`: a defined binding (ctor/knownFunc) shadows the intrinsic
  -- table, so `foreignIntrinsic` is the fallback (foreigns have no decl body).
  M.Var q@(Qualified (Just _) ident)
    | Just info <- Object.lookup (qualifiedKeyOf q) env.ctors -> applyArity info.arity (RMkData info.tag (ctorSig info))
    | Just arity <- Object.lookup (qualifiedKeyOf q) env.knownFuncs -> applyArity arity (RCallKnown (qualifiedFuncName q))
    -- `unsafeCoerce` is representation-preserving (values are uniformly `eqref`), so
    -- it is erased: the argument *is* the result, and any further args apply to it.
    -- Checked after ctors/knownFuncs, so a user binding of the name is never shadowed.
    | ident == "unsafeCoerce", Just { head: arg, tail } <- Array.uncons args -> case tail of
        [] -> lowerArg env arg k
        _ -> lowerApp env { head: arg, args: tail } k
    | Just (Tuple intr arity) <- foreignIntrinsic ident -> applyArity arity (RPrim intr)
    -- an applied `foreign import` (no intrinsic): a wasm host import (ADR 0014)
    | Just sig <- Object.lookup (qualifiedKeyOf q) env.foreignSigs ->
        applyArity (Array.length sig.params) (RCallForeign sig)
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

-- | Lift a single-parameter lambda to a top-level code function and return its name
-- | plus the atoms to capture (the lambda's free locals, resolved in the current
-- | scope).
-- |
-- | `self` names a binding the lambda may recursively refer to (a `let rec`).
-- | Rather than capturing it — which would need knot-tying, since the closure is not
-- | yet built — the self reference resolves to the code function's own closure
-- | parameter (local 0), and is therefore excluded from the captures.
liftLambda :: Maybe String -> Env -> String -> M.Expr -> Lower { codeName :: FuncName, captures :: Array Atom }
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
lowerTail :: Env -> M.Expr -> Lower AnfExpr
lowerTail env = case _ of
  M.Case scrutinees alternatives -> lowerCaseK env scrutinees alternatives lowerTail
  M.Let binds body -> lowerCoreLet env binds body
  expr -> lowerArg env expr \atom -> pure (Return atom)

-- | A MIR `let`: bind each group, extending the local environment, then lower the
-- | body. `NonRec` groups bind directly. A single-binding `Rec` group is
-- | self-recursion — lifted with the recursive name bound to the closure's own
-- | parameter (see `liftLambda`). A multi-binding `Rec` group is mutual recursion,
-- | compiled to a `LetRec` whose closures are allocated first and then back-patched
-- | to refer to one another (knot-tying).
lowerCoreLet :: Env -> Array Bind -> M.Expr -> Lower AnfExpr
lowerCoreLet env binds body = lowerCoreLetK env binds body lowerTail

-- | The general form of `lowerCoreLet`: bind the groups, then hand the extended
-- | environment and body to `finish`. A `let` in tail position finishes with
-- | `lowerTail`; a `let` in argument position (e.g. the `let v = p in v { … }` purs
-- | emits for a record update) finishes by reducing the body to an `Atom`.
lowerCoreLetK :: Env -> Array Bind -> M.Expr -> (Env -> M.Expr -> Lower AnfExpr) -> Lower AnfExpr
lowerCoreLetK env binds body finish = case Array.uncons binds of
  Nothing -> finish env body
  Just { head: NonRec _ ident e, tail } ->
    lowerArg env e \atom ->
      lowerCoreLetK (env { locals = Object.insert ident atom env.locals }) tail body finish
  Just { head: Rec recBinds, tail } -> case recBinds of
    [ r ]
      | M.Abs params recBody <- r.expr
      , Just { head: param, tail: rest } <- Array.uncons params -> do
          { codeName, captures } <- liftLambda (Just r.ident) env param (reAbs rest recBody)
          bindRhs (RMkClosure codeName captures) \fAtom ->
            lowerCoreLetK (env { locals = Object.insert r.ident fAtom env.locals }) tail body finish
    _ -> do
      -- Mutual recursion: pre-allocate a slot per binding so each member's closure
      -- can refer to its siblings (as forward references resolved by the `LetRec`
      -- knot-tying), then lift each member's body.
      slots <- traverse (const fresh) recBinds
      let
        bound = Array.zip recBinds slots
        env' = env
          { locals = foldl (\m (Tuple rb s) -> Object.insert rb.ident (AVar (Local s)) m) env.locals bound }
      recBindsIR <- traverse (lowerRecBind env') bound
      rest <- lowerCoreLetK env' tail body finish
      pure (LetRec recBindsIR rest)

-- | Lower one member of a mutually-recursive `let` group, given its pre-allocated
-- | slot. Captures are resolved in an environment where every group member is
-- | already bound to its slot, so sibling references become forward references for
-- | the `LetRec` to patch.
lowerRecBind :: Env -> Tuple M.RecBinding Slot -> Lower RecBind
lowerRecBind env (Tuple rb slot) = case rb.expr of
  M.Abs params recBody
    | Just { head: param, tail: rest } <- Array.uncons params -> do
        { codeName, captures } <- liftLambda Nothing env param (reAbs rest recBody)
        pure (RecBind slot codeName captures)
  _ -> throw (UnsupportedExpr "a recursive let binding must be a function")

-- | Compile a `case` into a `Switch` on the scrutinee's tag, finishing each branch
-- | with `finish` (so the same compiler serves a tail-position `case` — `finish =
-- | lowerTail` — and an argument-position one, where `finish` feeds the branch
-- | result to the surrounding continuation).
-- |
-- | A single-alternative match on a **newtype** constructor (in particular the
-- | `\dict -> case dict of C$Dict v -> …` a type-class method accessor unwraps to)
-- | carries no runtime tag — the newtype is erased — so it lowers transparently via
-- | `Lower.Match`: the sub-binder is bound directly to the scrutinee.
lowerCaseK :: Env -> Array M.Expr -> Array M.Alt -> (Env -> M.Expr -> Lower AnfExpr) -> Lower AnfExpr
lowerCaseK env scrutinees alternatives finish = case scrutinees of
  -- A record pattern (`\{ x, y } -> …`) is a single destructuring alternative that
  -- always matches: bind each field's sub-binder to a label projection. (Record
  -- binders are the one shape `Lower.Match` does not handle.)
  [ scrutinee ]
    | Just { fields, body } <- recordPatternAlternative alternatives ->
        lowerArg env scrutinee \scrutAtom -> bindRecordFields env scrutAtom fields body finish
  -- Everything else — constructor / literal / variable / wildcard / newtype /
  -- nested patterns, one or many scrutinees — compiles to a decision tree
  -- (`Lower.Match`). Scrutinees are lowered to occurrence atoms first.
  scruts ->
    lowerArgs env scruts \atoms -> compileMatch (matchOps env finish) env atoms alternatives

-- | The `Lower`-specific operations the decision-tree compiler needs, so it can stay
-- | an independent leaf module (see `Lower.Match`). `finish` lowers each matched
-- | branch body (tail position, or feeding a continuation in arg position).
matchOps :: Env -> (Env -> M.Expr -> Lower AnfExpr) -> MatchOps Env
matchOps env finish =
  { lowerBody: finish
  , lowerCond: lowerArg
  , bindLocal: \name atom e -> e { locals = Object.insert name atom e.locals }
  , lookupCtor: \q -> requireCtor env (qualifiedKeyOf q)
  , isEnumCtor: \q -> Object.member (qualifiedKeyOf q) env.enumCtors
  }

-- | Recognise a single record-pattern alternative `{ l: b, … } -> body` (a
-- | `LiteralBinder` of an object literal). Records are products, so it is the only
-- | alternative and always matches.
recordPatternAlternative :: Array M.Alt -> Maybe { fields :: Array (Tuple String Binder), body :: M.Expr }
recordPatternAlternative = case _ of
  [ { binders: [ LiteralBinder _ (LitObject fields) ], result: Right body } ] -> Just { fields, body }
  _ -> Nothing

-- | Bind a record pattern's fields, each to a label projection out of the
-- | scrutinee, then lower the body.
bindRecordFields :: Env -> Atom -> Array (Tuple String Binder) -> M.Expr -> (Env -> M.Expr -> Lower AnfExpr) -> Lower AnfExpr
bindRecordFields env scrutAtom fields body finish = case Array.uncons fields of
  Nothing -> finish env body
  Just { head: Tuple label subBinder, tail } -> case subBinder of
    NullBinder _ -> bindRecordFields env scrutAtom tail body finish
    VarBinder _ name -> do
      labelId <- internLabel env label
      slot <- fresh
      let env' = env { locals = Object.insert name (AVar (Local slot)) env.locals }
      rest <- bindRecordFields env' scrutAtom tail body finish
      pure (Let slot Boxed (RProjLabel scrutAtom labelId) rest)
    _ -> throw (UnsupportedBinder "record pattern field: only var / wildcard sub-binders")

requireCtor :: Env -> String -> Lower CtorInfo
requireCtor env ctorName = case Object.lookup ctorName env.ctors of
  Just info -> pure info
  Nothing -> throw (UnknownConstructor ctorName)

-- | Qualify a top-level identifier into a globally-unique wasm function name.
funcName :: Array String -> String -> FuncName
funcName moduleName ident = FuncName (qualifiedKey moduleName ident)

-- | Lower one top-level function definition to an `IRFunc` (eqref convention), given
-- | its module and whether that module is a link root (only roots' names are
-- | exported; everything else is internal and so DCE-eligible — ADR 0009).
lowerTopFunc :: ModuleInfo -> Array String -> Boolean -> Tuple String M.Expr -> Lower IRFunc
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
      , enumCtors: info.enumCtors
      , labelIds: info.labelIds
      , foreignSigs: info.foreignSigs
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

-- | Link and lower several MIR modules into one backend IR `Program` (one wasm; ADR
-- | 0009). Symbol tables are built across **all** modules and keyed by qualified
-- | name, so cross-module references resolve. Only functions **reachable** from the
-- | `roots` modules are lowered (so a `Prelude` module's unused — and possibly
-- | unsupported — instances are never visited); the roots' own functions are
-- | exported, the rest are internal.
lowerModules :: Boolean -> Object (Array Rep) -> Object ForeignImport -> Array (Array String) -> Array Module -> Either LowerError Program
lowerModules optimize fieldReps foreignSigs roots modules = do
  let
    dictCtors = collectDictCtors modules
    info =
      { knownFuncs: collectFuncs dictCtors modules
      , ctors: collectCtors fieldReps modules
      , dictCtors
      , enumCtors: collectEnumCtors modules
      , labelIds: collectLabels modules
      , foreignSigs
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
  let allFuncs = funcs <> st.lifted
  -- the marshal signature of each exported function (looked up by its qualified name
  -- in the externs-derived `foreignSigs`, which covers every top-level value), so the
  -- export wrapper and JS loader can marshal non-`i32` exports (ADR 0014)
  let
    exportSigs = Object.fromFoldable do
      fn <- allFuncs
      ident <- maybe [] pure fn.export
      let FuncName key = fn.name
      sig <- maybe [] pure (Object.lookup key foreignSigs)
      pure (Tuple ident sig)
  -- representation analysis (ADR 0013): unbox `Int`/`Number` where it avoids boxing
  pure
    { funcs: if optimize then assignProgramReps allFuncs else allFuncs
    , labels: Object.toUnfoldable info.labelIds
    , exportSigs
    }

-- | Lower a single MIR module to a backend IR `Program`, exporting its top-level
-- | functions (the single-module case of `lowerModules`).
lowerModule :: Boolean -> Module -> Either LowerError Program
lowerModule optimize m = lowerModules optimize Object.empty Object.empty [ m.name ] [ m ]
