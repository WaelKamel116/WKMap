"""Build the phone app's map data for a drive corridor from several open sources.

Sources (raw/<area>/):
  route_osrm.json          planned route (OSRM)
  roads.json               OpenStreetMap roads, bridges, traffic signals (tools/fetch_area.py)
  areas.json               OpenStreetMap parks, parking, water (optional)
  overture_buildings.json  Overture Maps buildings = OSM + Microsoft + Google Open Buildings,
                           already conflated by Overture (tools/fetch_overture.py)
  overture_places.json     Overture places (shops, restaurants, clinics, ...)
  ms_box.json              raw Microsoft footprints for the box: gap-filler (lowest priority),
                           added only where no other source has a building

Merge rules (each step is counted in the report at the end):
  1. Corridor: buildings and small streets within CORRIDOR m of the route(s); main roads,
     flyovers and signals for the whole box, so a different way between the same places still works.
  2. Buildings: drop tiny (<20 m2) and low-confidence (<0.65) machine-detected shapes;
     drop duplicates (centroid inside an already kept building of a higher-priority source:
     OSM > Microsoft > Google); drop footprints sitting on a main road or flyover.
  3. Height: real height or floors when a source has them; otherwise estimated from footprint
     area and neighbourhood (Nasr City apartment blocks vs New Cairo villas/compounds), with a
     stable per-building variation. Buildings with shops/offices inside get a commercial flag.
  4. Flyovers: OSM bridge ways; deck height 7 m per OSM layer (layer 2 = 14 m), ramps at 5.5 %
     measured along the structure from its free ends.

Usage: python tools/build_area.py cfc [--extra-route raw/route3.json] [--out app/assets/data]
"""
import argparse, hashlib, heapq, json, math, os
from collections import Counter

ap = argparse.ArgumentParser()
ap.add_argument("area")
ap.add_argument("--extra-route", action="append", default=[], help="more OSRM route files whose corridor is kept")
ap.add_argument("--out", default="app/assets/data")
ap.add_argument("--corridor", type=float, default=500.0)
args = ap.parse_args()

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "raw", args.area)
OUT = os.path.join(ROOT, args.out)
os.makedirs(OUT, exist_ok=True)
report = Counter()

LON0, LAT0 = 31.34, 30.07
MX = 111320 * math.cos(math.radians(LAT0))
MY = 110540


def xy(p): return ((p[0] - LON0) * MX, (p[1] - LAT0) * MY)
def ll(x, y): return [round(LON0 + x / MX, 6), round(LAT0 + y / MY, 6)]
def dist(a, b):
    ax, ay = xy(a); bx, by = xy(b)
    return math.hypot(ax - bx, ay - by)
def bearing(a, b):
    ax, ay = xy(a); bx, by = xy(b)
    return (math.degrees(math.atan2(bx - ax, by - ay)) + 360) % 360
def r6(c): return [round(c[0], 6), round(c[1], 6)]
def load(path):
    with open(path, encoding="utf-8") as f: return json.load(f)
