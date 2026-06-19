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
  , lowerProgramFragments
  , lowerModuleWithInterfaces
  , ModuleFragment
  , LoweredProgram
  , DepInterface
  , LoweredTarget
  , module ReExport
  ) where

import Prelude

import Control.Monad.State (gets, modify_, runStateT)
import Data.Array as Array
import Data.Char (toCharCode)
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Control.Alt ((<|>))
import Data.Maybe (Maybe(..), isJust, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (Pattern(..), joinWith)
import Data.String as Str
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Intrinsics (Intrinsic(MkEffectFn), qualifiedIntrinsic, foreignIntrinsic)
import PureScript.Backend.Wasm.Lower.Collect (collectCtors, collectDictCtors, collectEnumCtors, collectFuncs, collectLabels, labelCollisions, functionDecls, qualifiedRefs, reachableFunctions)
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

-- | A best-effort `ForeignImport` for a declared foreign whose real signature could not
-- | be reconstructed (ADR 0016): every parameter and the result are `MOpaque` (passed as
-- | bare `eqref`, no marshalling). `arity` is supplied by the call site. A `Nothing`
-- | module cannot occur (the name came from a module's `foreignNames`); it degrades to an
-- | empty module name rather than partially.
opaqueForeign :: Qualified String -> Int -> ForeignImport
opaqueForeign (Qualified mModule base) arity =
  { moduleName: maybe "" (joinWith ".") mModule
  , base
  , params: Array.replicate arity MOpaque
  , result: MOpaque
  }

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
  isEff q@(Qualified _ ident)
    | isJust (qualifiedIntrinsic (qualifiedKeyOf q)) = false
    | isJust (foreignIntrinsic ident) = false
    -- A user-defined top-level function has a decl body, so it is in `knownFuncs`; it is
    -- NOT a host foreign. It is performed via the unit-application path (its arity includes
    -- the perform-unit, ADR 0018), even though source reconstruction (ADR 0016) also lists
    -- it in `foreignSigs` with an `MEffect` result. Without this exclusion, a performed
    -- partial application of such a function (`perform (bad "x")`) is misrouted to the
    -- host-foreign path and lowered as a bare producer value — a partial closure that is
    -- built but never applied to the unit, silently dropping the effect.
    | Object.member (qualifiedKeyOf q) env.knownFuncs = false
    | otherwise = case Object.lookup (qualifiedKeyOf q) env.foreignSigs of
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
    -- callable, so it materializes directly rather than eta-expanding. The qualified
    -- `Effect.Ref` ops (ADR 0017) take precedence over the bare-ident `Prelude` table.
    | Just (Tuple intr arity) <- qualifiedIntrinsic (qualifiedKeyOf q) <|> foreignIntrinsic ident ->
        if arity == 0 then bindRhs (RPrim intr []) k
        else lowerArg env (etaExpand expr arity) k
    -- a `foreign import` with no intrinsic: a wasm host import (ADR 0014). A nullary
    -- foreign is a constant value, materialized directly; otherwise eta-expand.
    | Just sig <- Object.lookup (qualifiedKeyOf q) env.foreignSigs ->
        if Array.null sig.params then bindRhs (RCallForeign sig []) k
        else lowerArg env (etaExpand expr (Array.length sig.params)) k
    -- a declared foreign with no reconstructed signature (ADR 0016), used unapplied: with
    -- no arity to recover, treat it as a nullary opaque constant rather than fail the build
    | Set.member (qualifiedKeyOf q) env.foreignNames ->
        bindRhs (RCallForeign (opaqueForeign q 0) []) k
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
    -- A performed application of a non-foreign producer: append the perform unit to the
    -- producer's OWN argument list, so the whole thing lowers as one application. A function
    -- whose arity includes the perform-unit (ADR 0018) then saturates to a *direct*
    -- `RCallKnown` (the same direct shape a foreign perform takes), and `applyArity` still
    -- handles the over-applied case (call saturated, apply the unit to the result). The old
    -- `head: e` form passed the application itself as the head, hit the closure/`RApply`
    -- fallback, built the producer as a partial closure, and dropped the apply that feeds
    -- the unit — silently discarding the effect.
    | M.App h as <- e -> lowerApp env { head: h, args: as <> [ M.Lit (LitInt 0) ] } k
    | otherwise -> lowerApp env { head: e, args: [ M.Lit (LitInt 0) ] } k
  M.Abs params body -> case Array.uncons params of
    Nothing -> lowerArg env body k
    Just { head: param, tail } -> do
      { codeName, captures } <- liftLambda Nothing env param (reAbs tail body)
      bindRhs (RMkClosure codeName captures) k
  -- A `case` in argument position (e.g. `(if c then a else b) + d`): lower it to a
  -- **join point** (ADR 0022). Each branch finishes by `Return`-ing its value (so the
  -- compiled switch is a value-producing block), that value is bound once to a fresh
  -- join slot, and the continuation `k` runs a single time on the slot. Duplicating
  -- `k` into every branch instead (a naive commuting conversion) is `2^depth` on
  -- nested argument-position cases — the `genericShow`-on-recursive-type blowup.
  M.Case scrutinees alternatives -> do
    slot <- fresh
    producer <- lowerCaseK env scrutinees alternatives \env' body -> lowerArg env' body (pure <<< Return)
    rest <- k (AVar (Local slot))
    pure (LetJoin slot Boxed producer rest)
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
-- | row whose extra fields are unknown) is a chain of runtime copy-and-set over the
-- | original record — one `RRecSet` per updated field, which preserves the unknown
-- | tail fields (ADR 0023).
lowerObjectUpdate
  :: Env -> M.Expr -> Maybe (Array String) -> Array (Tuple String M.Expr) -> (Atom -> Lower AnfExpr) -> Lower AnfExpr
lowerObjectUpdate env record copyFields updates k = case copyFields of
  -- open row: the untouched fields are not known, so rebuild by copying the whole
  -- record and overwriting each named field in turn (ADR 0023)
  Nothing ->
    lowerArg env record \recAtom -> chainSet recAtom updates
  Just untouched ->
    lowerArg env record \recAtom ->
      lowerCopied recAtom untouched \copied ->
        lowerUpdated updates \updated ->
          bindRhs (RMkRecord (Array.sortWith fst (copied <> updated))) k
  where
  -- the open-row path: fold the updates left-to-right, each `recSet` copying the
  -- running record and replacing one field by its compile-time-interned label id
  chainSet recAtom ups = case Array.uncons ups of
    Nothing -> k recAtom
    Just { head: Tuple label expr, tail } -> do
      labelId <- internLabel env label
      lowerArg env expr \valAtom ->
        bindRhs (RRecSet recAtom labelId valAtom) \recAtom' -> chainSet recAtom' tail
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
    -- the qualified `Effect.Ref` ops (ADR 0017) take precedence over the bare-ident table
    | Just (Tuple intr arity) <- qualifiedIntrinsic (qualifiedKeyOf q) <|> foreignIntrinsic ident -> applyArity arity (RPrim intr)
    -- an applied `foreign import` (no intrinsic): a wasm host import (ADR 0014)
    | Just sig <- Object.lookup (qualifiedKeyOf q) env.foreignSigs ->
        applyArity (Array.length sig.params) (RCallForeign sig)
    -- a declared foreign whose signature could not be reconstructed (ADR 0016): fall back
    -- to an all-opaque host import with the call-site arity rather than failing the build
    | Set.member (qualifiedKeyOf q) env.foreignNames ->
        let
          arity = Array.length args
        in
          applyArity arity (RCallForeign (opaqueForeign q arity))
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
      | M.Abs params recBody <- recBindFunctionForm r.expr
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
lowerRecBind env (Tuple rb slot) = case recBindFunctionForm rb.expr of
  M.Abs params recBody
    | Just { head: param, tail: rest } <- Array.uncons params -> do
        { codeName, captures } <- liftLambda Nothing env param (reAbs rest recBody)
        pure (RecBind slot codeName captures)
  -- A point-free recursive *function* (e.g. purescript-run's `loop = resume f pure`): not a
  -- syntactic lambda, but a known callable whose (partial or saturated-returning-a-function)
  -- application is in fact a function. Eta-expand it (`\x -> e x`, sound by the eta law) and lower
  -- through the normal Abs path above. A saturated *constructor* application is genuine recursive
  -- data, not a function, so `recBindEtaArity` returns `Nothing` and it falls through to the error
  -- (a cyclic top-level value is instead handled by CAF globalization — ADR 0006, `FibAnd`).
  peeled
    | Just etaN <- recBindEtaArity env peeled ->
        lowerRecBind env (Tuple (rb { expr = etaExpand peeled etaN }) slot)
  _ -> throw (UnsupportedExpr ("a recursive let binding must be a function: " <> rb.ident))

-- | Normalise a recursive `let` binding's defining expression toward the syntactic lambda it
-- | denotes, so the `LetRec` machinery recognises it as a function:
-- |
-- |   * peel `Data.Function.Uncurried.mkFnN` / `Effect.Uncurried.mkEffectFnN`, which are the
-- |     identity (the uncurried value *is* the curried `$Clo`, ADR 0018; an *applied* `mkFnN`
-- |     lowers to the `RPrim MkEffectFn` no-op) — e.g. `Data.Map.Internal`'s `mkFn2`-wrapped folds;
-- |   * float a `let` whose body is a function inward — `let H in \xs -> b` becomes
-- |     `\xs -> let H in b`. Sound for this strict, pure IR: `H` was bound outside the lambda so
-- |     it cannot capture `xs`, and re-evaluating its (pure) bindings per call only forgoes
-- |     sharing — e.g. the `let goLit … in \v -> case v of …` a `where`-helper-rich recursive
-- |     worker compiles to.
-- |
-- | The middle-end normalises both, so only the `--no-opt` path reaches lowering with one intact.
recBindFunctionForm :: M.Expr -> M.Expr
recBindFunctionForm = case _ of
  M.App (M.Var q) [ inner ]
    | Just (Tuple MkEffectFn _) <- qualifiedIntrinsic (qualifiedKeyOf q) -> recBindFunctionForm inner
  M.Let binds body
    | M.Abs params inner <- recBindFunctionForm body -> M.Abs params (M.Let binds inner)
  other -> other

-- | The residual arity of a non-lambda binding RHS: a known callable (function / constructor /
-- | intrinsic / foreign) applied to fewer arguments than its arity still denotes a function, of
-- | the leftover arity. `Nothing` when the head's arity is unknown — then we cannot prove it is a
-- | function, so the caller keeps the conservative "must be a function" error.
-- | The number of parameters to eta-expand a non-lambda recursive binding by, turning it into a
-- | syntactic function — or `Nothing` if the binding denotes a value rather than a function.
-- |
-- | A *partial* application is always a function: eta by its residual arity (`Cons 1`, `resume f`).
-- | A *saturated* (or over-) application splits on the head. A constructor builds data, so a
-- | saturated `Ctor …` is a genuine recursive *value* — a cyclic *local* data binding would diverge
-- | under strict evaluation, so the only real case is a top-level CAF (handled by globalization,
-- | ADR 0006); reject it here. A function's result is itself a value that, for a non-diverging local
-- | recursive `let`, must be a function (e.g. `loop = resume f pure`, whose result type is a
-- | function), so eta-expand by one to apply it — `lowerApp`'s over-application path does the rest.
recBindEtaArity :: Env -> M.Expr -> Maybe Int
recBindEtaArity env = case _ of
  M.Var q -> etaArity q 0
  M.App (M.Var q) args -> etaArity q (Array.length args)
  _ -> Nothing
  where
  etaArity q@(Qualified (Just _) ident) nargs
    | Just info <- Object.lookup (qualifiedKeyOf q) env.ctors =
        let residual = info.arity - nargs in if residual >= 1 then Just residual else Nothing
    | Just arity <- funcArity q ident = Just (max 1 (arity - nargs))
  etaArity _ _ = Nothing
  funcArity q ident =
    Object.lookup (qualifiedKeyOf q) env.knownFuncs
      <|> (snd <$> (qualifiedIntrinsic (qualifiedKeyOf q) <|> foreignIntrinsic ident))
      <|> ((Array.length <<< _.params) <$> Object.lookup (qualifiedKeyOf q) env.foreignSigs)

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
  -- A *simple* record pattern (`\{ x, y } -> …`, all fields bound to a var/wildcard) is a
  -- single destructuring alternative that always matches: bind each field directly to a
  -- label projection, skipping the decision tree. Record patterns with nested field
  -- sub-binders (`{ x: Just y }`) fall through to `Lower.Match` below.
  [ scrutinee ]
    | Just { fields, body } <- recordPatternAlternative alternatives ->
        lowerArg env scrutinee \scrutAtom -> bindRecordFields env scrutAtom fields body finish
  -- Everything else — constructor / literal / variable / wildcard / newtype / nested
  -- patterns (including record patterns with nested field sub-binders), one or many
  -- scrutinees — compiles to a decision tree (`Lower.Match`). Scrutinees are lowered to
  -- occurrence atoms first.
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
  , internLabel: internLabel env
  }

-- | Recognise a single record-pattern alternative `{ l: b, … } -> body` (a
-- | `LiteralBinder` of an object literal) whose every field sub-binder is irrefutable
-- | and trivial (a var or wildcard). Records are products, so such an alternative is the
-- | only one and always matches — the fast `bindRecordFields` path projects each field
-- | directly. A field with a *nested* sub-binder (a constructor / literal / inner record,
-- | e.g. `{ x: Just y }`) is left to the decision-tree compiler (`Lower.Match`, which
-- | splices field sub-binders via `specializeRecord`) by returning `Nothing` here.
recordPatternAlternative :: Array M.Alt -> Maybe { fields :: Array (Tuple String Binder), body :: M.Expr }
recordPatternAlternative = case _ of
  [ { binders: [ LiteralBinder _ (LitObject fields) ], result: Right body } ]
    | Array.all (isTrivialField <<< snd) fields -> Just { fields, body }
  _ -> Nothing
  where
  isTrivialField = case _ of
    NullBinder _ -> true
    VarBinder _ _ -> true
    _ -> false

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
      , foreignNames: info.foreignNames
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
-- | `perModuleRep` (ADR 0037 ③) restricts the representation analysis to a per-module
-- | boundary: a function reached across a module boundary is pinned to the boxed ABI, so
-- | only intra-module signatures are unboxed. It does not change *what* is lowered (the
-- | build is still whole-program here) — it constrains the rep solver so the result matches
-- | what a separately-compiled per-module build would produce, for A/B measurement before
-- | the codegen split. `false` is the original whole-program rep analysis.
lowerModules :: Boolean -> Boolean -> Object (Array Rep) -> Object ForeignImport -> Set String -> Array (Array String) -> Array Module -> Either LowerError Program
lowerModules perModuleRep optimize fieldReps foreignSigs foreignNames roots modules = do
  let
    dictCtors = collectDictCtors modules
    labelIds = collectLabels modules
    info =
      { knownFuncs: collectFuncs dictCtors modules
      , ctors: collectCtors fieldReps modules
      , dictCtors
      , enumCtors: collectEnumCtors modules
      , labelIds
      , foreignSigs
      , foreignNames
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
    -- functions reached by a reference from a *different* module: in a per-module build
    -- each is imported/exported with a fixed boxed ABI, so the rep solver must pin them
    -- (ADR 0037 ③). Computed from the MIR refs; `Set.empty` keeps the whole-program rep.
    keyModule = Object.fromFoldable (entries <#> \e -> Tuple e.key e.moduleName)
    crossModulePins =
      if perModuleRep then
        Set.fromFoldable
          ( toLower >>= \e ->
              Array.mapMaybe
                ( \ref -> case Object.lookup ref keyModule of
                    Just refMod | refMod /= e.moduleName -> Just (FuncName ref)
                    _ -> Nothing
                )
                (qualifiedRefs e.expr)
          )
      else Set.empty
  -- A hashed label id (ADR 0037 ④) is a pure function of the name, so two distinct
  -- labels can in principle collide — which would merge two record fields. Reject it
  -- here rather than emit a corrupt record. Cheap: it only groups the computed ids.
  case Array.head (labelCollisions labelIds) of
    Just clash -> Left (LabelHashCollision clash)
    Nothing -> pure unit
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
    { funcs: if optimize then assignProgramReps crossModulePins allFuncs else allFuncs
    , labels: Object.toUnfoldable info.labelIds
    , exportSigs
    }

-- | Lower a single MIR module to a backend IR `Program`, exporting its top-level
-- | functions (the single-module case of `lowerModules`). A single module has no
-- | cross-module references, so `perModuleRep` is irrelevant here (passed `false`).
lowerModule :: Boolean -> Module -> Either LowerError Program
lowerModule optimize m = lowerModules false optimize Object.empty Object.empty Set.empty [ m.name ] [ m ]

-- | One module's lowered functions plus its export signatures, kept separate (NOT recombined) so
-- | the per-module codegen (ADR 0037 Phase 2, Slice 2.2) can emit it to its own wasm.
type ModuleFragment =
  { moduleName :: Array String
  , funcs :: Array IRFunc
  , exportSigs :: Object ForeignImport
  }

-- | The whole program lowered per-module: the fragments, plus the link-time facts a per-module
-- | codegen needs without re-deriving them — the shared label table, the home module of each
-- | function key (for the module field of a cross-module import), and the set of function keys
-- | referenced from another module (the export set + boxed boundary). Bodies are never recombined.
type LoweredProgram =
  { fragments :: Array ModuleFragment
  , labels :: Array (Tuple String Int)
  , keyHomeModule :: Object String
  , crossModuleRefs :: Set String
  }

-- | Lower every module to its own `ModuleFragment` (the per-module-codegen input). Same per-module
-- | lowering as `lowerModulesPerModule` (fresh code-fn counter + boxed-boundary `assignProgramReps`
-- | per module), but the fragments are returned separately, together with the cross-module facts
-- | the linker/codegen needs. The whole-program tables (ctors / labels / refs) are derived over the
-- | in-memory modules here; caching them as `.pmi` interfaces is Phase 3.
lowerProgramFragments
  :: Object (Array Rep)
  -> Object ForeignImport
  -> Set String
  -> Array (Array String)
  -> Array Module
  -> Either LowerError LoweredProgram
lowerProgramFragments fieldReps foreignSigs foreignNames roots modules = do
  let
    dictCtors = collectDictCtors modules
    labelIds = collectLabels modules
    info =
      { knownFuncs: collectFuncs dictCtors modules
      , ctors: collectCtors fieldReps modules
      , dictCtors
      , enumCtors: collectEnumCtors modules
      , labelIds
      , foreignSigs
      , foreignNames
      }
    entries = modules >>= \m ->
      functionDecls dictCtors m <#> \(Tuple ident expr) ->
        { key: qualifiedKey m.name ident, moduleName: m.name, expr }
    functions = Object.fromFoldable (entries <#> \e -> Tuple e.key e.expr)
    rootKeys = Array.mapMaybe (\e -> if Array.elem e.moduleName roots then Just e.key else Nothing) entries
    reachable = reachableFunctions functions rootKeys
    keyModule = Object.fromFoldable (entries <#> \e -> Tuple e.key e.moduleName)
    -- functions referenced from a *different* module → fixed to the boxed ABI (③), so every
    -- module agrees on a cross-module callee's representation without seeing the others' bodies.
    crossModuleRefs = Set.fromFoldable
      ( entries >>= \e ->
          Array.mapMaybe
            ( \ref -> case Object.lookup ref keyModule of
                Just refMod | refMod /= e.moduleName -> Just ref
                _ -> Nothing
            )
            (qualifiedRefs e.expr)
      )
  case Array.head (labelCollisions labelIds) of
    Just clash -> Left (LabelHashCollision clash)
    Nothing -> pure unit
  fragments <- traverse (lowerOneFragment info reachable crossModuleRefs roots foreignSigs) modules
  pure
    { fragments
    , labels: Object.toUnfoldable labelIds
    , keyHomeModule: map (joinWith ".") keyModule
    , crossModuleRefs
    }

-- | Lower one module into a `ModuleFragment`: its rep-assigned functions (`lowerOneModule`) plus
-- | the export signatures of its exported (`fn.export`) functions, looked up in `foreignSigs`.
lowerOneFragment
  :: ModuleInfo
  -> Object Unit
  -> Set String
  -> Array (Array String)
  -> Object ForeignImport
  -> Module
  -> Either LowerError ModuleFragment
lowerOneFragment info reachable crossModuleRefs roots foreignSigs m = do
  funcs <- lowerOneModule info reachable crossModuleRefs roots m
  let
    exportSigs = Object.fromFoldable do
      fn <- funcs
      ident <- maybe [] pure fn.export
      let FuncName key = fn.name
      sig <- maybe [] pure (Object.lookup key foreignSigs)
      pure (Tuple ident sig)
  pure { moduleName: m.name, funcs, exportSigs }

-- | Lower one module's reachable functions to rep-assigned `IRFunc`s: a fresh lowering state (so
-- | code functions are numbered per module — see `lowerModulesPerModule`), then a per-module
-- | `assignProgramReps` pinning this module's cross-module-visible functions to the boxed
-- | boundary. A cross-module *callee* is absent from this module's signature map, so it already
-- | defaults to boxed; the pin covers this module's own functions that *other* modules call.
lowerOneModule
  :: ModuleInfo
  -> Object Unit
  -> Set String
  -> Array (Array String)
  -> Module
  -> Either LowerError (Array IRFunc)
lowerOneModule info reachable crossModuleRefs roots m = do
  let
    isRoot = Array.elem m.name roots
    toLower = Array.filter (\(Tuple ident _) -> Object.member (qualifiedKey m.name ident) reachable)
      (functionDecls info.dictCtors m)
  Tuple funcs st <- runStateT
    (traverse (lowerTopFunc info m.name isRoot) toLower)
    { slot: 0, lifted: [], nextCode: 0 }
  let mFuncs = funcs <> st.lifted
  let
    pins = Set.fromFoldable
      ( Array.mapMaybe
          (\fn -> let FuncName k = fn.name in if Set.member k crossModuleRefs then Just fn.name else Nothing)
          mFuncs
      )
  pure (assignProgramReps pins mFuncs)

-- | A dependency's lowering interface (ADR 0038 Phase B M2b): the symbol tables a dependent merges
-- | into its `ModuleInfo` to resolve cross-module callees — loaded from the dep's `.pmi`, never its
-- | `.pmo`. Keys are module-qualified, so merging is a left-biased `Object.union`. (No `labels`: a
-- | dependent hashes its OWN labels; a dep's labels matter only to the orchestrator's pre-merge
-- | collision check.)
type DepInterface =
  { funcs :: Object Int
  , ctors :: Object CtorInfo
  , dictCtors :: Object Unit
  , enumCtors :: Object Unit
  , foreignSigs :: Object ForeignImport
  , foreignNames :: Array String
  }

-- | One target module lowered against its dependency interfaces, with the link facts a per-module
-- | codegen needs. `crossModuleRefs` over-exports ALL the target's own functions (a single-module
-- | worker cannot see which a dependent calls; the orchestrator internalises + DCEs the unused after
-- | merge), so a dependency-having module's wasm is BEHAVIOUR-identical to the whole-program oracle,
-- | not byte-identical.
type LoweredTarget =
  { fragment :: ModuleFragment
  , labels :: Array (Tuple String Int)
  , keyHomeModule :: Object String
  , crossModuleRefs :: Set String
  }

-- | Lower ONE target module against its dependencies' INTERFACES (ADR 0038 Phase B M2b) — no access
-- | to any dependency body. `info` is the target's own `collect*` tables merged with the dep
-- | interfaces (qualified keys ⇒ a plain `Object.union`); only the target's reachable functions are
-- | lowered. A cross-module callee resolves via `info` (`knownFuncs`/`ctors`/`foreignSigs`); a callee
-- | absent from every table is a hard `unknown callee` error (so the dep `.pmi` must be complete).
-- | No whole-program label-collision check (that is the orchestrator's pre-merge job, Phase C); only
-- | a local self-check.
lowerModuleWithInterfaces
  :: Object (Array Rep)
  -> Object ForeignImport
  -> Set String
  -> Array DepInterface
  -> Module
  -> Either LowerError LoweredTarget
lowerModuleWithInterfaces fieldReps foreignSigs foreignNames deps target = do
  let
    tDict = collectDictCtors [ target ]
    tLabels = collectLabels [ target ]
    info =
      { knownFuncs: foldl (\acc d -> Object.union acc d.funcs) (collectFuncs tDict [ target ]) deps
      , ctors: foldl (\acc d -> Object.union acc d.ctors) (collectCtors fieldReps [ target ]) deps
      , dictCtors: foldl (\acc d -> Object.union acc d.dictCtors) tDict deps
      , enumCtors: foldl (\acc d -> Object.union acc d.enumCtors) (collectEnumCtors [ target ]) deps
      , labelIds: tLabels
      , foreignSigs: foldl (\acc d -> Object.union acc d.foreignSigs) foreignSigs deps
      , foreignNames: foldl (\acc d -> Set.union acc (Set.fromFoldable d.foreignNames)) foreignNames deps
      }
    decls = functionDecls tDict target
    rootKeys = map (\(Tuple ident _) -> qualifiedKey target.name ident) decls
    functions = Object.fromFoldable (decls <#> \(Tuple ident e) -> Tuple (qualifiedKey target.name ident) e)
    reachable = reachableFunctions functions rootKeys
    -- over-export every own function (the worker cannot see its dependents); merge-time DCE prunes.
    crossModuleRefs = Set.fromFoldable rootKeys
    dotted = joinWith "." target.name
    homeOf k = maybe k (\i -> Str.take i k) (Str.lastIndexOf (Pattern ".") k)
    keyHomeModule = Object.fromFoldable
      ( map (\k -> Tuple k dotted) rootKeys
          <> (deps >>= \d -> map (\k -> Tuple k (homeOf k)) (Object.keys d.funcs))
      )
  case Array.head (labelCollisions tLabels) of
    Just clash -> Left (LabelHashCollision clash)
    Nothing -> pure unit
  fragment <- lowerOneFragment info reachable crossModuleRefs [ target.name ] info.foreignSigs target
  pure { fragment, labels: Object.toUnfoldable tLabels, keyHomeModule, crossModuleRefs }
