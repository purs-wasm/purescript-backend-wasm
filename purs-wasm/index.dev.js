#!/usr/bin/env node
import { dirname } from 'path';
import { fileURLToPath } from 'url';

import { main } from "../output/PursWasm.CLI.Main/index.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

main(__dirname)();
