#!/usr/bin/env bash
# Extract real machine code for numpy's float64 add loop.
#
# Usage: ./disasm.sh
#
# Requires: binutils (nm, objdump), python3+numpy
set -euo pipefail

SO_PATH=$(python3 -c "import numpy as np; print(getattr(np, '_core', np.core)._multiarray_umath.__file__)")
echo "Extension: $SO_PATH"
echo

echo "== Searching symbol table for candidate add loops =="
# Numpy's SIMD loops are LOCAL symbols (not in the dynamic export table),
# so use the full symbol table, not `nm -D`. Names look like:
#   DOUBLE_add, DOUBLE_add_X86_V3, DOUBLE_add_AVX512F, etc.
# The _X86_V3/_X86_V4/_AVX512* suffixed one is what actually executes on
# a modern CPU; the bare DOUBLE_add is the SSE2 baseline fallback.
nm "$SO_PATH" 2>/dev/null | grep -i double | grep -i add || true
echo

echo "== CPU dispatch info numpy reports for this machine =="
python3 - <<'PY'
import numpy as np
core = getattr(np, "_core", np.core)
try:
    print("baseline:", core._multiarray_umath.__cpu_baseline__)
    print("dispatch found:", core._multiarray_umath.__cpu_dispatch__)
except AttributeError:
    print("dispatch introspection attrs not present on this numpy build")
PY
echo

echo "== Pick a symbol from the list above and disassemble it, e.g.: =="
echo "objdump -d --disassemble=<SYMBOL_NAME> \"$SO_PATH\""
echo
echo "Prefer the symbol whose suffix matches the highest tier numpy reported"
echo "as 'found' above (e.g. DOUBLE_add_X86_V3 or a DOUBLE_add_AVX512* variant) —"
echo "that's the one your CPU will actually run, not the bare DOUBLE_add baseline."

# Best-effort: grab the highest-tier suffixed variant automatically.
CANDIDATE=$(nm "$SO_PATH" 2>/dev/null | grep -E '\bDOUBLE_add\b|\bDOUBLE_add_' | grep -v indexed | sort | tail -1 | awk '{print $3}' || true)
if [ -n "${CANDIDATE:-}" ]; then
    echo
    echo "== Auto-detected candidate: $CANDIDATE =="
    objdump -d --disassemble="$CANDIDATE" "$SO_PATH" || echo "objdump could not disassemble this symbol directly; try gdb_disasm.py instead."
fi
