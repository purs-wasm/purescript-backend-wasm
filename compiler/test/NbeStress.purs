-- | Standalone stress harness for the NbE exponential (bug A, ADR 0035) — NOT part of the
-- | routine `test:unit` suite (it deliberately blows up on the current reducer). Run on demand:
-- |
-- |     spago test -p compiler -m Test.NbeStress
-- |
-- | It drives `Semantics.normalize` directly against a synthetic **diamond inline DAG**: an
-- | inline set `b0 … bd` where each `bᵢ = f b₍ᵢ₋₁₎ b₍ᵢ₋₁₎` references the previous binding twice.
-- | Normalizing `bd` re-evaluates the shared leaf `b0` once per path = Θ(2ᵈ) on the current
-- | reducer (M1 in eval, M2 in quote), so the printed result size **doubles every depth** and the
-- | wall clock explodes around d≈22-25. After the ADR-0035 sharing fix the result stays O(d) and
-- | the loop runs to the end instantly — this is the exponential regression guard (ADR 0035 §8),
-- | reproduced without building the whole compiler to wasm. Edit `maxDepth` to taste.
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

main :: Effect Unit
main = do
  Console.error "NbE diamond stress — result size should be O(d); on the unfixed reducer it doubles per depth:"
  for_ (Array.range 1 maxDepth) \d ->
    Console.error ("  d=" <> show d <> "  normalized-size=" <> show (exprSize (normalize (ctxFor d) (ref d))))
