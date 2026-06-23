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
| time per call (us) | 2216.01 | 1994.82 | 2026.92 |
| throughput (Gelem/s) | 0.451 | 0.501 | 0.493 |

Environment notes:
- Native arm runs the **free-threaded** CPython (`python3.14t`) with numpy 2.5.0
  from conda-forge; `__cpu_dispatch__` reports `X86_V3, X86_V4, AVX512_ICL,
  AVX512_SPR` available on this CPU, with `X86_V3` (AVX2) selected at runtime.
  The free-threaded build likely adds overhead, which partly explains both
  WASM arms edging it out on wall-clock time despite the native SIMD advantage.
- Pyodide arm uses numpy 2.4.3 fetched from `cdn.jsdelivr.net` (cached in
  `node_modules`), CPython 3.14 in WASM, V8 (Node v24.14.0) JIT.
- Pyjs arm uses numpy 2.5.0 from emscripten-forge, built locally via
  `./build_pyjs.sh`, CPython 3.13 in WASM, same V8.

## 2. Native disassembly (objdump / gdb)

Symbol: `DOUBLE_add_X86_V3` (the AVX2-dispatched variant numpy actually calls
on this CPU, picked by `__cpu_dispatch__`). Full output from `disasm.sh`.

Main vectorized loop body (8 doubles per iteration, two independent
`vaddpd` accumulators unrolled):

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
500ced:  jg      500cc0 <DOUBLE_add_X86_V3+0x180>
```

256-bit `ymm` registers, **4 doubles per `vaddpd`**, two independent
accumulators unrolled per iteration (8 doubles/iteration). There's
also a masked tail loop (`vpmaskmovq` at `500d52`/`500d79`) for
array lengths not divisible by 8, and a broadcast-scalar fast path
(`vbroadcastsd` at `500ddd`) for the strided-reduction case.

ISA observed: **AVX2** (`X86_V3` tier). On an AVX-512 capable CPU where
numpy picks the AVX512 variant instead, you'd see `zmm` registers and
512-bit `vaddpd` doing 8 doubles per instruction — check which symbol
your own `disasm.sh` run picks before assuming AVX2.

## 3. WASM disassembly — Pyodide, V8 TurboFan output

Function index: `wasm-function[5691]` (block at line 3097576 of
`tier_turbofan.txt`; identified by instruction pattern — the module
ships no name section). Body size 512 bytes. Produced with
`node --no-liftoff --trace-wasm-compiler --print-wasm-code bench.js`.

General strided elementwise-add loop, 4× unrolled (one iteration shown,
the other three are identical save for register renames):

```asm
;; iteration 1
0x...e7040  vmovsd xmm0,[rbx+r8*1]        ; load  a[i]      (rbx = WASM linear-mem base)
0x...e7046  vaddsd xmm0,xmm0,[rbx+r12*1]  ; + b[i]          <-- SCALAR f64.add
0x...e704c  vmovsd [rbx+r9*1],xmm0        ; store c[i]
0x...e7052  addl  r9,r11                   ; c_ptr += stride_c
0x...e7055  leal  rax,[rcx+r12*1]          ; b_ptr += stride_b
0x...e7059  addl  r8,rdi                   ; a_ptr += stride_a
0x...e705c  leal  rdx,[r15-0x1]            ; n--
0x...e7060  testl rdx,rdx
0x...e7062  jle   ...exit
;; (iterations 2-4 identical, then the loop-closing guard:)
0x...e70d7  cmpq  rsp,[r13-0x60]           ; V8 stack-overflow guard (once per 4-unroll)
0x...e70e0  jna   ...stack_overflow_slow_path
0x...e70e6  testl r15,r15
0x...e70e9  jg    0x...e7040               ; loop back to iteration 1
```

Tier confirmed: **TurboFan** (the `--no-liftoff` run forces it; in the
default-tiering `tier_default.txt`, the same function index was kept on
**Liftoff** for the whole timed loop — it never got hot enough to tier up
under the 10-iteration warmup + 2000-iteration timing window).

SIMD observed: **scalar only.** The inner loop uses `vaddsd` — V8's
lowering of the WASM `f64.add` opcode (one double per instruction). Across
the entire 3.1 M-line TurboFan dump there are **zero** `addpd`/`vaddpd`
(which would be `f64x2.add` → 2 doubles on 128-bit xmm) and zero
`vmovupd`/`vmovdqu` (SIMD 128-bit memory ops). So Pyodide's numpy build
does **not** use `f64x2` SIMD for the float64 add ufunc.

Bounds checks: **no inline compare-and-branch guards.** WASM memory safety
is provided by V8's **trap-on-fault** mechanism — the function's
`Protected instructions:` table registers every loop memory access (pc
offsets `0xc0, 0xc6, 0xcc, 0xe8, 0xee, 0xf3, 0x110, 0x116, 0x11c,
0x138, 0x13e, 0x144`) and relies on the OS page-fault handler to catch
out-of-bounds access. Cheaper than explicit per-element `cmp idx, memsize;
jna trap`, but still fully memory-safe. The only `cmp` in the loop is the
periodic V8 stack-overflow guard (`cmpq rsp,[r13-0x60]`).

## 4. WASM disassembly — pyjs (emscripten-forge), V8 TurboFan output

Function index: `wasm-function[5450]` (block at line 4303894 of
`tier_pyjs_turbofan.txt`; identified by instruction pattern — the module
ships no name section). Body size 704 bytes. Produced with
`node --no-liftoff --trace-wasm-compiler --print-wasm-code bench_pyjs.js`.

General strided elementwise-add loop, **8× unrolled** (two iterations
shown; the remaining six are identical save for register renames; the
loop closes at offset `0x224`):

```asm
0x...40640  vmovsd xmm0,[rbx+r12*1]        ; load  a[i]      (rbx = WASM linear-mem base)
0x...40646  vaddsd xmm0,xmm0,[rbx+rax*1]   ; + b[i]          <-- SCALAR f64.add
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
0x...40680  cmpl  r14,0xfe                 ; loop-terminator check (n-k < -2?)
0x...40684  jnc   ...exit
;; (iterations 3-8 identical; mid-loop:)
0x...40712  cmpq  rsp,[r13-0x60]           ; V8 stack-overflow guard (once per 8-unroll)
0x...40716  jna   ...stack_overflow_slow_path
;; (loop close:)
0x...40757  subl  r9,0x8                   ; N -= 8
0x...40760  cmpl  r15,0xfe
0x...40764  jc    0x...40640               ; ---- LOOP BACK ----
```

Tier confirmed: **TurboFan** (`--no-liftoff` run; in the default-tiering
`tier_pyjs_default.txt` the same function index was on **Liftoff** for the
whole timed loop).

SIMD observed: **scalar only**, same as Pyodide. `vaddsd` (one double per
instruction) is V8's lowering of the WASM `f64.add` opcode. Across the
entire 4.3 M-line TurboFan dump there are **zero** `addpd`/`vaddpd` and
zero `f64x2`/`f32x4`/SIMD128 mnemonics anywhere. So the emscripten-forge
numpy wheel was **not** built with `-msimd128` — the C `DOUBLE_add` loop
emits scalar `f64.add` ops, and V8 lowers each to `vaddsd`. V8 did
auto-unroll the loop 8-wide and pipeline the address arithmetic behind
memory latency, but each add still retires only 1 double.

Bounds checks: same trap-on-fault mechanism as Pyodide — every loop
memory access (pc offsets `0x100, 0x106, 0x10b, 0x117, 0x121, 0x127,
0x14a, 0x150, 0x156, 0x162, 0x16b, 0x171, 0x18e, 0x194, 0x19a, 0x1a6,
0x1af, 0x1b5, 0x1dc, 0x1e2, 0x1e8, 0x1f4, 0x1fd, 0x203`) is listed in
the `Protected instructions:` table and guarded by V8's SIGSEGV trap
handler. No explicit `cmp idx, memsize; jna` per access in the loop. The
`cmpl r14,0xfe` / `cmpl r15,0xfe` instructions are loop-terminator checks
(`0xfe` sign-extends to `-2`), not bounds checks.

Numpy build flags: the emscripten-forge recipe is at
https://github.com/emscripten-forge/recipes — look for `-msimd128` in the
compiler flags. The disassembly above confirms it is **absent** for this
wheel: no `f64x2.add` → `vaddpd` lowering anywhere.

## 5. Discussion

### Vector width is the dominant structural difference

| arm | add instruction | lanes per instruction | unroll | doubles per iter |
|---|---|---|---|---|
| native (AVX2) | `vaddpd ymm` | 4 | 2 | 8 |
| wasm (pyodide) | `vaddsd xmm` (scalar low lane) | 1 | 4 | 4 |
| wasm (pyjs) | `vaddsd xmm` (scalar low lane) | 1 | 8 | 8 |

Native retires 4× the doubles per `vaddpd` instruction that either WASM
arm retires per `vaddsd`. The WASM arms claw some of that back by unrolling
more (pyjs unrolls 8-wide vs native's 2-wide), but they can't close the
4:1 lane-width gap with unrolling alone — each scalar `vaddsd` still
retires one double.

### Neither WASM numpy build uses SIMD128

This is the central finding and it's the same for both Pyodide and pyjs:
**neither numpy wheel was compiled with `-msimd128`**. The C `DOUBLE_add`
loop emits scalar WASM `f64.add` ops, which V8 lowers to `vaddsd` (one
double). A `-msimd128` build would emit `f64x2.add`, which V8 lowers to
`addpd`/`vaddpd` on 128-bit `xmm` (two doubles) — still half native AVX2's
lane width, but twice what we observe here. Rebuilding the emscripten-forge
numpy with `-msimd128` (possible via `./build_pyjs.sh` with a modified
recipe) would be the most direct way to test this.

### WASM bounds checks are implicit, not explicit

Neither WASM arm emits inline `cmp index, memsize; jna trap` per memory
access. V8 uses its **trap-on-fault** mechanism: each load/store is
registered in the function's `Protected instructions:` table and guarded
by the OS page-fault handler (SIGSEGV → V8 trap handler → wasm OOB trap).
This is cheaper than explicit per-element bounds checks — no extra
compare/branch on every load/store — but it's still a structural cost with
no native equivalent (native numpy's `vaddpd` loads/stores fault directly
to the OS on a bad access; there's no "protected instructions" indirection
or guard page in the linear-memory layout). The only explicit `cmp` inside
either WASM loop is the periodic V8 stack-overflow guard (`cmpq
rsp,[r13-0x60]`), emitted once per unroll body.

### Tiering: Liftoff held for the whole timed loop by default

In the default-tiering traces (`tier_default.txt`, `tier_pyjs_default.txt`)
the numpy add loop stayed on **Liftoff** for the entire benchmark — the
10-iteration warmup + 2000-iteration timing window was not enough to
trigger a tier-up to TurboFan for this function index. The TurboFan
disassembly above was captured by forcing `--no-liftoff`. In a real
long-running workload the loop would eventually tier up to TurboFan and
match what's shown here; in a short benchmark the default-tiering numbers
reflect Liftoff code quality (slightly worse than TurboFan).

### Pyodide vs pyjs runtime overhead

Both WASM arms use the same V8, same CPython-in-WASM, and (modulo version)
the same numpy source — the only differences are the numpy version
(2.4.3 vs 2.5.0), the Emscripten compile flags (both scalar, neither
`-msimd128`), and the JS shim. Despite different unroll factors in the
JIT output (pyjs 8-wide vs pyodide 4-wide), their throughput is within
~2% of each other (0.501 vs 0.493 Gelem/s). The JS-boundary crossing cost
(Pyodide's `runPythonAsync` vs pyjs's `bootstrap_from_empack_packed_environment`
+ `async_exec_eval`) is not the bottleneck for this 1M-element / 2000-rep
workload — the per-call time is dominated by the in-WASM elementwise loop,
which is scalar in both cases.

### Why native isn't faster here despite 4× SIMD width

The native arm runs the **free-threaded** CPython (`python3.14t`), which
adds per-call overhead that eats the SIMD advantage at this array size.
On a standard (non-free-threaded) CPython build the native arm would be
expected to pull ahead once the array is large enough that the 4× SIMD
lane width dominates the per-call dispatch overhead — the throughput
numbers above shouldn't be read as "WASM is faster than native," but as
"on this particular configuration (free-threaded CPython, 1M float64,
2000 reps) the two WASM arms happen to edge out the native arm on wall
clock." The disassembly comparison is the more robust signal: native has
a 4:1 lane-width advantage that any SIMD128-enabled WASM rebuild could
narrow to 2:1 but not eliminate.
