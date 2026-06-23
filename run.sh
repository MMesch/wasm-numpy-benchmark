#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d node_modules/pyodide ]; then
    echo "Installing pyodide npm package..."
    npm install pyodide
fi

N=${1:-1000000}
REPS=${2:-2000}

echo "=========================================================="
echo " Run 1: default tiering (Liftoff first, TurboFan if hot)"
echo "=========================================================="
node --trace-wasm-compiler --print-wasm-code bench.js "$N" "$REPS" \
    > tier_default.txt 2>&1 || true
echo "  -> raw V8 output saved to tier_default.txt"
grep -E "compiler:|kind:" tier_default.txt | tail -40 || true

echo
echo "=========================================================="
echo " Run 2: forced straight to TurboFan (--no-liftoff)"
echo "=========================================================="
node --no-liftoff --trace-wasm-compiler --print-wasm-code bench.js "$N" "$REPS" \
    > tier_turbofan.txt 2>&1 || true
echo "  -> raw V8 output saved to tier_turbofan.txt"

echo
echo "Next steps:"
echo "  1. Open tier_turbofan.txt and find the function whose name maps"
echo "     to numpy's add ufunc loop (search for the function index that"
echo "     --trace-wasm-compilation reported compiling around the time"
echo "     np.add ran, or search for 'kind: wasm function' blocks)."
echo "  2. Extract just that disassembly block and place it in"
echo "     results.md next to the native AVX2/AVX512 listing."
echo "  3. Compare instruction mnemonics directly: vaddpd (native)"
echo "     vs whatever TurboFan emitted for f64x2.add / scalar f64.add."

echo
echo "=========================================================="
echo " Run 3: pyjs (emscripten-forge) default tiering"
echo "=========================================================="
if [ ! -f pyjs_runtime_browser.wasm ]; then
    echo "  -> pyjs env not built; running ./build_pyjs.sh"
    bash ./build_pyjs.sh
fi
node --trace-wasm-compiler --print-wasm-code bench_pyjs.js "$N" "$REPS" \
    > tier_pyjs_default.txt 2>&1 || true
echo "  -> raw V8 output saved to tier_pyjs_default.txt"
grep -E "compiler:|kind:" tier_pyjs_default.txt | tail -40 || true

echo
echo "=========================================================="
echo " Run 4: pyjs (emscripten-forge) forced TurboFan (--no-liftoff)"
echo "=========================================================="
node --no-liftoff --trace-wasm-compiler --print-wasm-code bench_pyjs.js "$N" "$REPS" \
    > tier_pyjs_turbofan.txt 2>&1 || true
echo "  -> raw V8 output saved to tier_pyjs_turbofan.txt"

echo
echo "Next steps for the pyjs arm:"
echo "  1. Open tier_pyjs_turbofan.txt and find the numpy ufunc add loop"
echo "     disassembly (search for 'kind: wasm function' blocks)."
echo "  2. Place the relevant block in results.md next to native and pyodide."
echo
echo "For a clean timing table, run each benchmark without V8 flags:"
echo "  python bench.py 1000000 2000 > native_out.txt"
echo "  node bench.js 1000000 2000 > wasm_pyodide_out.txt"
echo "  node bench_pyjs.js 1000000 2000 > wasm_pyjs_out.txt"
echo "  python timing.py native_out.txt wasm_pyodide_out.txt wasm_pyjs_out.txt"
