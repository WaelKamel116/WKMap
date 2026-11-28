import 'package:cairo_nav/nav/search.dart';
import 'package:flutter_test/flutter_test.dart';

// Searches against the real offline index (assets/data/places.json).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final s = PlaceSearch();
  const lon = 31.33, lat = 30.07; // Nasr City

  Future<List<String>> names(String q) async => [for (final p in await s.local(q, lon: lon, lat: lat)) p.name];

  test('English, Arabic, word starts and small typos find City Stars', () async {
    for (final q in ['city stars', 'City Sta', 'citystars mall', 'citty stras', 'سيتي ستارز', 'ستارز']) {
      final r = await names(q);
      // ignore: avoid_print
      print('$q -> ${r.take(3).toList()}');
      expect(r.take(5).any((n) => n.toLowerCase().contains('city stars') || n.contains('ستارز')), isTrue, reason: q);
      expect(r.take(2).any((n) => n.startsWith('City Stars') || n.startsWith('سيتي ستارز')), isTrue, reason: q);
    }
  });

  test('streets in either language', () async {
    for (final q in ['abbas el akkad', 'عباس العقاد', 'makram ebeid', 'مكرم عبيد']) {
      final r = await names(q);
      // ignore: avoid_print
      print('$q -> ${r.take(3).toList()}');
      expect(r, isNotEmpty, reason: q);
    }
  });

  test('a category lists the nearest places of that kind', () async {
    final r = await s.local('pharmacy', lon: lon, lat: lat);
    expect(r.length, greaterThan(5));
    expect(r.first.metresFrom(lon, lat), lessThan(1500));
    for (var i = 1; i < r.length; i++) {
      expect(r[i].metresFrom(lon, lat) + 300, greaterThanOrEqualTo(r[i - 1].metresFrom(lon, lat)));
    }
    expect(PlaceSearch.categoryOf('صيدلية'), isNotNull);
    expect(PlaceSearch.categoryOf('بنزينة قريبة')?.label, 'Petrol');
  });

  test('coordinates go straight to a pin', () async {
    final r = await s.local('30.0725, 31.3460');
    expect(r.single.lat, closeTo(30.0725, 1e-6));
    expect(r.single.lon, closeTo(31.3460, 1e-6));
  });
}
