#!/usr/bin/env node
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

import { main } from "../output/UlibTooling.Main/index.js";

// Maintainer tool, monorepo only: `cliRoot` = the repo root (so `<cliRoot>/ulib`, `wasm-base`, `lib`,
// and `ulib-tooling/ulib-install.sh` resolve), binaryen from the workspace package.
const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const binaryenBinDir = join(repoRoot, "binaryen", "node_modules", "binaryen", "bin");

main(repoRoot)(binaryenBinDir)();
