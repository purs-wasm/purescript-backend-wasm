import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, statSync } from "node:fs";

export const execFileImpl = (cmd) => (args) => () => {
  execFileSync(cmd, args, { stdio: "inherit" });
};

// Pipe `input` to the child's stdin while inheriting stdout/stderr (so its progress shows). Used to
// feed a long-lived `purwc` batch worker its whole module work-list in one spawn (ADR 0038 C2).
export const execFileInputImpl = (cmd) => (args) => (input) => () => {
  execFileSync(cmd, args, { input, stdio: ["pipe", "inherit", "inherit"], maxBuffer: 1e9 });
};

// Read all of this process's stdin synchronously (fd 0). The batch worker's work-list.
export const readStdinImpl = () => readFileSync(0, "utf8");

// Capture stdout as text (the registry query in `ulib compat`). A large maxBuffer matches the
// prototype — `spago registry info --json` payloads can be sizeable.
export const execFileCaptureImpl = (cmd) => (args) => () =>
  execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 1e8 });

// `readFileSync` returns a Buffer, which is a Uint8Array; `writeFileSync` accepts a Uint8Array.
// So the CLI's binary currency stays `Uint8Array` with no Buffer conversion.
export const readFileBytesImpl = (path) => () => readFileSync(path);

export const writeFileBytesImpl = (path) => (bytes) => () => writeFileSync(path, bytes);

export const fileSizeImpl = (path) => () => statSync(path).size;
