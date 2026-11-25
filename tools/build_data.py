"""Build the demo's map data from raw OpenStreetMap + Microsoft footprints.

Inputs  (raw/):  route3.json (OSRM), buildings.json, base.json, major.json (Overpass), ms_area.json
Outputs (demo/data/): buildings.json, ground.json, bridges.json, route.json
"""
import json, math, hashlib, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "raw")
OUT = os.path.join(ROOT, "demo", "data")
os.makedirs(OUT, exist_ok=True)

LAT0 = 30.07
MX = 111320 * math.cos(math.radians(LAT0))  # metres per degree lon
MY = 110540                                 # metres per degree lat


def xy(p):
    return ((p[0] - 31.34) * MX, (p[1] - LAT0) * MY)


def ll(x, y):
    return [round(31.34 + x / MX, 6), round(LAT0 + y / MY, 6)]


def dist(a, b):
    ax, ay = xy(a); bx, by = xy(b)
    return math.hypot(ax - bx, ay - by)


def bearing(a, b):
    ax, ay = xy(a); bx, by = xy(b)
    return (math.degrees(math.atan2(bx - ax, by - ay)) + 360) % 360


def r5(c):
    return [round(c[0], 6), round(c[1], 6)]


def load(name):
    with open(os.path.join(RAW, name), encoding="utf-8") as f:
        return json.load(f)


def dump(name, obj):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    print(name, os.path.getsize(os.path.join(OUT, name)) // 1024, "KB")


def fc(features):
    return {"type": "FeatureCollection", "features": features}


# ---------------------------------------------------------------- route
route = load("route3.json")["routes"][0]
rcoords = [r5(c) for c in route["geometry"]["coordinates"]]
steps = [s for leg in route["legs"] for s in leg["steps"]]

# ---------------------------------------------------------------- roads
base = load("base.json")["elements"]
major = load("major.json")["elements"]
ways = {}
for e in base + major:
    if e["type"] == "way" and "highway" in e.get("tags", {}):
        ways[e["id"]] = e

DRIVE = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
         "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link", "service", "living_street"}
CLASS = {"motorway": "major", "trunk": "major", "primary": "major", "secondary": "medium", "tertiary": "medium",
         "motorway_link": "link", "trunk_link": "link", "primary_link": "link", "secondary_link": "link",
         "tertiary_link": "link", "residential": "minor", "unclassified": "minor", "living_street": "minor",
         "service": "service"}
DEFAULT_LANES = {"major": 3, "medium": 2, "link": 1, "minor": 1, "service": 1}

ground_roads, bridge_ways = [], []
for w in ways.values():
    t = w["tags"]; hw = t["highway"]
    if hw not in DRIVE:
        continue
    g = [r5([p["lon"], p["lat"]]) for p in w["geometry"]]
    cls = CLASS[hw]
    lanes = t.get("lanes")
    try:
        lanes = int(str(lanes).split(";")[0])
    except Exception:
        lanes = None
    if t.get("bridge") and t.get("bridge") != "no" and cls in ("major", "medium", "link"):
        bridge_ways.append((w, g, cls, lanes))
        continue
    if t.get("tunnel") and t.get("tunnel") != "no":
        continue
    ground_roads.append({"type": "Feature",
                         "properties": {"c": cls, "n": t.get("name:en") or t.get("name", ""),
                                        "l": lanes or DEFAULT_LANES[cls], "ow": 1 if t.get("oneway") == "yes" else 0},
                         "geometry": {"type": "LineString", "coordinates": g}})

# ---------------------------------------------------------------- landuse / parks
green_tags = {"garden", "grass", "park", "village_green", "recreation_ground", "meadow", "playground", "pitch", "stadium",
              "sports_centre", "cemetery", "greenfield"}
areas = []
for e in base:
    if e["type"] != "way":
        continue
    t = e.get("tags", {})
    kind = None
    for k in ("leisure", "landuse", "natural", "amenity"):
        v = t.get(k)
        if v in green_tags:
            kind = "pitch" if v in ("pitch", "stadium", "sports_centre") else "green"
        elif v == "parking":
            kind = "paved"
        elif v in ("military", "construction", "brownfield", "sand"):
            kind = "bare"
        elif v == "swimming_pool" or v == "water":
            kind = "water"
        if kind:
            break
    g = e.get("geometry")
    if not kind or not g or len(g) < 4:
        continue
    ring = [r5([p["lon"], p["lat"]]) for p in g]
    if ring[0] != ring[-1]:
        continue
    areas.append({"type": "Feature", "properties": {"k": kind}, "geometry": {"type": "Polygon", "coordinates": [ring]}})

signals = [{"type": "Feature", "properties": {},
            "geometry": {"type": "Point", "coordinates": r5([e["lon"], e["lat"]])}}
           for e in base if e["type"] == "node" and e.get("tags", {}).get("highway") == "traffic_signals"]

