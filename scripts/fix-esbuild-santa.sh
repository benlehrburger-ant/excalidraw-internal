#!/usr/bin/env bash
#
# fix-esbuild-santa.sh
#
# Replaces native esbuild with the pure JS/WASM fallback (esbuild-wasm)
# to avoid Santa (macOS binary authorization) blocking the binary.
#
# Idempotent — safe to run multiple times.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ESBUILD_WASM_VERSION="0.19.10"
ESBUILD_WASM_DIR="$REPO_ROOT/node_modules/esbuild-wasm"
ESBUILD_WASM_TARBALL="/tmp/esbuild-wasm-${ESBUILD_WASM_VERSION}.tgz"

# ── Step 1: Download esbuild-wasm if not cached ────────────────────────
if [ ! -f "$ESBUILD_WASM_TARBALL" ]; then
  echo "[fix-esbuild-santa] Downloading esbuild-wasm@${ESBUILD_WASM_VERSION}..."
  curl -sL "https://registry.npmjs.org/esbuild-wasm/-/esbuild-wasm-${ESBUILD_WASM_VERSION}.tgz" \
    -o "$ESBUILD_WASM_TARBALL"
fi

# ── Step 2: Extract into node_modules ──────────────────────────────────
if [ ! -f "$ESBUILD_WASM_DIR/lib/main.js" ]; then
  echo "[fix-esbuild-santa] Extracting esbuild-wasm..."
  mkdir -p "$ESBUILD_WASM_DIR"
  tar xzf "$ESBUILD_WASM_TARBALL" -C "$ESBUILD_WASM_DIR" --strip-components=1
fi

# ── Step 3: Patch all esbuild CJS entrypoints ─────────────────────────
WASM_MAIN="$ESBUILD_WASM_DIR/lib/main.js"

find "$REPO_ROOT/node_modules" \
  -path "*/esbuild/lib/main.js" \
  -not -path "*/esbuild-wasm/*" \
  2>/dev/null | while read -r f; do
  # Skip if already patched
  if head -1 "$f" 2>/dev/null | grep -q "^module.exports = require("; then
    continue
  fi
  cat > "$f" <<PATCH
module.exports = require("$WASM_MAIN");
PATCH
  echo "[fix-esbuild-santa] Patched CJS: $f"
done

# ── Step 4: Patch Vite's ESM import ────────────────────────────────────
# Vite bundles esbuild with ESM named imports which fail with CJS modules
# on Node v25+. Rewrite to use default import + destructuring.
for chunk in "$REPO_ROOT"/node_modules/vite/dist/node/chunks/dep-*.js; do
  [ -f "$chunk" ] || continue

  if grep -q "import esbuild, {" "$chunk" 2>/dev/null; then
    if ! grep -q "esbuild_default" "$chunk" 2>/dev/null; then
      sed -i '' \
        "s|import esbuild, { transform as transform\$1, formatMessages, build as build\$3 } from 'esbuild';|import esbuild_default from 'esbuild'; const { default: esbuild, transform: transform\$1, formatMessages, build: build\$3 } = esbuild_default;|" \
        "$chunk"
      echo "[fix-esbuild-santa] Patched ESM: $chunk"
    fi
  fi
done

echo "[fix-esbuild-santa] Done. esbuild will use WASM fallback."
