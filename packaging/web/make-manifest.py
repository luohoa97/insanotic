#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Writes the loader's manifest.json for the packs in DIR/data (sorted by name,
the order the engine loads them in): make-manifest.py DIR [MAP]"""
import json, os, sys
d = sys.argv[1]
packs = [{"name": n, "url": "data/" + n, "size": os.path.getsize(os.path.join(d, "data", n))}
         for n in sorted(os.listdir(os.path.join(d, "data"))) if n.endswith(".pk3")]
m = {"packs": packs, "args": []}
if len(sys.argv) > 2 and sys.argv[2]:
    m["map"] = sys.argv[2]
json.dump(m, open(os.path.join(d, "manifest.json"), "w"), indent=1)
