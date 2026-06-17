-- | The NbE exponential regression guard (bug A, ADR 0035 §8).
-- |
-- | It drives `Semantics.normalize` directly against a synthetic **diamond inline DAG**: an
-- | inline set `b0 … bd` where each `bᵢ = f b₍ᵢ₋₁₎ b₍ᵢ₋₁₎` references the previous binding twice.
-- | Normalizing `bd` re-evaluates the shared leaf `b0` once per path = Θ(2ᵈ) on the *unfixed*
-- | reducer (M1 in eval, M2 in quote), so the result size **doubles every depth** and the wall
-- | clock explodes around d≈22-25. After the ADR-0035 sharing fix (Layer A eval memo + Layer B
-- | quote CSE) the result stays **O(d)** (≈ 4d) and the loop runs instantly — verified without
-- | building the whole compiler to wasm.
-- |
-- | `spec` is the routine `test:unit` guard: the linear-bound diamond check above, plus a guard for
-- | the **Layer C size cap** (`DictElim.simplifyModule` falls back to the un-inlined form when a
-- | declaration inlines genuine, unshareable bulk — the `genericShow`-into-`show` blow-up that hung
-- | self-compilation). `main` sweeps deeper diamond depths for manual inspection:
-- |
-- |     spago test -p compiler -m Test.NbeStress
module Test.NbeStress where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (error) as Console
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Analysis (exprSize)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim (normalFormSizeCap, simplifyModule)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Semantics (normalize)
import PureScript.CoreFn (Literal(..), Qualified(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

maxDepth :: Int
maxDepth = 20

-- A reference to inline binding `bᵢ` (module `M`), keyed so `qkey` = `"M.bᵢ"`.
ref :: Int -> M.Expr
ref i = M.Var (Qualified (Just [ "M" ]) ("b" <> show i))

-- An opaque (non-inline) head, so the application stays a neutral whose two operands are each
-- re-evaluated — the binary fan-out that makes the DAG a diamond rather than a chain.
opaque :: M.Expr
opaque = M.Var (Qualified (Just [ "Ext" ]) "f")

-- The inline set for depth `d`: `b0` is a neutral leaf; `bᵢ = f b₍ᵢ₋₁₎ b₍ᵢ₋₁₎`.
diamondInline :: Int -> Map String M.Expr
diamondInline d =
  Map.fromFoldable
    ( Array.cons (Tuple "M.b0" (M.Var (Qualified (Just [ "Ext" ]) "leaf")))
        (map (\i -> Tuple ("M.b" <> show i) (M.App opaque [ ref (i - 1), ref (i - 1) ])) (Array.range 1 d))
    )

ctxFor :: Int -> { newtypeCtors :: Set.Set String, dataCtors :: Set.Set String, inline :: Map String M.Expr, instanceFields :: Map String (Array (Tuple String M.Expr)), effectfulForeigns :: Set.Set String, impureBindings :: Set.Set String, memEffBindings :: Set.Set String }
ctxFor d =
  { newtypeCtors: Set.empty
  , dataCtors: Set.empty
  , inline: diamondInline d
  , instanceFields: Map.empty
  , effectfulForeigns: Set.empty
  , impureBindings: Set.empty
  , memEffBindings: Set.empty
  }

-- An **un-shareable** term of `n` distinct-position leaves (a flat array of int literals): unlike a
-- diamond, `quote` cannot CSE it, so its normal form really is ~`n` nodes. Inlining a binding bound
-- to this produces genuine bulk with no reduction — the `genericShow`-into-`show` pathology in
-- miniature — which is exactly what the size cap must catch.
flatBig :: Int -> M.Expr
flatBig n = M.Lit (LitArray (Array.replicate n (M.Lit (LitInt 0))))

-- a one-declaration module `U.user = <body>`, the unit `simplifyModule` reduces.
userModule :: M.Expr -> M.Module
userModule body = { name: [ "U" ], decls: [ M.NonRec Nothing "user" body ] }

-- the reduced size of `U.user` after `simplifyModule`.
userSize :: M.Module -> Int
userSize m = case Array.head m.decls of
  Just (M.NonRec _ _ e) -> exprSize e
  _ -> -1

spec :: Spec Unit
spec = do
  -- | Routine guard (ADR 0035 §8): a depth-20 diamond normalizes to a *linear*-size term. On the
  -- | pre-sharing reducer this is 2^20 ≈ a million nodes (seconds of work + a huge tree); the
  -- | Layer A memo + Layer B quote CSE keep it ≈ 4·20 + 3 = 83. The generous `< 1000` bound passes
  -- | instantly when sharing holds and fails (or times out) the moment the exponential returns.
  describe "Semantics.normalize — NbE exponential guard (ADR 0035)" do
    it "normalizes a depth-20 diamond inline DAG to linear size, not O(2^d)" do
      let d = 20
      (exprSize (normalize (ctxFor d) (ref d)) < 1000) `shouldEqual` true

  -- | The Layer C size cap: inlining that blows the normal form past `normalFormSizeCap` falls back
  -- | to the un-inlined form (the binding stays a call). This is what bounds NbE when a declaration
  -- | inlines genuine, unshareable bulk — the `genericShow` dictionary of a large derived-`Generic`
  -- | ADT inlined into `show`, the case that hung the compiler compiling itself. The companion case
  -- | proves the cap discriminates: a reduced form *under* the cap is still inlined.
  describe "DictElim.simplifyModule — code-size cap (ADR 0035 Layer C lite)" do
    it "falls back to the un-inlined call when inlining blows the size cap" do
      let big = M.Var (Qualified (Just [ "M" ]) "big")
      let ctx = (ctxFor 0) { inline = Map.singleton "M.big" (flatBig (normalFormSizeCap + 10)) }
      -- inlined it would be > cap; the cap forces the un-inlined form, so `user` stays a small call.
      (userSize (simplifyModule ctx (userModule big)) < normalFormSizeCap) `shouldEqual` true
    it "still inlines a binding whose reduced form is under the cap (the cap discriminates)" do
      let small = M.Var (Qualified (Just [ "M" ]) "small")
      let ctx = (ctxFor 0) { inline = Map.singleton "M.small" (flatBig 50) }
      -- well under the cap: inlining proceeds, so `user` grows to the inlined array (≫ a bare call).
      (userSize (simplifyModule ctx (userModule small)) > 50) `shouldEqual` true

main :: Effect Unit
main = do
  Console.error "NbE diamond stress — result size should be O(d); on the unfixed reducer it doubles per depth:"
  for_ (Array.range 1 maxDepth) \d ->
    Console.error ("  d=" <> show d <> "  normalized-size=" <> show (exprSize (normalize (ctxFor d) (ref d))))
