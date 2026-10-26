# Parser Benchmark

Cross-language parser benchmark harnesses used by Galley. Each language keeps
its exclusive adapters, grammars, and datasets under its own directory
(`json/`, `python/`); shared infrastructure (build dispatcher, Tree-sitter
core, the pinned `galley` dependency, ignored `datasets/` and
`benchmark_results/` roots) stays top-level. The harness owns its
adapters and parser definitions; Galley, yyjson, and third-party parser
implementations are pinned Git submodules.

The Bison and Flex parser sources are generated into Zig's build cache. Install
`bison`, `flex`, `cargo`, `python3`, and a C++ compiler before building.

Galley is generated in LL and LR modes, both with and without AST construction,
from `languages/json-unicode`. Its benchmarks therefore validate raw UTF-8 and
JSON string escapes rather than using Galley's intentionally minimal JSON
throughput grammar. The Python harness generates Galley's LL parser (No AST and
AST variants) from `languages/python` with indentation-aware lexing enabled.

Clone with dependencies:

```sh
git clone https://github.com/sanbus-org/parser-benchmark.git
cd parser-benchmark
git submodule update --init
```

Run the default corpora — the ten standard JSON datasets, then the seven
standard Python datasets:

```sh
zig build -Doptimize=ReleaseFast run
```

The JSON default set is:

- `canada`
- `citm_catalog`
- `fgo`
- `github_events`
- `gsoc-2018`
- `lottie`
- `otfcc`
- `poet`
- `twitter`
- `twitterescaped`

The Python default set is:

- `asyncio-queues`
- `base-tasks`
- `graphlib`
- `numpy-globals`
- `opcode-metadata`
- `warnings`
- `weakrefset`

Benchmarking a local Galley checkout instead of the pinned `galley/`
submodule:

```sh
GALLEY_LOCAL_PATH=$PWD/../.. zig build -Doptimize=ReleaseFast run -- twitter
```

An empty value behaves as unset. The `galley-local` symlink is managed by
the build and ignored by git.

Pass one or more names to run only selected datasets. Arguments route by
language: Python dataset names and `.py` paths go to the Python harness,
everything else to the JSON harness, and a language that receives no
arguments runs nothing:

```sh
zig build -Doptimize=ReleaseFast run -- twitter canada  # JSON only
zig build -Doptimize=ReleaseFast run -- graphlib        # Python only
zig build -Doptimize=ReleaseFast run -- path/to/file.py # arbitrary Python file
```

Standard datasets are downloaded from an immutable `yyjson_benchmark` revision
(JSON) or immutable CPython `v3.14.0` and NumPy `v1.26.4` revisions (Python)
only when missing or
invalid. Their SHA-256 checksums are verified before the benchmark starts, and
`datasets/*.json` and `datasets/*.py` are ignored so downloaded assets are
never committed. Each result table is sorted from highest to lowest throughput.

## What the numbers compare

Both harnesses time every parser the same way (`timing.zig`): the same input,
2 warmup runs, then the best of 5, covering only the work of building the
tree. A tree is released after the clock stops, and a parser or session that
is meant to be reused is created once. Encoding is checked inside the timing
for every parser that needs valid UTF-8.

The rows still do different work, so read a ratio between tools as an
estimate, not a measurement of equal work:

- **Different trees.** Galley builds a generic node tree of spans with no
  decoded values. LALRPOP's Python adapter and Ruff build typed ASTs with
  decoded values, and Ruff also returns tokens and error lists. Tree-sitter
  builds a concrete tree of every node. CPython builds Python `ast` objects,
  and `compile` adds code generation. Bison and the JSON libraries each
  differ again.
- **Memory reuse.** Galley and Bison reuse one arena between parses, and
  their trees are valid only until the next parse. LALRPOP's Python adapter,
  Ruff, CPython, RapidJSON and yyjson allocate a new tree each time because
  the caller owns it, and Ruff has no way to reuse its memory.
- **Language coverage.** Galley's Python grammar parses a subset (see
  `python/README.md`). LALRPOP's RustPython grammar, Ruff, CPython and
  Tree-sitter parse full Python, and Ruff also recovers from errors.
- **Extra passes.** Galley's Python AST row runs a procedure that resolves
  operator precedence, which the other tools do inside their parsers.
- **No-AST rows.** Galley's and Bison's no-AST modes have no rival in Python,
  where no other tool has a parse-only mode. In JSON, simdjson's Validate row
  is the closest match.
- **Encoding checks.** LALRPOP, Ruff, CPython and Galley's Python adapter
  reject invalid UTF-8. Tree-sitter works on bytes and does not check.
- **Per-call costs left in.** Flex copies its input and rebuilds its buffer on
  every parse.
- **One run each.** Results are the best of 5 on one machine and one input,
  with no variance reported.
