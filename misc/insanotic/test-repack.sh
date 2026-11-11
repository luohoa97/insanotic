#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test of repack-assets.sh on a tiny pack made here: checks that text becomes
# a zstd entry (method 93) that reads back, a jpg stays stored, Ogg becomes
# Opus, and (with astcenc, set ASTCENC) a DXT1 texture becomes a KTX 1 file of
# ASTC levels with a valid header, and its symlink stub follows it.
#
#   misc/insanotic/test-repack.sh        (from the repository root)

set -eu
work=${TMPDIR:-/tmp}/insanotic-test-repack.$$
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"

ffmpeg -nostdin -loglevel error -f lavfi -i anoisesrc=d=3:c=pink -ac 2 -c:a vorbis -strict -2 "$work/tone.ogg"
python3 -I - "$work" <<'PY'
import struct, sys, zipfile
w = sys.argv[1]
# 16x16 DXT1 texture with a full mip chain (5 levels): 8 bytes per 4x4 block
blocks = [16, 4, 1, 1, 1]
hdr = bytearray(128)
hdr[0:4] = b"DDS "
struct.pack_into("<IIIIII", hdr, 4, 124, 0x81007, 16, 16, 128, 0)
struct.pack_into("<I", hdr, 28, 5)
struct.pack_into("<IIII", hdr, 76, 32, 4, 0x31545844, 0)
struct.pack_into("<I", hdr, 108, 0x401008)
dds = bytes(hdr) + b"".join(bytes([0x1F, 0xF8, 0xE0, 0x07, 0x1B, 0x1B, 0x1B, 0x1B]) * n for n in blocks)
with zipfile.ZipFile(w + "/in.pk3", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("scripts/test.cfg", "echo hello\n" * 100)
    z.writestr("textures/x.jpg", b"\xff\xd8" + bytes(range(256)) * 4)
    z.write(w + "/tone.ogg", "sound/misc/tone.ogg")
    z.writestr("dds/textures/x.dds", dds)
    link = zipfile.ZipInfo("dds/x.dds")
    link.external_attr = 0o120777 << 16
    z.writestr(link, "textures/x.dds")
PY

for profile in desktop android; do
	if [ "$profile" = android ] && [ -z "${ASTCENC:-}" ]; then
		echo "skip android profile (ASTCENC not set)"
		continue
	fi
	misc/insanotic/repack-assets.sh -p "$profile" -o "$work/out" -j 2 "$work/in.pk3" >/dev/null
	python3 -I - "$work/out/$profile-in.pk3" "$profile" <<'PY'
import struct, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
profile = sys.argv[2]
names = {i.filename: i for i in z.infolist()}
def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        sys.exit(1)
cfg = names["scripts/test.cfg"]
check(cfg.compress_type == 93 and z.read(cfg) == b"echo hello\n" * 100, profile + ": text is a zstd entry")
check(names["textures/x.jpg"].compress_type == 0, profile + ": jpg stays stored")
check("sound/misc/tone.opus" in names and "sound/misc/tone.ogg" not in names, profile + ": Ogg became Opus")
check(b"OpusHead" in z.read("sound/misc/tone.opus")[:80], profile + ": the Opus file is Opus")
if profile == "desktop":
    check("dds/textures/x.dds" in names, "desktop: DXT texture untouched")
else:
    ktx = z.read("dds/textures/x.ktx")
    f = struct.unpack("<13I", ktx[12:64])
    check(ktx[:12] == b"\xabKTX 11\xbb\r\n\x1a\n" and f[4] == 0x93B4 and f[6:8] == (16, 16) and f[11] == 5, "android: KTX 1 header, ASTC 6x6, 5 levels")
    check("dds/textures/x.dds" not in names and z.read("dds/x.ktx") == b"textures/x.ktx", "android: symlink stub follows")
PY
done
echo done
