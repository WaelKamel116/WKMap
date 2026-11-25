"""Download Overture Maps buildings and places for a bounding box (GeoParquet over HTTPS via DuckDB).

Usage: python tools/fetch_overture.py raw/cfc S W N E [release]
Writes overture_buildings.json and overture_places.json (GeoJSON-like lists).
Overture data: ODbL (buildings incl. OSM), CDLA-Permissive-2.0 / CC BY 4.0 for other sources; see sources field.
"""
import json, sys, duckdb

out, s, w, n, e = sys.argv[1], *map(float, sys.argv[2:6])
rel = sys.argv[6] if len(sys.argv) > 6 else "2026-11-18.0"
base = f"s3://overturemaps-us-west-2/release/{rel}"
con = duckdb.connect()
for ext in ("httpfs", "spatial"):
    con.execute(f"INSTALL {ext}; LOAD {ext};")
con.execute("SET s3_region='us-west-2';")
box = f"bbox.xmin < {e} AND bbox.xmax > {w} AND bbox.ymin < {n} AND bbox.ymax > {s}"

q = f"""SELECT id, height, num_floors, class, subtype, roof_shape, facade_color, facade_material, roof_color,
       is_underground, sources[1].dataset AS src, sources[1].confidence AS conf, ST_AsGeoJSON(geometry) AS g
FROM read_parquet('{base}/theme=buildings/type=building/*', hive_partitioning=1) WHERE {box}"""
rows = con.execute(q).fetchall()
cols = [d[0] for d in con.description]
b = [dict(zip(cols, r)) for r in rows]
for x in b: x["g"] = json.loads(x["g"])
json.dump(b, open(f"{out}/overture_buildings.json", "w", encoding="utf-8"), ensure_ascii=False)
from collections import Counter
print("buildings", len(b), Counter(x["src"] for x in b), "with height", sum(1 for x in b if x["height"]), "with floors", sum(1 for x in b if x["num_floors"]))

q = f"""SELECT id, names.primary AS name, COALESCE(basic_category, taxonomy.primary) AS cat, confidence AS conf, ST_X(geometry) AS lon, ST_Y(geometry) AS lat
FROM read_parquet('{base}/theme=places/type=place/*', hive_partitioning=1) WHERE {box} AND confidence > 0.5"""
rows = con.execute(q).fetchall()
cols = [d[0] for d in con.description]
p = [dict(zip(cols, r)) for r in rows]
json.dump(p, open(f"{out}/overture_places.json", "w", encoding="utf-8"), ensure_ascii=False)
print("places", len(p), Counter(x["cat"] for x in p).most_common(12))
