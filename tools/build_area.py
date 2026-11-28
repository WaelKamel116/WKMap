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

Output: main roads, flyovers, signs, places and the route as single files; buildings, small
streets and parks split into 0.01 degree tiles (about 1 km) in tiles/, which the app loads around
the car as it drives.

Usage: python tools/build_area.py cfc [--extra-route raw/route3.json] [--out app/assets/data] [--whole]
"""
import argparse, glob, hashlib, heapq, json, math, os, re
from collections import Counter, defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("area")
ap.add_argument("--extra-route", action="append", default=[], help="more OSRM route files whose corridor is kept")
ap.add_argument("--out", default="app/assets/data")
ap.add_argument("--corridor", type=float, default=500.0)
ap.add_argument("--whole", action="store_true",
                help="keep buildings, small streets and parks for the whole box (not just along the routes)")
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


if args.whole:
    def near_route(c, m=None):  # noqa: F811 - whole box: everything counts as near
        return True


# ------------------------------------------------------------------ roads
elements = load(os.path.join(RAW, "roads.json"))["elements"]
ways = {e["id"]: e for e in elements if e["type"] == "way" and "highway" in e.get("tags", {})}
CLASS = {"motorway": "major", "trunk": "major", "primary": "major", "secondary": "medium", "tertiary": "medium",
         "motorway_link": "link", "trunk_link": "link", "primary_link": "link", "secondary_link": "link",
         "tertiary_link": "link", "residential": "minor", "unclassified": "minor", "living_street": "minor",
         "service": "service"}
# lanes when OSM has no lanes tag: (one-way, two-way). Two-way counts both directions,
# like the OSM lanes tag does.
DEFAULT_LANES = {"major": (3, 6), "medium": (2, 4), "link": (1, 2), "minor": (1, 2), "service": (1, 1)}


def road_width(cls, l, ow):
    """Carriageway width in metres; the app draws roads with the same rule."""
    return max(l * 3.3 + (0.8 if ow else 1.6), {"minor": 5.0, "link": 4.5, "service": 3.5}.get(cls, 6.0))


def lanes_of(t, cls):
    try:
        return int(str(t.get("lanes")).split(";")[0])
    except Exception:
        return None


def name_of(t): return t.get("name:en") or t.get("name", "")


# ------------------------------------------------------------------ speed limits
# OpenStreetMap is the only open source of speed limits here (Overture copies it):
# about 1 in 100 road pieces has one, and neighbouring pieces of one road
# sometimes disagree (60 then 80 then 60). Cleaned up so the driver sees one
# consistent limit per stretch:
#   * values that cannot be right are dropped (residential street at 90),
#   * a short piece whose neighbours of the same road agree on another value
#     takes their value, and a short untagged piece between two pieces with
#     the same limit gets it too.
def parse_speed(v):
    m = re.match(r"\s*(\d+)", str(v or ""))
    return int(m.group(1)) if m else None


def way_len(w):
    g = w["geometry"]
    return sum(dist([a["lon"], a["lat"]], [b["lon"], b["lat"]]) for a, b in zip(g, g[1:]))


SPEED_CAP = {"minor": 60, "service": 40}
speed = {}
for wid, w in ways.items():
    cls = CLASS.get(w["tags"]["highway"])
    v = parse_speed(w["tags"].get("maxspeed"))
    if v and (v < 10 or v > 140 or v > SPEED_CAP.get(cls, 999)):
        report["speed: dropped impossible values"] += 1
        v = None
    if v:
        speed[wid] = v
report["speed: road pieces with an OSM limit"] = len(speed)
ends = defaultdict(list)
for wid, w in ways.items():
    if w.get("nodes"):
        ends[w["nodes"][0]].append(wid)
        ends[w["nodes"][-1]].append(wid)
for _ in range(3):
    for wid, w in ways.items():
        nm = name_of(w["tags"])
        if not nm or not w.get("nodes") or way_len(w) > 400:
            continue
        sides = [{speed[o] for o in ends[n] if o != wid and o in speed and name_of(ways[o]["tags"]) == nm}
                 for n in (w["nodes"][0], w["nodes"][-1])]
        if len(sides[0]) == 1 and sides[0] == sides[1]:
            v = next(iter(sides[0]))
            if speed.get(wid) != v:
                report["speed: evened out (short piece between same limits)" if wid in speed else
                       "speed: filled (short gap between same limits)"] += 1
                speed[wid] = v


# ------------------------------------------------------------------ lanes seen in capture videos
# tools/lanes_from_video.py writes one reading per second of straight driving
# (lanes seen, GPS position, heading) into raw/lanes/. A divided road piece
# (one-way way) that OSM has no lane count for takes the most common reading,
# when there are at least 5 readings and 60 % of them agree.
def video_lanes():
    obs = []
    for fn in glob.glob(os.path.join(os.path.dirname(RAW), "lanes", "*.json")):
        obs += [w for w in load(fn)["windows"] if w.get("ok")]
    if not obs:
        return {}
    G = 0.002
    grid = defaultdict(list)
    for w in ways.values():
        if CLASS.get(w["tags"]["highway"]) not in ("major", "medium", "link") or w["tags"].get("oneway") != "yes":
            continue
        g = [[q["lon"], q["lat"]] for q in w["geometry"]]
        for a, b in zip(g, g[1:]):
            grid[(int((a[0] + b[0]) / 2 / G), int((a[1] + b[1]) / 2 / G))].append((a, b, w["id"]))
    votes = defaultdict(Counter)
    for o in obs:
        p = [o["lon"], o["lat"]]
        px, py = xy(p)
        best = None
        for gx in (int(p[0] / G) - 1, int(p[0] / G), int(p[0] / G) + 1):
            for gy in (int(p[1] / G) - 1, int(p[1] / G), int(p[1] / G) + 1):
                for a, b, wid in grid.get((gx, gy), []):
                    if abs((bearing(a, b) - o["heading"] + 540) % 360 - 180) > 25:
                        continue
                    ax, ay = xy(a); bx, by = xy(b)
                    dx, dy = bx - ax, by - ay
                    L2 = dx * dx + dy * dy or 1e-9
                    f = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
                    d = math.hypot(ax + f * dx - px, ay + f * dy - py)
                    if d < 15 and (best is None or d < best[0]):
                        best = (d, wid)
        if best:
            votes[best[1]][o["lanes"]] += 1
    out = {}
    for wid, c in votes.items():
        n = sum(c.values())
        v, k = c.most_common(1)[0]
        osm = lanes_of(ways[wid]["tags"], None)
        if n >= 5 and k / n >= 0.6:
            if osm is None:
                out[wid] = v
            elif osm != v:
                report["lanes: video disagrees with OSM (kept OSM)"] += 1
        report["lanes: road pieces with video readings"] += 1
    report["lanes: road pieces given a lane count from video"] = len(out)
    return out


# filled in as if OSM had the lane count, so road width and sign placement agree
for _wid, _n in video_lanes().items():
    ways[_wid]["tags"]["lanes"] = str(_n)
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
    ow = 1 if t.get("oneway") == "yes" else 0
    ground_roads.append({"type": "Feature", "properties": {"c": cls, "n": name_of(t), "l": lanes or DEFAULT_LANES[cls][1 - ow],
                                                           "ow": ow, "ms": speed.get(w["id"], 0)},
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


def heliopolis(c):
    # Heliopolis / Masr El Gedida, north-west of Nasr City: older 4-8 floor blocks and villas
    return c[1] > 30.083 and c[0] < 31.355


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
    elif heliopolis(c) and a < 1500:
        lv = (3 + int(r * 3)) if a < 250 else (4 + int(r * 5))
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

# ------------------------------------------------------------------ road signs
# Placed where a driver would see them: beside the road on the right of the travel direction.
#   speed-NN  posted limit (OSM maxspeed): near the start of each road piece, repeated every 700 m
#   name      street-name plate (Arabic + English) for main roads, about every 450 m
#   camera    speed camera, crossing = marked zebra crossing, signal = traffic light (OSM nodes)
def point_along(g, s_at):
    """Point and compass bearing s_at metres along a lon/lat polyline."""
    run = 0.0
    for a, b in zip(g, g[1:]):
        d = dist(a, b)
        if d > 0 and run + d >= s_at:
            f = (s_at - run) / d
            return [a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1])], bearing(a, b)
        run += d
    return None, None


def beside(p, brg, off):
    x, y = xy(p)
    r = math.radians(brg)
    return ll(x + math.cos(r) * off, y - math.sin(r) * off)


def poly_len(g): return sum(dist(a, b) for a, b in zip(g, g[1:]))


signs, names, name_ix, placed = [], [], {}, []


def far_from(kind, p, brg, gap):
    for k, q, b in placed:
        if k == kind and dist(p, q) < gap and (brg is None or b is None or abs((brg - b + 180) % 360 - 180) < 60):
            return False
    return True


def add_sign(kind, p, brg=None, gap=0, group=None, **extra):
    if gap and not far_from(group or kind, p, brg, gap):
        return
    placed.append((group or kind, p, brg))
    signs.append({"type": "Feature", "properties": {"k": kind, **extra}, "geometry": {"type": "Point", "coordinates": r6(p)}})


RANK = {"major": 0, "medium": 1, "link": 2}
for w in sorted(ways.values(), key=lambda w: RANK.get(CLASS.get(w["tags"]["highway"]), 9)):
    t = w["tags"]; cls = CLASS.get(t["highway"])
    if cls not in ("major", "medium", "link") or t.get("tunnel") not in (None, "no"):
        continue
    g = [r6([q["lon"], q["lat"]]) for q in w["geometry"]]
    ow = t.get("oneway") == "yes"
    lanes = lanes_of(t, cls) or DEFAULT_LANES[cls][0 if ow else 1]
    half = road_width(cls, lanes, ow) / 2
    L = poly_len(g)
    if L < 30:
        continue
    dirs = [g] if ow else [g, g[::-1]]
    ms = str(speed.get(w["id"], ""))
    nm_en, nm_ar = t.get("name:en", ""), t.get("name", "")
    for gg in dirs:
        if ms.isdigit() and (cls != "link" or L > 150):
            # one speed sign per spot: no second sign with another number within
            # 250 m for the same direction (that showed 60 and 80 side by side)
            s_at = min(25.0, L / 2) if cls != "link" else L / 2
            while s_at < L:
                p, b = point_along(gg, s_at)
                add_sign(f"speed-{ms}", beside(p, b, half + 1.8), b, gap=250, group="speed")
                s_at += 700
        if (nm_en or nm_ar) and cls != "link" and t.get("bridge") in (None, "no"):
            key = nm_en or nm_ar
            s_at = min(60.0, L / 2)
            while s_at < L:
                p, b = point_along(gg, s_at)
                pos = beside(p, b, half + 2.5)
                if far_from("name:" + key, pos, b, 450):
                    if key not in name_ix:
                        name_ix[key] = len(names)
                        names.append([nm_en, nm_ar if nm_ar != nm_en else ""])
                    add_sign("name:" + key, pos, b)
                    signs[-1]["properties"] = {"k": "name", "ni": name_ix[key]}
                s_at += 450

# OSM maps cameras, crossings, stop signs and traffic lights as points ON the road
# centreline, which drew them in the middle of the road. Each is moved to the
# right-hand roadside of the road it belongs to, once per direction of travel
# (one-way roads: one sign), facing that direction.
WG = 0.002
way_grid = defaultdict(list)
for w in ways.values():
    cls = CLASS.get(w["tags"]["highway"])
    if cls in (None, "service") or w["tags"].get("tunnel") not in (None, "no"):
        continue
    g = [[q["lon"], q["lat"]] for q in w["geometry"]]
    ow = w["tags"].get("oneway") == "yes"
    lanes = lanes_of(w["tags"], cls) or DEFAULT_LANES[cls][0 if ow else 1]
    info = (w, cls, ow, road_width(cls, lanes, ow) / 2)
    for a, b in zip(g, g[1:]):
        for gx in range(int(min(a[0], b[0]) / WG), int(max(a[0], b[0]) / WG) + 1):
            for gy in range(int(min(a[1], b[1]) / WG), int(max(a[1], b[1]) / WG) + 1):
                way_grid[(gx, gy)].append((a, b, info))


def nearest_road(p, max_d=20, prefer_main=False):
    """(distance, foot point, bearing of the piece, way info) of the closest road to p."""
    best = None
    px, py = xy(p)
    seen = set()
    for gx in (int(p[0] / WG) - 1, int(p[0] / WG), int(p[0] / WG) + 1):
        for gy in (int(p[1] / WG) - 1, int(p[1] / WG), int(p[1] / WG) + 1):
            for a, b, info in way_grid.get((gx, gy), []):
                ax, ay = xy(a); bx, by = xy(b)
                dx, dy = bx - ax, by - ay
                L2 = dx * dx + dy * dy
                f = 0 if L2 == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
                d = math.hypot(ax + f * dx - px, ay + f * dy - py)
                if prefer_main and info[1] == "minor":
                    d += 8  # a light at a junction belongs to the main road
                if d <= max_d and (best is None or d < best[0]):
                    best = (d, ll(ax + f * dx, ay + f * dy), bearing(a, b), info)
    return best


def roadside(kind, p, gap=15, dir_tag=None, **extra):
    """Put a sign for point p beside its road, on the right of each travel direction."""
    r = nearest_road(p, prefer_main=kind == "signal")
    if r is None:
        add_sign(kind, p, gap=gap, **extra)
        report[f"signs: {kind} left in place (no road near)"] += 1
        return
    d, foot, b, (w, cls, ow, half) = r
    dirs = [b] if ow else [b, (b + 180) % 360]
    if dir_tag is not None and not ow:
        # camera direction: degrees, or forward/backward along the way
        try:
            want = float(dir_tag)
            dirs = [min(dirs, key=lambda x: abs((x - want + 540) % 360 - 180))]
        except ValueError:
            if dir_tag in ("forward", "backward"):
                dirs = [dirs[0] if dir_tag == "forward" else dirs[1]]
    for bb in dirs:
        add_sign(kind, beside(foot, bb, half + 1.2), bb, gap=gap, b=round(bb), **extra)


spath = os.path.join(RAW, "signs.json")
if os.path.exists(spath):
    for e in load(spath)["elements"]:
        t = e.get("tags", {})
        p = [e["lon"], e["lat"]]
        if t.get("highway") == "speed_camera" or t.get("enforcement") in ("maxspeed", "average_speed"):
            r = nearest_road(p)
            ms = parse_speed(t.get("maxspeed")) or (speed.get(r[3][0]["id"], 0) if r else 0)
            roadside("camera", p, gap=40, dir_tag=t.get("direction") or t.get("camera:direction"), **({"ms": ms} if ms else {}))
        elif t.get("highway") == "crossing" and t.get("crossing") in ("marked", "zebra", "traffic_signals", "uncontrolled"):
            roadside("crossing", p)
        elif t.get("highway") == "stop":
            roadside("stop", p)
        elif t.get("highway") == "give_way":
            roadside("give_way", p)
for f in signals:
    roadside("signal", f["geometry"]["coordinates"], gap=25)
# the game looks' 3D traffic lights stand where the signs now stand
signals = [{"type": "Feature", "properties": {}, "geometry": s["geometry"]} for s in signs if s["properties"]["k"] == "signal"]
for k, v in Counter(f["properties"]["k"].split("-")[0] for f in signs).items():
    report[f"signs: {k}"] = v

# ------------------------------------------------------------------ search index (offline)
# Everything the search box can find without internet, in one list:
#   [name, other names ("|"-separated: English / Arabic / alternates), kind, lon, lat, address, weight]
# Sources: Overture places (shops, clinics, ...: address and brand), OpenStreetMap
# named places (English and Arabic names, districts, stations, landmarks), and
# one point per named road (English and Arabic). The same place from both
# sources (same name within 120 m) is kept once with all its names. weight
# (0-9) ranks well-known places (malls, hospitals, stations) above small shops.
BIG = {"shopping_mall": 9, "airport": 9, "train_station": 8, "public_transit_facility_or_service": 7, "college_university": 7,
       "hospital": 6, "stadium_arena": 7, "museum": 7, "historic_site": 6, "monument": 6, "park": 6, "amusement_park": 7,
       "hotel": 6, "resort": 6, "department_store": 6, "superstore": 6, "movie_theater": 5, "muslim_place_of_worship": 5,
       "christian_place_of_worship": 5, "government_office": 5, "police_station": 5, "embassy": 5, "sport_or_recreation_club": 5,
       "gas_station": 4, "fueling_station": 4, "bank_or_credit_union": 3, "pharmacy_and_drug_store": 3, "high_school": 4,
       "district": 8, "neighbourhood": 7, "suburb": 8, "road": 5}
OSM_KIND = {("amenity", "hospital"): "hospital", ("amenity", "university"): "college_university", ("shop", "mall"): "shopping_mall",
            ("amenity", "fuel"): "gas_station", ("amenity", "pharmacy"): "pharmacy_and_drug_store", ("amenity", "bank"): "bank_or_credit_union",
            ("amenity", "atm"): "atm", ("amenity", "school"): "school", ("amenity", "place_of_worship"): "place_of_worship",
            ("amenity", "restaurant"): "restaurant", ("amenity", "cafe"): "cafe", ("amenity", "fast_food"): "fast_food_restaurant",
            ("amenity", "police"): "police_station", ("tourism", "hotel"): "hotel", ("tourism", "museum"): "museum",
            ("leisure", "park"): "park", ("leisure", "stadium"): "stadium_arena", ("railway", "station"): "train_station",
            ("public_transport", "station"): "train_station", ("amenity", "cinema"): "movie_theater", ("shop", "supermarket"): "supermarket",
            ("leisure", "sports_centre"): "sport_or_recreation_club", ("amenity", "clinic"): "clinic", ("amenity", "college"): "college_university"}
NORM = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ة": "ه", "ى": "ي"})


def nkey(n): return re.sub(r"[^\w]+", " ", (n or "").lower().translate(NORM)).strip()


search_ix = {}  # (normalised name, ~120 m cell) -> entry
SC = 0.0012


def add_place(names, kind, lon, lat, addr="", weight=2):
    names = [n.strip() for n in names if n and n.strip()]
    uniq = []
    for n in names:
        if nkey(n) and nkey(n) not in [nkey(u) for u in uniq]:
            uniq.append(n)
    if not uniq or not (W0 <= lon <= E0 and S0 <= lat <= N0):
        return
    cell = (round(lon / SC), round(lat / SC))
    for n in uniq:
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                e = search_ix.get((nkey(n), cell[0] + dx, cell[1] + dy))
                if e is not None:  # same place from another source: merge names, keep the better details
                    have = [nkey(x) for x in [e[0]] + e[1].split("|") if x]
                    e[1] = "|".join([x for x in e[1].split("|") if x] + [u for u in uniq if nkey(u) not in have])
                    e[5] = e[5] or addr
                    e[6] = max(e[6], weight)
                    if e[2] in ("", "place") and kind:
                        e[2] = kind
                    return
    e = [uniq[0], "|".join(uniq[1:]), kind or "", round(lon, 6), round(lat, 6), addr, weight]
    for n in uniq:
        search_ix[(nkey(n), *cell)] = e


lons = [q["lon"] for w in ways.values() for q in w["geometry"][:1]]
lats = [q["lat"] for w in ways.values() for q in w["geometry"][:1]]
W0, E0, S0, N0 = min(lons), max(lons), min(lats), max(lats)
# OpenStreetMap first: it has the English and Arabic names
opath = os.path.join(RAW, "pois.json")
if os.path.exists(opath):
    for e in load(opath)["elements"]:
        t = e.get("tags", {})
        c = e.get("center") or ({"lon": e["lon"], "lat": e["lat"]} if "lon" in e else None)
        if not c or not t.get("name"):
            continue
        kind = next((OSM_KIND[(k, t[k])] for k in ("amenity", "shop", "tourism", "leisure", "railway", "public_transport")
                     if (k, t.get(k)) in OSM_KIND), None)
        if not kind:
            pl = t.get("place")
            kind = pl if pl in ("suburb", "neighbourhood", "quarter", "district", "city", "town", "village") else \
                (t.get("amenity") or t.get("shop") or t.get("tourism") or t.get("leisure") or t.get("office") or
                 t.get("healthcare") or t.get("historic") or ("building" if t.get("building") else "") or t.get("landuse") or "place")
        w = BIG.get(kind, 2) + (1 if t.get("name:en") and t.get("name:ar") else 0) + (1 if t.get("wikidata") else 0)
        addr = ", ".join(x for x in (t.get("addr:street"), t.get("addr:suburb") or t.get("addr:district"), t.get("addr:city")) if x)
        add_place([t.get("name:en"), t.get("name"), t.get("name:ar"), t.get("int_name"), t.get("alt_name"), t.get("old_name"),
                   t.get("short_name")], kind, c["lon"], c["lat"], addr, min(w, 9))
# Overture: many more shops, clinics and offices, with addresses
for path in (os.path.join(RAW, "overture_places_full.json"), os.path.join(RAW, "overture_places.json")):
    if not os.path.exists(path):
        continue
    for pl in load(path):
        if not pl.get("name"):
            continue
        cat = pl.get("cat") or ""
        addr = ""
        if pl.get("addr"):
            a0 = pl["addr"][0]
            addr = ", ".join(x for x in (a0.get("freeform"), a0.get("locality")) if x)[:90]
        # Overture categories are sometimes wrong (a bookshop as a mall), so they count for less
        w = min(BIG.get(cat, 2), 6 if (pl.get("conf") or 0) > 0.8 else 4) + (1 if pl.get("brand") else 0)
        add_place([pl["name"]] + list((pl.get("common") or {}).values()), cat, pl["lon"], pl["lat"], addr, min(w, 9))
    break  # the full file has everything the short one has
# roads: one point per named road, English and Arabic names together
road_pts = {}
for w in ways.values():
    t = w["tags"]
    if CLASS.get(t["highway"]) not in ("major", "medium", "minor") or not (t.get("name") or t.get("name:en")):
        continue
    key = t.get("name:en") or t.get("name")
    g = [[q["lon"], q["lat"]] for q in w["geometry"]]
    L = poly_len(g)
    cur = road_pts.get(key)
    if cur is None or L > cur[0]:
        road_pts[key] = (L, point_along(g, L / 2)[0], [t.get("name:en"), t.get("name"), t.get("name:ar")],
                         CLASS[t["highway"]])
for key, (L, pt, nm, cls) in road_pts.items():
    if pt:
        add_place(nm, "road", pt[0], pt[1], "", 5 if cls == "major" else 4 if cls == "medium" else 2)
seen = set()
search = []
for e in search_ix.values():
    if id(e) not in seen:
        seen.add(id(e))
        search.append(e)
report["search: places and roads"] = len(search)

# ------------------------------------------------------------------ write
print("writing to", OUT)
dump("route.json", {"coords": [[c[0], c[1]] for c in rd], "elev": rel, "cum": [round(c, 1) for c in cum],
                    "maneuvers": maneuvers, "distance": round(cum[-1], 1)})
# tiles: buildings, small streets and parks, so the phone only holds what is around the car
TS = 0.01
tiles = {}


def tile_of(c): return f"{int(math.floor(c[0] / TS))}_{int(math.floor(c[1] / TS))}"


def r5(ring): return [[round(p[0], 5), round(p[1], 5)] for p in ring]


for f in bfeat:
    ring = f["geometry"]["coordinates"][0]
    t = tiles.setdefault(tile_of(centroid(ring)), {"b": [], "r": [], "a": []})
    t["b"].append({"type": "Feature", "properties": {"h": f["properties"]["h"], "com": f["properties"]["com"]},
                   "geometry": {"type": "Polygon", "coordinates": [r5(ring)]}})
main_roads = []
for f in ground_roads:
    g = f["geometry"]["coordinates"]
    if f["properties"]["c"] in ("major", "medium", "link"):
        main_roads.append(f)
    else:
        tiles.setdefault(tile_of(g[len(g) // 2]), {"b": [], "r": [], "a": []})["r"].append(
            {"type": "Feature", "properties": f["properties"], "geometry": {"type": "LineString", "coordinates": r5(g)}})
for f in areas:
    ring = f["geometry"]["coordinates"][0]
    tiles.setdefault(tile_of(centroid(ring)), {"b": [], "r": [], "a": []})["a"].append(
        {"type": "Feature", "properties": f["properties"], "geometry": {"type": "Polygon", "coordinates": [r5(ring)]}})
tdir = os.path.join(OUT, "tiles")
os.makedirs(tdir, exist_ok=True)
for old in os.listdir(tdir):
    os.remove(os.path.join(tdir, old))
tile_bytes = 0
for k, t in tiles.items():
    with open(os.path.join(tdir, f"{k}.json"), "w", encoding="utf-8") as fh:
        json.dump(t, fh, ensure_ascii=False, separators=(",", ":"))
    tile_bytes += os.path.getsize(os.path.join(tdir, f"{k}.json"))
with open(os.path.join(tdir, "index.json"), "w") as fh:
    json.dump({"size": TS, "tiles": {k: len(t["b"]) for k, t in tiles.items()}}, fh)
report["tiles"] = len(tiles)
report["tiles: most buildings in one"] = max(len(t["b"]) for t in tiles.values())
print(f"  tiles/           {tile_bytes // 1024:6d} KB in {len(tiles)} tiles")
old_b = os.path.join(OUT, "buildings.json")
if os.path.exists(old_b):
    os.remove(old_b)
dump("ground.json", {"roads": fc(main_roads), "signals": fc(signals)})
dump("bridges.json", {"decks": fc(decks), "pillars": fc(pillars), "lines": fc(bridge_lines)})
match_bridges = []
for w, g, cls, lanes, layer in bridge_ways:
    hs = []
    for i in range(len(g)):
        p, q = (g[i], g[i + 1]) if i < len(g) - 1 else (g[i - 1], g[i])
        hs.append(round(elev_seg(p, q, 0.0 if i < len(g) - 1 else 1.0, layer), 2))
    match_bridges.append({"id": w["id"], "name": name_of(w["tags"]), "oneway": 1 if w["tags"].get("oneway") == "yes" else 0,
                          "ms": speed.get(w["id"], 0), "c": g, "h": hs})
match_ground = [{"name": f["properties"]["n"], "oneway": f["properties"]["ow"], "ms": f["properties"]["ms"],
                 "c": f["geometry"]["coordinates"]}
                for f in ground_roads if f["properties"]["c"] in ("major", "medium", "link")]
dump("match.json", {"bridges": match_bridges, "ground": match_ground})
dump("signs.json", {"signs": fc(signs), "names": names})
dump("places.json", {"places": search})
dump("sources.json", {"report": dict(report), "attribution": [
    "Map data (c) OpenStreetMap contributors, ODbL",
    "Overture Maps Foundation (buildings, places): ODbL / CDLA-Permissive-2.0 / CC BY 4.0 per source",
    "Building footprints: Microsoft Global ML Building Footprints (ODbL), Google Open Buildings (CC BY 4.0)",
    "Routing: OSRM / Project OSRM demo server"]})
print("\nREPORT")
for k in sorted(report):
    print(f"  {k:48s} {report[k]}")
