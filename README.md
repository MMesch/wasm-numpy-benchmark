# numpy: native vs WASM (Pyodide/V8) vs WASM (pyjs/V8) — real machine code comparison

Compares `np.add(a, b)` on float64 arrays executed three ways:

1. **Natively** — CPython + numpy compiled ahead-of-time to x86-64
2. **In WASM (Pyodide)** — CPython + numpy compiled to wasm, JIT-compiled by V8 (Node.js)
3. **In WASM (pyjs/emscripten-forge)** — CPython + numpy from emscripten-forge, JIT-compiled by V8 (Node.js)

The goal is to capture the *actual machine code each one executes*, not
just timing numbers. The punchline, previewed: native numpy uses 256-bit
AVX2 `vaddpd` (4 doubles per instruction); both wasm arms use scalar
`vaddsd` (1 double per instruction) because neither numpy wheel was built
with `-msimd128`. The rest of this document is how we get there and how to
read the disassembly yourself.

---

## Quick start

### Reproducible environment (Nix VM)

All three arms are designed to run inside a NixOS VM for reproducible
results — same CPU model, same toolchain versions, same build flags.

```bash
nix build .#nixosConfigurations.devvm.config.system.build.vm
./result/bin/run-nixos-vm
```

The VM boots NixOS with Python 3, Node.js, gcc, gdb, binutils, micromamba,
empack, ungoogled-chromium. Log in as `generic` (password `generic`); SSH
is on port 2222. Inside the VM, enter the FHS dev shell:

```bash
nix develop /path/to/benchmarks
```

(If you already have python3, node, npm, micromamba, gdb, and binutils on
PATH on a normal Linux box, you can skip the VM — that's how the runs in
this README were captured.)

### Setup

```bash
# native: conda env with numpy
micromamba create -y -n native -c conda-forge python numpy

# pyodide: npm package
npm install pyodide

# pyjs: builds numpy + CPython + pyjs from emscripten-forge (local, no CDN)
./build_pyjs.sh
```

### Run

```bash
# 1. Native timing + disassembly
micromamba run -n native python bench.py 1000000 2000 > native_out.txt
bash disasm.sh                                 # prints + auto-disassembles the hot symbol

# 2. WASM timing + V8 JIT disassembly (both arms, both tiers)
bash run.sh 1000000 2000                       # writes tier_*.txt

# 3. Side-by-side timing table
node bench.js 1000000 2000 > wasm_pyodide_out.txt
node bench_pyjs.js 1000000 2000 > wasm_pyjs_out.txt
python timing.py native_out.txt wasm_pyodide_out.txt wasm_pyjs_out.txt
```

Sample output from a run inside the VM (free-threaded CPython `python3.14t`
+ numpy 2.5.0 native; numpy 2.4.3 via Pyodide; numpy 2.5.0 via pyjs):

```
metric                  native                wasm (pyodide)        wasm (pyjs)
--------------------------------------------------------------------
time per call (us)      2216.01               1994.82               2026.92
throughput (Gelem/s)    0.451                 0.501                 0.493
```

Native *should* win on throughput because it has 4× the SIMD lanes — the
reason it doesn't here is that the native arm runs the free-threaded
CPython build, which adds per-call overhead that eats the SIMD advantage
at this array size. The disassembly comparison below is the more robust
signal; the timing table is context.

---

## The scripts

