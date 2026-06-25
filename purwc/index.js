#!/usr/bin/env node
import { dirname, join } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';
import { existsSync } from 'fs';
import { createRequire } from 'module';

// A single entry for both the monorepo and a published worker. In the monorepo the spago output
// exists at <repo>/output, so import the worker straight from there (fast iteration) with assets at
// the repo root and binaryen from the workspace package. Otherwise import the self-contained
// `bundle/index.js`, with binaryen resolved as a dependency.
const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const devEntry = join(repoRoot, "output", "Purwc", "index.js");
const dev = existsSync(devEntry);

const { main } = await import(dev ? pathToFileURL(devEntry).href : "./bundle/index.js");
const cliRoot = dev ? repoRoot : here;
const require = createRequire(import.meta.url);
const binaryenBinDir = dev
  ? join(repoRoot, "binaryen", "node_modules", "binaryen", "bin")
  : join(dirname(require.resolve("binaryen/package.json")), "bin");

main(cliRoot)(binaryenBinDir)();
