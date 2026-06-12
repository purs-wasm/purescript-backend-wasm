#!/usr/bin/env node
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

import { main } from "../output/PursWasm.CLI.Main/index.js";

// Dev: assets live in the monorepo, not in this package. `cliRoot` = the repo root (so
// `<cliRoot>/runtime` and `<cliRoot>/lib` resolve), and the binaryen binaries come from the
// `binaryen` workspace package's own node_modules. The CLI works from any cwd this way.
const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(__dirname);
const binaryenBinDir = join(repoRoot, "binaryen", "node_modules", "binaryen", "bin");

console.log("\x1b[34m!!!This is a dev build of purs-wasm!!!\x1b[0m\n");

main(repoRoot)(binaryenBinDir)();
