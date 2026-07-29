#!/bin/sh
set -eu

dataset_name=${1:-}
dataset_dir=${DATASET_DIR:-datasets}
source_revision=478d5727c2a4048e835a29c65adecc7d795360d5
source_root="https://raw.githubusercontent.com/miloyip/nativejson-benchmark/${source_revision}/data"

case "$dataset_name" in
    canada|canada.json|datasets/canada.json)
        filename=canada.json
        expected_sha256=f83b3b354030d5dd58740c68ac4fecef64cb730a0d12a90362a7f23077f50d78
        ;;
    citm_catalog|citm_catalog.json|datasets/citm_catalog.json)
        filename=citm_catalog.json
        expected_sha256=a73e7a883f6ea8de113dff59702975e60119b4b58d451d518a929f31c92e2059
        ;;
    twitter|twitter.json|datasets/twitter.json)
        filename=twitter.json
        expected_sha256=a08b769f32b95f426cbc3abafcec65c1a19d3eb544d4ddf320eae142c99efc5d
        ;;
    *)
        echo "unknown external dataset: $dataset_name" >&2
        echo "available datasets: canada, citm_catalog, twitter" >&2
        exit 2
        ;;
esac

destination="${dataset_dir}/${filename}"

sha256()
{
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
    "${source_root}/${filename}"

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
