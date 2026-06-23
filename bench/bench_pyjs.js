/*
 * Same benchmark (c = a + b on float64 arrays) but running numpy
 * inside pyjs (CPython + numpy compiled to WebAssembly via
 * emscripten-forge), under Node.
 *
 * Unlike the Pyodide variant (bench.js), the numpy package is
 * built locally via ./scripts/build_pyjs.sh and served from
 * ./packages/*.tar.gz at the repo root — no runtime CDN fetch.
 * Build flags (e.g. -msimd128) are determined by the
 * emscripten-forge recipe.
 *
 * To get the *actual executed native machine code* (not the static
 * .wasm bytecode), run with V8 disassembly flags, e.g.:
 *
 *   node --trace-wasm-compiler --print-wasm-code bench/bench_pyjs.js \
 *     > wasm_pyjs_trace.txt 2>&1
 *
 * --trace-wasm-compiler : logs each function as it compiles, and
 *                             which tier compiled it (Liftoff vs TurboFan)
 * --print-wasm-code        : dumps the real disassembled native code
 *                             V8 generated for each wasm function
 *
 * Add --no-liftoff to force everything straight to TurboFan.
 *
 * Build first:
 *   ./scripts/build_pyjs.sh
 */
const fs = require("fs");
const path = require("path");

// The pyjs runtime files and empack-packed env live at the repo root
// (produced by scripts/build_pyjs.sh); this script lives in bench/.
const REPO_ROOT = path.join(__dirname, "..");

// The pyjs runtime is browser-oriented: it loads the wasm, the empack
// meta JSON, and every package tarball via fetch(). Node's undici fetch
// rejects bare filesystem paths and file:// URLs, so shim global fetch
// to serve local files from disk while passing real http(s) URLs through.
const _origFetch = globalThis.fetch;
globalThis.fetch = async function fetchLocal(input, init) {
  const url = typeof input === "string" ? input : input && input.url;
  if (url && (url.startsWith("/") || url.startsWith("file:"))) {
    const fsPath = url.startsWith("file:") ? new URL(url).pathname : url;
    const buf = fs.readFileSync(fsPath);
    return new Response(new Uint8Array(buf), {
      status: 200,
      headers: { "Content-Type": "application/octet-stream" },
    });
  }
  return _origFetch(input, init);
};

const createModule = require(path.join(REPO_ROOT, "pyjs_runtime_browser.js"));

async function main() {
  console.log(
    "Loading pyjs runtime (CPython + numpy as WASM from emscripten-forge)...",
  );
  // Node's fetch() cannot load bare filesystem paths or file:// URLs, so
  // read the wasm binary ourselves and hand it to the emscripten module
  // via wasmBinary — this bypasses the streaming/instantiateWasm fetch path.
  const wasmPath = path.join(REPO_ROOT, "pyjs_runtime_browser.wasm");
  const pyjs = await createModule({
    wasmBinary: fs.readFileSync(wasmPath),
    locateFile: (f) => path.join(REPO_ROOT, f),
  });

  console.log("Bootstrapping empack-packed environment...");
  await pyjs.bootstrap_from_empack_packed_environment(
    path.join(REPO_ROOT, "empack_env_meta.json"),
    path.join(REPO_ROOT, "packages") + "/",
  );

  const N = process.argv[2] ? parseInt(process.argv[2]) : 1_000_000;
  const REPS = process.argv[3] ? parseInt(process.argv[3]) : 2000;

  // Return timing info as JSON so we don't depend on pyjs's stdout
  // routing in Node. JS side prints in the same format as bench.js.
  const pyCode = `
import json
import time
import numpy as np

N = ${N}
REPS = ${REPS}

a = np.random.rand(N).astype(np.float64)
b = np.random.rand(N).astype(np.float64)

# Warmup: also lets V8 tier wasm functions up from
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

json.dumps({
    "numpy_version": np.__version__,
    "elapsed_s": round(elapsed, 4),
    "per_call_us": round(per_call * 1e6, 2),
    "throughput_gelem_s": round(throughput, 3),
})
`;

  const result = JSON.parse(await pyjs.async_exec_eval(pyCode));

  // Print timing in exact same format as bench.js and bench.py.
  // timing.py parses: "Time per call       : XX.XX us"
  //                    "Throughput          : X.XXX G-elements/s"
  console.log("numpy version:", result.numpy_version);
  console.log(`Elements per array : ${N.toLocaleString()}`);
  console.log(`Repetitions        : ${REPS.toLocaleString()}`);
  console.log(`Total time          : ${result.elapsed_s.toFixed(4)} s`);
  console.log(
    `Time per call       : ${result.per_call_us.toFixed(2)} us`,
  );
  console.log(
    `Throughput          : ${result.throughput_gelem_s.toFixed(3)} G-elements/s`,
  );
}

main();
