# Parser Benchmark

Cross-parser JSON benchmark harness used by Galley. The harness owns its
adapters and parser definitions; Galley, yyjson, and third-party parser
implementations are pinned Git submodules.

The Bison and Flex parser sources are generated into Zig's build cache. Install
`bison`, `flex`, `cargo`, and a C++ compiler before building.

Galley is generated in LL and LR modes, both with and without AST construction,
from `languages/json-unicode`. Its benchmarks therefore validate raw UTF-8 and
JSON string escapes rather than using Galley's intentionally minimal JSON
throughput grammar.

Clone with dependencies:

```sh
git clone https://github.com/sanbus-org/parser-benchmark.git
cd parser-benchmark
git submodule update --init
```

Run the default ten standard datasets:

```sh
zig build -Doptimize=ReleaseFast run
```

The default set is:

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

Pass one or more names to run only selected datasets:

```sh
zig build -Doptimize=ReleaseFast run -- twitter canada
```

Standard datasets are downloaded from an immutable `yyjson_benchmark` revision
only when missing or invalid. Their SHA-256 checksums are verified before the
benchmark starts, and `datasets/*.json` is ignored so downloaded assets are
never committed. Each result table is sorted from highest to lowest throughput.
