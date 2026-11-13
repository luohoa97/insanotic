#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Repacks the official Xonotic 0.8.6 packs for small downloads, fast loading
# and little memory on phones:
#
#   - every entry that compresses is stored with zstd (zip method 93) instead
#     of deflate: the engine inflates it several times faster. Files that are
#     compressed already (jpg, ogg, ...) are stored as they are,
#   - Ogg Vorbis sound becomes Ogg Opus (.ogg -> .opus; the engine finds an
#     .opus when the game asks for the .ogg or .wav),
#   - profile "android" also turns the S3TC textures (dds/foo.dds) into ASTC
#     in a KTX 1 file (dds/foo.ktx) with the whole mip chain: 6x6 blocks for
#     color, 4x4 for normal maps and the menu and HUD graphics. The engine
#     uploads those as they are when the GPU has GL_KHR_texture_compression_astc_ldr.
#
#   misc/insanotic/repack-assets.sh [-p android|desktop] [-o outdir] [-j jobs] pack.pk3...
#
# Writes outdir/<profile>-<pack name> for each pack, manifest-<profile>.txt
# (one line per pack: file name, size, CRC32, name to install it under) and
# sizes-<profile>.md (before and after, as a markdown table). Each pack is
# read entry by entry from the source zip and written entry by entry to the
# result, so nothing is unpacked on disk.
#
# Needs: python 3.14 (its zipfile and compression.zstd), ffmpeg with libopus
# and, for android, astcenc (set ASTCENC to its path; astcenc-avx2,
# astcenc-sse4.1 or astcenc on PATH are tried otherwise). ASTC_PRESET picks
# the encoder effort (default -medium); ASTC_COLOR (default 6x6) and
# ASTC_DETAIL (default 4x4, for normal maps and 2D graphics) the block sizes:
# bigger blocks are smaller files and blurrier textures.

set -eu

profile=android
outdir=.
jobs=$(nproc 2>/dev/null || echo 2)

while getopts p:o:j: opt; do
	case $opt in
	p) profile=$OPTARG ;;
	o) outdir=$OPTARG ;;
	j) jobs=$OPTARG ;;
	*) sed -n '2,/^$/p' "$0" >&2; exit 2 ;;
	esac
done
shift $((OPTIND - 1))

case $profile in
android | desktop) ;;
*) echo "unknown profile $profile (android or desktop)" >&2; exit 2 ;;
esac
[ $# -gt 0 ] || { echo "no packs given" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is required" >&2; exit 1; }
python3 -I -c 'from compression import zstd' 2>/dev/null || { echo "python 3.14 or newer is required (compression.zstd)" >&2; exit 1; }

astcenc=
if [ "$profile" = android ]; then
	astcenc=${ASTCENC:-}
	if [ -z "$astcenc" ]; then
		for c in astcenc-avx2 astcenc-sse4.1 astcenc; do
			if command -v "$c" >/dev/null 2>&1; then astcenc=$(command -v "$c"); break; fi
		done
	fi
	[ -n "$astcenc" ] || { echo "astcenc is required for the android profile (set ASTCENC)" >&2; exit 1; }
fi

mkdir -p "$outdir"
: > "$outdir/manifest-$profile.txt"
{
	echo "| pack | before | after |"
	echo "| --- | ---: | ---: |"
} > "$outdir/sizes-$profile.md"

for pack in "$@"; do
	[ -f "$pack" ] || { echo "$pack: not found" >&2; exit 1; }
	echo "$pack: repacking ($profile)"
	python3 -I - "$profile" "$jobs" "$astcenc" "${ASTC_PRESET:--medium}" "${ASTC_COLOR:-6x6}" "${ASTC_DETAIL:-4x4}" "$outdir" "$pack" <<'EOF'
import os, struct, subprocess, sys, tempfile, threading, zipfile, zlib
from compression import zstd
from concurrent.futures import ThreadPoolExecutor

profile, jobs, astcenc, preset, color_blocks, detail_blocks, outdir, pack = sys.argv[1:9]
jobs = int(jobs)
base = os.path.basename(pack)
outname = profile + "-" + base

# Already compressed: zstd would only cost time. Everything else is tried
# and stored plain when zstd does not save at least 3 percent.
STORE_EXT = {"jpg", "jpeg", "png", "ogg", "opus", "mp3", "pk3", "zip", "gz", "ktx"}

# bytes of one 128 bit ASTC block
ASTC_BLOCK = 16
KTX_ID = b"\xabKTX 11\xbb\r\n\x1a\n"
# glInternalFormat of GL_COMPRESSED_RGBA_ASTC_<n>x<m>_KHR
ASTC_FORMATS = {(4, 4): 0x93B0, (5, 4): 0x93B1, (5, 5): 0x93B2, (6, 5): 0x93B3, (6, 6): 0x93B4,
                (8, 5): 0x93B5, (8, 6): 0x93B6, (8, 8): 0x93B7, (10, 5): 0x93B8, (10, 6): 0x93B9,
                (10, 8): 0x93BA, (10, 10): 0x93BB, (12, 10): 0x93BC, (12, 12): 0x93BD}
COLOR_BLOCKS = tuple(int(x) for x in color_blocks.split("x"))
DETAIL_BLOCKS = tuple(int(x) for x in detail_blocks.split("x"))
if COLOR_BLOCKS not in ASTC_FORMATS or DETAIL_BLOCKS not in ASTC_FORMATS:
    sys.exit("unsupported ASTC block size")
GL_RGB, GL_RGBA = 0x1907, 0x1908


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-threads", "1", *args],
                   check=True, stdin=subprocess.DEVNULL)


