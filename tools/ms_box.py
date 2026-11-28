"""Cut raw Microsoft building footprints for a bounding box out of the country file.

Usage: python tools/ms_box.py raw/ms/cairo.csv.gz raw/greater/ms_box.json S W N E
Input: one GeoJSON feature per line (Microsoft Global ML Building Footprints, ODbL).
Output: a JSON list of outer rings ([lon, lat] pairs, 6 decimals) whose first point is in the box.
"""
import gzip
import json
import sys

src, out, s, w, n, e = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:7])
rings = []
with gzip.open(src, "rt", encoding="utf-8") as f:
    for line in f:
        line = line.strip().rstrip(",")
        if not line.startswith("{"):
            continue
        g = json.loads(line)["geometry"]
        ring = g["coordinates"][0] if g["type"] == "Polygon" else g["coordinates"][0][0]
        x, y = ring[0]
        if w <= x <= e and s <= y <= n:
            rings.append([[round(p[0], 6), round(p[1], 6)] for p in ring])
json.dump(rings, open(out, "w"))
print(len(rings), "footprints")
