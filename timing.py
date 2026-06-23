"""
Pulls timing numbers out of benchmark stdout (bench.py, bench.js,
bench_pyjs.js) and prints a side-by-side table. Run the benchmarks
first and redirect stdout into files, e.g.:

    python bench.py 1000000 2000 > native_out.txt
    node bench.js 1000000 2000 > wasm_pyodide_out.txt
    node bench_pyjs.js 1000000 2000 > wasm_pyjs_out.txt
    python timing.py native_out.txt wasm_pyodide_out.txt wasm_pyjs_out.txt

Accepts 2 or 3 files. With 2, prints native vs wasm (pyodide).
With 3, prints native vs wasm (pyodide) vs wasm (pyjs).
"""
import re
import sys

COL_LABELS = ["native", "wasm (pyodide)", "wasm (pyjs)"]


def parse(path):
    text = open(path).read()
    def grab(label):
        m = re.search(rf"{label}\s*:\s*([\d.,]+)", text)
        return m.group(1) if m else "n/a"
    return {
        "per_call_us": grab("Time per call"),
        "throughput_gelem_s": grab("Throughput"),
    }


def main():
    if len(sys.argv) < 3 or len(sys.argv) > 4:
        print(__doc__)
        sys.exit(1)

    results = [parse(p) for p in sys.argv[1:]]
    labels = COL_LABELS[:len(results)]
    col_w = 22

    header = f"{'metric':<24}" + "".join(f"{l:<{col_w}}" for l in labels)
    sep = "-" * (24 + col_w * len(results))
    print(header)
    print(sep)

    for metric, key in [("time per call (us)", "per_call_us"),
                        ("throughput (Gelem/s)", "throughput_gelem_s")]:
        line = f"{metric:<24}"
        for r in results:
            line += f"{r[key]:<{col_w}}"
        print(line)


if __name__ == "__main__":
    main()
