#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes the flatpak-builder sources for the launcher's vendored crates,
# from launcher/Cargo.lock: one archive per crate plus the cargo source
# replacement config. Run it again whenever Cargo.lock changes.
#
#   packaging/flatpak/gen-cargo-sources.sh > packaging/flatpak/cargo-sources.json

set -eu

LOCK=${1:-launcher/Cargo.lock}
MODULE=${MODULE:-insanotic-launcher}
VENDOR=/run/build/$MODULE/cargo/vendor

awk -v vendor="$VENDOR" '
function flush() {
	if (name != "" && checksum != "") {
		dir = "cargo/vendor/" name "-" version
		if (n++) printf ",\n"
		printf "  {\"type\": \"archive\", \"archive-type\": \"tar-gzip\", "
		printf "\"url\": \"https://static.crates.io/crates/%s/%s-%s.crate\", ", name, name, version
		printf "\"sha256\": \"%s\", \"dest\": \"%s\"},\n", checksum, dir
		printf "  {\"type\": \"inline\", \"contents\": \"{\\\"package\\\": \\\"%s\\\", \\\"files\\\": {}}\", ", checksum
		printf "\"dest\": \"%s\", \"dest-filename\": \".cargo-checksum.json\"}", dir
	}
	name = ""; version = ""; checksum = ""
}
BEGIN { print "[" }
/^\[\[package\]\]/ { flush(); next }
/^name = / { gsub(/"/, "", $3); name = $3 }
/^version = / { gsub(/"/, "", $3); version = $3 }
/^checksum = / { gsub(/"/, "", $3); checksum = $3 }
END {
	flush()
	printf ",\n  {\"type\": \"inline\", \"dest\": \"cargo\", \"dest-filename\": \"config.toml\", "
	printf "\"contents\": \"[source.crates-io]\\nreplace-with = \\\"vendored-sources\\\"\\n\\n[source.vendored-sources]\\ndirectory = \\\"%s\\\"\\n\"}\n", vendor
	print "]"
}' "$LOCK"
