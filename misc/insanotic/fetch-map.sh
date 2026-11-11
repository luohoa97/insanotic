#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Downloads the compiled 0.8.6 build of one or more official maps into data/
# so a dedicated server can run without the full release pk3s.
#
#   misc/insanotic/fetch-map.sh [map ...]     (default: stormkeep)
#
# The map source revision is looked up at the xonotic-v0.8.6 tag of
# xonotic-maps.pk3dir, then the matching pk3 is taken from the official
# autobuild server, together with the map's .mapinfo (the autobuild pk3 only
# carries the .bsp). Already downloaded maps are skipped.
#
# This is a development convenience: production servers should use the
# official release map pk3s, which also contain decorative models.

set -eu

TAG=xonotic-v0.8.6
API=https://gitlab.com/api/v4/projects/xonotic%2Fxonotic-maps.pk3dir/repository/files
AUTOBUILD=https://beta.xonotic.org/autobuild-bsp/
DEST=${DEST:-data}

[ $# -gt 0 ] || set -- stormkeep
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

index=""
for map in "$@"; do
	if [ ! -f "$DEST/maps/$map.mapinfo" ]; then
		mkdir -p "$DEST/maps"
		curl -fsS -o "$DEST/maps/$map.mapinfo" "$API/maps%2F$map.mapinfo/raw?ref=$TAG"
	fi
	if ls "$DEST/$map"-*.pk3 >/dev/null 2>&1; then
		echo "$map: already present"
		continue
	fi
	blob=$(curl -fsS "$API/maps%2F$map.map?ref=$TAG" | sed -n 's/.*"blob_id":"\([0-9a-f]*\)".*/\1/p')
	[ -n "$blob" ] || { echo "$map: not an official map at $TAG" >&2; exit 1; }
	[ -n "$index" ] || index=$(curl -fsS "$AUTOBUILD")
	pk3=$(printf '%s\n' "$index" | grep -o "href=\"$map-[0-9a-f]*-$blob\.pk3\"" | head -n 1 | sed 's/href="\(.*\)"/\1/')
	[ -n "$pk3" ] || { echo "$map: no autobuild for map revision $blob" >&2; exit 1; }
	echo "$map: downloading $pk3"
	curl -fSL --progress-bar -o "$DEST/$pk3.part" "$AUTOBUILD$pk3"
	mv "$DEST/$pk3.part" "$DEST/$pk3"
done
