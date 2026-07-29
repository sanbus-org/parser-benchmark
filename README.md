# Parser Benchmark

Cross-parser JSON benchmark harness used by Galley. The harness owns its
adapters and parser definitions; third-party parser implementations are pinned
Git submodules.

The Bison and Flex parser sources are generated into Zig's build cache. Install
`bison`, `flex`, `cargo`, and a C++ compiler before building.

Clone with dependencies:

```sh
git clone --recurse-submodules https://github.com/sanbus-org/parser-benchmark.git
cd parser-benchmark
```

Run the default standard dataset:

```sh
zig build -Doptimize=ReleaseFast run
```

Run a standard external dataset:

```sh
zig build -Doptimize=ReleaseFast run -- twitter
zig build -Doptimize=ReleaseFast run -- canada
zig build -Doptimize=ReleaseFast run -- citm_catalog
```

The default is `twitter.json`. Standard datasets are downloaded from an immutable
`nativejson-benchmark` revision only when missing or invalid. Their SHA-256
checksums are verified before the benchmark starts, and `datasets/*.json` is
ignored so downloaded assets are never committed.