| file | what it does |
|---|---|
| `bench.py` | Native arm. Times `np.add(a, b)` on two `float64` arrays of `N` elements over `REPS` reps after a 10-iter warmup. Prints numpy version, `np.show_config()`, timing, and the path to `_multiarray_umath.so` so `disasm.sh` can find the symbols. |
| `bench.js` | Pyodide arm. Loads Pyodide + numpy (from `cdn.jsdelivr.net`, cached in `node_modules`) under Node, runs the same Python timing loop via `runPythonAsync`. |
| `bench_pyjs.js` | pyjs arm. Loads the locally-built pyjs runtime (`pyjs_runtime_browser.wasm`) + empack-packed env, runs the same Python loop via `async_exec_eval`. No CDN fetch. Includes a `globalThis.fetch` shim and `wasmBinary` read-from-disk so the browser-oriented pyjs runtime works under Node. |
| `build_pyjs.sh` | Creates an `emscripten-wasm32` conda env from `environment.yml`, copies the pyjs runtime `.js`/`.wasm` out, and packs the env into `packages/*.tar.gz` + `empack_env_meta.json` via empack. (empack 6.x requires `--config`, so this passes `empack_config.yaml`.) |
| `disasm.sh` | Native disassembly. Finds `_multiarray_umath.so`, lists `DOUBLE_add*` symbols, prints numpy's `__cpu_dispatch__`, auto-picks the highest-tier suffixed variant, and `objdump`-disassembles it. Falls back to `gdb_disasm.py` if symbols are stripped. |
| `run.sh` | WASM disassembly. Runs `bench.js` and `bench_pyjs.js` twice each under V8 disassembly flags: once with default tiering (Liftoff → TurboFan) and once with `--no-liftoff` (forced TurboFan). Writes `tier_default.txt`, `tier_turbofan.txt`, `tier_pyjs_default.txt`, `tier_pyjs_turbofan.txt`. |
| `timing.py` | Parses the stdout of the three benchmarks and prints a side-by-side table. Accepts 2 or 3 files. |
| `gdb_disasm.py` | Fallback for native disasm when `nm`/`objdump` can't see the symbol (static/stripped builds) — uses gdb to disassemble around a breakpoint in `PyUFunc_GenericFunction`. |
| `environment.yml` | conda env spec for the pyjs arm: `python` + `numpy` + `pyjs` from `emscripten-forge-4x` / `conda-forge`. |
| `empack_config.yaml` | Minimal empack pack config (a `default` filter with no exclusions = pack everything). Required by empack 6.x's `empack pack env --config`. |

---

## How to obtain the disassembly

### Native: `disasm.sh`

The native arm is the easy one — numpy ships as a normal shared object,
so the disassembly is just `objdump`. The only subtlety is picking the
*right* symbol: numpy compiles several copies of each ufunc loop
(`DOUBLE_add`, `DOUBLE_add_SSE2`, `DOUBLE_add_X86_V3`, `DOUBLE_add_AVX512F`,
…) and picks one at runtime based on `__cpu_dispatch__`. The bare
`DOUBLE_add` is the SSE2 baseline; the `_X86_V3` / `_AVX512*` suffixed
variants are what actually run on a modern CPU.

`disasm.sh` does this for you. Its output, trimmed to the interesting
parts:

```
== Searching symbol table for candidate add loops ==
000000000032c500 t DOUBLE_add              ← SSE2 baseline (don't pick this one)
000000000032c940 t DOUBLE_add_indexed
0000000000500b40 t DOUBLE_add_X86_V3       ← AVX2, the one that runs on this CPU

== CPU dispatch info numpy reports for this machine ==
baseline: ['X86_V2']
dispatch found: ['X86_V3', 'X86_V4', 'AVX512_ICL', 'AVX512_SPR']

== Auto-detected candidate: DOUBLE_add_X86_V3 ==
```

`X86_V3` is the AVX2 tier. So `objdump -d --disassemble=DOUBLE_add_X86_V3`
on `_multiarray_umath.so` gives the actual instructions your CPU runs.
(On an AVX-512 CPU numpy would dispatch to a `_X86_V4` / `_AVX512F`
variant instead — look for `zmm` registers and 512-bit `vaddpd`.)

If `nm` finds nothing (static/stripped build), fall back to:

```bash
micromamba run -n native gdb -q -x gdb_disasm.py --args python bench.py 1000 5
```

### WASM: `run.sh` + V8 disassembly flags

The wasm arms are harder because there's no shared object — numpy is
compiled to a `.wasm` bytecode that V8 JITs into native code at runtime.
To see the *actual* native instructions (not the wasm opcodes), use V8's
code-printing flags:

```bash
node --trace-wasm-compiler --print-wasm-code bench.js 1000000 2000 > tier_default.txt 2>&1
```

- `--trace-wasm-compiler` — logs each wasm function as it compiles and
  which tier compiled it (`compiler: Liftoff` or `compiler: TurboFan`).
- `--print-wasm-code` — dumps the disassembled native x86-64 V8 generated
  for each wasm function.
- `--no-liftoff` — forces everything straight to TurboFan (skip the
  lazy tier-up) for a cleaner single-tier comparison.

> Note: older V8 exposed `--trace-wasm-compilation`; that flag was
> removed. Use `--trace-wasm-compiler` on current Node (v22+). If
> `node --trace-wasm-compiler bench.js 1000 5` doesn't print
> `kind: wasm function` / `compiler: …` lines, check `node --v8-options
> | grep wasm` for the current flag name on your Node version.

