"""Download OpenStreetMap data for an area from Overpass (with retries).

Usage: python tools/fetch_area.py raw/cfc  S W N E [--only signs.json]
Writes roads.json, areas.json, buildings.json, signs.json and pois.json into the folder.
"""
import json
import sys
import time
import urllib.parse
import urllib.request

out, s, w, n, e = sys.argv[1], *sys.argv[2:6]
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
bbox = f"{s},{w},{n},{e}"
QUERIES = {
    "roads.json": f"""[out:json][timeout:180];
(way["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"]({bbox});
 node["highway"="traffic_signals"]({bbox}););
out geom;""",
    "areas.json": f"""[out:json][timeout:180];
(way["leisure"~"^(garden|park|pitch|stadium|sports_centre|playground|recreation_ground)$"]({bbox});
 way["landuse"~"^(grass|village_green|recreation_ground|meadow|cemetery|greenfield|military|construction|brownfield)$"]({bbox});
 way["amenity"="parking"]({bbox});
 way["natural"~"^(water|sand)$"]({bbox});
 way["leisure"="swimming_pool"]({bbox}););
out geom;""",
    "buildings.json": f"""[out:json][timeout:240];
(way["building"]({bbox}); relation["building"]({bbox}););
out geom;""",
    # road signs and markings mapped as points: stop, give way, crossings, speed cameras, sign codes
    "signs.json": f"""[out:json][timeout:180];
(node["highway"~"^(stop|give_way|crossing|speed_camera|traffic_signals)$"]({bbox});
 node["traffic_sign"]({bbox});
 node["enforcement"]({bbox});
 node["crossing"]({bbox}););
out;""",
    # named places for the search box (OSM has English and Arabic names: name, name:en, name:ar)
    "pois.json": f"""[out:json][timeout:240];
(nwr["name"]["amenity"]({bbox}); nwr["name"]["shop"]({bbox}); nwr["name"]["tourism"]({bbox});
 nwr["name"]["leisure"]({bbox}); nwr["name"]["office"]({bbox}); nwr["name"]["healthcare"]({bbox});
 nwr["name"]["building"]({bbox}); nwr["name"]["place"]({bbox}); nwr["name"]["landuse"]({bbox});
 nwr["name"]["historic"]({bbox}); nwr["name"]["public_transport"="station"]({bbox}); nwr["name"]["railway"="station"]({bbox}););
out tags center;""",
}
SERVERS = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"]

for name, q in QUERIES.items():
    if only and name != only:
        continue
    for attempt in range(8):
        url = SERVERS[attempt % len(SERVERS)]
        try:
            req = urllib.request.Request(url, data=urllib.parse.urlencode({"data": q}).encode(),
                                         headers={"User-Agent": "map-demo-builder/1.0"})
            with urllib.request.urlopen(req, timeout=300) as r:
                data = json.loads(r.read().decode("utf-8"))
            with open(f"{out}/{name}", "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            print(name, len(data["elements"]), "elements")
            break
        except Exception as ex:
            print(name, "attempt", attempt + 1, "failed:", str(ex)[:100])
            time.sleep(10 + attempt * 10)
    else:
        sys.exit(f"could not download {name}")
