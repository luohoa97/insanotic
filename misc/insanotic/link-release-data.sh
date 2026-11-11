#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Links the official Xonotic 0.8.6 map, music and data packs from an
# existing installation into data/: maps get their textures and the exact
# release .bsp files, and the release data pack brings precompressed DDS
# textures, which halves map load time compared to the source images in
# xonotic-data.pk3dir (that folder still wins for game code and anything
# Insanotic changes, as it loads after the pack). Nothing is copied.
#
#   misc/insanotic/link-release-data.sh [xonotic-data-dir]
#
# Without an argument it looks for the Flatpak (org.xonotic.Xonotic, system
# or user install) and a release unpacked in ~/Xonotic.
# Exits with 1 when nothing was found (then use fetch-map.sh instead).

set -eu

DEST=${DEST:-data}
VERSION=20230620 # 0.8.6

found=""
for dir in ${1:-} \
	/var/lib/flatpak/app/org.xonotic.Xonotic/current/active/files/share/xonotic/data \
	"$HOME/.local/share/flatpak/app/org.xonotic.Xonotic/current/active/files/share/xonotic/data" \
	"$HOME/Xonotic/data"; do
	if [ -f "$dir/xonotic-$VERSION-maps.pk3" ]; then
		found=$dir
		break
	fi
done

if [ -z "$found" ]; then
	echo "no Xonotic 0.8.6 installation found (looked for xonotic-$VERSION-maps.pk3)" >&2
	exit 1
fi

for pack in maps music data; do
	src="$found/xonotic-$VERSION-$pack.pk3"
	if [ -f "$src" ]; then
		ln -sf "$src" "$DEST/xonotic-$VERSION-$pack.pk3"
		echo "linked $DEST/xonotic-$VERSION-$pack.pk3 -> $src"
	fi
done

# the release pack supersedes development downloads from fetch-map.sh
for f in "$DEST"/*-*-*.pk3; do
	case $f in
		"$DEST"/xonotic-*) ;;
		*) [ -f "$f" ] && rm -f "$f" && echo "removed $f (superseded)" ;;
	esac
done
rm -f "$DEST"/maps/*.mapinfo
exit 0
