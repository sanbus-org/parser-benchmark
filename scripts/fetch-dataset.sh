#!/bin/sh
set -eu

dataset_name=${1:-}
dataset_dir=${DATASET_DIR:-datasets}
source_revision=aeefe6a44f37fccf1f9d730766abab9ffea43c6b
source_root="https://raw.githubusercontent.com/ibireme/yyjson_benchmark/${source_revision}/data/json"

case "$dataset_name" in
    canada|canada.json|datasets/canada.json)
        filename=canada.json
        expected_sha256=f83b3b354030d5dd58740c68ac4fecef64cb730a0d12a90362a7f23077f50d78
        ;;
    citm_catalog|citm_catalog.json|datasets/citm_catalog.json)
        filename=citm_catalog.json
        expected_sha256=a73e7a883f6ea8de113dff59702975e60119b4b58d451d518a929f31c92e2059
        ;;
    fgo|fgo.json|datasets/fgo.json)
        filename=fgo.json
        expected_sha256=4d0153f122aa4f049888dce8162d38b677e0127e2be90ae3afd998813f44a738
        ;;
    github_events|github_events.json|datasets/github_events.json)
        filename=github_events.json
        expected_sha256=c9eebb2cf2d46649059e9d48700919bacb3e8e0fb58452065a1a9de7778fd22e
        ;;
    gsoc-2018|gsoc-2018.json|datasets/gsoc-2018.json)
        filename=gsoc-2018.json
        expected_sha256=72f1ef4898d88049da856c2ab8f4ec3e2c968ce209b2bbfd16cef842eb2e185f
        ;;
    lottie|lottie.json|datasets/lottie.json)
        filename=lottie.json
        expected_sha256=7617a0bd9c5fadd1e20a9beccf127e4ab2eec90ae54aa3b251416c3246f8b716
        ;;
    otfcc|otfcc.json|datasets/otfcc.json)
        filename=otfcc.json
        expected_sha256=7cbdeac112ab424d7cc94c99f675b2b0b4b0315055437725cd47648426c831df
        ;;
    poet|poet.json|datasets/poet.json)
        filename=poet.json
        expected_sha256=2c2689a3b5df460f02e4dee2a36ac32cc27c43e2964fba7965eba3469bf617ec
        ;;
    twitter|twitter.json|datasets/twitter.json)
        filename=twitter.json
        expected_sha256=a08b769f32b95f426cbc3abafcec65c1a19d3eb544d4ddf320eae142c99efc5d
        ;;
    twitterescaped|twitterescaped.json|datasets/twitterescaped.json)
        filename=twitterescaped.json
        expected_sha256=2a288b5af4691c55b6f40fa534225b3e08b8d8b7f7ca4ed29bc5c7c81566ed4a
        ;;
    *)
        echo "unknown external dataset: $dataset_name" >&2
        echo "available datasets: canada, citm_catalog, fgo, github_events, gsoc-2018, lottie, otfcc, poet, twitter, twitterescaped" >&2
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