def opus_packet_samples(pkt):
    """Samples (48 kHz) in one Opus packet, from its TOC byte."""
    toc, config, code = pkt[0], pkt[0] >> 3, pkt[0] & 3
    if config < 12:
        frame = (480, 960, 1920, 2880)[config & 3]
    elif config < 16:
        frame = (480, 960)[config & 1]
    else:
        frame = (120, 240, 480, 960)[config & 3]
    return frame * (1 if code == 0 else 2 if code < 3 else pkt[1] & 63)


def opus_is_sane(data):
    """False when the page granule positions of an Ogg Opus file disagree with
    the audio in the pages. libopusfile refuses such a file (OP_EBADTIMESTAMP)
    and the game then cannot play the sound. Only the last page may be short."""
    pos, total, last_gp, seen = 0, 0, None, 0
    while pos + 27 <= len(data):
        if data[pos:pos + 4] != b"OggS":
            return False
        nseg = data[pos + 26]
        table = data[pos + 27:pos + 27 + nseg]
        gp = struct.unpack_from("<q", data, pos + 6)[0]
        body = pos + 27 + nseg
        size = 0
        for lacing in table:
            size += lacing
            if lacing < 255:  # a packet ends here
                if seen >= 2 and size:
                    total += opus_packet_samples(data[body:body + size])
                seen += 1
                body += size
                size = 0
        body += size
        eos = data[pos + 5] & 4
        if seen > 2 and gp >= 0 and not eos and gp != total:
            return False
        if eos and seen > 2 and gp > total:
            return False
        pos = body
    return seen > 2


def to_opus(name, data):
    """Ogg Vorbis to Ogg Opus; None when it cannot be done."""
    # sound effects do well at a low rate, music gets more
    rate = "56k" if name.startswith("sound/") and "cdtracks" not in name else "96k"
    with tempfile.TemporaryDirectory() as t:
        src, wav, dst = os.path.join(t, "in.ogg"), os.path.join(t, "mid.wav"), os.path.join(t, "out.opus")
        with open(src, "wb") as f:
            f.write(data)
        try:
            # Decode to 48 kHz PCM first and encode from that. Feeding the
            # Vorbis decoder straight into libopus makes ffmpeg write page
            # granule positions that libopusfile rejects when the source is not
            # 48 kHz (hagar_fire, rocket_fire); a PCM source does not.
            ffmpeg("-i", src, "-map", "0:a:0", "-ar", "48000", "-c:a", "pcm_s16le", wav)
            # the -map_metadata options keep the loop and ReplayGain tags the engine reads
            ffmpeg("-i", wav, "-i", src, "-map", "0:a:0", "-map_metadata", "1", "-map_metadata:s:a:0", "1:s:a:0", "-c:a", "libopus",
                   "-b:a", rate, "-vbr", "on", "-application", "audio", dst)
            with open(dst, "rb") as f:
                out = f.read()
        except (subprocess.CalledProcessError, OSError) as e:
            print("  %s: kept as Ogg (%s)" % (name, e), file=sys.stderr)
            return None
    if not opus_is_sane(out):
        print("  %s: kept as Ogg (bad Opus timestamps)" % name, file=sys.stderr)
        return None
    return out if len(out) < len(data) else None


def dds_info(data):
    """(width, height, mip levels, fourcc) of a DXT1/3/5 DDS file, else None."""
    if len(data) < 128 or data[:4] != b"DDS ":
        return None
    height, width = struct.unpack_from("<II", data, 12)
    levels = struct.unpack_from("<I", data, 28)[0] if struct.unpack_from("<I", data, 108)[0] & 0x400000 else 1
    pf_flags = struct.unpack_from("<I", data, 80)[0]
    fourcc = data[84:88]
    if not pf_flags & 4 or fourcc not in (b"DXT1", b"DXT2", b"DXT3", b"DXT4", b"DXT5"):
        return None
    if width < 1 or height < 1:
        return None
    return width, height, max(levels, 1), fourcc


