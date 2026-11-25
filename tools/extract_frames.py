"""Cut geotagged still frames out of a road-capture folder from the app.

A capture folder (copied from the phone) looks like:
    capture_20261126_091500/
        trip.csv     GPS, barometer and level decisions (phone clock, ms)
        videos.csv   clip file, start_ms, end_ms
        clip_001.mp4 ...

This walks along the GPS track and saves one JPEG every --every metres,
plus frames.csv and frames.geojson with position, heading, speed, flyover
level and height for each frame (open the GeoJSON in QGIS or geojson.io).

Needs ffmpeg on PATH (https://ffmpeg.org, or `winget install ffmpeg`).

Usage:
    python tools/extract_frames.py path/to/capture_folder [--every 5] [--out frames]

Footage shows people and number plates: internal use only. Blur faces and
plates before sharing any frame outside the team.
"""
import argparse
import bisect
import csv
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path


def read_rows(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(line for line in f if not line.startswith("#")))


def metres(a, b):
    """Distance between two (lon, lat) points, good enough over a few metres."""
    k = math.cos(math.radians((a[1] + b[1]) / 2))
    return math.hypot((b[0] - a[0]) * 111320 * k, (b[1] - a[1]) * 110540)


def nearest(times, values, t):
    if not times:
        return None
    i = bisect.bisect_left(times, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(times)), key=lambda j: abs(times[j] - t))
    return values[best]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path)
    ap.add_argument("--every", type=float, default=5.0, help="metres between frames (default 5)")
    ap.add_argument("--out", default="frames", help="output subfolder name (default frames)")
    ap.add_argument("--max-accuracy", type=float, default=30.0, help="ignore GPS fixes worse than this (m)")
    args = ap.parse_args()

    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        sys.exit("ffmpeg not found. Install it (winget install ffmpeg) and open a new terminal.")

    rows = read_rows(args.folder / "trip.csv")
    clips = read_rows(args.folder / "videos.csv")
    if not clips:
        sys.exit("videos.csv has no clips (was the capture stopped before the first clip was saved?)")

    gps = [r for r in rows if r["kind"] == "gps" and float(r["accuracy_m"] or 999) <= args.max_accuracy]
    if len(gps) < 2:
        sys.exit("not enough good GPS fixes in trip.csv")
    baro = [r for r in rows if r["kind"] == "baro"]
    level = [r for r in rows if r["kind"] == "level"]
    baro_t = [int(r["t_ms"]) for r in baro]
    level_t = [int(r["t_ms"]) for r in level]

    out = args.folder / args.out
    out.mkdir(exist_ok=True)

    # walk the track and place a sample every N metres (interpolated between fixes)
    samples = []
    travelled, next_at = 0.0, 0.0
    for a, b in zip(gps, gps[1:]):
        pa = (float(a["lon"]), float(a["lat"]))
        pb = (float(b["lon"]), float(b["lat"]))
        ta, tb = int(a["t_ms"]), int(b["t_ms"])
        d = metres(pa, pb)
        if d < 0.01 or tb <= ta:
            continue
        while next_at <= travelled + d:
            f = (next_at - travelled) / d
            samples.append({
                "t_ms": round(ta + f * (tb - ta)),
                "lon": pa[0] + f * (pb[0] - pa[0]),
                "lat": pa[1] + f * (pb[1] - pa[1]),
                "dist_m": round(next_at, 1),
                "heading_deg": float(b["heading_deg"]),
                "speed_kmh": round(float(b["speed_mps"]) * 3.6, 1),
            })
            next_at += args.every
        travelled += d

    saved = []
    for s in samples:
        clip = next((c for c in clips if int(c["start_ms"]) <= s["t_ms"] <= int(c["end_ms"])), None)
        if clip is None:
            continue  # gap between clips, or GPS before/after recording
        offset = (s["t_ms"] - int(clip["start_ms"])) / 1000
        name = f"f_{len(saved) + 1:05d}.jpg"
        r = subprocess.run(
            [ffmpeg, "-loglevel", "error", "-y", "-ss", f"{offset:.3f}", "-i", str(args.folder / clip["file"]),
             "-frames:v", "1", "-q:v", "2", str(out / name)],
            capture_output=True, text=True)
        if r.returncode != 0 or not (out / name).exists():
            print(f"skip {name}: {r.stderr.strip()[:120]}")
            continue
        lv = nearest(level_t, level, s["t_ms"]) or {}
        b = nearest(baro_t, baro, s["t_ms"]) or {}
        s.update({
            "file": name, "clip": clip["file"], "clip_s": round(offset, 2),
            "level": lv.get("level", ""), "road": lv.get("road", ""),
            "deck_h_m": lv.get("deck_h_m", ""), "baro_h_m": lv.get("baro_h_m", ""),
            "pressure_hpa": b.get("pressure_hpa", ""),
        })
        saved.append(s)
        if len(saved) % 50 == 0:
            print(f"{len(saved)} frames...")

    if not saved:
        sys.exit("no frames matched a clip; check that trip.csv and videos.csv are from the same capture")

    with open(out / "frames.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(saved[0].keys()))
        w.writeheader()
        w.writerows(saved)
    with open(out / "frames.geojson", "w", encoding="utf-8") as f:
        json.dump({"type": "FeatureCollection", "features": [
            {"type": "Feature", "geometry": {"type": "Point", "coordinates": [s["lon"], s["lat"]]},
             "properties": {k: v for k, v in s.items() if k not in ("lon", "lat")}}
            for s in saved]}, f, ensure_ascii=False)
    print(f"saved {len(saved)} frames over {travelled / 1000:.2f} km to {out}")


if __name__ == "__main__":
    main()
