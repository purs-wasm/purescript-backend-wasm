// Generate / verify `ulib/compat.json` — the record of which package-set version the ulib
// shadows (ADR 0028) are pinned to, the exact package versions each shadow targets, and the
// `purs` compiler pin the shipped lib is built with (ADR 0029).
//
// `spago.lock` is the authoritative source for the version data: `workspace.package_set.address.
// registry` is the pinned set version, `.content` its `{package: version}` map, and `.compiler`
// its compiler constraint. The shadow set is the directory structure `ulib/shadow/<pkg>-<ver>/…`.
// The compiler pin is cross-checked against the registry's per-version `compilers` lists
// (`spago registry info <pkg> --json`).
//
//   node ulib-compat.mjs           regenerate ulib/compat.json:
//                                    - version data from spago.lock + shadow dirs (offline);
//                                    - purs pin/min from the registry compiler-compat (online,
//                                      best-effort: kept from the prior compat.json if offline).
//   node ulib-compat.mjs --check   verify (offline, CI) the shadows are still in sync with the
//                                    pinned set and ulib/compat.json's *version data* is current:
//                                    - a major.minor divergence FAILS (stale shadow — re-shadow);
//                                    - a patch-only divergence WARNS;
//                                    - missing / out-of-date version data FAILS.
//                                    (The purs pin is release-time/online, so --check leaves it.)
// Run from the repo root.
import { readFileSync, writeFileSync, readdirSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const LOCK = "spago.lock";
const SHADOW_ROOT = "ulib/shadow";
const COMPAT = "ulib/compat.json";

// purs-wasm's CoreFn decoder is verified against this compiler; the shipped lib is built with it
// (ADR 0029). It must lie in the shadowed packages' supported-compiler range — the guard below.
const PURS_PIN = "0.15.16";

const check = process.argv.includes("--check");

// `<package>-<version>` → { pkg, ver }, splitting on the LAST `-` (a package name may contain
// `-`, a version never does): `foldable-traversable-6.0.0` → foldable-traversable / 6.0.0.
function splitPkgVer(dir) {
  const i = dir.lastIndexOf("-");
  return { pkg: dir.slice(0, i), ver: dir.slice(i + 1) };
}
const parts = (v) => v.split(".").map(Number);
const cmp = (a, b) => {
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0);
  return 0;
};
const majorMinor = (v) => v.split(".").slice(0, 2).join(".");

if (!existsSync(LOCK)) {
  console.error(`ulib-compat: ${LOCK} not found (run a spago build first).`);
  process.exit(1);
}
const lock = JSON.parse(readFileSync(LOCK, "utf8"));
// `address.registry` = pinned set version; `.content` = that set's authoritative `{pkg: version}`
// map (a superset of the resolved `packages`); `.compiler` = the set's compiler constraint.
const pkgSet = lock.workspace?.package_set ?? {};
const packageSet = pkgSet.address?.registry ?? null;
const setCompiler = pkgSet.compiler ?? null; // e.g. ">=0.15.15 <0.16.0"
const lockVersion = (pkg) => pkgSet.content?.[pkg] ?? lock.packages?.[pkg]?.version ?? null;