def has_alpha(data, fourcc, width, height):
    """False when a DXT3/DXT5 texture is opaque everywhere (the engine then
    skips blending); looks at the top level only."""
    if fourcc == b"DXT1":
        return False
    blocks = ((width + 3) // 4) * ((height + 3) // 4)
    top = data[128:128 + blocks * 16]
    if fourcc in (b"DXT5", b"DXT4"):
        # alpha endpoints 255 and 255: every texel is 255
        return not (top[0::16].count(255) == blocks and top[1::16].count(255) == blocks)
    # DXT3: 8 bytes of 4 bit alpha ahead of the colors, all ones when opaque
    return not all(top[j::16].count(255) == blocks for j in range(8))


def block_size(name):
    """Normal maps and the 2D graphics show blockiness the most: they get
    the small blocks."""
    stem = name.rsplit(".", 1)[0]
    if stem.endswith("_norm") or name.startswith("dds/gfx/"):
        return DETAIL_BLOCKS
    return COLOR_BLOCKS


def to_astc(name, data):
    """A DDS file to a KTX 1 file of ASTC levels; None when it cannot be done."""
    info = dds_info(data)
    if info is None:
        return None
    width, height, levels, fourcc = info
    alpha = has_alpha(data, fourcc, width, height)
    bw, bh = block_size(name)
    srgb_flag = "-cl" if name.rsplit(".", 1)[0].endswith("_norm") else "-cs"
    sizes = [(max(width >> i, 1), max(height >> i, 1)) for i in range(levels)]
    with tempfile.TemporaryDirectory() as t:
        src = os.path.join(t, "in.dds")
        with open(src, "wb") as f:
            f.write(data)
        # one decode of the top level, scaled down with a box filter to every
        # level, and to one pixel for the average color the engine wants
        chain = "[0:v]format=rgba,split=%d%s;" % (levels + 1, "".join("[s%d]" % i for i in range(levels + 1)))
        outs = []
        parts = []
        for i, (w, h) in enumerate(sizes):
            parts.append("[s%d]scale=%d:%d:flags=area[l%d]" % (i, w, h, i) if i else "[s0]null[l0]")
            outs += ["-map", "[l%d]" % i, "-frames:v", "1", "-compression_level", "1", os.path.join(t, "l%d.png" % i)]
        parts.append("[s%d]scale=1:1:flags=area[avg]" % levels)
        outs += ["-map", "[avg]", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", os.path.join(t, "avg.raw")]
        try:
            ffmpeg("-i", src, "-filter_complex", chain + ";".join(parts), *outs)
            images = []
            for i, (w, h) in enumerate(sizes):
                png = os.path.join(t, "l%d.png" % i)
                astc = os.path.join(t, "l%d.astc" % i)
                subprocess.run([astcenc, srgb_flag, png, astc, "%dx%d" % (bw, bh), preset, "-silent", "-j", "1"],
                               check=True, stdin=subprocess.DEVNULL)
                with open(astc, "rb") as f:
                    blocks = f.read()[16:]
                if len(blocks) != -(-w // bw) * -(-h // bh) * ASTC_BLOCK:
                    raise ValueError("unexpected astcenc output size")
                images.append(blocks)
            with open(os.path.join(t, "avg.raw"), "rb") as f:
                avg = f.read(4)
        except (subprocess.CalledProcessError, OSError, ValueError) as e:
            print("  %s: kept as DDS (%s)" % (name, e), file=sys.stderr)
            return None
    # key/value data: the average color the DDS loader would have computed
    kv = b"DPAVGCOLOR\0" + avg
    kv = struct.pack("<I", len(kv)) + kv
    kv += b"\0" * (-len(kv) % 4)
    out = [KTX_ID, struct.pack("<13I", 0x04030201, 0, 1, 0, ASTC_FORMATS[(bw, bh)],
                               GL_RGBA if alpha else GL_RGB, width, height, 0, 0, 1, levels, len(kv)), kv]
    for blocks in images:
        out.append(struct.pack("<I", len(blocks)))
        out.append(blocks)
        out.append(b"\0" * (-len(blocks) % 4))
    return b"".join(out)


def convert(item):
    """(name, data, attr, how) of the entry that replaces one of the source."""
    name, data, attr = item
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if ext == "ogg":
        opus = to_opus(name, data)
        if opus is not None:
            return name[:-3] + "opus", opus, attr, "audio"
    elif ext == "dds" and profile == "android":
        ktx = to_astc(name, data)
        if ktx is not None:
            return name[:-3] + "ktx", ktx, attr, "textures"
    return name, data, attr, "other"


def compress(name, data):
    """(method, bytes): zstd when it pays, else stored."""
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if ext in STORE_EXT or len(data) < 64:
        return 0, data
    c = zstd.compress(data, 19 if len(data) <= 16 << 20 else 15)
    return (93, c) if len(c) < len(data) * 0.97 else (0, data)


def is_symlink(attr):
    return (attr >> 16) & 0o170000 == 0o120000


# a minimal zip writer: the python zipfile cannot write a zstd entry with the
# content size in the frame header, which keeps the engine's decoder window small
class ZipOut:
    def __init__(self, path):
        self.f = open(path, "wb")
        self.entries = []

    def add(self, name, method, cdata, usize, crc, attr):
        raw = name.encode("utf-8")
        offset = self.f.tell()
        version = 63 if method == 93 else 20
        self.f.write(struct.pack("<IHHHHHIIIHH", 0x04034B50, version, 0, method, 0, 0x21, crc, len(cdata), usize, len(raw), 0))
        self.f.write(raw)
        self.f.write(cdata)
        self.entries.append((raw, method, version, crc, len(cdata), usize, attr, offset))

    def close(self):
        start = self.f.tell()
        for raw, method, version, crc, csize, usize, attr, offset in self.entries:
            if offset >= 1 << 32 or csize >= 1 << 32:
                raise OverflowError("pack too big for plain zip")
            self.f.write(struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, (3 << 8) | version, version, 0, method, 0, 0x21,
                                     crc, csize, usize, len(raw), 0, 0, 0, 0, attr, offset))
            self.f.write(raw)
        size = self.f.tell() - start
        if len(self.entries) >= 1 << 16:
            raise OverflowError("too many entries for plain zip")
        self.f.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(self.entries), len(self.entries), size, start, 0))
        self.f.close()


