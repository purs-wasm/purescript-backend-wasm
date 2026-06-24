#!/usr/bin/env node
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

import { main } from "./bundle/index.js";

// Dev: assets live in the monorepo, not in this package. `cliRoot` = the repo root (so
// `<cliRoot>/runtime` and `<cliRoot>/lib` resolve), and the binaryen binaries come from the
// `binaryen` workspace package's own node_modules. The CLI works from any cwd this way.
const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(__dirname);
const binaryenBinDir = join(repoRoot, "binaryen", "node_modules", "binaryen", "bin");

main(repoRoot)(binaryenBinDir)();
