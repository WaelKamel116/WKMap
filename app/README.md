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
    - Look: **Night** (default), **Day**, **Game**, **Neon** (dark city, glowing cyan and magenta road edges, neon-green route) or **Toy** (mint ground, pastel buildings, orange route). Game, Neon and Toy have the 3D car and 3D traffic lights. Game is a bright arcade look with coloured buildings, white lane paint, yellow kerbs, a glowing route, a small 3D car and 3D traffic lights that cycle green, amber and red. The cycling is for show, not real signal timing.
    - Camera: **3D**, **Close** (game chase camera, the default in the game looks), **Street** (very low, buildings tower over the car), **Look ahead** (car at the bottom, long view up the road), **Helicopter** (high and wide), **Auto zoom** (close when slow, wider and looking further ahead when fast), **Overview** (flat, heading up) or **Top-down** (north up). Switching glides between views.
    - Switches for 3D buildings, traffic lights, and road signs with street names.
- **Screen layout** (map first):
  - Top: a one-line pill showing Ground / On flyover and the road name. While navigating, the next turn shows above it.
  - Bottom bar: speed, the speed limit of the road you are on (red ring, when known; your speed turns red above it), then **Where to?** (search), or while navigating the time left, distance left and arrival time.
  - **Re-centre** (blue button above the bar) appears when you move, zoom or tilt the map. It glides back to following the car at the chosen view's own zoom and tilt. While driving (Live GPS or a route) the map re-centres by itself 12 s after you last touched it.
  - **Speed camera ahead:** a banner under the top pill, "Speed camera in 350 m" with the limit it checks, from about 20 s away (300-800 m). It sounds and vibrates once per camera, and turns red with SLOW DOWN when you are above the limit. Only cameras facing your direction on your road count.
  - Right edge: map options, test tools (flask icon) and my location.
  - Test tools panel: Simulated / Live GPS, sensor log, road capture, and the detector readings (GPS accuracy, pressure, barometer height, confidence and reason).
- **Search and route** (magnifier button):
  - **Search** (`lib/nav/search.dart`):
    - Offline index of about 56,000 places: shops, malls, clinics, stations, districts and streets, with English and Arabic names where the sources have them (Overture places with addresses, OpenStreetMap named places, every named street).
    - Forgiving: any word order, word starts ("city sta"), small typos ("citty stras"), Arabic letter variants (أ/ا, ة/ه, ى/ي), "al"/"el", Egyptian spellings that differ (Akkad/Aqad, Ebeid/Abaid), and English/Arabic words for the same thing (mall = مول, street = شارع).
    - Ranked by match, how well known the place is and distance from you. Results show the distance, the other-language name and the address.
    - Category buttons and words (Petrol, Pharmacy, ATM, Hospital, صيدلية, بنزينة ...) list the nearest places of that kind. Typed coordinates ("30.0725, 31.346") drop a pin. Recent destinations are kept.
    - Online: **Google Places** when built with `--dart-define=GOOGLE_PLACES_KEY=...` (the same places as Google Maps; the key needs Places API (New) enabled and is billed by Google), else **TomTom** search when `TOMTOM_KEY` is set, else Photon (OpenStreetMap). Pressing search on the keyboard also asks Nominatim (OpenStreetMap; its rules do not allow searching on every key press).
    - Open data covers Cairo's shops far less than Google does; for search as good as Google Maps, the Google key is the way.
  - Routes: up to 3 options, with Fastest / Shortest and Avoid highways. The other options show in grey on the map.
  - Navigation: turn banner with distance to the next turn, time and distance left, and automatic re-routing after about 5 s off the route. In Simulated mode the simulator drives the chosen route.
  - Route servers: free Valhalla (OpenStreetMap), with no live traffic. Live traffic (slow stretches coloured on the route, a traffic layer on all roads, traffic delay per option) needs a TomTom key at build time: `flutter build apk --dart-define=TOMTOM_KEY=...`, or the `TOMTOM_KEY` environment variable in Codemagic.
