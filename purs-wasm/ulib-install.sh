#!/usr/bin/env sh
# Build the ulib shadow library (ADR 0028/0031): compile each ulib module in
# `<ulib-src>/<package>/<Module>.purs` (dotted, flat per package — ADR 0031 §2.1) against the
# resolved package-set sources (so its imports/interface resolve) with WasmBase overlaid, then
# extract the modules' corefn + externs into `<lib>/<package>-<version>/<Module>/`. The version is
# read from `<manifest>` (`ulib-manifest.json`) since it is no longer encoded in the source path.
#
# NOTE (ADR 0031 migration phase 3): only the SOURCE layout moved; the lib OUTPUT layout is still the
# versioned `<package>-<version>/<Module>/` so `loadShadowMap` / `shadowOrRegistry` / `ulib validate`
# keep working unchanged. The new `$LIB/<Module>/` layout lands at the switch (phase 4).
#
# Invoked by `purs-wasm ulib install` as:
#   sh ulib-install.sh <lib> <ulib-src> <wasm-base-src> <purs> <manifest> [<spago-packages-dir>]
set -eu

LIB="$1"; ULIB_SRC="$2"; WASM_BASE="$3"; PURS="$4"; MANIFEST="$5"; SPAGO="${6:-.spago/p}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"

# 1. all resolved package-set sources (one version per package — coherent set).
for d in "$SPAGO"/*/src; do
  [ -d "$d" ] && cp -R "$d/." "$TMP/src/"
done

# 2. WasmBase primitives (the shadows are PureScript over these).
cp -R "$WASM_BASE/." "$TMP/src/"

# 3. overlay shadows: replace the registry module with the ulib one, and drop its `.js` foreign
#    (the ulib module has none — it is PureScript over WasmBase + a kept foreign provided by wat).
#    Sources are `<package>/<Module>.purs` (dotted); overlay at the registry module's nested path.
shadows="$(cd "$ULIB_SRC" && find . -mindepth 2 -name '*.purs' | sed 's#^\./##')"
for rel in $shadows; do
  mod="$(basename "$rel" .purs)"                       # e.g. Data.Functor
  modrel="$(printf '%s' "$mod" | tr . /).purs"         # e.g. Data/Functor.purs
  cp "$ULIB_SRC/$rel" "$TMP/src/$modrel"
  rm -f "$TMP/src/${modrel%.purs}.js"
done

# 4. compile the whole set to corefn (+ externs, for `ulib check`).
"$PURS" compile --codegen corefn --output "$TMP/output" "$TMP/src/**/*.purs"

# 5. extract the modules into the (still versioned) lib layout; version comes from the manifest.
for rel in $shadows; do
  pkg="${rel%%/*}"                                      # e.g. prelude
  mod="$(basename "$rel" .purs)"                        # e.g. Data.Functor
  ver="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((m[process.argv[2]]||{}).version||"")' "$MANIFEST" "$pkg")"
  if [ -z "$ver" ]; then echo "  ulib: ERROR no manifest version for package '$pkg'" >&2; exit 1; fi
  dst="$LIB/$pkg-$ver/$mod"
  mkdir -p "$dst"
  cp "$TMP/output/$mod/corefn.json" "$dst/corefn.json"
  cp "$TMP/output/$mod/externs.cbor" "$dst/externs.cbor"
  echo "  ulib: installed $mod ($pkg-$ver)"
done
