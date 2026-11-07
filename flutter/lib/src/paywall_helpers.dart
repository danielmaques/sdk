part of 'paywall.dart';

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : <String, Object?>{};
List<Map<String, Object?>> _maps(Object? value) =>
    value is List ? value.map(_map).toList() : <Map<String, Object?>>[];