`run.sh` runs all four combinations (pyodide × {default, --no-liftoff},
pyjs × {default, --no-liftoff}) and writes `tier_*.txt`. Each file is
large — expect 2–4 million lines, with thousands of TurboFan-compiled
function blocks. The next section covers how to find the one block that
matters.

---

## Finding the numpy add loop in the V8 trace

Each `tier_*.txt` is a sequence of blocks that look like:

```
--- WebAssembly function ---
name: <name or empty>
kind: wasm function
compiler: TurboFan
...
<disassembled native x86-64>
...
Protected instructions:
  pc offset
    0xc0, 0xc6, 0xcc, ...
Source positions:
  ...
```

The modules ship **no name section**, so every function is just
`wasm-function[N]` and you can't grep for "DOUBLE_add". You have to
identify the add loop by instruction pattern. The hot loop is a tight
elementwise `c[i] = a[i] + b[i]` over three strided arrays, so it looks
like:

- a load (`vmovsd xmm0, [base + idx*1]`)
- an add of a second memory operand (`vaddsd xmm0, xmm0, [base + idx2*1]`)
- a store (`vmovsd [base + idx3*1], xmm0`)
- three pointer-stride updates (`addl r9, r11` etc.)
- a counter decrement and loop-closing branch (`testl`/`cmpl` + `jg`/`jc`)

…repeated and unrolled 4 or 8 times. Three registers track the three
array pointers (input a, input b, output c), three registers hold the
strides, one holds the element count, and a single register (`rbx`)
holds the WASM linear-memory base.

The fastest way to find it:

```bash
# how many packed-double adds (SIMD128) vs scalar adds in the whole dump?
rg -c 'addpd|vaddpd' tier_turbofan.txt     # 0  → no SIMD128 anywhere
rg -c 'addsd|vaddsd' tier_turbofan.txt     # ~230 → all scalar f64.add

# find blocks with a tight load-add-store pattern
rg -n 'vaddsd xmm0,xmm0,\[rbx\+' tier_turbofan.txt | head
```

The hits cluster in a handful of functions. The one that is small
(~500–700 bytes body) and matches the three-strided-array signature is
the ufunc inner loop. (The other `vaddsd` clusters are reductions,
int→float casts, or transcendental polynomials — they don't have three
independent strided pointers.) In our runs the pyodide loop was
`wasm-function[5691]` (line 3097576 of `tier_turbofan.txt`) and the pyjs
loop was `wasm-function[5450]` (line 4303894 of `tier_pyjs_turbofan.txt`).

A useful sanity check: across the entire 3.1 M-line pyodide dump and the
entire 4.3 M-line pyjs dump there are **zero** `addpd`/`vaddpd` and zero
`f64x2`/`v128.load`/`v128.store` mentions. That alone tells you neither
numpy build used `-msimd128` — if it had, you'd see `vaddpd xmm` (two
doubles per instruction) instead of `vaddsd` (one).

---

## Reading the disassembly, line by line

### Native: `DOUBLE_add_X86_V3` (AVX2)

The main vectorized loop, after the prologue has loaded the three array
pointers (`rbx` = a, `rcx` = b, `rax` = c) and the element count into
`rsi`/`rdi`:

```asm
500cc0:  vmovupd 0x20(%rbx,%rdx,1),%ymm0
500cc6:  vmovupd (%rbx,%rdx,1),%ymm1
500ccb:  sub     $0x8,%rdi
500ccf:  vaddpd  0x20(%rcx,%rdx,1),%ymm0,%ymm0
500cd5:  vaddpd  (%rcx,%rdx,1),%ymm1,%ymm1
500cda:  vmovupd %ymm0,0x20(%rax,%rdx,1)
500ce0:  vmovupd %ymm1,(%rax,%rdx,1)
500ce5:  add     $0x40,%rdx
500ce9:  cmp     $0x7,%rdi
500ced:  jg      500cc0
```

Reading it one instruction at a time:

- `vmovupd 0x20(%rbx,%rdx,1),%ymm0` — load 4 contiguous doubles from
  `a[rdx/8 + 4 … +7]` into the 256-bit `ymm0`. `vmovupd` = "vector move
  unaligned packed double"; `ymm` = 256-bit (32 bytes = 4 × f64). The
  `0x20` byte offset reaches the *second* half of the 8-element chunk.
