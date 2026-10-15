#!/usr/bin/env python3
"""Measure one CPython parse mode for the Galley benchmark driver.

Usage: cpython_bench.py <file> <ast|compile> <repeats>

Runs the selected mode in this interpreter (interpreter startup is outside
the timed region), runs the same protocol as python/main.zig (2 untimed
warmup parses, then the best of 5 timed parses), and prints seconds per
parse as a single float on stdout. Any compile failure exits nonzero with the
traceback on stderr, which the driver reports as a parse failure.

The source is repeated <repeats> times before timing, so each parse
consumes the same multiplied input the in-process adapters receive; the
driver (python/main.zig) computes and passes the count.

The driver spawns this once per mode per dataset; timing stays in-process
here because a per-run interpreter spawn would measure startup, not
parsing.
"""

import ast
import gc
import sys
import time

# Keep in sync with warmup_runs and measure_runs in timing.zig.
WARMUP_RUNS = 2
MEASURE_RUNS = 5


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(2)
    path, mode = sys.argv[1], sys.argv[2]
    repeats = int(sys.argv[3])
    source = open(path, "rb").read() * repeats
    if mode == "ast":

        def once():
            return compile(source, "x", "exec", ast.PyCF_ONLY_AST)
    elif mode == "compile":

        def once():
            return compile(source, "x", "exec")
    else:
        sys.exit(2)

    # Like timeit, keep the cyclic collector out of the timing. Each result is
    # dropped after the clock stops, so the timing covers building the tree
    # and not tearing it down, as for the Galley and Ruff adapters.
    gc.disable()

    # The warmup parses also validate the source: a SyntaxError exits nonzero.
    for _ in range(WARMUP_RUNS):
        once()

    best = None
    for _ in range(MEASURE_RUNS):
        start = time.perf_counter()
        result = once()
        elapsed = time.perf_counter() - start
        del result
        best = elapsed if best is None or elapsed < best else best

    print(f"{best:.12e}")


if __name__ == "__main__":
    main()
