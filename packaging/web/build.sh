#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the WebAssembly client into packaging/web/dist/ (insanotic.js,
# insanotic.wasm) and copies the page (index.html, loader.js, ...) next to it.
#
#   packaging/web/build.sh [engine-dir]
#
# engine-dir defaults to ../darkplaces (what misc/insanotic/checkout.sh
# makes). Needs the Emscripten SDK on PATH (emcmake, emcc), cmake and ninja
# or make. Plain POSIX sh, so it runs from fish too.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
engine=${1:-$here/../../darkplaces}
engine=$(cd "$engine" && pwd)
version=${INSANOTIC_VERSION:-dev}
build=${BUILD_DIR:-$here/build}
dist=${DIST_DIR:-$here/dist}

command -v emcmake >/dev/null || { echo "emcmake not found: source emsdk_env.sh first" >&2; exit 1; }
emcmake cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Release \
	-DINSANOTIC_ENGINE_DIR="$engine" -DINSANOTIC_VERSION="$version"
cmake --build "$build" --parallel "$(nproc 2>/dev/null || echo 2)"

mkdir -p "$dist"
cp "$build/insanotic.js" "$build/insanotic.wasm" "$dist/"
cp "$here"/site/* "$dist/"
echo "built $dist"
