"""
Fallback approach: numpy's inner SIMD loops are frequently *static*
functions, invisible to `nm -D` (dynamic symbol table only). If
scripts/disasm.sh finds nothing useful, use this gdb script instead,
which breaks on the umath dispatch entry point and disassembles
whatever's actually running.

Usage:
    gdb -q -x scripts/gdb_disasm.py --args python3 bench/bench.py 1000 5
"""
import gdb

gdb.execute("set pagination off")

# Break on the generic ufunc inner-loop dispatcher. Exact symbol name
# varies by numpy version; try these in order until one sticks.
candidates = [
    "DOUBLE_add",
    "npy_DOUBLE_add",
    "BINARY_DEFS",          # fallback marker, won't be an exact match
]

bp = None
for name in candidates:
    try:
        bp = gdb.Breakpoint(name)
        print(f"[gdb_disasm] breakpoint set on {name}")
        break
    except gdb.error:
        continue

if bp is None:
    print("[gdb_disasm] No symbol matched. Run:")
    print("  (gdb) info functions add")
    print("inside an interactive `gdb python3` session to find the real name,")
    print("then set the breakpoint manually and run `disassemble`.")
else:
    gdb.execute("run")
    print("\n=== Live disassembly of the function currently executing ===")
    gdb.execute("disassemble")
