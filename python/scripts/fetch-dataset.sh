#!/bin/sh
set -eu

dataset_name=${1:-}
dataset_dir=${DATASET_DIR:-datasets/python}
source_revision=ebf955df7a89ed0c7968f79faec1de49f61ed7cb
source_root="https://raw.githubusercontent.com/python/cpython/${source_revision}/Lib"

# The corpus is CPython 3.14.0 stdlib files, plus one NumPy file, that the
# pinned Galley Python grammar parses (see python/README.md); each is
# checksum-verified on download. A dataset from another project sets its own
# `source_root`.

case "$dataset_name" in
opcode-metadata | opcode-metadata.py | datasets/python/opcode-metadata.py | datasets/opcode-metadata.py)
	upstream=_opcode_metadata.py
	filename=opcode-metadata.py
	expected_sha256=d9badc5ab19a66415e230bf8f4299491b2207d584981a92b6e7c447cfa1aeac3
	;;
asyncio-queues | asyncio-queues.py | datasets/python/asyncio-queues.py | datasets/asyncio-queues.py)
	upstream=asyncio/queues.py
	filename=asyncio-queues.py
	expected_sha256=48693f7c118584b0a896d3ad7c5fd6c1250104733075be071e6b19708b866d96
	;;
graphlib | graphlib.py | datasets/python/graphlib.py | datasets/graphlib.py)
	upstream=graphlib.py
	filename=graphlib.py
	expected_sha256=1cfcffd2270ce6b96f300671a88932a3873438d7eb74004431852439fcdd976a
	;;
weakrefset | weakrefset.py | datasets/python/weakrefset.py | datasets/weakrefset.py)
	upstream=_weakrefset.py
	filename=weakrefset.py
	expected_sha256=2dd7cb459d654fe78b00c5c47ee8e786c037ee77763304603f5e976dd62cbf81
	;;
base-tasks | base-tasks.py | datasets/python/base-tasks.py | datasets/base-tasks.py)
	upstream=asyncio/base_tasks.py
	filename=base-tasks.py
	expected_sha256=56efac65b63db927af336fa55eb5bda93c97a2defa4734ea8d695ed20fd6712a
	;;
warnings | warnings.py | datasets/python/warnings.py | datasets/warnings.py)
	upstream=warnings.py
	filename=warnings.py
	expected_sha256=142225786de63c593f1c9abdacf5b4fc0b05dd847f6bed0ebb4b4aa2d4d93b02
	;;
numpy-globals | numpy-globals.py | datasets/python/numpy-globals.py | datasets/numpy-globals.py)
	# numpy/_globals.py at the commit of NumPy v1.26.4.
	source_root="https://raw.githubusercontent.com/numpy/numpy/9815c16f449e12915ef35a8255329ba26dacd5c0/numpy"
	upstream=_globals.py
	filename=numpy-globals.py
	expected_sha256=9de11d71f2d9a072f06deaffd57cab9f6e8b717cb432b4ad6b4dd97bb68a6ba8
	;;
*)
	echo "unknown external dataset: $dataset_name" >&2
	echo "available datasets: opcode-metadata, asyncio-queues, graphlib, weakrefset, base-tasks, warnings, numpy-globals" >&2
	exit 2
	;;
esac

destination="${dataset_dir}/${filename}"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

if [ -f "$destination" ] && [ "$(sha256 "$destination")" = "$expected_sha256" ]; then
	echo "dataset ready: $destination"
	exit 0
fi

mkdir -p "$dataset_dir"
temporary=$(mktemp "${destination}.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM

echo "downloading $filename"
curl --fail --location --silent --show-error \
	--output "$temporary" \
	"${source_root}/${upstream}"

actual_sha256=$(sha256 "$temporary")
if [ "$actual_sha256" != "$expected_sha256" ]; then
	echo "checksum mismatch for $filename" >&2
	echo "expected: $expected_sha256" >&2
	echo "actual:   $actual_sha256" >&2
	exit 1
fi

mv "$temporary" "$destination"
trap - EXIT HUP INT TERM
echo "dataset ready: $destination"
