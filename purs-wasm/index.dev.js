#!/usr/bin/env node
import { dirname } from 'path';
import { fileURLToPath } from 'url';

import { main } from "../output/PursWasm.CLI.Main/index.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
console.log("\x1b[34m!!!This is a dev build of purs-wasm!!!\x1b[0m\n");

main(__dirname)();
