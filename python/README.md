# Python Benchmark (scaffold)

Head-to-head Python parsing comparison, mirroring `json/`:

- **Galley LL** (generated from the parent repo's `languages/python`,
  No AST / AST) — driver TBD (`python/main.zig`, same 2-warmup +
  best-of-5 methodology and `[Name - Mode]` result format as
  `json/main.zig`).
- **Ruff** (`ruff-bench/`, pinned `ruff_python_parser` crate):
  `parse_module` (AST) and lexer-only (No-AST analogue).
- **CPython** (`cpython_bench.py`): `ast.parse` (AST) and `compile`
  (AST + codegen).

`datasets/python/` takes the checksum-verified `.py` corpus (sources and
pins TBD); results go to `benchmark_results/python/`. The Zig driver and
corpus selection are the remaining work — this directory currently holds
only the promoted prototype harnesses, unreferenced by `build.zig`, so
the JSON benchmark is unaffected.
