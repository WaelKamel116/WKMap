# Cairo 3D Navigation: Phase 0 demo (Nasr City)

A simulated 3D drive westbound on El Nasr Road over the Ganzoury and Mamdouh Marei flyovers.

## Run locally
    cd demo
    python -m http.server 8765
Then open http://127.0.0.1:8765/ (opening the HTML file directly will not load the data).

## Layout
- `demo/index.html`: the page (MapLibre GL JS 4.7.1 for the map, three.js r128 for styled buildings and street furniture; no map tiles, all data is bundled)
- `demo/data/`: generated map data (route, streets/parks/signals, flyover decks, buildings)
- `tools/build_data.py`: rebuilds `demo/data/` from the raw downloads in `raw/`
- `tools/build_signs.py`: places traffic lights, speed-limit signs, speed cameras, zebra crossings and overhead direction signs (run after build_data.py)
- `raw/`: OSRM route, Overpass (OpenStreetMap) extracts, Microsoft building footprints for the area

## Data sources
- Streets, flyovers, lanes, parks, traffic signals: (c) OpenStreetMap contributors, ODbL
- Extra building footprints: Microsoft Global ML Building Footprints, ODbL
- Route and maneuvers: OSRM demo server

## Known simplifications
- Building heights are estimated from footprint size (the source data has almost none).
- Facades are procedural textures in typical Nasr City styles, not photos of the real buildings.
- 131 of the 138 traffic lights are estimated at junctions of two named main streets; only 7 are mapped in OSM.
- Flyover decks are modeled at 7 m with a 5.5% approach slope, not surveyed.
- The car position is simulated; there is no GPS yet.
