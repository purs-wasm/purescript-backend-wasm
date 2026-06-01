import { execFileSync } from "node:child_process";

// Run a tool synchronously, inheriting stdio; throws on a non-zero exit.
export const execFileImpl = (cmd) => (args) => () => {
  execFileSync(cmd, args, { stdio: "inherit" });
};
