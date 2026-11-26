# Cairo Nav: Android app, milestone 1

Proves the core idea on a real phone: **is the car up on the flyover or on the road underneath?**

## What it does
- 3D night map of Nasr City (same data as the web demo in `../demo`).
- **Flyover level card** at the top: Ground level / On flyover ramp / Upper level, with confidence and the reason.
- Two modes:
  - **Simulated**: drives the El Nasr Road demo route with fake GPS (about 4 m error) and fake barometer noise. Works anywhere, including at a desk.
  - **Live GPS**: real GPS at 1 Hz plus the phone's barometer. Keeps running with the screen off (shows a notification).
- **Record**: writes every GPS fix, barometer reading and level decision to a CSV file, so a real drive can be replayed and the detector tuned.
  Files: `Android/data/com.smarttechsys.caironav/files/trips/` (copy them over USB).
- **Map buttons** (right edge):
  - **Move to my location**: in Live GPS it follows the car again; in Simulated it finds the phone's real position, shows a blue dot and moves the map there.
  - **Map options**:
    - Look: **Night** (default), **Day**, or **Game**. Game is a bright arcade look with coloured buildings, white lane paint, yellow kerbs, a glowing route, a small 3D car and 3D traffic lights that cycle green, amber and red. The cycling is for show, not real signal timing.
    - Camera: **3D**, **Close** (low chase camera, the default in Game), or **Top-down** (north up).
    - Switches for 3D buildings, traffic lights, and road signs with street names.
- **Camera Inside**: driver's-seat view down the road with a dashboard frame (the car itself is hidden).
- **Search and route** (magnifier button):
  - Search: offline index of about 13,600 shops, malls, clinics and main roads on the map, plus online OpenStreetMap results (Photon) for the rest of Cairo.
  - Routes: up to 3 options, with Fastest / Shortest and Avoid highways. The other options show in grey on the map.
  - Navigation: turn banner with distance to the next turn, time and distance left, and automatic re-routing after about 5 s off the route. In Simulated mode the simulator drives the chosen route.
  - Route servers: free Valhalla (OpenStreetMap), with no live traffic. Live traffic (slow stretches coloured on the route, a traffic layer on all roads, traffic delay per option) needs a TomTom key at build time: `flutter build apk --dart-define=TOMTOM_KEY=...`, or the `TOMTOM_KEY` environment variable in Codemagic.
- **Road signs** stand beside the road, on the right in the direction of travel:
  - Speed limits (OpenStreetMap maxspeed) and speed cameras.
  - Marked crossings and traffic lights.
  - Blue street-name plates in Arabic and English.
- **Smooth car**: each GPS fix is snapped to the matched road (or the flyover deck when the detector says so). The car glides between fixes at 20 frames a second instead of jumping once a second.
- **Road width**: drawn at true scale from lane counts (3.3 m per lane). An earlier scale bug drew every road at half its width.

### Replaying a real drive
`flutter test test/replay_trip_test.dart --dart-define=TRIP_CSV=C:/path/to/capture_.../trip.csv` runs a recorded drive through the level detector and prints when it was on a flyover. Drive logs hold the tester's track: keep them out of the repo.

## Road capture (internal test mode)
The camera button next to Record films the road ahead and records the sensor log at the same time.
- One folder per drive: `trips/capture_YYYYMMDD_HHMMSS/` with `trip.csv` (GPS, barometer, level), `videos.csv` (clip times) and `clip_001.mp4`, `clip_002.mp4`, ... (1080p, 30 fps, no sound, a new clip every 3 minutes, about 180 MB each).
- Mount the phone on the windscreen facing forward, landscape is best, lens clear of the wipers and the dashboard reflection. Keep the app open: phones stop the camera in the background, so capture stops and saves if you leave the app.
- Videos stay on the phone. Copy the folder to the PC, then cut geotagged frames:
  `python ../tools/extract_frames.py path/to/capture_folder --every 5` (needs ffmpeg: `winget install ffmpeg`).
  Output: `frames/f_00001.jpg ...` plus `frames.csv` and `frames.geojson` (position, heading, speed, flyover level per frame).
