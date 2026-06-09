import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

export const execFileImpl = (cmd) => (args) => () => {
  execFileSync(cmd, args, { stdio: "inherit" });
};

// `readFileSync` returns a Buffer, which is a Uint8Array; `writeFileSync` accepts a Uint8Array.
// So the CLI's binary currency stays `Uint8Array` with no Buffer conversion.
export const readFileBytesImpl = (path) => () => readFileSync(path);

export const writeFileBytesImpl = (path) => (bytes) => () => writeFileSync(path, bytes);
