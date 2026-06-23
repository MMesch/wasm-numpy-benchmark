#!/usr/bin/env bash
# Build the pyjs (emscripten-forge) WASM environment for the benchmark.
# Produces: pyjs_runtime_browser.js / .wasm, empack_env_meta.json,
#           packages/*.tar.gz
#
# Prerequisites: micromamba (available in the Nix FHS dev shell)
#
# Run: ./build_pyjs.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v micromamba &> /dev/null; then
    echo "Error: micromamba not found."
    echo "Are you inside the Nix FHS dev shell? (nix develop)"
    exit 1
fi

if ! command -v empack &> /dev/null; then
    echo "Error: empack not found. Install with: python3 -m pip install --user empack"
    echo "  (or re-enter the FHS dev shell: nix develop)"
    exit 1
fi

echo "Creating emscripten-wasm32 conda environment..."
micromamba create -y -f environment.yml --platform emscripten-wasm32 --prefix ./env

echo "Copying pyjs runtime files..."
cp ./env/lib_js/pyjs/* .

echo "Packing environment with empack..."
empack pack env --env-prefix ./env --outdir .

echo "Organizing package files..."
mkdir -p packages
mv ./*.tar.gz packages/

echo
echo "Done. Artifacts:"
echo "  pyjs_runtime_browser.js / .wasm  — pyjs runtime"
echo "  empack_env_meta.json             — package manifest"
echo "  packages/*.tar.gz                 — packed env (python, numpy)"
