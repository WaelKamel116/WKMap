"""Place traffic lights, speed-limit signs, overhead direction signs and zebra crossings.

Run after build_data.py.  Inputs: raw/base.json, raw/major.json, raw/signs2.json (optional), demo/data/route.json
Output: demo/data/signs.json

What is real data and what is generated:
- traffic lights tagged in OpenStreetMap          -> "src": "osm"
- traffic lights at junctions of two named main
  streets that OSM has no signal for              -> "src": "inferred"
- speed-limit signs: value from the OSM maxspeed tag of the road; positions are generated
- overhead direction signs: generated from the route's fork data (lanes + road names)
- zebra crossings: OSM highway=crossing nodes (if the optional download succeeded)
"""
import json, math, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW, OUT = os.path.join(ROOT, "raw"), os.path.join(ROOT, "demo", "data")
LAT0 = 30.07
MX = 111320 * math.cos(math.radians(LAT0)); MY = 110540


def xy(p): return ((p[0] - 31.34) * MX, (p[1] - LAT0) * MY)
def ll(x, y): return [round(31.34 + x / MX, 7), round(LAT0 + y / MY, 7)]
def dist(a, b):
    ax, ay = xy(a); bx, by = xy(b); return math.hypot(ax - bx, ay - by)
def bearing(a, b):
    ax, ay = xy(a); bx, by = xy(b); return (math.degrees(math.atan2(bx - ax, by - ay)) + 360) % 360
def move(p, brg, fwd, right):
    x, y = xy(p); t = math.radians(brg)
    return ll(x + fwd * math.sin(t) + right * math.cos(t), y + fwd * math.cos(t) - right * math.sin(t))


def load(n):
    with open(os.path.join(RAW, n), encoding="utf-8") as f: return json.load(f)


elements = load("base.json")["elements"] + load("major.json")["elements"]
ways, seen = [], set()
for e in elements:
    if e["type"] == "way" and "highway" in e.get("tags", {}) and e["id"] not in seen:
        seen.add(e["id"]); ways.append(e)
route = json.load(open(os.path.join(OUT, "route.json"), encoding="utf-8"))
CLASS = {"motorway": "major", "trunk": "major", "primary": "major", "secondary": "medium", "tertiary": "medium",
         "residential": "minor", "unclassified": "minor"}


def lanes_of(t, cls):
    try: return int(str(t.get("lanes")).split(";")[0])
    except Exception: return {"major": 3, "medium": 2, "minor": 1}.get(cls, 1)


def half_width_right(t, cls):
    """distance from the way's centreline to the right-hand kerb for traffic in one direction"""
    n = lanes_of(t, cls)
    if t.get("oneway") == "yes": return n * 3.4 / 2
    return max(n * 3.4, 7) / 2


# ---------------------------------------------------------------- traffic lights
node_ways = {}
for w in ways:
    t = w["tags"]; cls = CLASS.get(t["highway"])
    if not cls or t.get("bridge") not in (None, "no") or t.get("tunnel") not in (None, "no"): continue
    g = [(p["lon"], p["lat"]) for p in w["geometry"]]
    for i, c in enumerate(g):
        node_ways.setdefault((round(c[0], 7), round(c[1], 7)), []).append((w, g, i, cls))


def approaches(key):
    """incoming traffic directions at a node: (bearing of travel, way tags, class)"""
    out = []
    for w, g, i, cls in node_ways.get(key, []):
        t = w["tags"]; ow = t.get("oneway") == "yes"
        if i > 0: out.append((bearing(g[max(0, i - 2)] if dist(g[i - 1], g[i]) < 6 and i > 1 else g[i - 1], g[i]), t, cls))
        if i < len(g) - 1 and not ow: out.append((bearing(g[min(len(g) - 1, i + 2)] if dist(g[i + 1], g[i]) < 6 and i < len(g) - 2 else g[i + 1], g[i]), t, cls))
    # one light per distinct approach direction
    uniq = []
    for a in out:
        if all(abs(((a[0] - u[0] + 540) % 360) - 180) > 25 for u in uniq): uniq.append(a)
    return uniq[:4]


signal_nodes = []
for e in elements:
    if e["type"] == "node" and e.get("tags", {}).get("highway") == "traffic_signals":
        signal_nodes.append(((round(e["lon"], 7), round(e["lat"], 7)), "osm"))
# inferred: shared vertex of two differently named main streets (secondary or larger)
for key, lst in node_ways.items():
    names = {w["tags"].get("name") for w, g, i, cls in lst if cls in ("major", "medium") and w["tags"].get("name")}
    if len(names) >= 2 and all(dist(key, s[0]) > 45 for s in signal_nodes):
        signal_nodes.append((key, "inferred"))

lights = []
for key, src in signal_nodes:
    aps = approaches(key)
    if not aps:
        # signal mapped on a way vertex we did not index (e.g. a link); fall back to nearest way direction
        continue
    for k, (b, t, cls) in enumerate(aps):
        hw = half_width_right(t, cls)
        pos = move(list(key), b, -9, hw + 1.4)
        lights.append({"ll": pos, "brg": round(b, 1), "arm": round(min(hw + 0.6, 7.5), 1), "src": src,
                       "phase": 0 if round(b / 90) % 2 == 0 else 1})

# ---------------------------------------------------------------- speed limits along the route
maxspeed_segs = []
for w in ways:
    ms = w["tags"].get("maxspeed")
    if not ms or not ms.isdigit(): continue
    g = [(p["lon"], p["lat"]) for p in w["geometry"]]
    for a, b in zip(g, g[1:]): maxspeed_segs.append((a, b, int(ms)))