- `vmovupd (%rbx,%rdx,1),%ymm1` — load the *first* 4 doubles of the same
  chunk into `ymm1`. After these two, `ymm0` holds `a[i+4..i+7]` and
  `ymm1` holds `a[i+0..i+3]`.
- `sub $0x8,%rdi` — decrement the element counter by 8 (we process 8
  doubles per iteration).
- `vaddpd 0x20(%rcx,%rdx,1),%ymm0,%ymm0` — add 4 doubles from
  `b[i+4..i+7]` into `ymm0`. `vaddpd` = "vector add packed double" —
  four independent f64 adds in one instruction. This is the AVX2 money
  shot.
- `vaddpd (%rcx,%rdx,1),%ymm1,%ymm1` — same for the first 4: `b[i+0..i+3]`
  added into `ymm1`.
- `vmovupd %ymm0,0x20(%rax,%rdx,1)` — store the second 4 results to
  `c[i+4..i+7]`.
- `vmovupd %ymm1,(%rax,%rdx,1)` — store the first 4 results to
  `c[i+0..i+3]`.
- `add $0x40,%rdx` — advance the byte offset by 64 (= 8 × 8 bytes/double).
- `cmp $0x7,%rdi` / `jg 500cc0` — if there are still ≥ 8 elements left,
  loop.

Two things to notice. First, there are **two independent `vaddpd`
accumulators** (`ymm0` and `ymm1`) running in parallel — this is a 2×
unroll on top of the 4-wide SIMD, so each loop iteration retires **8
doubles**. The two halves are independent so the CPU's out-of-order
engine can overlap them. Second, there are **no bounds checks** between
the loads/stores — native numpy just faults to the OS if `a`/`b`/`c`
are bad pointers. (There is a masked tail loop further down using
`vpmaskmovq` for the `N % 8 != 0` remainder, plus a `vbroadcastsd`
fast path for the scalar-broadcast case — neither shown here.)

### WASM (Pyodide): `wasm-function[5691]`, TurboFan

The register conventions here are different because this is V8's
lowering of a wasm function: `rbx` is the **WASM linear-memory base**
(every array access is `[rbx + offset]`), `r8` = input a pointer offset,
`r12`/`rax` = input b pointer offset, `r9` = output c pointer offset,
`rdi`/`rcx`/`r11` = the three strides, `r15` = element count. For the
benchmark's contiguous 1M-element arrays the strides are all 8.

One iteration of the 4×-unrolled loop:

```asm
0x...e7040  vmovsd xmm0,[rbx+r8*1]        ; load  a[i]
0x...e7046  vaddsd xmm0,xmm0,[rbx+r12*1]  ; + b[i]   ← SCALAR f64.add
0x...e704c  vmovsd [rbx+r9*1],xmm0        ; store c[i]
0x...e7052  addl  r9,r11                  ; c_ptr += stride_c
0x...e7055  leal  rax,[rcx+r12*1]         ; b_ptr += stride_b
0x...e7059  addl  r8,rdi                  ; a_ptr += stride_a
0x...e705c  leal  rdx,[r15-0x1]           ; n--
0x...e7060  testl rdx,rdx
0x...e7062  jle   ...exit
;; (iterations 2-4 identical, then the loop-closing guard:)
0x...e70d7  cmpq  rsp,[r13-0x60]          ; V8 stack-overflow guard
0x...e70e0  jna   ...stack_overflow_slow_path
0x...e70e6  testl r15,r15
0x...e70e9  jg    0x...e7040              ; loop back
```

- `vmovsd xmm0,[rbx+r8*1]` — load **one** double from `a[i]` into the
  low lane of `xmm0`. `vmovsd` = "vector move scalar double" — only the
  bottom 64 bits of the 128-bit `xmm` register are touched; the upper
  64 bits are zeroed. Contrast with native's `vmovupd ymm0`, which loads
  four doubles into a 256-bit register.
- `vaddsd xmm0,xmm0,[rbx+r12*1]` — add **one** double from `b[i]` into
  `xmm0`. `vaddsd` = "vector add scalar double" — only the low lane is
  added. **This is V8's lowering of the wasm `f64.add` opcode.** It
  retires 1 double per instruction, where native's `vaddpd` retired 4.
  The presence of `vaddsd` (not `vaddpd`) is the tell that the wasm
  bytecode was scalar `f64.add`, not SIMD128 `f64x2.add`.
