"""Count lanes from a road-capture folder (dash-mounted phone video + trip.csv).

For every second of driving it finds the painted lane lines in front of the
car and reports how many lanes it sees and which one the car is in, tagged
with the GPS position and heading. tools/build_area.py reads the results
(raw/lanes/*.json) and uses them for roads that OpenStreetMap has no lane
count for.

How it works (plain OpenCV, no machine learning):
  1. The car's bonnet and dashboard do not change between frames, so the
     rows that stay the same over a clip mark where the road ends at the bottom.
  2. Lane lines and kerbs all run towards one point on the horizon (the
     vanishing point). It is found per 30 s of video by letting every short
     straight bright segment vote for where its line crosses the others.
  3. Each painted mark in the road band is turned into its sideways offset
     from the car: u = (x - vanishing x) / (y - vanishing y), which on a flat
     road is the lateral distance divided by the camera height. Marks of one
     lane line pile up at the same u, so a histogram of u over a second of
     frames shows one peak per line.
  4. Lane width (in u) is the common spacing between peaks over the whole
     drive; lanes = span between the outer lines / lane width.
Only straight stretches at 15+ km/h are used (the vanishing point needs a
straight road), and a second only counts when lines are found on both sides
of the car.

Usage:
    python tools/lanes_from_video.py path/to/capture_folder [--out raw/lanes] [--qa]

--qa also saves one overlay picture every 20 s into <capture>/lanes_qa/ to
check the detection by eye. Footage shows people and number plates: keep the
pictures internal (blur faces and plates before sharing).
"""
import argparse
import bisect
import csv
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np

W, H = 540, 960  # frames are processed at this size (portrait capture)


def read_rows(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(line for line in f if not line.startswith("#")))


