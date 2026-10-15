#!/bin/sh
# Runs the benchmark executable, fetching and resolving the ten standard
# datasets by name. Zig 0.17 no longer exposes the arguments after `--` to
# build(); a run step receives them through `addPassthruArgs`, so dataset
# selection happens here instead of in build.zig:
#
#   zig build -Doptimize=ReleaseFast run                # all ten datasets
#   zig build -Doptimize=ReleaseFast run -- twitter     # selected datasets
#   zig build -Doptimize=ReleaseFast run -- file.json   # arbitrary file path
#
# An argument names a standard dataset in any form `fetch-dataset.sh`
# accepts (bare name, `name.json`, `datasets/json/name.json`, or
# `datasets/name.json`); it is fetched, checksum-verified, and replaced by
# its canonical path. Every other argument passes through untouched.
set -eu

exe=$1
shift

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
export DATASET_DIR="$repo_root/datasets/json"

# Prints the canonical `datasets/json/<name>.json` path on success after
# fetching and verifying the dataset, or fails when the argument is not a
# standard dataset. The fetch script's progress output goes to stderr so
# only the path is captured.
resolve_dataset() {
	name=$1
	case "$name" in
	datasets/json/*.json) name=${name#datasets/json/} ;;
	datasets/*.json) name=${name#datasets/} ;;
	esac
	case "$name" in
	*.json) name=${name%.json} ;;
	esac
	case "$name" in
	canada | citm_catalog | fgo | github_events | gsoc-2018 | lottie | otfcc | poet | twitter | twitterescaped)
		sh "$script_dir/fetch-dataset.sh" "$name" >&2
		;;
	*)
		return 1
		;;
	esac
	printf 'datasets/json/%s.json\n' "$name"
}

if [ "$#" -eq 0 ]; then
	set -- canada citm_catalog fgo github_events gsoc-2018 lottie otfcc poet twitter twitterescaped
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
