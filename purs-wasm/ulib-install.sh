#!/usr/bin/env sh
# Build the ulib shadow library (ADR 0028/0031): compile each ulib module in
# `<ulib-src>/<package>/<Module>.purs` (dotted, flat per package — ADR 0031 §2.1) against the
# resolved package-set sources (so its imports/interface resolve) with WasmBase overlaid, then
# extract the modules' corefn + externs into the flat `<lib>/<Module>/` layout (ADR 0031 §2.2). The
# version lives only in `<manifest>` (`ulib-manifest.json`); `pkgver` reads it for the install log
# and as the "package must be ulib-covered" guard.
#
# Invoked by `purs-wasm ulib install` as:
#   sh ulib-install.sh <lib> <ulib-src> <wasm-base-src> <purs> <manifest> <wasm-as> [<spago-packages-dir>]
set -eu

LIB="$1"; ULIB_SRC="$2"; WASM_BASE="$3"; PURS="$4"; MANIFEST="$5"; WASM_AS="$6"; SPAGO="${7:-.spago/p}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"

# `<package>` -> `<package>-<version>` (version read from the manifest; hard error if missing).
pkgver() {
  v="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((m[process.argv[2]]||{}).version||"")' "$MANIFEST" "$1")"
  [ -z "$v" ] && { echo "  ulib: ERROR no manifest version for package '$1'" >&2; exit 1; }
  printf '%s-%s' "$1" "$v"
}

# Assemble a co-located foreign `.wat` *fragment* (wrapped with the shared `_header.wat`) to a wasm.
assemble_wat() { # <src.wat> <dst.wasm>
  { printf '(module\n'; cat "$ULIB_SRC/_header.wat" "$1"; printf '\n)\n'; } > "$TMP/asm.wat"
  "$WASM_AS" "$TMP/asm.wat" -o "$2" --all-features
}

# 1. all resolved package-set sources (one version per package — coherent set).
for d in "$SPAGO"/*/src; do
  [ -d "$d" ] && cp -R "$d/." "$TMP/src/"
done

# 2. WasmBase primitives (the shadows are PureScript over these).
cp -R "$WASM_BASE/." "$TMP/src/"

# 3. overlay shadows: replace the registry module with the ulib one, and drop its `.js` foreign
#    (the ulib module has none — it is PureScript over WasmBase + a kept foreign provided by wat).
#    Sources are `<package>/<Module>.purs` (dotted); overlay at the registry module's nested path.
#    A ulib-internal helper (ADR 0031 §6, e.g. `Data.String.Internal.Utf8`) has no registry module,
#    so its nested dir may not exist yet — `mkdir -p` before copying.
shadows="$(cd "$ULIB_SRC" && find . -mindepth 2 -name '*.purs' | sed 's#^\./##')"
for rel in $shadows; do
  mod="$(basename "$rel" .purs)"                       # e.g. Data.Functor
  modrel="$(printf '%s' "$mod" | tr . /).purs"         # e.g. Data/Functor.purs
  mkdir -p "$(dirname "$TMP/src/$modrel")"
  cp "$ULIB_SRC/$rel" "$TMP/src/$modrel"
  rm -f "$TMP/src/${modrel%.purs}.js"
done

# 4. compile the whole set to corefn (+ externs, for `ulib check`).
"$PURS" compile --codegen corefn --output "$TMP/output" "$TMP/src/**/*.purs"

# 4b. copy the manifest into the lib root so the precompiled lib is self-describing (ADR 0031): the
#     build + `ulib validate` read versions from `$LIB/ulib-manifest.json`, needing no ulib source.
mkdir -p "$LIB"
cp "$MANIFEST" "$LIB/ulib-manifest.json"

# 5. extract the shadowed modules into the flat `$LIB/<Module>/` lib layout (ADR 0031 §2.2 — the
#    version is in the manifest, not the path); a sibling co-located `.wat` (the module's kept
#    foreign, e.g. Data.Show's showNumberImpl) is assembled into `foreign.wasm`. `pkgver` still runs
#    (its manifest lookup is the "package must be ulib-covered" check + the install log).
for rel in $shadows; do
  pkg="${rel%%/*}"; mod="$(basename "$rel" .purs)"
  pv="$(pkgver "$pkg")"
  dst="$LIB/$mod"
  mkdir -p "$dst"
  cp "$TMP/output/$mod/corefn.json" "$dst/corefn.json"
  cp "$TMP/output/$mod/externs.cbor" "$dst/externs.cbor"
  wat="$ULIB_SRC/$pkg/$mod.wat"
  [ -f "$wat" ] && assemble_wat "$wat" "$dst/foreign.wasm"
  echo "  ulib: installed $mod ($pv)"
done

# 6. ADR 0031: wat-only ulib modules — a co-located `<package>/<Module>.wat` with NO sibling `.purs`
#    (e.g. Data.Int, Data.Show.Generic): NOT shadowed (the build uses the registry corefn); ulib only
#    provides their foreign from the lib so programs using them stay standalone. Emit foreign.wasm only.
# (exclude `foreign.wat` — those are the global ulib/<Module>/ wat layer, not co-located sources)
wats="$(cd "$ULIB_SRC" && find . -mindepth 2 -name '*.wat' ! -name 'foreign.wat' | sed 's#^\./##')"
for rel in $wats; do
  pkg="${rel%%/*}"; mod="$(basename "$rel" .wat)"
  [ -f "$ULIB_SRC/$pkg/$mod.purs" ] && continue          # a shadow — already handled in step 5
  pv="$(pkgver "$pkg")"
  dst="$LIB/$mod"
  mkdir -p "$dst"
  assemble_wat "$ULIB_SRC/$rel" "$dst/foreign.wasm"
  echo "  ulib: installed $mod ($pv, foreign only)"
done