# ---------------------------------------------------------------- bridges: elevation profile
DECK = 7.0      # metres, typical Cairo flyover clearance + structure
GRADE = 0.055   # approach slope

import heapq
# Graph of bridge structures: distance along the deck to the nearest free end drives the ramp-up height.
adj = {}
for w, g, cls, lanes in bridge_ways:
    for p, q in zip(g, g[1:]):
        p, q = tuple(p), tuple(q)
        L = dist(p, q)
        adj.setdefault(p, []).append((q, L)); adj.setdefault(q, []).append((p, L))
ends = [v for v, nb in adj.items() if len(nb) == 1]
dfe = {v: 0.0 for v in ends}
pq = [(0.0, v) for v in ends]
while pq:
    d0, v = heapq.heappop(pq)
    if d0 > dfe.get(v, 1e18):
        continue
    for u, L in adj[v]:
        if d0 + L < dfe.get(u, 1e18):
            dfe[u] = d0 + L; heapq.heappush(pq, (d0 + L, u))


def elev_seg(a, b, t):
    da, db = dfe.get(tuple(a), 1e9), dfe.get(tuple(b), 1e9)
    L = dist(a, b)
    return min(DECK, min(da + t * L, db + (1 - t) * L) * GRADE)


# segment grid for "is this point on a bridge" queries
SG = 0.0004
seg_grid = {}
for w, g, cls, lanes in bridge_ways:
    for p, q in zip(g, g[1:]):
        for gx in range(int(min(p[0], q[0]) / SG), int(max(p[0], q[0]) / SG) + 1):
            for gy in range(int(min(p[1], q[1]) / SG), int(max(p[1], q[1]) / SG) + 1):
                seg_grid.setdefault((gx, gy), []).append((p, q))


def bridge_height_at(c, hdg, tol=1.5):
    best = None
    for p, q in seg_grid.get((int(c[0] / SG), int(c[1] / SG)), []):
        if abs(((bearing(p, q) - hdg + 540) % 360) - 180) > 30:
            continue
        px, py = xy(p); qx, qy = xy(q); cx, cy = xy(c)
        dx, dy = qx - px, qy - py
        L2 = dx * dx + dy * dy or 1e-9
        t = max(0, min(1, ((cx - px) * dx + (cy - py) * dy) / L2))
        d = math.hypot(px + t * dx - cx, py + t * dy - cy)
        if d < tol and (best is None or d < best[0]):
            best = (d, elev_seg(p, q, t))
    return best[1] if best else 0.0


