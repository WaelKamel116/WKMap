import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'routing.dart' show tomtomKey;

/// Google Places key (optional): build with --dart-define=GOOGLE_PLACES_KEY=...
/// With it, online results come from Google, the same data as Google Maps.
const googlePlacesKey = String.fromEnvironment('GOOGLE_PLACES_KEY');

/// A place the driver can route to.
class Place {
  const Place(this.name, this.detail, this.lon, this.lat, {this.online = false, this.kind = '', this.source = ''});
  final String name;

  /// Address or what kind of place it is, shown under the name.
  final String detail;
  final double lon, lat;
  final bool online;

  /// 'road', 'shopping_mall', 'pharmacy_and_drug_store', ... ('' when unknown).
  final String kind;

  /// Where an online result came from (Google, TomTom, OpenStreetMap).
  final String source;

  /// Straight-line distance in metres.
  double metresFrom(double lon0, double lat0) {
    final k = math.cos(lat0 * math.pi / 180);
    return math.sqrt(math.pow((lon - lon0) * 111320 * k, 2) + math.pow((lat - lat0) * 110540, 2));
  }

  Map<String, dynamic> toJson() => {'n': name, 'd': detail, 'x': lon, 'y': lat, 'k': kind};
  static Place fromJson(Map<String, dynamic> j) =>
      Place(j['n'] as String, j['d'] as String? ?? '', (j['x'] as num).toDouble(), (j['y'] as num).toDouble(), kind: j['k'] as String? ?? '');
}

/// A shortcut button on the search page ("Petrol", "Pharmacy", ...).
class Category {
  const Category(this.label, this.words, this.kinds);
  final String label;
  final List<String> words; // query words that mean this category (English and Arabic)
  final List<String> kinds; // place kinds in the index
}

const categories = [
  Category('Petrol', ['petrol', 'gas', 'fuel', 'station', 'بنزين', 'بنزينه', 'محطه', 'وقود'], ['gas_station', 'fueling_station', 'fuel']),
  Category('Pharmacy', ['pharmacy', 'chemist', 'drugstore', 'صيدليه', 'اجزخانه'], ['pharmacy_and_drug_store', 'pharmacy']),
  Category('ATM', ['atm', 'cash', 'صراف', 'ماكينه'], ['atm']),
  Category('Bank', ['bank', 'بنك', 'مصرف'], ['bank_or_credit_union', 'bank']),
  Category('Hospital', ['hospital', 'emergency', 'مستشفي', 'مستشفى', 'طوارئ'], ['hospital', 'emergency_or_urgent_care_facility', 'clinic']),
  Category('Restaurant', ['restaurant', 'food', 'مطعم', 'اكل'], ['restaurant', 'fast_food_restaurant', 'casual_eatery']),
  Category('Café', ['cafe', 'coffee', 'كافيه', 'قهوه', 'مقهي'], ['cafe', 'coffee_shop']),
  Category('Mall', ['mall', 'shopping', 'مول'], ['shopping_mall', 'department_store', 'mall']),
  Category('Supermarket', ['supermarket', 'grocery', 'سوبرماركت', 'هايبر'], ['supermarket', 'superstore', 'convenience_store', 'food_and_beverage_store']),
  Category('Parking', ['parking', 'جراج', 'باركنج', 'موقف'], ['parking']),
  Category('Mosque', ['mosque', 'masjid', 'مسجد', 'جامع'], ['muslim_place_of_worship']),
  Category('Hotel', ['hotel', 'فندق', 'اوتيل'], ['hotel', 'lodging', 'resort']),
];

