# numpy: native vs WASM (Pyodide/V8) vs WASM (pyjs/V8) — real machine code comparison

Compares `np.add(a, b)` on float64 arrays executed:
1. **Natively** — CPython + numpy compiled ahead-of-time to x86-64
2. **In WASM (Pyodide)** — CPython + numpy JIT-compiled by V8 (Node.js)
3. **In WASM (pyjs/emscripten-forge)** — CPython + numpy from emscripten-forge, JIT-compiled by V8 (Node.js)

The goal is to capture the *actual machine code each one executes*,
not just timing numbers.

## Reproducible environment (Nix VM)

All three arms are designed to run inside a NixOS VM for reproducible
results — same CPU model, same toolchain versions, same build flags for
everyone who clones the repo.

```bash
# Build the VM (takes a few minutes first time; cached after)
nix build .#nixosConfigurations.devvm.config.system.build.vm

# Run the VM
./result/bin/run-nixos-vm
```

The VM boots a NixOS with:
- Python 3, Node.js, gcc, gdb, binutils, objdump, nm
- micromamba (for conda envs) + empack (for pyjs packaging)
- ungoogled-chromium

Log in as `generic` (password: `generic`). SSH is available on
port 2222 (on the host).

Inside the VM, enter the FHS dev shell:

```bash
nix develop /path/to/benchmarks
```

This drops you into a shell with all the tooling above on PATH.
The repo should be checked out inside the VM (or mounted via virtiofs).

## Setup (inside the VM / FHS shell)

Native side:
```bash
pip install numpy
```

Pyodide side:
```bash
npm install pyodide
```

Pyjs side (builds numpy + CPython + pyjs from emscripten-forge):
```bash
./build_pyjs.sh
```

## Run

```bash
# 1. Native timing + disassembly
python bench.py 1000000 2000
bash disasm.sh
# if nm -D finds nothing (static/stripped symbols), fall back to:
gdb -q -x gdb_disasm.py --args python3 bench.py 1000 5

# 2. WASM (Pyodide) timing + V8 JIT disassembly
bash run.sh 1000000 2000
# inspect tier_default.txt and tier_turbofan.txt (pyodide runs)
# inspect tier_pyjs_default.txt and tier_pyjs_turbofan.txt (pyjs runs)

# 3. Side-by-side timing table
python bench.py 1000000 2000 > native_out.txt
node bench.js 1000000 2000 > wasm_pyodide_out.txt
node bench_pyjs.js 1000000 2000 > wasm_pyjs_out.txt
python timing.py native_out.txt wasm_pyodide_out.txt wasm_pyjs_out.txt
```

## What to look for

- **Native**: numpy dispatches to a SIMD-specific loop at runtime
  (`__cpu_dispatch__`); you want the symbol actually selected on your
  CPU (AVX2/AVX512/SSE2), not just whichever appears first in the
  symbol table.
- **WASM (Pyodide)**: confirm which V8 tier ran during your timed loop
  (`--trace-wasm-compilation` log), and whether Pyodide's numpy build
  was compiled with `-msimd128` at all.
- **WASM (pyjs)**: numpy from emscripten-forge; build flags are
  inspectable via the emscripten-forge recipe. Check whether
  `-msimd128` was used (common for emscripten-forge WASM packages).
  Since you build locally, you can rebuild with different flags for
  a controlled comparison.
- Bounds-checks on WASM linear memory accesses are a structural cost
  with no native equivalent — look for them in the TurboFan output.
- Compare the Pyodide vs pyjs V8 output: same numpy version, same
  CPython, but possibly different compile flags → different
  instruction sequences from V8's JIT.

## Three-way comparison

| arm | runtime | numpy source | SIMD128 flags |
|---|---|---|---|
| native | CPython (host) | pip / conda-forge | N/A (native AVX2/AVX512) |
| wasm (pyodide) | CPython → Emscripten → V8 JIT | cdn.jsdelivr.net | unknown (likely no -msimd128) |
| wasm (pyjs) | CPython → Emscripten → V8 JIT | built locally from emscripten-forge | inspectable / rebuildable |

## Known limitations

- The Pyodide arm fetches numpy from `cdn.jsdelivr.net` at runtime.
  This works inside the VM (normal internet access) but may fail in
  sandboxes with egress restrictions.
- The pyjs arm builds numpy locally — no CDN fetch needed.
- Native disassembly is CPU-dependent. Run inside the VM to get a
  reproducible baseline (VM's CPU model is pinned by the NixOS config).
