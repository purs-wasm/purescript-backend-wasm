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
-- | `spec` is the routine `test:unit` guard (a generous linear bound at depth 20 that fails loudly
-- | if the exponential ever returns). `main` sweeps deeper depths for manual inspection:
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
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Semantics (normalize)
import PureScript.CoreFn (Qualified(..))
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

-- | Routine guard (ADR 0035 §8): a depth-20 diamond normalizes to a *linear*-size term. On the
-- | pre-sharing reducer this is 2^20 ≈ a million nodes (seconds of work + a huge tree); the
-- | Layer A memo + Layer B quote CSE keep it ≈ 4·20 + 3 = 83. The generous `< 1000` bound passes
-- | instantly when sharing holds and fails (or times out) the moment the exponential returns.
spec :: Spec Unit
spec = describe "Semantics.normalize — NbE exponential guard (ADR 0035)" do
  it "normalizes a depth-20 diamond inline DAG to linear size, not O(2^d)" do
    let d = 20
    (exprSize (normalize (ctxFor d) (ref d)) < 1000) `shouldEqual` true

main :: Effect Unit
main = do
  Console.error "NbE diamond stress — result size should be O(d); on the unfixed reducer it doubles per depth:"
  for_ (Array.range 1 maxDepth) \d ->
    Console.error ("  d=" <> show d <> "  normalized-size=" <> show (exprSize (normalize (ctxFor d) (ref d))))