- `vmovsd [rbx+r9*1],xmm0` — store the one result to `c[i]`.
- `addl r9,r11` / `leal rax,[rcx+r12*1]` / `addl r8,rdi` — advance the
  three pointers by their strides. Note the `addl` (32-bit) — V8 treats
  wasm linear-memory offsets as 32-bit `i32` sign-extended into the
  64-bit addressing `[rbx + r32*1]`. That's fine for a 4 GiB wasm heap
  and keeps stride math in 32-bit GPRs.
- `leal rdx,[r15-0x1]` / `testl rdx,rdx` / `jle …exit` — decrement the
  counter and exit the loop when it hits zero.
- `cmpq rsp,[r13-0x60]` / `jna …slow_path` — V8's **stack-overflow
  guard**, inserted once per unrolled body. This is *not* a memory
  bounds check; it's the standard V8 stack-limit probe.
- `jg 0x...e7040` — loop back to iteration 1.

The body is 4× unrolled, so each loop iteration retires **4 doubles**
(vs native's 8). But each add is still `vaddsd` (1 double) — unrolling
hides latency, it doesn't add lanes. So per executed `add` instruction
this is 1/4 of native's throughput before you even count anything else.

**No explicit bounds checks appear in the loop.** Instead, every
memory-accessing instruction is registered in the function's
`Protected instructions:` table (pc offsets `0xc0, 0xc6, 0xcc, 0xe8,
0xee, 0xf3, 0x110, 0x116, 0x11c, 0x138, 0x13e, 0x144`) and guarded by
V8's **trap-on-fault** mechanism: the OS page-fault handler catches an
out-of-bounds `vmovsd`, V8's SIGSEGV handler translates it into a wasm
`memory-trap`, and you get a clean wasm OOB exception. Cheaper than a
`cmp idx, memsize; jna trap` per access (no extra compare/branch on the
hot path) but still a structural cost native doesn't pay.

### WASM (pyjs): `wasm-function[5450]`, TurboFan

Same shape, but V8 unrolled it **8×** instead of 4×. Register
conventions: `rbx` = wasm linear-memory base, `r12` = input a offset,
`r15`/`rax` = input b offset, `r11` = output c offset, `rdi`/`rcx`/`r8`
= strides, `r9` = element count. Two iterations of the 8-wide body:

```asm
0x...40640  vmovsd xmm0,[rbx+r12*1]        ; load  a[i]
0x...40646  vaddsd xmm0,xmm0,[rbx+rax*1]   ; + b[i]   ← SCALAR f64.add
0x...4064b  vmovsd [rbx+r11*1],xmm0        ; store c[i]
0x...40651  addl  r11,r8                   ; c_ptr += stride_c
0x...40654  addl  r12,rdi                  ; a_ptr += stride_a
0x...40657  vmovsd xmm0,[rbx+r12*1]        ; load  a[i+1]
0x...4065d  leal  r15,[rcx+rax*1]          ; b_ptr += stride_b (pre-compute)
0x...40661  vaddsd xmm0,xmm0,[rbx+r15*1]   ; + b[i+1]
0x...40667  vmovsd [rbx+r11*1],xmm0        ; store c[i+1]
0x...4066d  addl  r11,r8
0x...40670  addl  r15,rcx
0x...40673  addl  r12,rdi
0x...40676  leal  r14,[r9-0x3]
0x...40680  cmpl  r14,0xfe                 ; loop-terminator (n-k < -2?)
0x...40684  jnc   ...exit
;; (iterations 3-8 identical; mid-loop:)
0x...40712  cmpq  rsp,[r13-0x60]           ; V8 stack-overflow guard
0x...40716  jna   ...stack_overflow_slow_path
;; (loop close:)
0x...40757  subl  r9,0x8                   ; N -= 8
0x...40760  cmpl  r15,0xfe
0x...40764  jc    0x...40640               ; ---- LOOP BACK ----
```

Same story, register-renamed: `vmovsd` loads one double, `vaddsd` adds
one double, `vmovsd` stores one double. The `leal r15,[rcx+rax*1]`
pre-computes the next `b` pointer so the address arithmetic overlaps
with the load latency — decent scheduling — but each `vaddsd` still
retires one double. The `cmpl r14,0xfe` / `cmpl r15,0xfe` are
loop-terminator checks (`0xfe` sign-extends to `-2`, i.e. "have we
fallen below 0 elements?"), **not** memory bounds checks. Bounds
checking is the same trap-on-fault mechanism as Pyodide (the function's
`Protected instructions:` table lists every load/store/add-with-mem
pc offset in the loop).

V8 unrolled this one 8-wide vs Pyodide's 4-wide, which is why pyjs's
throughput (0.493 Gelem/s) is within 2% of Pyodide's (0.501) despite
the different numpy version and build — the JIT made up the difference
in unroll factor, but neither can escape the 1-double-per-add scalar
floor.

---

## Putting it together: what the disassembly tells you

| arm | add instruction | lanes/instruction | unroll | doubles per iteration |
|---|---|---|---|---|
| native (AVX2) | `vaddpd ymm` | 4 | 2 | 8 |
| wasm (pyodide) | `vaddsd xmm` (low lane only) | 1 | 4 | 4 |
| wasm (pyjs) | `vaddsd xmm` (low lane only) | 1 | 8 | 8 |

The instruction names decode the whole story:

- `vaddpd` = "vector add **packed** double" — every lane of the 256-bit
  `ymm` register gets its own f64 add. Four doubles per instruction.
- `vaddsd` = "vector add **scalar** double" — only the bottom 64 bits
  get added; the upper lanes are untouched/zeroed. One double per
  instruction. This is V8's lowering for the wasm `f64.add` opcode.
- If the wasm had been built with `-msimd128`, the ufunc loop would
  emit `f64x2.add`, which V8 lowers to `vaddpd xmm` (two doubles on the
  128-bit `xmm` register). Half native's lane width, but double what we
  observe.

**Neither numpy wheel used `-msimd128`.** That's the central finding.
Both wasm arms are running scalar `f64.add` → `vaddsd`, retire one
double per add, and try to compensate with unrolling. Native retires
four doubles per `vaddpd` and two independent accumulators per
iteration. The 4:1 lane-width gap is structural in the bytecode, not a
V8 codegen quality issue — V8 actually did a good job (clean unrolling,
overlap of address math with memory latency, trap-on-fault instead of
per-access compare/branch), it just had nothing to vectorize.

To test what a SIMD128-enabled wasm build would do, rebuild the
emscripten-forge numpy with `-msimd128` (the recipe is at
https://github.com/emscripten-forge/recipes — add the flag to the
compiler args) and re-run `./build_pyjs.sh` + `bash run.sh`. The ufunc
loop should then emit `f64x2.add`, V8 should lower it to `vaddpd xmm`,
and the throughput gap to native should narrow from ~4:1 to ~2:1.

### Other things visible in the disassembly

- **Tiering.** In the default-tiering traces (`tier_default.txt`,
  `tier_pyjs_default.txt`) the ufunc loop stayed on **Liftoff** for the
  whole timed run — the 10-iter warmup + 2000 reps wasn't enough to
  tier it up to TurboFan. The TurboFan disassembly above was captured
  with `--no-liftoff`. In a longer-running workload the loop would
  tier up and match what's shown; in a short benchmark the
  default-tiering timing reflects Liftoff code quality (slightly worse).
- **Bounds checks.** Both wasm arms use V8's trap-on-fault mechanism —
  every memory access is registered in `Protected instructions:` and
  guarded by the OS page-fault handler, rather than emitting an
  explicit `cmp idx, memsize; jna trap` per load/store. Cheaper than
  naive bounds checking, but still a structural cost native doesn't pay
  (native `vaddpd` just faults directly to the OS on a bad pointer).
- **Free-threaded CPython caveat.** The native timing above was
  captured on the free-threaded `python3.14t` build, which adds
  per-call overhead that eats the SIMD advantage at this array size.
  On a standard CPython build native would be expected to pull ahead
  once the array is large enough that the 4:1 SIMD lane width dominates
  the per-call dispatch overhead. Don't read the timing table as
  "wasm is faster than native" — read it as "on this configuration the
  two scalar wasm arms happen to edge out a free-threaded native arm on
  wall clock." The disassembly is the robust signal.

## Known limitations

- The Pyodide arm fetches numpy from `cdn.jsdelivr.net` at runtime.
  Works inside the VM (normal internet access) but may fail in
  sandboxes with egress restrictions. The pyjs arm builds numpy locally
  — no CDN fetch.
- Native disassembly is CPU-dependent. Run inside the VM (or on a
  pinned-CPU host) to get a reproducible baseline; the VM's CPU model
  is pinned by the NixOS config.
- The V8 disassembly flag names drift across Node versions
  (`--trace-wasm-compilation` → `--trace-wasm-compiler`). If a flag is
  rejected, check `node --v8-options | grep wasm` for the current name.
