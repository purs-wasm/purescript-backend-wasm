// Live build progress for the `compile-batch` worker. The worker's stdout is discarded by the
// orchestrator (it owns the build framing); progress is written to STDERR (inherited) so it shows on
// a TTY (sharing the terminal cursor with the orchestrator's stdout) without polluting piped stdout.
export const stderrIsTTY = process.stderr.isTTY === true;
export const progressWriteImpl = (s) => () => {
  process.stderr.write(s);
};