class Clip:
    def __init__(self, path, start_ms, end_ms):
        self.cap = cv2.VideoCapture(str(path))
        self.start, self.end = start_ms, end_ms
        n = self.cap.get(cv2.CAP_PROP_FRAME_COUNT)
        fps = self.cap.get(cv2.CAP_PROP_FPS) or 30
        self.length = n / fps

    def frame(self, sec):
        self.cap.set(cv2.CAP_PROP_POS_MSEC, sec * 1000)
        ok, f = self.cap.read()
        if not ok:
            return None
        if f.shape[1] > f.shape[0]:  # landscape file: the app records portrait
            f = cv2.rotate(f, cv2.ROTATE_90_CLOCKWISE)
        return cv2.resize(f, (W, H))

    def hood_row(self):
        """First row of the bonnet: the band of rows that hardly changes over the clip."""
        fr = []
        for s in np.arange(0, self.length - 1, max(self.length / 36, 1)):
            f = self.frame(s)
            if f is not None:
                fr.append(cv2.cvtColor(cv2.resize(f, (W // 2, H // 2)), cv2.COLOR_BGR2GRAY).astype(np.float32))
        sd = np.convolve(np.array(fr).std(0).mean(1), np.ones(9) / 9, "same")
        lo, hi = int(0.5 * H / 2), int(0.75 * H / 2)
        return (lo + int(np.argmin(sd[lo:hi]))) * 2


def band_of(hood):
    y1 = hood - 10
    return y1 - 130, y1


def segments(f, y0, y1):
    """Short straight bright segments (paint, kerbs) in the road band."""
    g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
    top = y0 - 20
    th = cv2.morphologyEx(g[top:y1], cv2.MORPH_TOPHAT, cv2.getStructuringElement(cv2.MORPH_RECT, (19, 1)))
    m = (th > max(12, np.percentile(th, 96))).astype(np.uint8) * 255
    L = cv2.HoughLinesP(m, 1, np.pi / 180, 15, minLineLength=14, maxLineGap=6)
    out = []
    if L is None:
        return out
    for x1, a, x2, b in L.reshape(-1, 4):
        a += top
        b += top
        ang = abs(math.degrees(math.atan2(b - a, x2 - x1))) % 180
        ang = min(ang, 180 - ang)
        if 15 < ang < 85:
            out.append((x1, a, x2, b))
    return out


def vanishing_point(segs, y0):
    """Point most segment lines pass through, and the share of segment length that supports it."""
    if len(segs) < 20:
        return None, 0
    S = np.array(segs, float)
    x1, a, x2, b = S.T
    ln = np.hypot(x2 - x1, b - a)
    vys = np.arange(y0 - 300, y0 - 5, 4)
    vxs = np.arange(40, W - 40, 4)
    best, at = 0, None
    for vy in vys:
        xv = x1 + (x2 - x1) * (vy - a) / np.where(b == a, 1e-6, b - a)
        tol = 4 + 0.02 * np.abs(vy - a)
        hit = np.abs(xv[:, None] - vxs[None, :]) < tol[:, None]
        sc = (hit * ln[:, None]).sum(0)
        i = int(np.argmax(sc))
        if sc[i] > best:
            best, at = sc[i], (float(vxs[i]), float(vy))
    return at, best / ln.sum()


def support_at(segs, vp):
    """Share of segment length whose line passes through vp."""
    if not segs:
        return 0
    S = np.array(segs, float)
    x1, a, x2, b = S.T
    ln = np.hypot(x2 - x1, b - a)
    xv = x1 + (x2 - x1) * (vp[1] - a) / np.where(b == a, 1e-6, b - a)
    return float((ln * (np.abs(xv - vp[0]) < 4 + 0.02 * np.abs(vp[1] - a))).sum() / ln.sum())


def mark_points(f, y0, y1):
    """Centre points of bright paint marks, row by row (each brighter than both sides)."""
    g = cv2.GaussianBlur(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.float32), (5, 1), 0)
    pts = []
    for y in range(y0 + 30, y1, 2):  # the far end of the band is mostly noise
        row = g[y]
        k = 4 + int(10 * (y - y0) / (y1 - y0))  # marks look wider closer to the car
        c = np.concatenate([[0], np.cumsum(row)])
        x = np.arange(3 * k, W - 3 * k)
        left = (c[x - k] - c[x - 3 * k]) / (2 * k)
        right = (c[x + 3 * k] - c[x + k]) / (2 * k)
        h = k // 2
        mid = (c[x + h + 1] - c[x - h]) / (2 * h + 1)
        r = mid - np.maximum(left, right)
        T = max(9.0, float(np.percentile(r, 97)))
        ok = (r > T) & (r >= np.roll(r, 1)) & (r >= np.roll(r, -1))
        pts.extend((float(xx), float(y)) for xx in x[ok])
    return pts


def line_peaks(us):
    """Lane-line positions (u) from the marks of about one second of frames."""
    h, e = np.histogram(us, bins=160, range=(-8, 8))
    hs = np.convolve(h, [1, 2, 3, 2, 1], "same").astype(float)
    if hs.max() < 30:
        return []
    cand = [i for i in range(1, 159) if hs[i] >= hs[i - 1] and hs[i] > hs[i + 1] and hs[i] > max(30, 0.3 * hs.max())]
    cand.sort(key=lambda i: -hs[i])
    keep = []
    for i in cand:  # at least 0.9 u apart (about a metre)
        if all(abs(i - j) >= 9 for j in keep):
            keep.append(i)
    return sorted(round(float((e[i] + e[i + 1]) / 2), 2) for i in keep)


def lane_width(windows):
    """Most common spacing between neighbouring lines over the drive (u units)."""
    d = [b - a for w in windows for a, b in zip(w["u"], w["u"][1:])]
    d = [x for x in d if 1.8 <= x <= 3.8]
    if len(d) < 10:
        return 2.7  # 3.4 m lanes seen from about 1.25 m up
    h, e = np.histogram(d, bins=20, range=(1.8, 3.8))
    i = int(np.argmax(np.convolve(h, [1, 2, 1], "same")))
    return float((e[i] + e[i + 1]) / 2)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path)
    ap.add_argument("--out", type=Path, default=Path("raw/lanes"))
    ap.add_argument("--qa", action="store_true", help="save overlay pictures into <capture>/lanes_qa/")
    args = ap.parse_args()

    rows = read_rows(args.folder / "trip.csv")
    gps = [r for r in rows if r["kind"] == "gps" and r["lon"] and float(r["accuracy_m"] or 999) <= 20]
    gt = [int(r["t_ms"]) for r in gps]
    clips = read_rows(args.folder / "videos.csv")
    if len(gps) < 10 or not clips:
        sys.exit("need trip.csv with GPS and videos.csv with clips")

    def fix_at(t):
        i = bisect.bisect_left(gt, t)
        if i <= 0 or i >= len(gt) or gt[i] - gt[i - 1] > 3000:
            return None
        a, b = gps[i - 1], gps[i]
        f = (t - gt[i - 1]) / (gt[i] - gt[i - 1])
        return {
            "lon": float(a["lon"]) + f * (float(b["lon"]) - float(a["lon"])),
            "lat": float(a["lat"]) + f * (float(b["lat"]) - float(a["lat"])),
            "heading": float(b["heading_deg"] or 0),
            "speed": float(b["speed_mps"] or 0),
            "h0": float(a["heading_deg"] or 0),
        }

    def straight(t):
        p, q = fix_at(t - 1500), fix_at(t + 1500)
        if not p or not q:
            return False
        return abs((q["heading"] - p["heading"] + 540) % 360 - 180) < 6

    qa = args.folder / "lanes_qa"
    if args.qa:
        qa.mkdir(exist_ok=True)
    windows = []
    for c in clips:
        clip = Clip(args.folder / c["file"], int(c["start_ms"]), int(c["end_ms"]))
        if not clip.cap.isOpened():
            print("cannot open", c["file"])
            continue
        y0, y1 = band_of(clip.hood_row())
        # the phone stays put in its mount, so one vanishing point per clip (from
        # all of it); 30 s stretches that do not agree with it (camera knocked,
        # pointing at the dashboard) are skipped
        segs_at = {t: segments(clip.frame(t), y0, y1) for t in np.arange(0, clip.length - 0.5, 1.0)}
        vp, support = vanishing_point([s for v in segs_at.values() for s in v], y0)
        print(c["file"], f"{clip.length:.0f} s, road band rows {y0}-{y1}, vanishing point {vp} ({support:.0%} of segments)")
        if vp is None or support < 0.08:
            print("  no clear vanishing point in this clip (camera moved or road not in view), skipped")
            continue
        vx, vy = vp
        for chunk in np.arange(0, clip.length - 1, 30.0):
            sup = support_at([s for t, v in segs_at.items() if chunk <= t < chunk + 30 for s in v], vp)
            if sup < 0.06:
                print(f"  {chunk:4.0f}s: road not in view (camera moved or blocked), skipped")
                continue
            for sec in np.arange(chunk, min(chunk + 30, clip.length - 1), 1.0):
                t = clip.start + int(sec * 1000)
                fx = fix_at(t)
                if not fx or fx["speed"] < 4 or not straight(t):
                    continue
                us = []
                for d in (0, 0.2, 0.4, 0.6, 0.8):
                    f = clip.frame(sec + d)
                    if f is None:
                        continue
                    us += [(x - vx) / (y - vy) for x, y in mark_points(f, y0, y1) if y - vy > 5]
                peaks = line_peaks(np.array(us))
                w = {"t": t, "lon": round(fx["lon"], 6), "lat": round(fx["lat"], 6), "heading": round(fx["heading"], 1),
                     "speed": round(fx["speed"], 1), "u": peaks}
                windows.append(w)
                if args.qa and int(sec) % 20 == 0:
                    f = clip.frame(sec)
                    for x, y in mark_points(f, y0, y1)[::2]:
                        cv2.circle(f, (int(x), int(y)), 1, (0, 255, 255), -1)
                    for p in peaks:
                        cv2.line(f, (int(vx), int(vy)), (int(vx + p * (H - vy)), H), (0, 0, 255), 2)
                    cv2.imwrite(str(qa / f"{c['file'][:-4]}_{int(sec):04d}.jpg"), f[int(vy) - 80:y1 + 60])
    uw = lane_width(windows)
    # lane widths in Cairo are 3.0-3.7 m: from a phone 1.0-1.5 m up that is
    # 2.1-3.4 u. Anything else means the lines were not really found (faint
    # paint, glare, camera too low): then no reading is trusted.
    reliable = 2.1 <= uw <= 3.4
    good = 0
    for w in windows if reliable else []:
        u = [x for x in w["u"] if abs(x) < 3.5 * uw]
        left, right = [x for x in u if x < -0.15 * uw], [x for x in u if x > 0.15 * uw]
        w["ok"] = bool(left and right and 0.7 * uw < min(right) - max(left) < 1.35 * uw)
        if w["ok"]:
            good += 1
            w["lanes"] = max(1, round((max(u) - min(u)) / uw))
            w["lane"] = 1 + round((max(left) - min(u)) / uw)  # 1 = leftmost lane seen
    args.out.mkdir(parents=True, exist_ok=True)
    out = args.out / f"{args.folder.name}.json"
    json.dump({"capture": args.folder.name, "lane_width_u": round(uw, 2), "windows": windows}, open(out, "w"), indent=0)
    if not reliable:
        print(f"lane width came out at {uw:.2f} u, outside 2.1-3.4: lines not found reliably in this drive,"
              " so no lane counts are used from it (see the --qa pictures)")
    print(f"{len(windows)} seconds of straight driving, {good} with lane lines on both sides; lane width {uw:.2f} u"
          f" (about {uw * 1.25:.1f} m if the phone is 1.25 m up); written to {out}")


if __name__ == "__main__":
    main()
