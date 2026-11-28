"""Overture extras for search and speed limits (GeoParquet over HTTPS via DuckDB).

Usage: python tools/fetch_overture_extra.py raw/greater S W N E [release]
Writes:
  overture_places_full.json  places with every name (Arabic, English, alternates),
                             brand, address and categories, confidence > 0.3
  overture_speed.json        road segments that carry a speed limit
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


def rows(q):
    r = con.execute(q).fetchall()
    cols = [d[0] for d in con.description]
    return [dict(zip(cols, x)) for x in r]


p = rows(f"""SELECT id, names.primary AS name, to_json(names.common) AS common, to_json(names.rules) AS rules, to_json(phones) AS phones,
       brand.names.primary AS brand, COALESCE(basic_category, taxonomy.primary) AS cat,
       to_json(taxonomy.alternates) AS alt, to_json(addresses) AS addr, confidence AS conf,
       ST_X(geometry) AS lon, ST_Y(geometry) AS lat
FROM read_parquet('{base}/theme=places/type=place/*', hive_partitioning=1) WHERE {box} AND confidence > 0.3""")
for x in p:
    for k in ("common", "rules", "alt", "addr", "phones"):
        x[k] = json.loads(x[k]) if x[k] else None
json.dump(p, open(f"{out}/overture_places_full.json", "w", encoding="utf-8"), ensure_ascii=False)
print("places", len(p))

sg = rows(f"""SELECT id, class, names.primary AS name, to_json(speed_limits) AS sl, to_json(sources) AS src,
       ST_AsGeoJSON(geometry) AS g
FROM read_parquet('{base}/theme=transportation/type=segment/*', hive_partitioning=1)
WHERE {box} AND subtype = 'road' AND speed_limits IS NOT NULL""")
for x in sg:
    x["sl"] = json.loads(x["sl"]); x["src"] = json.loads(x["src"]); x["g"] = json.loads(x["g"])
json.dump(sg, open(f"{out}/overture_speed.json", "w", encoding="utf-8"), ensure_ascii=False)
print("segments with speed limits", len(sg))
