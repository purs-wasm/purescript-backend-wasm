#!/usr/bin/env node
import { dirname, join } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';
import { existsSync } from 'fs';
import { createRequire } from 'module';

// A single entry for both the monorepo and a published worker. In the monorepo the spago output
// exists at <repo>/output, so import the worker straight from there (fast iteration) with binaryen
// from the workspace package. Otherwise import the self-contained `bundle/index.js`, with binaryen
// resolved as a dependency. Either way `cliRoot` is the PARENT of this `purwc/` dir — the repo root in
// the monorepo, the purs-wasm package root when shipped inside it — so the worker resolves `lib/`
// (ADR 0028 shadows) from `<cliRoot>/lib`, which is where the orchestrator's `lib/` sits too.
const here = dirname(fileURLToPath(import.meta.url));
const cliRoot = dirname(here);
const devEntry = join(cliRoot, "output", "Purwc", "index.js");
const dev = existsSync(devEntry);

const { main } = await import(dev ? pathToFileURL(devEntry).href : "./bundle/index.js");
const require = createRequire(import.meta.url);
const binaryenBinDir = dev
  ? join(cliRoot, "binaryen", "node_modules", "binaryen", "bin")
  : join(dirname(require.resolve("binaryen/package.json")), "bin");

main(cliRoot)(binaryenBinDir)();