def dump(name, obj):
    p = os.path.join(OUT, name)
    with open(p, "w", encoding="utf-8") as f: json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  {name:16s} {os.path.getsize(p) // 1024:6d} KB")
def fc(features): return {"type": "FeatureCollection", "features": features}


def densify(g, step):
    out = [g[0]]
    for a, b in zip(g, g[1:]):
        n = max(1, int(dist(a, b) // step))
        for k in range(1, n + 1):
            out.append([a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n])
    return out


# ------------------------------------------------------------------ routes and corridor index
def route_coords(path):
    r = load(path)["routes"][0]
    return [r6(c) for c in r["geometry"]["coordinates"]], [s for leg in r["legs"] for s in leg["steps"]]

rcoords, steps = route_coords(os.path.join(RAW, "route_osrm.json"))
corr_pts = densify(rcoords, 40)
for extra in args.extra_route:
    corr_pts += densify(route_coords(os.path.join(ROOT, extra))[0], 40)
CG = 0.004  # ~400 m grid
corr_grid = {}
for p in corr_pts:
    corr_grid.setdefault((int(p[0] / CG), int(p[1] / CG)), []).append(p)


def near_route(c, m=args.corridor):
    gx, gy = int(c[0] / CG), int(c[1] / CG)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for p in corr_grid.get((gx + dx, gy + dy), []):
                if dist(p, c) < m + 25:  # +25: half the 40 m sample spacing
                    return True
    return False


# ------------------------------------------------------------------ roads
elements = load(os.path.join(RAW, "roads.json"))["elements"]
ways = {e["id"]: e for e in elements if e["type"] == "way" and "highway" in e.get("tags", {})}
CLASS = {"motorway": "major", "trunk": "major", "primary": "major", "secondary": "medium", "tertiary": "medium",
         "motorway_link": "link", "trunk_link": "link", "primary_link": "link", "secondary_link": "link",
         "tertiary_link": "link", "residential": "minor", "unclassified": "minor", "living_street": "minor",
         "service": "service"}
DEFAULT_LANES = {"major": 3, "medium": 2, "link": 1, "minor": 1, "service": 1}


def lanes_of(t, cls):
    try:
        return int(str(t.get("lanes")).split(";")[0])
    except Exception:
        return None


def name_of(t): return t.get("name:en") or t.get("name", "")


ground_roads, bridge_ways = [], []
for w in ways.values():
    t = w["tags"]; cls = CLASS.get(t["highway"])
    if not cls:
        continue
    g = [r6([p["lon"], p["lat"]]) for p in w["geometry"]]
    lanes = lanes_of(t, cls)
    if t.get("bridge") not in (None, "no") and cls in ("major", "medium", "link"):
        try:
            layer = max(1, int(t.get("layer", "1")))
        except ValueError:
            layer = 1
        bridge_ways.append((w, g, cls, lanes, layer))
        continue
    if t.get("tunnel") not in (None, "no"):
        report["roads: tunnels skipped"] += 1
        continue
    if cls in ("minor", "service") and not any(near_route(c, args.corridor + 150) for c in g[:: max(1, len(g) // 4)] + [g[-1]]):
        report["roads: small streets outside corridor"] += 1
        continue
    ground_roads.append({"type": "Feature", "properties": {"c": cls, "n": name_of(t), "l": lanes or DEFAULT_LANES[cls],
                                                           "ow": 1 if t.get("oneway") == "yes" else 0},
                         "geometry": {"type": "LineString", "coordinates": g}})
report["roads: kept ground"] = len(ground_roads)
report["roads: flyover/bridge pieces"] = len(bridge_ways)
report["roads: with OSM lane count"] = sum(1 for w in ways.values() if "lanes" in w["tags"])

signals = [{"type": "Feature", "properties": {}, "geometry": {"type": "Point", "coordinates": r6([e["lon"], e["lat"]])}}
           for e in elements if e["type"] == "node" and e.get("tags", {}).get("highway") == "traffic_signals"]
report["signals (OSM)"] = len(signals)

# ------------------------------------------------------------------ parks / parking / water
areas = []
apath = os.path.join(RAW, "areas.json")
if os.path.exists(apath):
    green = {"garden", "grass", "park", "village_green", "recreation_ground", "meadow", "playground", "cemetery", "greenfield"}
    for e in load(apath)["elements"]:
        t = e.get("tags", {}); g = e.get("geometry")
        if e["type"] != "way" or not g or len(g) < 4:
            continue
        ring = [r6([p["lon"], p["lat"]]) for p in g]
        if ring[0] != ring[-1] or not near_route(ring[0], args.corridor + 300):
            continue
        v = t.get("leisure") or t.get("landuse") or t.get("amenity") or t.get("natural")
        kind = ("pitch" if v in ("pitch", "stadium", "sports_centre") else "green" if v in green else
                "paved" if v == "parking" else "water" if v in ("water", "swimming_pool") else
                "bare" if v in ("military", "construction", "brownfield", "sand") else None)
        if kind:
            areas.append({"type": "Feature", "properties": {"k": kind}, "geometry": {"type": "Polygon", "coordinates": [ring]}})
report["areas (parks, parking, water)"] = len(areas)

# ------------------------------------------------------------------ flyover elevation model
DECK, GRADE = 7.0, 0.055
adj = {}
for w, g, cls, lanes, layer in bridge_ways:
    for p, q in zip(g, g[1:]):
        p, q = tuple(p), tuple(q); L = dist(p, q)
        adj.setdefault(p, []).append((q, L)); adj.setdefault(q, []).append((p, L))
dfe = {v: 0.0 for v, nb in adj.items() if len(nb) == 1}
pq = [(0.0, v) for v in dfe]
while pq:
    d0, v = heapq.heappop(pq)
    if d0 > dfe.get(v, 1e18):
        continue
    for u, L in adj[v]:
        if d0 + L < dfe.get(u, 1e18):
            dfe[u] = d0 + L; heapq.heappush(pq, (d0 + L, u))
way_layer = {}
for w, g, cls, lanes, layer in bridge_ways:
    for p in g:
        way_layer[tuple(p)] = max(way_layer.get(tuple(p), 1), layer)


def elev_seg(a, b, t, layer=1):
    da, db = dfe.get(tuple(a), 1e9), dfe.get(tuple(b), 1e9)
    L = dist(a, b)
    return min(DECK * layer, min(da + t * L, db + (1 - t) * L) * GRADE)


SG = 0.0004
seg_grid = {}
for w, g, cls, lanes, layer in bridge_ways:
    for p, q in zip(g, g[1:]):
        for gx in range(int(min(p[0], q[0]) / SG), int(max(p[0], q[0]) / SG) + 1):
            for gy in range(int(min(p[1], q[1]) / SG), int(max(p[1], q[1]) / SG) + 1):
                seg_grid.setdefault((gx, gy), []).append((p, q, layer))


def bridge_height_at(c, hdg, tol=1.5):
    best = None
    for p, q, layer in seg_grid.get((int(c[0] / SG), int(c[1] / SG)), []):
        if abs(((bearing(p, q) - hdg + 540) % 360) - 180) > 30:
            continue
        px, py = xy(p); qx, qy = xy(q); cx, cy = xy(c)
        dx, dy = qx - px, qy - py
        t = max(0, min(1, ((cx - px) * dx + (cy - py) * dy) / (dx * dx + dy * dy or 1e-9)))
        d = math.hypot(px + t * dx - cx, py + t * dy - cy)
        if d < tol and (best is None or d < best[0]):
            best = (d, elev_seg(p, q, t, layer))
    return best[1] if best else 0.0


def quad(a, b, half):
    ax, ay = xy(a); bx, by = xy(b)
    dx, dy = bx - ax, by - ay; L = math.hypot(dx, dy) or 1
    nx, ny = -dy / L * half, dx / L * half; ex, ey = dx / L * 0.6, dy / L * 0.6
    return [ll(ax - ex + nx, ay - ey + ny), ll(bx + ex + nx, by + ey + ny), ll(bx + ex - nx, by + ey - ny),
            ll(ax - ex - nx, ay - ey - ny), ll(ax - ex + nx, ay - ey + ny)]


decks, pillars, bridge_lines, deck_polys = [], [], [], []
for w, g, cls, lanes, layer in bridge_ways:
    half = (lanes or (2 if cls != "link" else 1)) * 3.4 / 2 + 0.8
    run = 0.0
    for p, q in zip(g, g[1:]):
        n = max(1, int(dist(p, q) // 8))
        for k in range(n):
            t0, t1 = k / n, (k + 1) / n
            a = [p[0] + (q[0] - p[0]) * t0, p[1] + (q[1] - p[1]) * t0]
            b = [p[0] + (q[0] - p[0]) * t1, p[1] + (q[1] - p[1]) * t1]
            h = (elev_seg(p, q, t0, layer) + elev_seg(p, q, t1, layer)) / 2
            poly = quad(a, b, half)
            decks.append({"type": "Feature", "properties": {"b": round(max(h - 0.9, 0), 2), "h": round(h, 2)},
                          "geometry": {"type": "Polygon", "coordinates": [poly]}})
            deck_polys.append(poly)
            run += dist(a, b)
            if run > 32 and h > 3.5:
                run = 0
                mx, my = xy([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]); s = 0.9
                pillars.append({"type": "Feature", "properties": {"h": round(h - 0.9, 2)},
                                "geometry": {"type": "Polygon", "coordinates": [[ll(mx - s, my - s), ll(mx + s, my - s),
                                             ll(mx + s, my + s), ll(mx - s, my + s), ll(mx - s, my - s)]]}})
    bridge_lines.append({"type": "Feature", "properties": {"n": name_of(w["tags"])},
                         "geometry": {"type": "LineString", "coordinates": g}})
report["flyover deck pieces"] = len(decks)
report["flyover pillars"] = len(pillars)

# ------------------------------------------------------------------ route profile + maneuvers
rd = densify(rcoords, 4.0)
cum = [0.0]
for i in range(1, len(rd)):
    cum.append(cum[-1] + dist(rd[i - 1], rd[i]))
rel = [round(bridge_height_at(c, bearing(rd[max(i - 1, 0)], rd[max(i, 1)])), 2) for i, c in enumerate(rd)]
report["route km"] = round(cum[-1] / 1000, 2)
report["route km on flyovers"] = round(sum(cum[i] - cum[i - 1] for i in range(1, len(rd)) if rel[i] > 0.5) / 1000, 2)
en_names = {w["tags"]["name"]: w["tags"]["name:en"] for w in ways.values() if "name" in w["tags"] and "name:en" in w["tags"]}
maneuvers = []
steps = [st for k, st in enumerate(steps) if not ((st["maneuver"]["type"] == "arrive" and k != len(steps) - 1) or
                                                 (st["maneuver"]["type"] == "depart" and k != 0))]
for s in steps:
    m = s["maneuver"]; loc = m["location"]
    at = min(range(len(rd)), key=lambda i: dist(rd[i], loc))
    nm = s.get("name", "")
    maneuvers.append({"at": round(cum[at], 1), "type": m["type"], "mod": m.get("modifier", ""), "name": nm,
                      "name_en": en_names.get(nm, ""), "in": m.get("bearing_before", 0), "out": m.get("bearing_after", 0)})

# ------------------------------------------------------------------ buildings: merge and validate
def ring_area(ring):
    pts = [xy(p) for p in ring]
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:]))) / 2


def pip(pt, ring):
    x, y = pt; inside = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1 + 1e-15) + x1:
            inside = not inside
    return inside


def centroid(ring):
    pts = ring[:-1]
    return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))


# main carriageways + decks as obstacles: a building whose footprint covers road centreline points is wrong
RG = 0.0005
road_pts = {}
for f in ground_roads:
    if f["properties"]["c"] in ("major", "medium"):
        for p in densify(f["geometry"]["coordinates"], 6):
            road_pts.setdefault((int(p[0] / RG), int(p[1] / RG)), []).append(p)
for w, g, cls, lanes, layer in bridge_ways:
    for p in densify(g, 6):
        road_pts.setdefault((int(p[0] / RG), int(p[1] / RG)), []).append(p)


def on_road(ring):
    xs = [p[0] for p in ring]; ys = [p[1] for p in ring]
    hits = 0
    for gx in range(int(min(xs) / RG), int(max(xs) / RG) + 1):
        for gy in range(int(min(ys) / RG), int(max(ys) / RG) + 1):
            for p in road_pts.get((gx, gy), []):
                if pip(p, ring):
                    hits += 1
                    if hits >= 2:
                        return True
    return False


SRC = {"OpenStreetMap": ("o", 0), "Microsoft ML Buildings": ("m", 1), "Google Open Buildings": ("g", 2)}
ob = load(os.path.join(RAW, "overture_buildings.json"))
report["buildings: Overture in box"] = len(ob)
cands = []
for b in ob:
    g = b["g"]
    polys = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"] if g["type"] == "MultiPolygon" else []
    src, prio = SRC.get(b["src"], ("x", 3))
    for poly in polys:
        ring = [r6(c) for c in poly[0]]
        if len(ring) < 4:
            continue
        c = centroid(ring)
        if not near_route(c):
            report["buildings: outside corridor"] += 1
            continue
        a = ring_area(ring)
        if a < 20:
            report["buildings: dropped tiny (<20 m2)"] += 1
            continue
        if src in ("m", "g") and b["conf"] is not None and 0 <= b["conf"] < 0.65:
            report["buildings: dropped low confidence"] += 1
            continue
        if b.get("is_underground"):
            continue
        cands.append({"ring": ring, "c": c, "a": a, "src": src, "prio": prio, "b": b})

# raw Microsoft footprints as gap-filler (Overture's copy can be older or missing some)
msb = os.path.join(RAW, "ms_box.json")
if os.path.exists(msb):
    for ring in load(msb):
        ring = [r6(c) for c in ring]
        if len(ring) < 4 or ring[0] != ring[-1]:
            continue
        c = centroid(ring)
        if not near_route(c):
            continue
        a = ring_area(ring)
        if a < 20:
            continue
        cands.append({"ring": ring, "c": c, "a": a, "src": "M", "prio": 4, "b": {}})

# duplicate check across sources (Overture conflates, this verifies): higher priority first
cands.sort(key=lambda x: (x["prio"], -x["a"]))
BG = 0.0006
kept_grid, kept = {}, []
for x in cands:
    cx, cy = x["c"]
    dup = False
    for gx in (int(cx / BG) - 1, int(cx / BG), int(cx / BG) + 1):
        for gy in (int(cy / BG) - 1, int(cy / BG), int(cy / BG) + 1):
            for k in kept_grid.get((gx, gy), []):
                if pip((cx, cy), kept[k]["ring"]) or pip(kept[k]["c"], x["ring"]):
                    dup = True; break
            if dup: break
        if dup: break
    if dup:
        report[f"buildings: duplicate removed ({x['src']})"] += 1
        continue
    if on_road(x["ring"]):
        report[f"buildings: on a road/flyover removed ({x['src']})"] += 1
        continue
    idx = len(kept); kept.append(x)
    xs = [p[0] for p in x["ring"]]; ys = [p[1] for p in x["ring"]]
    for gx in range(int(min(xs) / BG), int(max(xs) / BG) + 1):
        for gy in range(int(min(ys) / BG), int(max(ys) / BG) + 1):
            kept_grid.setdefault((gx, gy), []).append(idx)

# places -> commercial flag (shop, restaurant, clinic, bank ... inside or within 8 m of the footprint)
places = load(os.path.join(RAW, "overture_places.json")) if os.path.exists(os.path.join(RAW, "overture_places.json")) else []
COMMERCIAL_SKIP = {None, "residential_building", "apartment_building", "home_service", "real_estate_service"}
TALL = ("hospital", "hotel", "office", "bank", "government")
BIG_LOW = ("shopping_mall", "mall", "supermarket", "hypermarket", "stadium", "mosque", "church", "school", "university")
place_grid = {}
for p in places:
    if p["cat"] in COMMERCIAL_SKIP:
        continue
    place_grid.setdefault((int(p["lon"] / BG), int(p["lat"] / BG)), []).append(p)


def places_in(x):
    xs = [p[0] for p in x["ring"]]; ys = [p[1] for p in x["ring"]]
    out = []
    for gx in range(int(min(xs) / BG), int(max(xs) / BG) + 1):
        for gy in range(int(min(ys) / BG), int(max(ys) / BG) + 1):
            for p in place_grid.get((gx, gy), []):
                if pip((p["lon"], p["lat"]), x["ring"]):
                    out.append(p)
    return out


def new_cairo(c):
    # east of the Ring Road / south-east of Nasr City: villas and compounds, low-rise
    return c[0] > 31.395 or (c[1] < 30.045 and c[0] > 31.36)


def est_height(x, inside):
    b = x["b"]
    if b.get("height"):
        report["height: from source"] += 1
        return float(b["height"])
    if b.get("num_floors"):
        report["height: from floors"] += 1
        return float(b["num_floors"]) * 3.2
    report["height: estimated"] += 1
    a = x["a"]; c = x["c"]
    r = int(hashlib.md5(f"{c[0]:.6f},{c[1]:.6f}".encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    cats = " ".join(p["cat"] or "" for p in inside)
    if any(k in cats for k in BIG_LOW) and a > 1500:
        lv = 3 + int(r * 3)
    elif any(k in cats for k in TALL) and a > 300:
        lv = 6 + int(r * 8)
    elif a < 60:
        lv = 1 + int(r * 2)
    elif new_cairo(c):
        lv = (2 + int(r * 2)) if a < 700 else (4 + int(r * 4)) if a < 3000 else (3 + int(r * 3))
    elif a < 150:
        lv = 3 + int(r * 4)
    elif a < 1500:
        lv = 6 + int(r * 7)  # Nasr City apartment blocks: 6-12 floors
    elif a < 5000:
        lv = 4 + int(r * 6)
    else:
        lv = 2 + int(r * 3)
    return lv * 3.2


bfeat = []
for x in kept:
    inside = places_in(x)
    com = 1 if inside else 0
    report["buildings: with shops/offices"] += com
    bfeat.append({"type": "Feature", "properties": {"h": round(est_height(x, inside), 1), "s": x["src"], "com": com},
                  "geometry": {"type": "Polygon", "coordinates": [x["ring"]]}})
    report[f"buildings: kept from {x['src']}"] += 1
report["buildings: kept total"] = len(bfeat)

# cross-check: every raw Microsoft footprint in the corridor should now be covered by some kept building
if os.path.exists(msb):
    hit = tot = 0
    for ring in load(msb)[::7]:
        c = centroid(ring)
        if not near_route(c) or ring_area(ring) < 30:
            continue
        tot += 1
        cx, cy = c
        if any(pip(c, kept[k]["ring"]) or pip(kept[k]["c"], ring) for gx in (int(cx / BG) - 1, int(cx / BG), int(cx / BG) + 1)
               for gy in (int(cy / BG) - 1, int(cy / BG), int(cy / BG) + 1) for k in kept_grid.get((gx, gy), [])):
            hit += 1
    report["check: Microsoft footprints covered after merge %"] = round(100 * hit / max(tot, 1), 1)

# ------------------------------------------------------------------ write
print("writing to", OUT)
dump("route.json", {"coords": [[c[0], c[1]] for c in rd], "elev": rel, "cum": [round(c, 1) for c in cum],
                    "maneuvers": maneuvers, "distance": round(cum[-1], 1)})
dump("buildings.json", fc(bfeat))
dump("ground.json", {"roads": fc(ground_roads), "areas": fc(areas), "signals": fc(signals)})
dump("bridges.json", {"decks": fc(decks), "pillars": fc(pillars), "lines": fc(bridge_lines)})
match_bridges = []
for w, g, cls, lanes, layer in bridge_ways:
    hs = []
    for i in range(len(g)):
        p, q = (g[i], g[i + 1]) if i < len(g) - 1 else (g[i - 1], g[i])
        hs.append(round(elev_seg(p, q, 0.0 if i < len(g) - 1 else 1.0, layer), 2))
    match_bridges.append({"id": w["id"], "name": name_of(w["tags"]), "oneway": 1 if w["tags"].get("oneway") == "yes" else 0,
                          "c": g, "h": hs})
match_ground = [{"name": f["properties"]["n"], "oneway": f["properties"]["ow"], "c": f["geometry"]["coordinates"]}
                for f in ground_roads if f["properties"]["c"] in ("major", "medium", "link")]
dump("match.json", {"bridges": match_bridges, "ground": match_ground})
dump("sources.json", {"report": dict(report), "attribution": [
    "Map data (c) OpenStreetMap contributors, ODbL",
    "Overture Maps Foundation (buildings, places): ODbL / CDLA-Permissive-2.0 / CC BY 4.0 per source",
    "Building footprints: Microsoft Global ML Building Footprints (ODbL), Google Open Buildings (CC BY 4.0)",
    "Routing: OSRM / Project OSRM demo server"]})
print("\nREPORT")
for k in sorted(report):
    print(f"  {k:48s} {report[k]}")
