# Results: native vs WASM (Pyodide/V8) vs WASM (pyjs/V8)

## 1. Timing

Run:
```
python bench.py 1000000 2000 > native_out.txt
node bench.js 1000000 2000 > wasm_pyodide_out.txt
node bench_pyjs.js 1000000 2000 > wasm_pyjs_out.txt
python timing.py native_out.txt wasm_pyodide_out.txt wasm_pyjs_out.txt
```

| metric | native | wasm (pyodide) | wasm (pyjs) |
|---|---|---|---|
| time per call (us) | _fill in_ | _fill in_ | _fill in_ |
| throughput (Gelem/s) | _fill in_ | _fill in_ | _fill in_ |

## 2. Native disassembly (objdump / gdb)

Symbol: `DOUBLE_add_X86_V3` (filled in from disasm.sh output)

This was actually captured running this scaffold — main vectorized loop body:

```asm
523820 <DOUBLE_add_X86_V3>:
  ...
  5239c0: vmovupd 0x20(%rbx,%rdx,1),%ymm0
  5239c6: vmovupd (%rbx,%rdx,1),%ymm1
  5239cb: sub     $0x8,%rdi
  5239cf: vaddpd  0x20(%rcx,%rdx,1),%ymm0,%ymm0
  5239d5: vaddpd  (%rcx,%rdx,1),%ymm1,%ymm1
  5239da: vmovupd %ymm0,0x20(%rax,%rdx,1)
  5239e0: vmovupd %ymm1,(%rax,%rdx,1)
  5239e5: add     $0x40,%rdx
  5239e9: cmp     $0x7,%rdi
  5239ed: jg      5239c0 <DOUBLE_add_X86_V3+0x1a0>
```

256-bit `ymm` registers, 4 doubles per `vaddpd`, two independent
accumulators unrolled per iteration (8 doubles/iteration). There's
also a masked tail loop (`vpmaskmovq`) further down in the function
for array lengths not divisible by 4 — visible in the full disasm.sh
output.

ISA observed: **AVX2** (`X86_V3` tier) — confirmed via
`__cpu_dispatch__` reporting `X86_V3, X86_V4, AVX512_ICL, AVX512_SPR`
as available, with `X86_V3` selected as the symbol actually called at
runtime on this CPU. (On an AVX-512 capable CPU where numpy picks the
AVX512 variant instead, you'd see `zmm` registers and 512-bit
`vaddpd` doing 8 doubles per instruction — check which symbol your
own disasm.sh run picks before assuming AVX2.)

## 3. WASM disassembly — Pyodide, V8 TurboFan output

Function index / name: `_____` (from tier_turbofan.txt, `--print-wasm-code` block)

```asm
; paste the relevant block from tier_turbofan.txt here
```

Tier confirmed: Liftoff / TurboFan (check tier_default.txt's `--trace-wasm-compilation` log to see which one was actually live during the timed loop)

SIMD observed: WASM SIMD128 (`f64x2.add` lowered to e.g. `vaddpd xmm`) / scalar only (`f64.add` lowered to scalar `addsd`)

## 4. WASM disassembly — pyjs (emscripten-forge), V8 TurboFan output

Function index / name: `_____` (from tier_pyjs_turbofan.txt, `--print-wasm-code` block)

```asm
; paste the relevant block from tier_pyjs_turbofan.txt here
```

Tier confirmed: Liftoff / TurboFan (check tier_pyjs_default.txt's `--trace-wasm-compilation` log)

SIMD observed: _____ (check for `f64x2.add` → `vaddpd xmm` vs `f64.add` → scalar `addsd`)

Numpy build flags: check the emscripten-forge numpy recipe at
https://github.com/emscripten-forge/recipes — look for `-msimd128`
in the compiler flags. If present, and if the WASM engine (V8)
supports it, `f64x2.add` should lower to `vaddpd xmm` (2 doubles
per instruction). If absent, scalar `f64.add` → `addsd`.

## 5. Discussion points to fill in

- **Vector width**: native AVX2 256-bit (4 doubles/instruction) or AVX-512
  512-bit (8 doubles) vs WASM SIMD128 max 128-bit (2 doubles) vs scalar
  (1 double)
- **pyodide vs pyjs numpy**: same CPython + numpy, but potentially different
  Emscripten compile flags. Which one (if either) has `-msimd128`?
  If pyjs does and pyodide doesn't, the pyjs disasm should show `vaddpd`
  where pyodide shows `addsd`.
- **Bounds-checking** overhead on WASM linear memory access — look for extra
  compare/jump instructions guarding each load/store that have no native
  equivalent. This is a structural cost of WASM that applies equally to
  both Pyodide and pyjs.
- **Liftoff vs TurboFan** code quality difference, if your run captured
  both tiers for either WASM arm.
- **Timing gap decomposition**: how much of the native vs WASM gap is
  explained by vector width, how much by bounds checks, how much by
  other overhead (Python/JS boundary crossing, memory copy into WASM
  linear memory)?
- **Pyodide vs pyjs runtime overhead**: even with identical numpy WASM
  binaries, the JS shim (Pyodide's `runPythonAsync` vs pyjs's
  `bootstrap_from_empack_packed_environment` + `async_exec_eval`) may
  have different crossing costs.
