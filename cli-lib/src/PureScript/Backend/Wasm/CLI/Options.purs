-- | The shared CLI option machinery: the global-options parser and the `withGlobals` combinator
-- | that pairs it with any command parser. Each binary (`purs-wasm`, `purwc`, `ulib-tooling`)
-- | defines its own command parsers and reuses `withGlobals` so the global flags are defined once.
module PureScript.Backend.Wasm.CLI.Options
  ( withGlobals
  ) where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.CLI.Options.Types (GlobalOptions)

-- | The options every command accepts (logging verbosity, …). Defined once and threaded onto each
-- | command by `withGlobals`, so there is no per-command copy.
globalOptionsParser :: ArgParser GlobalOptions
globalOptionsParser =
  ArgParser.fromRecord
    { verbose:
        ArgParser.flag [ "--verbose" ]
          "Print all messages, including debug-level logs."
          # ArgParser.boolean
    }

-- | Pair a command's own parser with the shared global options. ArgParse confines flags to the
-- | subcommand they follow, so the globals must live inside each leaf — but the flag definition
-- | stays in `globalOptionsParser` alone. Polymorphic in the command type so each CLI reuses it for
-- | its own `Command`.
withGlobals :: forall c. ArgParser c -> ArgParser (Tuple GlobalOptions c)
withGlobals command = Tuple <$> globalOptionsParser <*> command
