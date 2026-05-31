-- | The lowering effect for `PureScript.Backend.Wasm.Lower`: a state of
-- | local-slot and lifted-function bookkeeping over an error channel. Kept in
-- | its own module (per the project's `XX.Monad` convention) so the effect's
-- | abstraction is separate from the lowering algorithm that uses it.
module PureScript.Backend.Wasm.Lower.Monad
  ( LowerError(..)
  , LState
  , Lower
  , throw
  , fresh
  ) where

import Prelude

import Control.Monad.State (StateT, gets, modify_)
import Control.Monad.Trans.Class (lift)
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)
import PureScript.Backend.Wasm.IR (IRFunc, Slot(..))

-- | The lowering supports a strict subset of CoreFn; anything outside it is
-- | reported so the gap is explicit rather than silently mis-compiled.
data LowerError
  = UnsupportedExpr String
  | UnsupportedBinder String
  | UnknownVariable String
  | UnknownConstructor String
  | NotSaturated String Int Int -- name, expected arity, actual args
  | GuardedCaseUnsupported

derive instance eqLowerError :: Eq LowerError
derive instance genericLowerError :: Generic LowerError _
instance showLowerError :: Show LowerError where
  show = genericShow

-- | Lowering state. `slot` is the current function's next free local slot
-- | (saved/restored around each top-level function and each lambda lift);
-- | `lifted` accumulates the code functions produced by lambda lifting, and
-- | `nextCode` names them uniquely. The latter two persist across the module.
type LState =
  { slot :: Int
  , lifted :: Array IRFunc
  , nextCode :: Int
  }

type Lower a = StateT LState (Either LowerError) a

throw :: forall a. LowerError -> Lower a
throw = lift <<< Left

-- | Allocate a fresh local slot in the current function.
fresh :: Lower Slot
fresh = do
  n <- gets _.slot
  modify_ _ { slot = n + 1 }
  pure (Slot n)
