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

export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/.mamba}"

if ! command -v micromamba &> /dev/null; then
    echo "Error: micromamba not found."
    echo "Are you inside the Nix FHS dev shell? (nix develop)"
    exit 1
fi

if ! python3 -c "import empack" 2>/dev/null; then
    echo "Installing empack (one-time)..."
    python3 -m pip install --user empack
fi
# empack CLI lands in ~/.local/bin after pip install --user
export PATH="$HOME/.local/bin:$PATH"

echo "Creating emscripten-wasm32 conda environment..."
micromamba create -y -f environment.yml --platform emscripten-wasm32 --prefix ./env

echo "Copying pyjs runtime files..."
cp ./env/lib_js/pyjs/* .

echo "Packing environment with empack..."
empack pack env --env-prefix ./env --outdir . --config empack_config.yaml

echo "Organizing package files..."
mkdir -p packages
mv ./*.tar.gz packages/

echo
echo "Done. Artifacts:"
echo "  pyjs_runtime_browser.js / .wasm  — pyjs runtime"
echo "  empack_env_meta.json             — package manifest"
echo "  packages/*.tar.gz                 — packed env (python, numpy)"
