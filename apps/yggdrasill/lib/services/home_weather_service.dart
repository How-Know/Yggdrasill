import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'data_manager.dart';

class HomeWeatherSnapshot {
  final int weatherCode;
  final bool isDay;
  final double temperatureC;
  final String localityName;
  final DateTime fetchedAt;
  final bool usedFallbackLocation;

  const HomeWeatherSnapshot({
    required this.weatherCode,
    required this.isDay,
    required this.temperatureC,
    required this.localityName,
    required this.fetchedAt,
    required this.usedFallbackLocation,
  });
}

class HomeWeatherService {
  HomeWeatherService._();

  static final HomeWeatherService instance = HomeWeatherService._();

  static const Duration _cacheTtl = Duration(minutes: 20);
  static const Duration _httpTimeout = Duration(seconds: 8);
  static const Duration _locationTimeout = Duration(seconds: 6);

  // 기본 학원 위치 폴백 좌표 (서울 시청 인근)
  static const double _fallbackLatitude = 37.5665;
  static const double _fallbackLongitude = 126.9780;

  HomeWeatherSnapshot? _cachedSnapshot;
  Future<HomeWeatherSnapshot>? _inFlight;

  Future<HomeWeatherSnapshot> loadCurrentWeather() {
    final now = DateTime.now();
    final cachedSnapshot = _cachedSnapshot;
    if (cachedSnapshot != null &&
        now.difference(cachedSnapshot.fetchedAt) < _cacheTtl) {
      return Future.value(cachedSnapshot);
    }
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final future = _fetchCurrentWeather();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
  }

  Future<HomeWeatherSnapshot> _fetchCurrentWeather() async {
    final resolved = await _resolveCoordinates();
    final uri = Uri.https(
      'api.open-meteo.com',
      '/v1/forecast',
      <String, String>{
        'latitude': resolved.latitude.toStringAsFixed(4),
        'longitude': resolved.longitude.toStringAsFixed(4),
        'current': 'weather_code,is_day,temperature_2m',
        'forecast_days': '1',
        'timezone': 'auto',
      },
    );

    final response = await http.get(uri).timeout(_httpTimeout);
    if (response.statusCode != 200) {
      throw Exception('weather_api_failed_${response.statusCode}');
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('weather_api_invalid_payload');
    }
    final current = decoded['current'];
    if (current is! Map<String, dynamic>) {
      throw Exception('weather_api_missing_current');
    }

    final weatherCode = _toInt(current['weather_code']);
    final isDay = _toInt(current['is_day']) == 1;
    final temperatureC = _toDouble(current['temperature_2m']);
    final localityName = await _resolveLocalityName(resolved);
    final snapshot = HomeWeatherSnapshot(
      weatherCode: weatherCode,
      isDay: isDay,
      temperatureC: temperatureC,
      localityName: localityName,
      fetchedAt: DateTime.now(),
      usedFallbackLocation: resolved.usedFallback,
    );
    _cachedSnapshot = snapshot;
    return snapshot;
  }

