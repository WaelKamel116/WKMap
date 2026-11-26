import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../nav/search.dart';

/// Type a place or street; pick one to plan a route there.
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
  List<Place> _local = const [], _online = const [];
  bool _loadingOnline = false;
  int _seq = 0;

  void _changed(String q) {
    _debounce?.cancel();
    final seq = ++_seq;
    widget.search.local(q).then((r) {
      if (mounted && seq == _seq) setState(() => _local = r);
    });
    if (q.trim().length < 3) {
      setState(() => _online = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      setState(() => _loadingOnline = true);
      final r = await widget.search.online(q, lon: widget.lon, lat: widget.lat);
      if (!mounted || seq != _seq) return;
      setState(() {
        _loadingOnline = false;
        // do not repeat what the offline list already shows
        _online = [for (final p in r) if (!_local.any((l) => l.name == p.name && (l.lon - p.lon).abs() < 0.002)) p];
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Widget _tile(Place p) => ListTile(
        leading: Icon(p.detail == 'road' ? Icons.add_road : p.online ? Icons.public : Icons.place_outlined, color: Colors.white70),
        title: Text(p.name, style: const TextStyle(color: Colors.white)),
        subtitle: p.detail.isEmpty ? null : Text(p.detail, style: const TextStyle(color: Colors.white54)),
        onTap: () => Navigator.pop(context, p),
      );

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 0.8, fontWeight: FontWeight.w600);
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
          style: const TextStyle(color: Colors.white, fontSize: 18),
          cursorColor: Colors.white,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search a place or street (English or عربي)',
            hintStyle: TextStyle(color: Colors.white38),
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
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
        if (_local.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 14, 16, 4), child: Text('ON THE MAP', style: head)),
        ..._local.map(_tile),
        if (_online.isNotEmpty || _loadingOnline)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(children: [
              const Text('MORE RESULTS (ONLINE)', style: head),
              const SizedBox(width: 8),
              if (_loadingOnline) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
        ..._online.map(_tile),
        if (_ctrl.text.length >= 2 && _local.isEmpty && _online.isEmpty && !_loadingOnline)
          const Padding(padding: EdgeInsets.all(24), child: Text('Nothing found.', style: TextStyle(color: Colors.white54))),
      ]),
    );
  }
}
