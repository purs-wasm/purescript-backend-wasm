#!/usr/bin/env node
import { dirname } from 'path';
import { fileURLToPath } from 'url';

import { main } from "../output/UlibTooling.Main/index.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

main(__dirname)();
