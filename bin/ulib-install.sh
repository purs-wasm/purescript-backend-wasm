#!/usr/bin/env sh
# Build the ulib shadow library (ADR 0028): compile each shadow in
# `<shadow-root>/<package>-<version>/<Module path>.purs` against the resolved package-set
# sources (so its imports/interface resolve) with WasmBase overlaid, then extract the
# shadowed modules' corefn + externs into `<lib>/<package>-<version>/<Module>/`.
#
# Invoked by `purs-wasm ulib install` (bin/src/Main.purs) as:
#   sh ulib-install.sh <lib> <shadow-root> <wasm-base-src> <purs> [<spago-packages-dir>]
set -eu

LIB="$1"; SHADOW_ROOT="$2"; WASM_BASE="$3"; PURS="$4"; SPAGO="${5:-.spago/p}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"

# 1. all resolved package-set sources (one version per package — coherent set).
for d in "$SPAGO"/*/src; do
  [ -d "$d" ] && cp -R "$d/." "$TMP/src/"
done

# 2. WasmBase primitives (the shadows are PureScript over these).
cp -R "$WASM_BASE/." "$TMP/src/"

# 3. overlay shadows: replace the registry module with the shadow, and drop its `.js`
#    foreign (the shadow has none — it is PureScript over WasmBase).
shadows="$(cd "$SHADOW_ROOT" && find . -mindepth 2 -name '*.purs' | sed 's#^\./##')"
for rel in $shadows; do
  modrel="${rel#*/}"                                  # e.g. Data/Functor.purs
  cp "$SHADOW_ROOT/$rel" "$TMP/src/$modrel"
  rm -f "$TMP/src/${modrel%.purs}.js"
done

# 4. compile the whole set to corefn (+ externs, for `ulib check`).
"$PURS" compile --codegen corefn --output "$TMP/output" "$TMP/src/**/*.purs"

# 5. extract the shadowed modules into the versioned lib layout.
for rel in $shadows; do
  pkgver="${rel%%/*}"                                 # e.g. prelude-6.0.2
  modrel="${rel#*/}"                                  # e.g. Data/Functor.purs
  mod="$(printf '%s' "${modrel%.purs}" | tr / .)"     # e.g. Data.Functor
  dst="$LIB/$pkgver/$mod"
  mkdir -p "$dst"
  cp "$TMP/output/$mod/corefn.json" "$dst/corefn.json"
  cp "$TMP/output/$mod/externs.cbor" "$dst/externs.cbor"
  echo "  ulib: installed $mod ($pkgver)"
done