def densify(g, step=8.0):
    out = [g[0]]
    for a, b in zip(g, g[1:]):
        n = max(1, int(dist(a, b) // step))
        for k in range(1, n + 1):
            out.append([a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n])
    return out


def quad(a, b, half):
    ax, ay = xy(a); bx, by = xy(b)
    dx, dy = bx - ax, by - ay
    L = math.hypot(dx, dy) or 1
    nx, ny = -dy / L * half, dx / L * half
    ex, ey = dx / L * 0.6, dy / L * 0.6   # small overlap so segments join
    return [ll(ax - ex + nx, ay - ey + ny), ll(bx + ex + nx, by + ey + ny), ll(bx + ex - nx, by + ey - ny),
            ll(ax - ex - nx, ay - ey - ny), ll(ax - ex + nx, ay - ey + ny)]


decks, pillars, bridge_lines = [], [], []
for w, g, cls, lanes in bridge_ways:
    t = w["tags"]
    nl = lanes or (2 if cls != "link" else 1)
    half = nl * 3.4 / 2 + 0.8
    run = 0.0
    pieces = []
    for p, q in zip(g, g[1:]):
        n = max(1, int(dist(p, q) // 8))
        for k in range(n):
            t0, t1 = k / n, (k + 1) / n
            a = [p[0] + (q[0] - p[0]) * t0, p[1] + (q[1] - p[1]) * t0]
            b = [p[0] + (q[0] - p[0]) * t1, p[1] + (q[1] - p[1]) * t1]
            pieces.append((a, b, (elev_seg(p, q, t0) + elev_seg(p, q, t1)) / 2))
    for a, b, h in pieces:
        decks.append({"type": "Feature", "properties": {"b": round(max(h - 0.9, 0), 2), "h": round(h, 2)},
                      "geometry": {"type": "Polygon", "coordinates": [quad(a, b, half)]}})
        run += dist(a, b)
        if run > 32 and h > 3.5:
            run = 0
            mx, my = xy([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2])
            s = 0.9
            pillars.append({"type": "Feature", "properties": {"h": round(h - 0.9, 2)},
                            "geometry": {"type": "Polygon", "coordinates": [[ll(mx - s, my - s), ll(mx + s, my - s),
                                                                             ll(mx + s, my + s), ll(mx - s, my + s),
                                                                             ll(mx - s, my - s)]]}})
    bridge_lines.append({"type": "Feature", "properties": {"n": t.get("name:en") or t.get("name", "")},
                         "geometry": {"type": "LineString", "coordinates": g}})

# ---------------------------------------------------------------- route elevation + maneuvers
rd = densify(rcoords, 4.0)
cum = [0.0]
for i in range(1, len(rd)):
    cum.append(cum[-1] + dist(rd[i - 1], rd[i]))
rel = [round(bridge_height_at(c, bearing(rd[max(i - 1, 0)], rd[max(i, 1)])), 2) for i, c in enumerate(rd)]

# name lookup for English names
en_names = {}
for w in ways.values():
    t = w["tags"]
    if t.get("name") and t.get("name:en"):
        en_names[t["name"]] = t["name:en"]


def arms_at(loc, route_after):
    """Find road arms leaving the maneuver point; mark the one the route takes."""
    # OSRM sometimes reports the vertex just before the real split: snap to a nearby node where 2+ ways start
    starts = {}
    for w in ways.values():
        if w["tags"]["highway"] in DRIVE and w["tags"]["highway"] != "service":
            p0 = w["geometry"][0]
            starts.setdefault((p0["lon"], p0["lat"]), 0)
            starts[(p0["lon"], p0["lat"])] += 1
    near = [c for c, n in starts.items() if n >= 2 and dist(list(c), loc) < 4]
    if near:
        loc = list(min(near, key=lambda c: dist(list(c), loc)))
    arms = []
    for w in ways.values():
        t = w["tags"]
        if t["highway"] not in DRIVE or t["highway"] == "service":
            continue
        g = [[p["lon"], p["lat"]] for p in w["geometry"]]
        for i, c in enumerate(g):
            if dist(c, loc) > 1.0:
                continue
            ow = t.get("oneway") == "yes"
            dirs = []
            if i < len(g) - 1:
                dirs.append(g[i + 1:])
            if i > 0 and not ow:
                dirs.append(list(reversed(g[:i])))
            for path in dirs:
                # point ~30 m along
                acc, prev, tgt = 0, c, path[-1]
                for p in path:
                    acc += dist(prev, p); prev = p
                    if acc >= 60:
                        tgt = p; break
                cls = CLASS[t["highway"]]
                try:
                    nl = int(str(t.get("lanes")).split(";")[0])
                except Exception:
                    nl = DEFAULT_LANES[cls]
                arms.append({"brg": round(bearing(c, tgt)), "lanes": nl, "cls": cls,
                             "bridge": 1 if (t.get("bridge") not in (None, "no") or "Bridge" in t.get("name:en", "")
                                             or "كوبر" in t.get("name", "")) else 0,
                             "name": t.get("name:en") or t.get("name", ""), "id": w["id"]})
    # de-duplicate (split ways at the same node pointing the same way)
    uniq = []
    for a in arms:
        if not any(abs(((a["brg"] - u["brg"] + 540) % 360) - 180) < 4 and a["name"] == u["name"] for u in uniq):
            uniq.append(a)
    rb = bearing(loc, route_after)
    best = min(uniq, key=lambda a: abs(((a["brg"] - rb + 540) % 360) - 180)) if uniq else None
    for a in uniq:
        a["route"] = 1 if a is best else 0
    return uniq


def point_along(dist_m):
    for i in range(1, len(rd)):
        if cum[i] >= dist_m:
            return rd[i]
    return rd[-1]


def nearest_cum(loc):
    best = min(range(len(rd)), key=lambda i: dist(rd[i], loc))
    return cum[best]


maneuvers = []
steps = [st for k, st in enumerate(steps) if not ((st["maneuver"]["type"] == "arrive" and k != len(steps) - 1) or
                                                 (st["maneuver"]["type"] == "depart" and k != 0))]
for s in steps:
    m = s["maneuver"]
    loc = m["location"]
    at = nearest_cum(loc)
    name = s.get("name", "")
    entry = {"at": round(at, 1), "type": m["type"], "mod": m.get("modifier", ""),
             "name": name, "name_en": en_names.get(name, ""), "in": m.get("bearing_before", 0), "out": m.get("bearing_after", 0)}
    if m["type"] in ("fork", "off ramp", "turn", "end of road", "new name"):
        arms = arms_at(loc, point_along(at + 60))
        if len(arms) >= 2:
            entry["arms"] = arms
    maneuvers.append(entry)

dump("route.json", {"coords": [[c[0], c[1]] for c in rd], "elev": rel, "cum": [round(c, 1) for c in cum],
                    "maneuvers": maneuvers, "distance": round(cum[-1], 1)})

# ---------------------------------------------------------------- buildings (OSM + Microsoft)
def ring_area(ring):
    pts = [xy(p) for p in ring]
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:]))) / 2