  Future<_ResolvedCoordinates> _resolveCoordinates() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return _resolveFallbackCoordinates();
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return _resolveFallbackCoordinates();
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: _locationTimeout,
        ),
      );
      return _ResolvedCoordinates(
        latitude: position.latitude,
        longitude: position.longitude,
        usedFallback: false,
        localityName: '',
      );
    } catch (_) {
      return _resolveFallbackCoordinates();
    }
  }

  Future<_ResolvedCoordinates> _resolveFallbackCoordinates() async {
    final academyAddress = DataManager.instance.academySettings.address.trim();
    if (academyAddress.isNotEmpty) {
      final geocoded = await _searchCoordinatesFromAddress(academyAddress);
      if (geocoded != null) {
        return geocoded;
      }
    }
    return const _ResolvedCoordinates(
      latitude: _fallbackLatitude,
      longitude: _fallbackLongitude,
      usedFallback: true,
      localityName: '학원 기본 위치',
    );
  }

  Future<_ResolvedCoordinates?> _searchCoordinatesFromAddress(
    String address,
  ) async {
    try {
      final uri = Uri.https(
        'geocoding-api.open-meteo.com',
        '/v1/search',
        <String, String>{
          'name': address,
          'count': '1',
          'language': 'ko',
          'format': 'json',
        },
      );
      final response = await http.get(uri).timeout(_httpTimeout);
      if (response.statusCode != 200) {
        return null;
      }
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final results = decoded['results'];
      if (results is! List || results.isEmpty) {
        return null;
      }
      final first = results.first;
      if (first is! Map<String, dynamic>) {
        return null;
      }
      final latitude = _toDouble(first['latitude']);
      final longitude = _toDouble(first['longitude']);
      if (latitude == 0 && longitude == 0) {
        return null;
      }
      final localityName = _firstNonEmpty(
            <String?>[
              first['admin4']?.toString(),
              first['name']?.toString(),
              first['admin3']?.toString(),
              first['admin2']?.toString(),
            ],
          ) ??
          '학원 기본 위치';
      return _ResolvedCoordinates(
        latitude: latitude,
        longitude: longitude,
        usedFallback: true,
        localityName: localityName,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveLocalityName(_ResolvedCoordinates resolved) async {
    if (resolved.localityName.trim().isNotEmpty) {
      return resolved.localityName.trim();
    }
    final reverse = await _reverseGeocodeLocality(
      latitude: resolved.latitude,
      longitude: resolved.longitude,
    );
    if (reverse != null && reverse.trim().isNotEmpty) {
      return reverse.trim();
    }
    final nominatimReverse = await _reverseGeocodeNominatimLocality(
      latitude: resolved.latitude,
      longitude: resolved.longitude,
    );
    if (nominatimReverse != null && nominatimReverse.trim().isNotEmpty) {
      return nominatimReverse.trim();
    }
    return resolved.usedFallback ? '학원 기본 위치' : '위치 정보';
  }

  Future<String?> _reverseGeocodeLocality({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final uri = Uri.https(
        'geocoding-api.open-meteo.com',
        '/v1/reverse',
        <String, String>{
          'latitude': latitude.toStringAsFixed(4),
          'longitude': longitude.toStringAsFixed(4),
          'count': '1',
          'language': 'ko',
          'format': 'json',
        },
      );
      final response = await http.get(uri).timeout(_httpTimeout);
      if (response.statusCode != 200) {
        return null;
      }
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final results = decoded['results'];
      if (results is! List || results.isEmpty) {
        return null;
      }
      final first = results.first;
      if (first is! Map<String, dynamic>) {
        return null;
      }
      return _firstNonEmpty(
        <String?>[
          first['admin4']?.toString(),
          first['suburb']?.toString(),
          first['village']?.toString(),
          first['name']?.toString(),
          first['admin3']?.toString(),
          first['admin2']?.toString(),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _reverseGeocodeNominatimLocality({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/reverse',
        <String, String>{
          'format': 'jsonv2',
          'lat': latitude.toStringAsFixed(6),
          'lon': longitude.toStringAsFixed(6),
          'zoom': '17',
          'addressdetails': '1',
          'accept-language': 'ko',
        },
      );
      final response = await http.get(
        uri,
        headers: const <String, String>{
          'User-Agent': 'Yggdrasill/1.0 (weather locality lookup)',
        },
      ).timeout(_httpTimeout);
      if (response.statusCode != 200) {
        return null;
      }
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final address = decoded['address'];
      if (address is! Map<String, dynamic>) {
        return null;
      }
      return _firstNonEmpty(
        <String?>[
          address['suburb']?.toString(),
          address['neighbourhood']?.toString(),
          address['quarter']?.toString(),
          address['city_district']?.toString(),
          address['town']?.toString(),
          address['village']?.toString(),
          address['city']?.toString(),
          address['county']?.toString(),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  String? _firstNonEmpty(List<String?> candidates) {
    for (final raw in candidates) {
      final v = (raw ?? '').trim();
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _ResolvedCoordinates {
  final double latitude;
  final double longitude;
  final bool usedFallback;
  final String localityName;

  const _ResolvedCoordinates({
    required this.latitude,
    required this.longitude,
    required this.usedFallback,
    required this.localityName,
  });
}
