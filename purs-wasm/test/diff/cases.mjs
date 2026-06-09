// Declarative case table for the differential parity harness (ADR 0009: the build is
// deterministic, so the same input + flags must yield byte-identical artifacts whichever
// CLI produced them). Each case is a build invocation run through BOTH the legacy `bin`
// oracle and the new `purs-wasm`; the driver (run.mjs) asserts the two output trees match
// byte-for-byte. Keep cases self-contained: `input` is a directory of compiler artifacts
// (corefn.json + externs.cbor) that exists after the harness' prerequisite build step.
//
// `args` are passed verbatim after `build` (so `-I <input> -e <entry> [...flags]`), minus
// the `-O <out>` the driver injects. Both CLIs run from the repo root, so `input` is a
// repo-relative path and the cliRoot-relative `lib`/`ulib`/`runtime` resolve identically
// for both (the parity invariant — see the plan's Gotchas).

export const cases = [
  // --- bench package (built into bench/output by the prerequisite step) ---
  { name: "bench/Bench.Main", args: ["-I", "bench/output", "-e", "Bench.Main"] },
  { name: "bench/Bench.Main --no-opt", args: ["-I", "bench/output", "-e", "Bench.Main", "--no-opt"] },
  { name: "bench/Bench.Main -t (wat)", args: ["-I", "bench/output", "-e", "Bench.Main", "-t"] },
  { name: "bench/Bench.Main -g (debug)", args: ["-I", "bench/output", "-e", "Bench.Main", "-g"] },
  { name: "bench/BenchCurry", args: ["-I", "bench/output", "-e", "BenchCurry"] },
  { name: "bench/CountEffect", args: ["-I", "bench/output", "-e", "CountEffect"] },
  { name: "bench/CountState", args: ["-I", "bench/output", "-e", "CountState"] },

  // --- committed self-contained fixtures (no spago build of an example needed) ---
  // Effect export exposed as a callable thunk (ADR 0015).
  { name: "fixture/EffMain", args: ["-I", "compiler/test/fixtures/bin-effmain", "-e", "EffMain"] },
  // Private foreign reconstructed from .purs via cache-db.json (ADR 0016).
  { name: "fixture/Priv", args: ["-I", "compiler/test/fixtures/source-foreign", "-e", "Priv"] },
];

// `ulib validate` / `ulib check` produce no build artifact — only stdout + an exit code (0 on
// success, non-zero on divergence). So parity here is "same exit code AND same normalized stdout"
// rather than byte-identity. The driver installs a fresh lib (via the `bin` oracle) into a temp
// dir and appends `-L <that dir>`, so both CLIs see identical inputs. (`ulib install` is NOT a
// differential case: purs embeds the install scratch dir's absolute path into corefn/externs, so
// its output is not byte-reproducible even bin-vs-bin — that command is covered by unit tests.)
export const ulibCases = [
  { name: "ulib validate", args: ["ulib", "validate"] },
  { name: "ulib check", args: ["ulib", "check"] },
];