- **Privacy:** footage shows people and number plates. Internal team use only; blur faces and plates before sharing any frame, and do not upload footage anywhere.

## How the detector works (`lib/nav/level_detector.dart`)
1. Map matching: find the road segments that fit the GPS position and heading.
2. No flyover fits: you're on the ground. That moment is used to learn ground-level air pressure.
3. Only the flyover fits: you're on it.
4. Both the flyover and the road below fit (GPS can't separate them): the barometer decides by comparing measured height above ground with the deck height. Hysteresis stops flickering.

Tests: `flutter test` (synthetic stacked roads plus a simulated drive over the real Ganzoury and Mamdouh Marei flyovers, correct in about 98% of readings).

## Test drive plan (El Nasr Road)
1. Use a phone **with a barometer** (most mid- and high-end Android phones; check with a sensor app).
2. Mount the phone, switch to **Live GPS**, press **Record**.
3. Drive westbound on El Nasr Road from near the Abou Ghazala Bridge. Take the **Ganzoury flyover**, then the **Mamdouh Marei flyover**.
4. Drive the same stretch again on the **ground road underneath**, keeping right at both forks.
5. Stop recording and send the two CSV files back for analysis.

## Build and run
Toolchain (installed in `%USERPROFILE%\dev`): Flutter stable, OpenJDK 21 (MapLibre needs 21), Android SDK 36, NDK 28.2.

```
set JAVA_HOME=%USERPROFILE%\dev\jdk21
set PATH=%USERPROFILE%\dev\flutter\bin;%PATH%
cd app
flutter test
flutter build apk --debug          # -> build\app\outputs\flutter-apk\app-debug.apk
flutter run                        # with a phone connected over USB (USB debugging on)
```

## iPhone build (no Mac needed)
iPhone apps must be built on a Mac, so we use Codemagic's cloud Macs (`../codemagic.yaml` at the repo root).
Bundle id: `com.smarttechsys.caironav`. Trips are saved in the app's Documents folder (Files app > On My iPhone > Cairo Nav > trips).
1. Put the repo on GitHub/GitLab/Bitbucket (private).
2. Apple Developer: register the bundle id; App Store Connect: create the app; Users and Access > Integrations: create an API key (App Manager role) and download the .p8.
3. Codemagic: sign up, add the repo, Team settings > Integrations > App Store Connect: add the key with the name `CairoNav ASC key`.
4. Start the `ios-testflight` workflow. About 20 minutes later the build appears in TestFlight on your iPhone.

## Map data: City Stars to Cairo Festival City (current)
`assets/data/` covers Nasr City to New Cairo. Built by merging several open sources with `../tools/build_area.py`:
- **OpenStreetMap:** roads, flyovers (with layer for stacked bridges), traffic lights, parks.
- **Overture Maps:** buildings already merged from OpenStreetMap, Microsoft and **Google Open Buildings**, plus 13,000+ places (shops, clinics, banks) used to mark commercial buildings.
- **Microsoft footprints (raw):** gap-filler where no other source has a building.
- Checks in the build: duplicates across sources, buildings sitting on roads or flyovers, tiny or low-confidence shapes, coverage against raw Microsoft footprints (96 %). The report is saved in `assets/data/sources.json`.
- Heights are **estimated** (no source has real heights for Cairo): Nasr City blocks 6 to 12 floors, New Cairo villas 2 to 3, malls, hospitals and offices by type.
- Main roads and flyovers cover the whole area; buildings and small streets a 500 m strip along the route.

Rebuild:
```
python ../tools/fetch_area.py ../raw/cfc 30.015 31.325 30.100 31.430      # OSM (Overpass)
python ../tools/fetch_overture.py ../raw/cfc 30.015 31.325 30.100 31.430  # Overture (pip install duckdb)
python ../tools/build_area.py cfc --extra-route raw/route3.json            # run from the repo root
```

## Data
`assets/data/*.json` is copied from `../demo/data` (built by `../tools/build_data.py`).
Map data © OpenStreetMap contributors (ODbL); Overture Maps Foundation; building footprints © Microsoft (ODbL) and Google Open Buildings (CC BY 4.0).
