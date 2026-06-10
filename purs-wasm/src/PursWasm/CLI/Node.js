import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

export const execFileImpl = (cmd) => (args) => () => {
  execFileSync(cmd, args, { stdio: "inherit" });
};

// Capture stdout as text (the registry query in `ulib compat`). A large maxBuffer matches the
// prototype — `spago registry info --json` payloads can be sizeable.
export const execFileCaptureImpl = (cmd) => (args) => () =>
  execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 1e8 });

// `readFileSync` returns a Buffer, which is a Uint8Array; `writeFileSync` accepts a Uint8Array.
// So the CLI's binary currency stays `Uint8Array` with no Buffer conversion.
export const readFileBytesImpl = (path) => () => readFileSync(path);

export const writeFileBytesImpl = (path) => (bytes) => () => writeFileSync(path, bytes);