def pip(pt, ring):
    x, y = pt; inside = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1 + 1e-15) + x1:
            inside = not inside
    return inside


def est_height(key, area, levels=None, height=None):
    if height:
        try:
            return float(str(height).replace("m", "").strip())
        except Exception:
            pass
    if levels:
        try:
            return float(levels) * 3.2
        except Exception:
            pass
    hsh = int(hashlib.md5(key.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    if area < 60:
        lv = 1 + int(hsh * 2)          # kiosks, guard rooms
    elif area < 150:
        lv = 3 + int(hsh * 4)
    elif area < 1500:
        lv = 6 + int(hsh * 7)          # typical Nasr City residential blocks: 6-12 floors
    elif area < 5000:
        lv = 4 + int(hsh * 6)
    else:
        lv = 2 + int(hsh * 3)          # malls, halls, institutions
    return lv * 3.2


osm_b = load("buildings.json")["elements"]
bfeat, osm_rings = [], []
for e in osm_b:
    t = e.get("tags", {})
    rings = []
    if e["type"] == "way" and e.get("geometry"):
        rings = [[r5([p["lon"], p["lat"]]) for p in e["geometry"]]]
    elif e["type"] == "relation":
        for m in e.get("members", []):
            if m.get("role") == "outer" and m.get("geometry"):
                rings.append([r5([p["lon"], p["lat"]]) for p in m["geometry"]])
    for ring in rings:
        if len(ring) < 4 or ring[0] != ring[-1]:
            continue
        a = ring_area(ring)
        h = est_height(str(e["id"]), a, t.get("building:levels"), t.get("height"))
        bfeat.append({"type": "Feature", "properties": {"h": round(h, 1), "s": "o"},
                      "geometry": {"type": "Polygon", "coordinates": [ring]}})
        osm_rings.append(ring)

# spatial grid of OSM rings
G = 0.0006
grid = {}
for idx, ring in enumerate(osm_rings):
    xs = [p[0] for p in ring]; ys = [p[1] for p in ring]
    for gx in range(int(min(xs) / G), int(max(xs) / G) + 1):
        for gy in range(int(min(ys) / G), int(max(ys) / G) + 1):
            grid.setdefault((gx, gy), []).append(idx)

ms = load("ms_area.json")
added = 0
for k, f in enumerate(ms):
    ring = [r5(c) for c in f["geometry"]["coordinates"][0]]
    cx = sum(p[0] for p in ring[:-1]) / (len(ring) - 1)
    cy = sum(p[1] for p in ring[:-1]) / (len(ring) - 1)
    cands = grid.get((int(cx / G), int(cy / G)), [])
    if any(pip((cx, cy), osm_rings[i]) for i in cands):
        continue
    a = ring_area(ring)
    if a < 25:
        continue
    h = est_height("ms%d" % k, a)
    bfeat.append({"type": "Feature", "properties": {"h": round(h, 1), "s": "m"},
                  "geometry": {"type": "Polygon", "coordinates": [ring]}})
    added += 1

# keep buildings clear of the bridge decks (footprint data sometimes overlaps road edges)
print("osm buildings", len(osm_rings), "ms added", added)
dump("buildings.json", fc(bfeat))
dump("ground.json", {"roads": fc(ground_roads), "areas": fc(areas), "signals": fc(signals)})
dump("bridges.json", {"decks": fc(decks), "pillars": fc(pillars), "lines": fc(bridge_lines)})
for m in maneuvers:
    print(round(m["at"]), m["type"], m["mod"], m["name_en"] or m["name"],
          [(a["brg"], a["lanes"], a["bridge"], a["route"]) for a in m.get("arms", [])])

# ---------------------------------------------------------------- map-matching data for the phone app
# bridges: centreline vertices with deck height; ground: main ground carriageways (candidates "under" a flyover)
match_bridges = []
for w, g, cls, lanes in bridge_ways:
    hs = []
    for i, c in enumerate(g):
        p, q = (g[i], g[i + 1]) if i < len(g) - 1 else (g[i - 1], g[i])
        t = 0.0 if i < len(g) - 1 else 1.0
        hs.append(round(elev_seg(p, q, t), 2))
    match_bridges.append({"id": w["id"], "name": w["tags"].get("name:en") or w["tags"].get("name", ""),
                          "oneway": 1 if w["tags"].get("oneway") == "yes" else 0, "c": g, "h": hs})
match_ground = []
for f in ground_roads:
    if f["properties"]["c"] in ("major", "medium", "link"):
        match_ground.append({"name": f["properties"]["n"], "oneway": f["properties"]["ow"], "c": f["geometry"]["coordinates"]})
dump("match.json", {"bridges": match_bridges, "ground": match_ground})