stats = {"audio": [0, 0], "textures": [0, 0], "other": [0, 0]}
result = os.path.join(outdir, outname)
out = ZipOut(result + ".part")
converted = set()  # source names of the dds files that became ktx
links = []  # symlink entries wait until it is known what became of their targets
seen = set()


def emit(name, data, attr, how, src_size):
    if name in seen:
        print("  duplicate entry %s dropped" % name, file=sys.stderr)
        return
    seen.add(name)
    method, cdata = compress(name, data)
    out.add(name, method, cdata, len(data), zlib.crc32(data), attr)
    stats[how][0] += src_size
    stats[how][1] += len(cdata)


with zipfile.ZipFile(pack) as zin, ThreadPoolExecutor(jobs) as pool:
    zin_lock = threading.Lock()
    todo = []
    for info in zin.infolist():
        if info.is_dir():
            continue
        if is_symlink(info.external_attr):
            links.append((info.filename, zin.read(info), info.external_attr))
        else:
            todo.append(info)

    def work(info):
        with zin_lock:
            data = zin.read(info)
        return info.file_size, convert((info.filename, data, info.external_attr))

    # a window of entries at a time keeps the memory in check
    window = max(jobs * 4, 8)
    for i in range(0, len(todo), window):
        for src_size, (name, data, attr, how) in pool.map(work, todo[i:i + window]):
            if how == "textures":
                converted.add(name[:-3] + "dds")
            emit(name, data, attr, how, src_size)

for name, target, attr in links:
    text = target.decode("utf-8", "replace")
    if name.endswith(".dds") and text.endswith(".dds"):
        # relative to the directory of the link
        full = os.path.normpath(os.path.join(os.path.dirname(name), text)).replace(os.sep, "/")
        if full in converted:
            name, target = name[:-3] + "ktx", (text[:-3] + "ktx").encode()
    emit(name, target, attr, "other", len(target))

out.close()
os.replace(result + ".part", result)

with open(result, "rb") as f:
    crc = 0
    while True:
        chunk = f.read(1 << 22)
        if not chunk:
            break
        crc = zlib.crc32(chunk, crc)
size = os.path.getsize(result)
before = os.path.getsize(pack)
with open(os.path.join(outdir, "manifest-%s.txt" % profile), "a") as f:
    f.write("%s %d %08x %s\n" % (outname, size, crc, base))
with open(os.path.join(outdir, "sizes-%s.md" % profile), "a") as f:
    f.write("| %s | %.1f MB | %.1f MB |\n" % (base, before / 1e6, size / 1e6))
for how, (b, a) in stats.items():
    print("  %-8s %9.1f MB -> %9.1f MB" % (how, b / 1e6, a / 1e6))
print("  %s: %.1f MB -> %.1f MB" % (base, before / 1e6, size / 1e6))
EOF
done
