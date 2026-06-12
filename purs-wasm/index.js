#!/usr/bin/env node
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

import { main } from "./bundle/index.js";

// Published package: assets ship inside it (`<cliRoot>/runtime`, `<cliRoot>/lib`), so `cliRoot` is
// this directory. The binaryen binaries come from the `binaryen` dependency, resolved by node so it
// works regardless of where npm hoists it.
const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const binaryenBinDir = join(dirname(require.resolve("binaryen/package.json")), "bin");

main(__dirname)(binaryenBinDir)();
