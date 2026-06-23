"""
Native CPython + numpy benchmark for a trivial op: c = a + b
Run long enough that any JIT-equivalent warmup (numpy's own dispatch
table lookup) has settled, then time the steady-state loop.

Usage:
    python bench/bench.py [N_ELEMENTS] [N_REPS]
"""
import sys
import time
import numpy as np

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
REPS = int(sys.argv[2]) if len(sys.argv) > 2 else 2000

print(f"numpy version: {np.__version__}")
print(f"numpy config (look for AVX2/AVX512):")
np.show_config()

a = np.random.rand(N).astype(np.float64)
b = np.random.rand(N).astype(np.float64)

# Warmup (let numpy resolve its internal dispatch table / fault in pages)
for _ in range(10):
    c = np.add(a, b)

t0 = time.perf_counter()
for _ in range(REPS):
    c = np.add(a, b)
t1 = time.perf_counter()

elapsed = t1 - t0
per_call = elapsed / REPS
throughput = N * REPS / elapsed / 1e9

print(f"\nElements per array : {N:,}")
print(f"Repetitions        : {REPS:,}")
print(f"Total time          : {elapsed:.4f} s")
print(f"Time per call       : {per_call*1e6:.2f} us")
print(f"Throughput          : {throughput:.3f} G-elements/s")

# Print the path to the compiled extension so disasm.sh can find symbols
_umath = getattr(np, "_core", np.core)._multiarray_umath
print(f"\nCompiled extension: {_umath.__file__}")
