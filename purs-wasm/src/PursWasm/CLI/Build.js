// A monotonic clock in milliseconds, for the build's elapsed-time report.
export const nowMsImpl = () => performance.now();

export const stdoutIsTTY = process.stdout.isTTY;