/// English and Arabic words for the same thing, so "City Stars mall" finds
/// "سيتي ستارز" and "مستشفى السلام" finds "Al Salam Hospital".
const _synonyms = <List<String>>[
  ['mall', 'مول'], ['street', 'st', 'شارع', 'ش'], ['road', 'rd', 'طريق'], ['square', 'sq', 'ميدان'],
  ['bridge', 'كوبري', 'جسر'], ['hospital', 'مستشفي'], ['pharmacy', 'صيدليه'], ['bank', 'بنك'], ['school', 'مدرسه'],
  ['university', 'uni', 'جامعه'], ['mosque', 'masjid', 'مسجد', 'جامع'], ['church', 'كنيسه'], ['club', 'نادي'],
  ['hotel', 'فندق'], ['restaurant', 'مطعم'], ['cafe', 'كافيه'], ['station', 'محطه'], ['metro', 'مترو'],
  ['airport', 'مطار'], ['tower', 'برج'], ['towers', 'ابراج'], ['park', 'حديقه', 'بارك'], ['garden', 'حديقه'],
  ['center', 'centre', 'سنتر', 'مركز'], ['city', 'سيتي', 'مدينه'], ['stars', 'ستارز'], ['festival', 'فستيفال'],
  ['cairo', 'القاهره', 'كايرو'], ['new', 'الجديده', 'جديده'], ['nasr', 'نصر'], ['heliopolis', 'مصر الجديده', 'هليوبوليس'],
  ['maadi', 'المعادي'], ['settlement', 'التجمع'], ['fifth', 'الخامس'], ['first', 'الاول'], ['axis', 'محور'],
  ['ring', 'الدائري'], ['makram', 'مكرم'], ['abbas', 'عباس'], ['akkad', 'العقاد'], ['tayaran', 'الطيران'],
  ['merghany', 'الميرغني'], ['higaz', 'hegaz', 'الحجاز'], ['korba', 'الكوربه'], ['rehab', 'الرحاب'], ['madinaty', 'مدينتي'],
  ['zamalek', 'الزمالك'], ['tahrir', 'التحرير'], ['downtown', 'وسط البلد'], ['gate', 'جيت', 'بوابه'], ['plaza', 'بلازا'],
  ['hyper', 'هايبر'], ['market', 'ماركت', 'سوق'], ['carrefour', 'كارفور'], ['spinneys', 'سبينيس'], ['seoudi', 'سعودي'],
  ['ikea', 'ايكيا'], ['gym', 'جيم'], ['clinic', 'عياده'], ['lab', 'معمل'], ['police', 'شرطه', 'قسم'],
  ['north', 'شمال', 'الشمالي'], ['south', 'جنوب', 'الجنوبي'], ['east', 'شرق'], ['west', 'غرب'],
];

class _Entry {
  _Entry(this.name, this.alt, this.kind, this.lon, this.lat, this.addr, this.weight)
      : tokens = {
          for (final n in [name, ...alt]) ...PlaceSearch.tokens(n),
          // two words written as one ("citystars", "nasrcity")
          for (final n in [name, ...alt]) ...PlaceSearch._pairs(n),
        }.toList(),
        keys = [for (final n in [name, ...alt]) PlaceSearch.norm(n)],
        nameTokens = [
          for (final n in [name, ...alt])
            [for (final t in PlaceSearch.tokens(n)) if (!PlaceSearch._generic.contains(t) && !t.startsWith('~')) t],
        ];
  final String name;
  final List<String> alt;
  final String kind, addr;
  final double lon, lat;
  final int weight;
  final List<String> tokens;
  final List<String> keys;

  /// Words of each name without "street", "road", "شارع", ...
  final List<List<String>> nameTokens;
}

/// Finds places like a map app's search box does:
///  * offline index built into the app (about 60,000 shops, malls, clinics,
///    stations, districts and streets with English and Arabic names, from
///    Overture and OpenStreetMap),
///  * forgiving matching: any word order, word starts ("city sta"), small
///    typos ("citty stras"), English or Arabic, "al"/"el" and Arabic letter
///    variants, and English/Arabic words for the same thing (mall = مول),
///  * ranked by how well the name matches, how well-known the place is and
///    how close it is,
///  * categories ("petrol", "صيدلية") list the nearest places of that kind,
///  * coordinates ("30.07, 31.34") go straight to that point,
///  * online: Google Places when built with GOOGLE_PLACES_KEY, else TomTom
///    when built with TOMTOM_KEY, else Photon (OpenStreetMap); Nominatim
///    (OpenStreetMap) as well when the driver presses search.
class PlaceSearch {
  List<_Entry>? _index;