const shadows = readdirSync(SHADOW_ROOT, { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => splitPkgVer(d.name));

// the offline-derivable core: what version of each shadowed package the pinned set resolves.
const core = {
  packageSet,
  packages: Object.fromEntries(shadows.map((s) => [s.pkg, lockVersion(s.pkg) ?? s.ver]).sort()),
};

const prior = existsSync(COMPAT) ? JSON.parse(readFileSync(COMPAT, "utf8")) : {};

// ── --check (offline): version data only ────────────────────────────────────────────────────
if (check) {
  let stale = 0;
  let drift = 0;
  for (const s of shadows) {
    const lv = lockVersion(s.pkg);
    if (lv === null) {
      console.log(`  ? ${s.pkg}: shadow ${s.ver}, not resolved in the package set`);
    } else if (majorMinor(lv) !== majorMinor(s.ver)) {
      console.log(`  ✗ ${s.pkg}: shadow ${s.ver} ≠ set ${lv} (major.minor) — shadow is STALE, re-shadow it`);
      stale++;
    } else if (lv !== s.ver) {
      console.log(`  ~ ${s.pkg}: shadow ${s.ver}, set ${lv} (patch differs — still applies; refresh compat.json)`);
      drift++;
    } else {
      console.log(`  ✓ ${s.pkg}: ${s.ver}`);
    }
  }
  // version data in compat.json must match what we'd derive now (purs fields are release-time)
  const recordedCore = { packageSet: prior.packageSet ?? null, packages: prior.packages ?? {} };
  let outOfDate = false;
  if (!existsSync(COMPAT)) {
    console.log(`  ✗ ${COMPAT} is missing — run \`node ulib-compat.mjs\``);
    outOfDate = true;
  } else if (JSON.stringify(recordedCore) !== JSON.stringify(core)) {
    console.log(`  ✗ ${COMPAT} version data is out of date — run \`node ulib-compat.mjs\``);
    outOfDate = true;
  }
  if (stale > 0 || outOfDate) {
    console.error(`ulib-compat: check failed (${stale} stale shadow(s)${outOfDate ? ", compat.json out of date" : ""}).`);
    process.exit(1);
  }
  console.log(`ulib-compat: check OK${drift > 0 ? ` (${drift} patch drift — regenerate compat.json)` : ""}.`);
  process.exit(0);
}

// ── generate ────────────────────────────────────────────────────────────────────────────────
// purs pin (online, best-effort): the shipped lib is built with PURS_PIN. The supported set is the
// intersection of every shadowed package's target-version `compilers` ∩ the package-set's compiler
// constraint. PURS_PIN must be a MEMBER of it — neither too old (below the set's min) nor too new
// (above the newest the packages have been published-tested against). Record both bounds (ADR
// 0029). On any failure (offline / spago missing) keep the prior purs fields.
// Query the registry for the supported-compiler set (intersection of every shadowed package's
// target-version `compilers`, ∩ the package-set's compiler constraint). Throws only on a *query*
// failure (offline / spago missing) — distinct from a guard violation, which is a hard error.
function querySupported() {
  const within = (v) => {
    if (!setCompiler) return true;
    const lo = /[>]=?\s*([0-9.]+)/.exec(setCompiler);
    const hi = /<\s*([0-9.]+)/.exec(setCompiler);
    return (!lo || cmp(v, lo[1]) >= 0) && (!hi || cmp(v, hi[1]) < 0);
  };
  let supported = null;
  for (const s of shadows) {
    const out = execFileSync("spago", ["registry", "info", s.pkg, "--json"], { encoding: "utf8", maxBuffer: 1e8 });
    const j = JSON.parse(out.slice(out.indexOf("{")));
    const comps = j.published?.[lockVersion(s.pkg) ?? s.ver]?.compilers ?? [];
    const set = new Set(comps);
    supported = supported === null ? set : new Set([...supported].filter((x) => set.has(x)));
  }
  return [...(supported ?? [])].filter(within).sort(cmp);
}

let purs;
let range;
try {
  range = querySupported();
} catch (e) {
  // QUERY failure only (no network / no spago): best-effort, keep the prior pin.
  range = null;
  if (prior.pursPin) {
    purs = { pursPin: prior.pursPin, pursMin: prior.pursMin, pursMax: prior.pursMax };
    console.log(`ulib-compat: keeping prior purs pin ${purs.pursPin} (compiler-compat query skipped: ${e.message}).`);
  } else {
    console.error(`ulib-compat: ${e.message}`);
    process.exit(1);
  }
}

// GUARD (hard fail): when the supported set was obtained, PURS_PIN must be a member — neither too
// old (below min) nor too new (above the newest the packages are published-tested against).
if (range !== null) {
  if (range.length === 0) {
    console.error("ulib-compat: no purs is supported by all shadowed packages within the package-set constraint.");
    process.exit(1);
  }
  const [min, max] = [range[0], range[range.length - 1]];
  if (!range.includes(PURS_PIN)) {
    const why =
      cmp(PURS_PIN, min) < 0 ? `too old (below the supported min ${min})`
      : cmp(PURS_PIN, max) > 0 ? `too new (above the supported max ${max} — a shadowed package has not been published-tested against it)`
      : `not in the supported set (a gap; supported: ${range.join(", ")})`;
    console.error(`ulib-compat: pinned purs ${PURS_PIN} is ${why}. Re-shadow against package versions that support ${PURS_PIN}, or bump the decoder's pin.`);
    process.exit(1);
  }
  purs = { pursPin: PURS_PIN, pursMin: min, pursMax: max };
  console.log(`ulib-compat: purs pin ${purs.pursPin} ∈ supported [${min} .. ${max}] — OK (not too old, not too new).`);
}

const out = { packageSet: core.packageSet, pursPin: purs.pursPin, pursMin: purs.pursMin, pursMax: purs.pursMax, packages: core.packages };
writeFileSync(COMPAT, JSON.stringify(out, null, 2) + "\n");
console.log(`ulib-compat: wrote ${COMPAT} (package-set ${packageSet}):`);
for (const s of shadows) console.log(`  ${s.pkg}: shadow ${s.ver}, set ${lockVersion(s.pkg) ?? "?"}`);
