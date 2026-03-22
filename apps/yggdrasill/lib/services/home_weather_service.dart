import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class HomeWeatherSnapshot {
  final int weatherCode;
  final bool isDay;
  final DateTime fetchedAt;
  final bool usedFallbackLocation;

  const HomeWeatherSnapshot({
    required this.weatherCode,
    required this.isDay,
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
        'current': 'weather_code,is_day',
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
    final snapshot = HomeWeatherSnapshot(
      weatherCode: weatherCode,
      isDay: isDay,
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
        return const _ResolvedCoordinates(
          latitude: _fallbackLatitude,
          longitude: _fallbackLongitude,
          usedFallback: true,
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return const _ResolvedCoordinates(
          latitude: _fallbackLatitude,
          longitude: _fallbackLongitude,
          usedFallback: true,
        );
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
      );
    } catch (_) {
      return const _ResolvedCoordinates(
        latitude: _fallbackLatitude,
        longitude: _fallbackLongitude,
        usedFallback: true,
      );
    }
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _ResolvedCoordinates {
  final double latitude;
  final double longitude;
  final bool usedFallback;

  const _ResolvedCoordinates({
    required this.latitude,
    required this.longitude,
    required this.usedFallback,
  });
}
