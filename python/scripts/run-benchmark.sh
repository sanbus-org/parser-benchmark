#!/bin/sh
# Runs the Python benchmark executable, fetching and resolving the standard
# dataset corpus by name. Zig 0.17 no longer exposes the arguments after
# `--` to build(); a run step receives them through `addPassthruArgs`, so
# dataset selection happens here instead of in build.zig:
#
#   zig build -Doptimize=ReleaseFast run                # full Python corpus
#   zig build -Doptimize=ReleaseFast run -- graphlib     # selected datasets
#   zig build -Doptimize=ReleaseFast run -- file.py     # arbitrary file path
#
# An argument names a standard dataset in any form `fetch-dataset.sh`
# accepts (bare name, `name.py`, `datasets/python/name.py`, or
# `datasets/name.py`); it is fetched, checksum-verified, and replaced by
# its canonical path. Every other argument passes through untouched.
set -eu

exe=$1
shift

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
export DATASET_DIR="$repo_root/datasets/python"

# Prints the canonical `datasets/python/<name>.py` path on success after
# fetching and verifying the dataset, or fails when the argument is not a
# standard dataset. The fetch script's progress output goes to stderr so
# only the path is captured.
resolve_dataset() {
	name=$1
	case "$name" in
	datasets/python/*.py) name=${name#datasets/python/} ;;
	datasets/*.py) name=${name#datasets/} ;;
	esac
	case "$name" in
	*.py) name=${name%.py} ;;
	esac
	case "$name" in
	opcode-metadata | asyncio-queues | graphlib | weakrefset | base-tasks | warnings | numpy-globals)
		sh "$script_dir/fetch-dataset.sh" "$name" >&2
		;;
	*)
		return 1
		;;
	esac
	printf 'datasets/python/%s.py\n' "$name"
}

if [ "$#" -eq 0 ]; then
	set -- asyncio-queues base-tasks graphlib numpy-globals opcode-metadata warnings weakrefset
fi

prepend=1
for arg in "$@"; do
	if resolved=$(resolve_dataset "$arg"); then
		arg=$resolved
	fi
	if [ "$prepend" -eq 1 ]; then
		set -- "$arg"
		prepend=0
	else
		set -- "$@" "$arg"
	fi
done

exec "$exe" "$@"
