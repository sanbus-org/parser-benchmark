#!/bin/sh
# Top-level benchmark dispatcher: routes arguments to the per-language
# wrappers and runs each benchmark in sequence. Zig 0.17 delivers the
# arguments after `--` to the run step through `addPassthruArgs`, so this
# script sees them:
#
#   scripts/run-benchmark.sh <json-exe> <python-exe> [args...]
#
# No arguments: both languages run their full default sets. Otherwise each
# argument routes by Python dataset name or `.py` extension to the Python
# harness, and everything else (JSON dataset names and any other path) goes
# to the JSON harness. A language that receives no arguments runs nothing,
# so a single dataset never pulls in the other language's corpus:
#
#   zig build -Doptimize=ReleaseFast run                 # both corpora
#   zig build -Doptimize=ReleaseFast run -- twitter      # JSON only
#   zig build -Doptimize=ReleaseFast run -- graphlib     # Python only
set -eu

json_exe=$1
python_exe=$2
shift 2

# Keep in sync with the dataset names in python/scripts/run-benchmark.sh.
is_python_arg() {
  case "$1" in
  *.py) return 0 ;;
  opcode-metadata | asyncio-queues | numpy-globals | graphlib | weakrefset | base-tasks | warnings) return 0 ;;
  *) return 1 ;;
  esac
}

# run_partition <json|python> [args...]: collect the arguments belonging to
# the language (the pre-expanded `for` list keeps iterating over the
# original arguments while `set --` rebuilds the subset), then invoke its
# wrapper only when at least one argument matched.
run_partition() {
  language=$1
  shift
  first=1
  for arg in "$@"; do
    case "$language" in
    python) is_python_arg "$arg" || continue ;;
    json) is_python_arg "$arg" && continue ;;
    esac
    if [ "$first" -eq 1 ]; then
      set -- "$arg"
      first=0
    else
      set -- "$@" "$arg"
    fi
  done
  if [ "$first" -eq 1 ]; then
    return 0
  fi
  case "$language" in
  json) sh json/scripts/run-benchmark.sh "$json_exe" "$@" ;;
  python) sh python/scripts/run-benchmark.sh "$python_exe" "$@" ;;
  esac
}

if [ "$#" -eq 0 ]; then
  sh json/scripts/run-benchmark.sh "$json_exe"
  exec sh python/scripts/run-benchmark.sh "$python_exe"
fi

run_partition json "$@"
run_partition python "$@"
