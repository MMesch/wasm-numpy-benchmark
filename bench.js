/*
 * Same benchmark (c = a + b on float64 arrays) but running numpy
 * inside Pyodide (CPython + numpy compiled to WebAssembly), under Node.

 * To get the *actual executed native machine code* (not the static
 * .wasm bytecode), run this script with V8 disassembly flags, e.g.:
 *
 *   node --trace-wasm-compiler --print-wasm-code run.js > wasm_trace.txt 2>&1
 *
 * --trace-wasm-compiler : logs each function as it compiles, and
 *                             which tier compiled it (Liftoff vs TurboFan)
 * --print-wasm-code        : dumps the real disassembled native code
 *                             V8 generated for each wasm function
 *
 * Add --no-liftoff to force everything straight to TurboFan for a
 * cleaner single-tier comparison (slower startup, optimized steady state).
 *
 * Install:
 *   npm install pyodide
 */
const { loadPyodide } = require("pyodide");

async function main() {
  console.log("Loading Pyodide (CPython + numpy as WASM)...");
  const pyodide = await loadPyodide();

  console.log("Loading numpy package into the WASM runtime...");
  await pyodide.loadPackage("numpy");

  const N = process.argv[2] ? parseInt(process.argv[2]) : 1_000_000;
  const REPS = process.argv[3] ? parseInt(process.argv[3]) : 2000;

  const pyCode = `
import time
import numpy as np

print("numpy version:", np.__version__)

N = ${N}
REPS = ${REPS}

a = np.random.rand(N).astype(np.float64)
b = np.random.rand(N).astype(np.float64)

# Warmup: this is also where V8 tiers wasm functions up from
# Liftoff to TurboFan if they get hot enough.
for _ in range(10):
    c = np.add(a, b)

t0 = time.perf_counter()
for _ in range(REPS):
    c = np.add(a, b)
t1 = time.perf_counter()

elapsed = t1 - t0
per_call = elapsed / REPS
throughput = N * REPS / elapsed / 1e9

print(f"Elements per array : {N:,}")
print(f"Repetitions        : {REPS:,}")
print(f"Total time          : {elapsed:.4f} s")
print(f"Time per call       : {per_call*1e6:.2f} us")
print(f"Throughput          : {throughput:.3f} G-elements/s")
`;

  await pyodide.runPythonAsync(pyCode);
}

main();
