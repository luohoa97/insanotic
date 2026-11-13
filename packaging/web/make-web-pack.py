#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the browser's game data: the files one map load actually opens.

    make-web-pack.py --data DIR --preload insanotic_preload.txt --out web-pack

DIR is a game data directory (what the engine ran from): the official
xonotic-*.pk3 packs and the pk3dirs next to them. The preload list is what the
engine wrote (insanotic_preload.txt: every file a map load and its first
seconds of play opened, see FS_RecordStart in the engine). Each listed file is
taken from where the engine found it (a pk3dir wins over a pack, as in the
engine) and written to one pk3. The font packs go in whole (the menu opens them
before the list starts). The result is split into web-pack-01.pk3, -02, ...
of at most --part-mb each: a browser stores a file in IndexedDB as one value
(Chromium refuses more than ~128 MB), so one big pack cannot be kept. Also prints the map name when --pick-map is given:
the smallest map in the maps pack.
"""
import argparse, glob, os, sys, zipfile

ap = argparse.ArgumentParser()
ap.add_argument("--data", required=True)
ap.add_argument("--preload")
ap.add_argument("--out", help="output prefix: PREFIX-01.pk3, PREFIX-02.pk3, ...")
ap.add_argument("--part-mb", type=int, default=80)
ap.add_argument("--pick-map", action="store_true")
ap.add_argument("--extra", action="append", default=[], help="file name to add besides the list")
args = ap.parse_args()

packs = sorted(glob.glob(os.path.join(args.data, "*.pk3")))
dirs = sorted(glob.glob(os.path.join(args.data, "*.pk3dir")))
# engine order: packs sorted, then pk3dirs (later wins)
opened = [(p, zipfile.ZipFile(p)) for p in packs if "compat" not in p]

if args.pick_map:
    best = None
    for p, z in opened:
        for i in z.infolist():
            if i.filename.startswith("maps/") and i.filename.endswith(".bsp") \
                    and not os.path.basename(i.filename).startswith("_"):  # _init is the menu's empty map
                if best is None or i.file_size < best[0]:
                    best = (i.file_size, os.path.basename(i.filename)[:-4])
    print(best[1])
    sys.exit(0)

names = [l.strip() for l in open(args.preload) if l.strip()] + args.extra
seen, missing, total = set(), [], 0
parts, out = [], None
limit = args.part_mb * 1048576

def add(name, data):
    global total, out
    if name in seen:
        return
    seen.add(name)
    if out is None or os.path.getsize(parts[-1]) > limit:
        if out: out.close()
        parts.append("%s-%02d.pk3" % (args.out, len(parts) + 1))
        out = zipfile.ZipFile(parts[-1], "w", zipfile.ZIP_DEFLATED, compresslevel=9)
    out.writestr(name, data)
    out.fp.flush()
    total += len(data)

if True:
    for name in names:
        data = None
        for d in reversed(dirs):
            f = os.path.join(d, name)
            if os.path.isfile(f):
                data = open(f, "rb").read()
                break
        if data is None:
            for p, z in reversed(opened):
                try:
                    data = z.read(name)
                    break
                except KeyError:
                    pass
        if data is None:
            missing.append(name)
            continue
        add(name, data)
    # what the engine opens before the list starts: game code (progs.dat,
    # menu.dat), configs, shaders and Insanotic's own files from the pk3dirs
    for d in dirs:
        whole = os.path.basename(d).startswith("insanotic")
        for root, _, files in os.walk(d):
            for fn in files:
                f = os.path.join(root, fn)
                rel = os.path.relpath(f, d).replace(os.sep, "/")
                if rel.startswith((".git/", "qcsrc/")) or os.path.getsize(f) > 8 * 1048576:
                    continue
                top = "/" not in rel
                if whole or rel.startswith(("scripts/", "ui/", "mods/", "plugins/")) \
                        or (top and rel.endswith((".cfg", ".dat", ".txt", ".rc", ".lst"))):
                    add(rel, open(f, "rb").read())
    # fonts and anything else the menu needs before the list begins
    for p, z in opened:
        if os.path.basename(p).startswith("font-"):
            for i in z.infolist():
                if not i.is_dir():
                    add(i.filename, z.read(i.filename))
out.close()
print("%d files, %.1f MB uncompressed, %d packs (%.1f MB); %d listed names not found"
      % (len(seen), total / 1048576, len(parts), sum(os.path.getsize(x) for x in parts) / 1048576, len(missing)))
for m in missing[:40]:
    print("  not found:", m)
