#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Rewrites pk3 packs with every file stored uncompressed (zip method 0).
# DarkPlaces then reads them without inflating anything: on an SSD a plain
# read is faster than any decompressor, and inflate was about a third of
# the map load time. Costs disk space (the 0.8.6 data and maps packs grow
# from 0.9 GB to 2 GB).
#
#   misc/insanotic/repack-stored.sh [pack.pk3 ...]
#
# Without arguments it repacks the release packs linked into data/ by
# link-release-data.sh, replacing each link with an uncompressed copy.
# Needs python3 (zipfile, streamed: no temporary unpacked copy).

set -eu

[ $# -gt 0 ] || set -- data/xonotic-*-data.pk3 data/xonotic-*-maps.pk3
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

for pack in "$@"; do
	[ -e "$pack" ] || { echo "$pack: not found" >&2; continue; }
	src=$(readlink -f "$pack")
	tmp="$pack.stored.part"
	echo "$pack: repacking uncompressed"
	python3 -I - "$src" "$tmp" <<'EOF'
import sys, zipfile, shutil
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_STORED, allowZip64=False) as zout:
    stored = 0
    for info in zin.infolist():
        if info.is_dir():
            continue
        out = zipfile.ZipInfo(info.filename, info.date_time)
        out.compress_type = zipfile.ZIP_STORED
        out.external_attr = info.external_attr
        with zin.open(info) as fin, zout.open(out, "w") as fout:
            shutil.copyfileobj(fin, fout, 1 << 20)
        stored += 1
    print("  %d files" % stored)
EOF
	rm -f "$pack"
	mv "$tmp" "$pack"
done
