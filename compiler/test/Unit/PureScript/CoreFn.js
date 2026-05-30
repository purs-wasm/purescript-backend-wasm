import { readFileSync } from "node:fs";

export const readFixture = (path) => () => readFileSync(path, "utf8");
