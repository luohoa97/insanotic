#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Starts Insanotic from an unpacked release tarball. The Xonotic 0.8.6 data
# packs are not in the tarball: the first start links them from an
# installed Xonotic (Flatpak or ~/Xonotic), or tells you where to put them.
#
#   ./insanotic.sh [engine options]       play
#   ./insanotic.sh -dedicated [options]   run a dedicated server

set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

if ! ls data/xonotic-*-data.pk3 >/dev/null 2>&1; then
	if ! DEST=data sh ./link-release-data.sh; then
		echo "Insanotic needs the Xonotic 0.8.6 data packs." >&2
		echo "Copy xonotic-20230620-*.pk3 from the data/ folder of a Xonotic 0.8.6" >&2
		echo "install (https://xonotic.org/download/) into $here/data/" >&2
		exit 1
	fi
fi

if [ "${1:-}" = "-dedicated" ]; then
	shift
	exec ./darkplaces-dedicated -xonotic -basedir "$here" "$@"
fi
exec ./darkplaces-sdl -xonotic -basedir "$here" "$@"