  Future<void> _load() async {
    if (_index != null) return;
    final j = jsonDecode(await rootBundle.loadString('assets/data/places.json')) as Map<String, dynamic>;
    _index = [
      for (final r in (j['places'] as List).cast<List<dynamic>>())
        if (r.length >= 7)
          _Entry(r[0] as String, (r[1] as String).isEmpty ? const [] : (r[1] as String).split('|'), r[2] as String,
              (r[3] as num).toDouble(), (r[4] as num).toDouble(), r[5] as String, (r[6] as num).toInt())
        else // older index: name, kind, lon, lat
          _Entry(r[0] as String, const [], r[1] as String, (r[2] as num).toDouble(), (r[3] as num).toDouble(), '', 2),
    ];
  }

  static final _diacritics = RegExp('[ً-ْـ]');

  /// Lower case, Arabic letter variants unified, punctuation removed.
  static String norm(String s) => s
      .toLowerCase()
      .replaceAll(_diacritics, '')
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll(RegExp('[éè]'), 'e')
      .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static const _stop = {'al', 'el', 'the', 'of', 'and', 'de', 'و'};
  static const _generic = {'street', 'st', 'road', 'rd', 'شارع', 'ش', 'طريق', 'axis', 'محور'};

  /// Words of a name, without "al"/"el"/"the"; Arabic words also without the "ال" prefix.
  static List<String> tokens(String s) {
    final out = <String>[];
    for (var w in norm(s).split(' ')) {
      if (w.isEmpty) continue;
      if (w.startsWith('al-') || w.startsWith('el-')) w = w.substring(3);
      if (_stop.contains(w)) continue;
      out.add(w);
      if (w.length > 3 && w.startsWith('ال')) out.add(w.substring(2));
      final f = fold(w);
      if (f != null) out.add(f);
    }
    return out;
  }

  static Iterable<String> _pairs(String n) sync* {
    final t = [for (final w in norm(n).split(' ')) if (w.isNotEmpty && !_stop.contains(w)) w];
    for (var i = 0; i + 1 < t.length; i++) {
      yield t[i] + t[i + 1];
    }
  }

  static final _latin = RegExp(r'^[a-z]+$');

  /// Sound-alike key for Latin spellings of Arabic names, which vary a lot:
  /// Akkad / Aqad, Ebeid / Abaid, Hegaz / Higaz all become the same key
  /// (q -> k, doubled letters once, vowels after the first letter dropped).
  /// Marked with "~" so it only ever matches another key.
  static String? fold(String w) {
    if (w.length < 5 || !_latin.hasMatch(w)) return null;
    var s = w.replaceAll('q', 'k').replaceAll('ph', 'f');
    s = s.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
    final first = 'aeiouy'.contains(s[0]) ? 'a' : s[0];
    final rest = s.substring(1).replaceAll(RegExp('[aeiouy]'), '');
    return rest.length < 2 ? null : '~$first$rest';
  }

  static final Map<String, Set<String>> _syn = () {
    final m = <String, Set<String>>{};
    for (final g in _synonyms) {
      final all = {for (final w in g) ...tokens(w)};
      for (final w in all) {
        m.putIfAbsent(w, () => {}).addAll(all);
      }
    }
    return m;
  }();

