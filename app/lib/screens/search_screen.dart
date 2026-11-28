import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../nav/search.dart';

/// Type a place, street, category or coordinates; pick one to plan a route there.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.search, this.lon = 31.37, this.lat = 30.05});
  final PlaceSearch search;
  final double lon, lat;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Place> _local = const [], _online = const [], _recent = const [];
  Category? _category;
  bool _loadingOnline = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    widget.search.recent().then((r) {
      if (mounted) setState(() => _recent = r);
    });
  }

  void _changed(String q, {bool submitted = false}) {
    _debounce?.cancel();
    final seq = ++_seq;
    final cat = PlaceSearch.categoryOf(q);
    widget.search.local(q, lon: widget.lon, lat: widget.lat).then((r) {
      if (mounted && seq == _seq) {
        setState(() {
          _local = r;
          _category = cat;
        });
      }
    });
    if (q.trim().length < 3 || cat != null) {
      setState(() {
        _online = const [];
        _loadingOnline = false;
      });
      return;
    }
    _debounce = Timer(Duration(milliseconds: submitted ? 0 : 450), () async {
      setState(() => _loadingOnline = true);
      final r = await widget.search.online(q, lon: widget.lon, lat: widget.lat, submitted: submitted);
      if (!mounted || seq != _seq) return;
      setState(() {
        _loadingOnline = false;
        // do not repeat what the offline list already shows
        _online = [
          for (final p in r)
            if (!_local.any((l) => PlaceSearch.norm(l.name) == PlaceSearch.norm(p.name) && l.metresFrom(p.lon, p.lat) < 200)) p
        ];
      });
    });
  }

  void _pick(Place p) {
    widget.search.remember(p);
    Navigator.pop(context, p);
  }

  void _searchCategory(Category c) {
    _ctrl.text = c.label;
    _changed(c.words.first);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  static String _dist(double m) => m < 950 ? '${(m / 10).round() * 10} m' : m < 9500 ? '${(m / 1000).toStringAsFixed(1)} km' : '${(m / 1000).round()} km';

  IconData _icon(Place p) => switch (p.kind) {
        'road' => Icons.add_road,
        'pin' => Icons.push_pin_outlined,
        'shopping_mall' || 'department_store' || 'mall' => Icons.local_mall_outlined,
        'hospital' || 'clinic' || 'emergency_or_urgent_care_facility' => Icons.local_hospital_outlined,
        'pharmacy_and_drug_store' || 'pharmacy' => Icons.local_pharmacy_outlined,
        'gas_station' || 'fueling_station' || 'fuel' => Icons.local_gas_station_outlined,
        'restaurant' || 'fast_food_restaurant' || 'casual_eatery' => Icons.restaurant_outlined,
        'cafe' || 'coffee_shop' => Icons.local_cafe_outlined,
        'atm' || 'bank_or_credit_union' || 'bank' => Icons.account_balance_outlined,
        'hotel' || 'lodging' || 'resort' => Icons.hotel_outlined,
        'muslim_place_of_worship' || 'christian_place_of_worship' || 'place_of_worship' => Icons.mosque_outlined,
        'college_university' || 'school' || 'high_school' || 'education' => Icons.school_outlined,
        'train_station' || 'public_transit_facility_or_service' => Icons.train_outlined,
        'park' || 'garden' => Icons.park_outlined,
        'suburb' || 'neighbourhood' || 'district' || 'quarter' => Icons.location_city_outlined,
        'parking' => Icons.local_parking_outlined,
        _ => p.online ? Icons.public : Icons.place_outlined,
      };

  Widget _tile(Place p, {bool recent = false}) {
    final d = p.metresFrom(widget.lon, widget.lat);
    final sub = [if (d < 200000) _dist(d), if (p.detail.isNotEmpty) p.detail, if (p.source.isNotEmpty) p.source].join(' · ');
    return ListTile(
      leading: Icon(recent ? Icons.history : _icon(p), color: Colors.white70),
      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
      onTap: () => _pick(p),
    );
  }

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 0.8, fontWeight: FontWeight.w600);
    final empty = _ctrl.text.trim().isEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFF0E141B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF17202A),
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          onChanged: _changed,
          onSubmitted: (q) => _changed(q, submitted: true),
          style: const TextStyle(color: Colors.white, fontSize: 18),
          cursorColor: Colors.white,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Place, street, category or عربي',
            hintStyle: TextStyle(color: Colors.white38),
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (!empty)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _ctrl.clear();
                _changed('');
              },
            ),
        ],
      ),
      body: ListView(children: [
        if (empty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in categories)
                ActionChip(
                  label: Text(c.label),
                  onPressed: () => _searchCategory(c),
                  backgroundColor: const Color(0xFF243140),
                  labelStyle: const TextStyle(color: Colors.white),
                  side: BorderSide.none,
                ),
            ]),
          ),
          if (_recent.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 14, 16, 4), child: Text('RECENT', style: head)),
          ..._recent.map((p) => _tile(p, recent: true)),
        ],
        if (!empty && _local.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(_category != null ? 'NEAREST ${_category!.label.toUpperCase()}' : 'ON THE MAP', style: head),
          ),
        if (!empty) ..._local.map(_tile),
        if (!empty && (_online.isNotEmpty || _loadingOnline))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(children: [
              Text('MORE RESULTS (${PlaceSearch.onlineSource.toUpperCase()})', style: head),
              const SizedBox(width: 8),
              if (_loadingOnline) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
        if (!empty) ..._online.map(_tile),
        if (_ctrl.text.length >= 2 && _local.isEmpty && _online.isEmpty && !_loadingOnline)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nothing found. Press search on the keyboard to also ask OpenStreetMap.', style: TextStyle(color: Colors.white54)),
          ),
      ]),
    );
  }
}