- **Road signs** stand beside the road, on the right in the direction of travel:
  - Speed limits and speed cameras (blue camera sign with the limit it checks; a red zone on the road marks the camera spot).
  - Marked crossings, stop and give-way signs, and traffic lights.
  - Blue street-name plates in Arabic and English.
  - OpenStreetMap maps cameras, crossings and lights as points on the road's centre line, which drew them in the middle of the road. The build now moves each to the right-hand roadside of its road, once per direction of travel (one sign on one-way roads; a camera's direction tag is used when mapped).
- **Speed limits** (OpenStreetMap is the only open source; Overture copies it):
  - Only about 425 of 41,000 road pieces in the area have a limit, so most roads show none. The app never guesses one.
  - The build drops impossible values (a residential street at 90), evens out short pieces whose neighbours on the same road agree on another limit, and fills short untagged gaps between equal limits.
  - One sign per spot: no second speed sign with a different number within 250 m for the same direction (before, a 60 and an 80 from a road and its ramp could stand side by side). Main roads place their signs first; ramps only get one, half-way along, when longer than 150 m.
  - The limit in the bottom bar is the one of the road the car is matched to, so only one value shows at a time.
  - Better coverage needs a data source with a key (TomTom or HERE speed limits, or Mapillary's detected speed-limit signs), or reading the signs from capture videos.
- **Smooth car**: each GPS fix is snapped to the matched road (or the flyover deck when the detector says so). The car glides between fixes at 20 frames a second instead of jumping once a second.
- **Position**:
  - **Path matching:** the road is picked from the recent path through the road network (hidden Markov model), not just the nearest road to each fix. Noisy fixes no longer pull the car onto a parallel service road or the road under a flyover, one-way roads are respected, and junctions are followed.
    - Simulated 5 m GPS error: wrong road 1.4 % vs 8.6 % (El Nasr Road) and 1.7 % vs 3.4 % (City Stars to Cairo Festival City), compared with nearest-road snapping.
    - The car is placed on the road only when it is within GPS error of it, so small side streets (not in the matching data) keep the raw GPS position.
  - **Between fixes:** on a matched road the car moves along the road's own curve; if GPS drops out (under a flyover) it keeps following the road for up to 8 s.
  - **Gyroscope:** gives the heading between fixes off the main roads.
    - It works at any mounting angle, because the rotation is measured around the gravity direction.
    - The sensor offset is learned while stopped, and the turn direction is confirmed against 3 GPS turns before it is used.
    - Test tools shows GYRO learning or on, and the matched road.
  - Logged in trip.csv as `yaw` rows (`yaw_dps`, degrees per second clockwise).
  - **Camera lanes** (`lib/vision/lane_detector.dart`, while road capture is on): about three frames a second go to a lane-line detector. Test tools shows CAMERA LANE (for example "2 of 3"), and each reading is logged in trip.csv as a `lane` row (road column: lane/lanes/offset in metres). It does not move the car yet: first it has to prove itself on real drives (see Lanes from capture videos).
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
- **Lanes from capture videos:** `python ../tools/lanes_from_video.py path/to/capture_folder --qa` counts the lanes for every second of straight driving and writes `raw/lanes/<capture>.json` (gitignored: it holds the drive track). The next map build gives divided roads with no OpenStreetMap lane count the lane count seen most often (at least 5 readings, 60 % agreeing). `--qa` saves overlay pictures into the capture folder to check by eye.
  - How it works: the bonnet rows (still between frames) bound the road; short bright segments vote for the vanishing point; each paint mark's sideways offset is (x - vanishing x) / (y - vanishing y), which is lateral distance / camera height, so marks of one lane line pile up in a histogram.
  - The 26 Nov drive did not give usable lane counts: sunrise glare, faint paint and a low phone with a large bonnet in view left a thin strip of road. The tool notices this (lane spacing outside 3.0-3.7 m) and uses nothing from such a drive.
  - For lane capture: mount the phone high on the windscreen (behind the mirror), lens level with the road, as little bonnet in view as possible; drive in daylight with the sun not ahead.
- **Privacy:** footage shows people and number plates. Internal team use only; blur faces and plates before sharing any frame, and do not upload footage anywhere.

## How the detector works (`lib/nav/level_detector.dart`)
1. Map matching: find the road segments that fit the GPS position and heading.
2. No flyover fits: you're on the ground. That moment is used to learn ground-level air pressure.
3. Only the flyover fits: you're on it.
4. Both the flyover and the road below fit (GPS can't separate them): the barometer decides by comparing measured height above ground with the deck height. Hysteresis stops flickering.

Tests: `flutter test` (synthetic stacked roads plus a simulated drive over the real Ganzoury and Mamdouh Marei flyovers, correct in about 98% of readings).

## Test drive plan (El Nasr Road)
1. Use a phone **with a barometer** (most mid- and high-end Android phones; check with a sensor app).
2. Mount the phone. In **Test tools** (flask button) switch to **Live GPS** and press **Sensor log** or **Road capture**.
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

## Map data: Nasr City, Heliopolis and New Cairo (current)
`assets/data/` covers the box 29.98-30.135 N, 31.29-31.52 E: Heliopolis, Nasr City, the airport road, the Ring Road and New Cairo (Fifth Settlement, Rehab edge). Built by merging several open sources with `../tools/build_area.py --whole`:
- **OpenStreetMap:** roads, flyovers (with layer for stacked bridges), traffic lights, speed limits, speed cameras, crossings, parks.
- **Overture Maps:** buildings already merged from OpenStreetMap, Microsoft and **Google Open Buildings**, plus about 46,500 places (shops, clinics, banks, with addresses) used for search and to mark commercial buildings.
- **Microsoft footprints (raw):** gap-filler where no other source has a building.
- **Result:** 174,573 buildings and 40,708 street pieces.
- **Checks in the build:** duplicates across sources, buildings sitting on roads or flyovers, tiny or low-confidence shapes, and coverage against raw Microsoft footprints (97 %). The report is saved in `assets/data/sources.json`.
- **Heights are estimated** (no source has real heights for Cairo):
  - Nasr City blocks: 6 to 12 floors.
  - Heliopolis: 4 to 8 floors.
  - New Cairo villas: 2 to 3 floors.
  - Malls, hospitals and offices: by type.
- **Tiles:**
  - Buildings, small streets and parks are split into 417 tiles of 0.01 degree (about 1 km) in `assets/data/tiles/`. The app shows the 3 x 3 tiles around the car, or around the middle of the screen when you move the map, and swaps them as you drive.
  - Main roads, flyovers, signs and the search index are single files for the whole area.
  - Street-name plates are drawn only for streets in the loaded tiles.

Rebuild (from the repo root):
```
python tools/fetch_area.py raw/greater 29.98 31.29 30.135 31.52 --only roads.json   # OSM (Overpass); also areas.json, signs.json
python tools/fetch_area.py raw/greater 29.98 31.29 30.135 31.52 --only pois.json    # OSM named places (English + Arabic names)
python tools/fetch_overture.py raw/greater 29.98 31.29 30.135 31.52                 # Overture (pip install duckdb)
python tools/fetch_overture_extra.py raw/greater 29.98 31.29 30.135 31.52           # Overture places with addresses; speed limits (checked: OSM copies)
python tools/ms_box.py raw/ms/cairo.csv.gz raw/greater/ms_box.json 29.98 31.29 30.135 31.52
python tools/build_area.py greater --extra-route raw/route3.json --whole
```

## Data
`assets/data/*.json` is copied from `../demo/data` (built by `../tools/build_data.py`).
Map data © OpenStreetMap contributors (ODbL); Overture Maps Foundation; building footprints © Microsoft (ODbL) and Google Open Buildings (CC BY 4.0).