  /// Edit distance (with swaps) up to [max]; returns max + 1 when further.
  static int _edits(String a, String b, int max) {
    if ((a.length - b.length).abs() > max) return max + 1;
    var prev2 = List<int>.filled(b.length + 1, 0);
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      var rowMin = cur[0];
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var v = math.min(math.min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
        if (i > 1 && j > 1 && a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) && a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
          v = math.min(v, prev2[j - 2] + 1);
        }
        cur[j] = v;
        rowMin = math.min(rowMin, v);
      }
      if (rowMin > max) return max + 1;
      prev2 = prev;
      prev = cur;
    }
    return prev[b.length];
  }

  /// How well query word [q] (with its synonyms) matches one of the name words:
  /// 3 same word, 2 start of a word (only for the word being typed), 1 small typo, 0 no match.
  static int _wordScore(Set<String> q, List<String> words, bool typing) {
    var best = 0;
    for (final a in q) {
      for (final w in words) {
        if (w == a) return 3;
        if (w.startsWith(a) && (typing || a.length >= 4)) {
          best = math.max(best, 2);
        } else if (best < 1 && a.length >= 4 && w.isNotEmpty && w[0] == a[0]) {
          final max = a.length >= 8 ? 2 : 1;
          final cut = w.length > a.length + max ? w.substring(0, a.length) : w; // typo in a word being typed
          if (_edits(a, cut, max) <= max) best = 1;
        }
      }
    }
    return best;
  }

  static final _coords = RegExp(r'^\s*(-?\d{1,2}\.\d+)\s*[, ]\s*(-?\d{1,3}\.\d+)\s*$');

  /// The category the whole query asks for ("petrol", "صيدلية قريبة"), or null.
  static Category? categoryOf(String query) {
    final t = tokens(query).where((w) => !{'near', 'nearest', 'me', 'قريب', 'قريبه', 'اقرب'}.contains(w)).toList();
    if (t.isEmpty || t.length > 2) return null;
    for (final c in categories) {
      final words = {for (final w in c.words) ...tokens(w)};
      if (t.every(words.contains)) return c;
    }
    return null;
  }

  /// Offline matches, best first.
  Future<List<Place>> local(String query, {double lon = 31.37, double lat = 30.05, int limit = 20}) async {
    await _load();
    final m = _coords.firstMatch(query);
    if (m != null) {
      var a = double.parse(m.group(1)!), b = double.parse(m.group(2)!);
      if (a > 30.6 && b < 30.6) (a, b) = (b, a); // typed as lon, lat (Cairo: lat about 30.0, lon about 31.3)
      return [Place('Dropped pin', '${a.toStringAsFixed(5)}, ${b.toStringAsFixed(5)}', b, a, kind: 'pin')];
    }
    final cat = categoryOf(query);
    if (cat != null) return nearest(cat, lon: lon, lat: lat, limit: limit);
    final qt = tokens(query);
    if (qt.isEmpty) return const [];
    final typingLast = !query.endsWith(' ');
    // each query word with its other-language words and its sound-alike key
    final qs = <Set<String>>[];
    for (final w in qt) {
      if (w.startsWith('~')) {
        qs.last.add(w);
      } else {
        qs.add({w, ...?_syn[w]});
      }
    }
    final qn = norm(query);
    final scored = <(double, _Entry)>[];
    for (final e in _index!) {
      var sum = 0;
      var ok = true;
      for (var i = 0; i < qs.length; i++) {
        final s = _wordScore(qs[i], e.tokens, typingLast && i == qs.length - 1);
        if (s == 0) {
          ok = false;
          break;
        }
        sum += s;
      }
      if (!ok) continue;
      var score = sum / qs.length * 3; // 3 .. 9
      if (e.keys.any((k) => k == qn)) {
        score += 5;
      } else if (e.keys.any((k) => k.startsWith(qn))) {
        score += 3;
      }
      // names that are mostly the query ("عباس العقاد" street) before names that
      // merely contain it ("مكتبة بيبو عباس العقاد")
      var cover = 0.0;
      for (final nt in e.nameTokens) {
        if (nt.isEmpty) continue;
        var hit = 0;
        for (final t in nt) {
          if (qs.any((q) => q.any((a) => t == a || (a.length >= 3 && t.startsWith(a))))) hit++;
        }
        cover = math.max(cover, hit / nt.length);
      }
      score += 4 * cover;
      score += e.weight * 0.45;
      final km = _km(e.lon, e.lat, lon, lat);
      score -= 2.2 * math.log(1 + km) / math.ln10; // 1 km: -0.7, 10 km: -2.3, 30 km: -3.3
      scored.add((score, e));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    final out = <Place>[];
    for (final s in scored) {
      final e = s.$2;
      // the same name twice within 300 m (two entrances, two sources): keep the best
      if (out.any((p) => norm(p.name) == norm(e.name) && p.metresFrom(e.lon, e.lat) < 300)) continue;
      out.add(_place(e));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Nearest places of a category.
  Future<List<Place>> nearest(Category c, {required double lon, required double lat, int limit = 20}) async {
    await _load();
    final hits = [for (final e in _index!) if (c.kinds.contains(e.kind)) e];
    hits.sort((a, b) => (_km(a.lon, a.lat, lon, lat) - a.weight * 0.05).compareTo(_km(b.lon, b.lat, lon, lat) - b.weight * 0.05));
    return [for (final e in hits.take(limit)) _place(e)];
  }

  static double _km(double lon1, double lat1, double lon0, double lat0) {
    final k = math.cos(lat0 * math.pi / 180);
    return math.sqrt(math.pow((lon1 - lon0) * 111.32 * k, 2) + math.pow((lat1 - lat0) * 110.54, 2));
  }

  static String kindLabel(String k) => switch (k) {
        '' || 'place' => '',
        'road' => 'Street',
        'pin' => 'Point',
        _ => (k[0].toUpperCase() + k.substring(1)).replaceAll('_', ' ').replaceAll(' and drug store', '').replaceAll(' or credit union', ''),
      };

  static Place _place(_Entry e) {
    // show the other-language name next to the address
    final other = e.alt.firstWhere((a) => _isArabic(a) != _isArabic(e.name), orElse: () => '');
    final detail = [kindLabel(e.kind), if (other.isNotEmpty) other, if (e.addr.isNotEmpty) e.addr].where((x) => x.isNotEmpty).join(' · ');
    return Place(e.name, detail, e.lon, e.lat, kind: e.kind);
  }

  static bool _isArabic(String s) => RegExp('[؀-ۿ]').hasMatch(s);

  // ------------------------------------------------------------------ online

  static const _ua = 'CairoNav-test/0.1';

  static Future<dynamic> _getJson(Uri u, {Map<String, String>? headers, Object? body}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = body == null ? await client.getUrl(u) : await client.postUrl(u);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      headers?.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return jsonDecode(await res.transform(utf8.decoder).join());
    } finally {
      client.close();
    }
  }

  /// Which online source is used while typing.
  static String get onlineSource => googlePlacesKey.isNotEmpty ? 'Google' : tomtomKey.isNotEmpty ? 'TomTom' : 'OpenStreetMap';

  /// Online matches near (lon, lat). [submitted]: the driver pressed search,
  /// so slower sources that must not be queried on every key press are asked too.
  Future<List<Place>> online(String query, {double lon = 31.37, double lat = 30.05, bool submitted = false}) async {
    if (query.trim().length < 3 || _coords.hasMatch(query)) return const [];
    final lang = _isArabic(query) ? 'ar' : 'en';
    final jobs = <Future<List<Place>>>[];
    if (googlePlacesKey.isNotEmpty) {
      jobs.add(_google(query, lon, lat, lang));
    } else if (tomtomKey.isNotEmpty) {
      jobs.add(_tomtom(query, lon, lat, lang));
    } else {
      jobs.add(_photon(query, lon, lat));
    }
    if (submitted) jobs.add(_nominatim(query, lon, lat, lang));
    final all = <Place>[];
    for (final r in await Future.wait(jobs.map((j) => j.catchError((_) => <Place>[])))) {
      for (final p in r) {
        if (!all.any((q) => norm(q.name) == norm(p.name) && q.metresFrom(p.lon, p.lat) < 150)) all.add(p);
      }
    }
    return all;
  }

  Future<List<Place>> _google(String q, double lon, double lat, String lang) async {
    final j = await _getJson(Uri.https('places.googleapis.com', '/v1/places:searchText'), headers: {
      'X-Goog-Api-Key': googlePlacesKey,
      'X-Goog-FieldMask': 'places.displayName,places.formattedAddress,places.location,places.primaryType',
    }, body: {
      'textQuery': q,
      'languageCode': lang,
      'regionCode': 'EG',
      'pageSize': 10,
      'locationBias': {
        'circle': {'center': {'latitude': lat, 'longitude': lon}, 'radius': 30000.0},
      },
    });
    if (j == null) return const [];
    return [
      for (final p in (j['places'] as List? ?? const []))
        Place(p['displayName']?['text'] as String? ?? '', p['formattedAddress'] as String? ?? '',
            (p['location']['longitude'] as num).toDouble(), (p['location']['latitude'] as num).toDouble(),
            online: true, kind: p['primaryType'] as String? ?? '', source: 'Google'),
    ];
  }

  Future<List<Place>> _tomtom(String q, double lon, double lat, String lang) async {
    final j = await _getJson(Uri.https('api.tomtom.com', '/search/2/search/${Uri.encodeComponent(q)}.json', {
      'key': tomtomKey, 'lat': '$lat', 'lon': '$lon', 'radius': '60000', 'limit': '10', 'countrySet': 'EG',
      'typeahead': 'true', 'language': lang == 'ar' ? 'ar' : 'en-GB',
    }));
    if (j == null) return const [];
    return [
      for (final r in (j['results'] as List? ?? const []))
        Place((r['poi']?['name'] ?? r['address']?['freeformAddress'] ?? '') as String,
            r['poi'] != null ? (r['address']?['freeformAddress'] as String? ?? '') : '',
            (r['position']['lon'] as num).toDouble(), (r['position']['lat'] as num).toDouble(),
            online: true, kind: r['poi'] != null ? 'place' : 'road', source: 'TomTom'),
    ];
  }

  Future<List<Place>> _photon(String q, double lon, double lat) async {
    final j = await _getJson(Uri.https('photon.komoot.io', '/api/', {
      'q': q, 'lat': '$lat', 'lon': '$lon', 'limit': '10', 'location_bias_scale': '0.4',
      'bbox': '30.9,29.7,32.0,30.4', // Greater Cairo
    }));
    if (j == null) return const [];
    return [
      for (final f in j['features'] as List)
        if ((f['properties']['name'] as String?)?.isNotEmpty == true)
          Place(
            f['properties']['name'] as String,
            [f['properties']['street'], f['properties']['district'], f['properties']['city']].whereType<String>().join(', '),
            ((f['geometry']['coordinates'] as List)[0] as num).toDouble(),
            ((f['geometry']['coordinates'] as List)[1] as num).toDouble(),
            online: true,
            kind: f['properties']['osm_value'] as String? ?? '',
            source: 'OpenStreetMap',
          ),
    ];
  }

  /// Nominatim's rules allow no searching on every key press: only on submit.
  Future<List<Place>> _nominatim(String q, double lon, double lat, String lang) async {
    final j = await _getJson(Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': q, 'format': 'jsonv2', 'limit': '8', 'countrycodes': 'eg', 'accept-language': '$lang,en',
      'viewbox': '${lon - 0.4},${lat + 0.3},${lon + 0.4},${lat - 0.3}',
    }));
    if (j == null) return const [];
    return [
      for (final r in j as List)
        Place((r['name'] as String?)?.isNotEmpty == true ? r['name'] as String : (r['display_name'] as String).split(',').first,
            (r['display_name'] as String).split(',').skip(1).take(3).join(',').trim(),
            double.parse(r['lon'] as String), double.parse(r['lat'] as String),
            online: true, kind: r['type'] as String? ?? '', source: 'OpenStreetMap'),
    ];
  }

  // ------------------------------------------------------------------ recent places

  static Future<File> _recentFile() async => File('${(await getApplicationDocumentsDirectory()).path}/recent_places.json');

  Future<List<Place>> recent() async {
    try {
      final f = await _recentFile();
      if (!await f.exists()) return const [];
      return [for (final j in jsonDecode(await f.readAsString()) as List) Place.fromJson(j as Map<String, dynamic>)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> remember(Place p) async {
    if (p.kind == 'pin' && p.name == 'Dropped pin') return;
    try {
      final list = [p, ...(await recent()).where((q) => !(q.name == p.name && q.metresFrom(p.lon, p.lat) < 100))].take(12).toList();
      await (await _recentFile()).writeAsString(jsonEncode([for (final q in list) q.toJson()]));
    } catch (_) {}
  }
}
