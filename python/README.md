# Python Benchmark

Head-to-head Python parsing comparison, mirroring `json/`:

- **Galley LL** (generated from the pinned `galley/` dependency's
  `languages/python`, No AST / AST) — both variants parse with
  `indentation_syntax` and `newline_after_block_end` enabled and no
  error recovery or position tracking. The AST variant also runs the
  grammar's procedures, which resolve operator precedence.
- **Tree-sitter** (`tree-sitter-python/`, pinned submodule at v0.25.0,
  with the repository's Tree-sitter core): a full parse to a concrete
  syntax tree, on one parser kept across parses.
- **Ruff** (`ruff-bench/`, pinned `ruff_python_parser` crate built as a
  C-ABI static library): `parse_module` (AST), with jemalloc as the
  allocator as in Ruff's own binary and benchmark. Ruff has no parse mode
  without a tree, so it has no No-AST row.
- **CPython** (`cpython_bench.py`): `ast.parse` (AST) and `compile`
  (AST + codegen), run in a spawned `python3`.

Run through the top-level dispatcher, which routes arguments by dataset
name or `.py` extension:

```sh
zig build -Doptimize=ReleaseFast run                 # JSON + Python corpora
zig build -Doptimize=ReleaseFast run -- graphlib     # Python only
```

The driver (`main.zig`) mirrors `json/main.zig`: 2 warmup + best of 5 runs
per parser, a descending-throughput table, and `[Name - Mode]` results
written to `benchmark_results/python/`. CPython is spawned as
`python3 python/cpython_bench.py <file> <ast|compile>`; interpreter
startup stays outside the timed region because the script runs the same
2 warmup + best-of-5 protocol in one process and prints seconds per
parse for the driver. Every parse consumes at least 4 MB: smaller inputs
are repeated to that size so each timing is long enough to be stable.

Any CPython compile failure exits nonzero and surfaces as a parse error.
Each timing covers building the tree only, with CPython's collector disabled
and UTF-8 checked inside every timed parse (Ruff's `&str` conversion, and a
check in the Galley adapter because the grammar captures comments and
triple-quoted strings without validating them). The rows still do different
work; see "What the numbers compare" in the top-level README.

The corpus in `datasets/python/` is six checksum-verified CPython 3.14.0
stdlib files and one NumPy file (`numpy/_globals.py` at NumPy v1.26.4),
fetched from immutable revisions by `scripts/fetch-dataset.sh`. The pinned
Galley Python grammar does not yet parse arbitrary real-world Python:
documented limitations apply (`match = 1`, no `;` separators, no `\` line
continuations, no one-line suites, triple-quoted strings end at the first
closing triple quote). The corpus is therefore the subset of real files that
parses; grow it by scanning further files through
`zig-out/bin/benchmark-python` once the grammar advances.

Results go to `benchmark_results/python/`. Requires `python3` on `PATH`
and `cargo` for the Ruff static library. Ruff 0.17.0 needs a newer Rust
than most distributions ship, so `python/ruff-bench/rust-toolchain.toml` pins
1.99.0, which `rustup` installs on first use.