def maxspeed_at(p, hdg):
    best = None
    for a, b, v in maxspeed_segs:
        if abs(((bearing(a, b) - hdg + 540) % 360) - 180) > 30: continue
        ax, ay = xy(a); bx, by = xy(b); px, py = xy(p)
        dx, dy = bx - ax, by - ay; L2 = dx * dx + dy * dy or 1e-9
        t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
        d = math.hypot(ax + t * dx - px, ay + t * dy - py)
        if d < 2.5 and (best is None or d < best[0]): best = (d, v)
    return best[1] if best else None


C, E, CUM = route["coords"], route["elev"], route["cum"]


def at_dist(d):
    for i in range(1, len(CUM)):
        if CUM[i] >= d: return i
    return len(CUM) - 1


def hdg_at(i): return bearing(C[max(0, i - 2)], C[min(len(C) - 1, i + 2)])


spots = [120]
for m in route["maneuvers"]:
    if m["type"] in ("fork", "merge", "new name") and m["at"] + 70 < route["distance"] - 100: spots.append(m["at"] + 70)
d = 120
while d < route["distance"] - 150:
    if all(abs(d - s) > 350 for s in spots): spots.append(d)
    d += 650
speed_signs = []
for d in sorted(spots):
    i = at_dist(d); h = hdg_at(i); v = maxspeed_at(C[i], h)
    if v:
        speed_signs.append({"ll": move(C[i], h, 0, 2 * 3.4 / 2 + 1.3), "z": E[i], "brg": round(h, 1), "v": v})

# ---------------------------------------------------------------- overhead direction signs before forks
SHORT = [("Ganzoury", "Ganzoury Flyover", "كوبري الجنزوري"), ("Marei", "Mamdouh Marei Flyover", "كوبري ممدوح مرعي"),
         ("Nasr", "Al Nasr Road", "طريق النصر")]


def short(name):
    for k, en, ar in SHORT:
        if k in name: return en, ar
    return name, ""


gantries = []
for m in route["maneuvers"]:
    if not m.get("arms"): continue
    arms = sorted(m["arms"], key=lambda a: ((a["brg"] - m["in"] + 540) % 360) - 180)
    i = at_dist(m["at"] - 230); h = hdg_at(i)
    lanes = sum(a["lanes"] for a in arms)
    width = lanes * 3.4 + 1.5
    panels = []
    for k, a in enumerate(arms):
        en, ar = short(a["name"])
        panels.append({"en": en, "ar": ar, "lanes": a["lanes"], "dir": "left" if k == 0 else "right" if k == len(arms) - 1 else "straight",
                       "flyover": a["bridge"]})
    # route line is the centre of the left (flyover) half: shift the gantry centre right so it spans all lanes
    gantries.append({"ll": move(C[i], h, 0, width / 2 - arms[0]["lanes"] * 3.4 / 2 - 0.8), "brg": round(h, 1),
                     "width": round(width, 1), "panels": panels})

# ---------------------------------------------------------------- zebra crossings + speed cameras (OSM nodes)
crossings, cameras = [], []
seg_index = []
for w in ways:
    t = w["tags"]; cls = CLASS.get(t["highway"])
    if not cls or t.get("bridge") not in (None, "no"): continue
    g = [(p["lon"], p["lat"]) for p in w["geometry"]]
    for a, b in zip(g, g[1:]): seg_index.append((a, b, t, cls))


def nearest_road(p, tol=4.0):
    best = None
    for a, b, t, cls in seg_index:
        if abs(a[0] - p[0]) > 0.001 or abs(a[1] - p[1]) > 0.001: continue
        ax, ay = xy(a); bx, by = xy(b); px, py = xy(p)
        dx, dy = bx - ax, by - ay; L2 = dx * dx + dy * dy or 1e-9
        u = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
        d = math.hypot(ax + u * dx - px, ay + u * dy - py)
        if d < tol and (best is None or d < best[0]): best = (d, bearing(a, b), t, cls)
    return best


try:
    for e in load("signs2.json")["elements"]:
        t = e.get("tags", {}); p = (e["lon"], e["lat"])
        if t.get("highway") == "crossing" and (t.get("crossing") in ("marked", "zebra", "traffic_signals", "uncontrolled")
                                              or t.get("crossing:markings") not in (None, "no")):
            r = nearest_road(p)
            if r:
                d, b, wt, cls = r
                hw = lanes_of(wt, cls) * 3.4 / 2 if wt.get("oneway") == "yes" else max(lanes_of(wt, cls) * 3.4, 7) / 2
                crossings.append({"ll": [round(p[0], 7), round(p[1], 7)], "brg": round(b, 1), "half": round(hw, 1)})
        if t.get("highway") == "speed_camera":
            r = nearest_road(p, 15)
            b = r[1] if r else 0
            hw = (half_width_right(r[2], r[3]) if r else 4) + 1.2
            cameras.append({"ll": move([p[0], p[1]], b, 0, hw), "brg": round(b, 1)})
except Exception as ex:
    print("no crossings/cameras:", ex)

out = {"lights": lights, "speed": speed_signs, "gantries": gantries, "crossings": crossings, "cameras": cameras}
with open(os.path.join(OUT, "signs.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
print("lights", len(lights), "(osm", sum(l["src"] == "osm" for l in lights), ") speed", len(speed_signs),
      "gantries", len(gantries), "crossings", len(crossings), "cameras", len(cameras))
