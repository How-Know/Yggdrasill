import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class WeatherInfo {
  const WeatherInfo({required this.temperature, required this.description});
  final double temperature;
  final String description;

  String get label => '${temperature.round()}°  $description';
}

class WeatherService {
  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _cacheDuration = Duration(minutes: 20);
  static const _cacheKey = 'kiosk.weather.cache';

  Future<WeatherInfo?> getWeather(String address) async {
    if (address.trim().isEmpty) return null;
    final preferences = await SharedPreferences.getInstance();
    final cached = preferences.getString(_cacheKey);
    if (cached != null) {
      try {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        final savedAt = DateTime.parse(json['savedAt'] as String);
        if (json['address'] == address &&
            DateTime.now().difference(savedAt) < _cacheDuration) {
          return WeatherInfo(
            temperature: (json['temperature'] as num).toDouble(),
            description: json['description'] as String,
          );
        }
      } catch (_) {
        // 손상된 캐시는 새 조회로 복구한다.
      }
    }

    try {
      final geocode = await _client
          .get(
            Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
              'name': address,
              'count': '1',
              'language': 'ko',
              'format': 'json',
            }),
          )
          .timeout(const Duration(seconds: 8));
      final geoJson = jsonDecode(utf8.decode(geocode.bodyBytes));
      final results = geoJson is Map ? geoJson['results'] : null;
      if (results is! List || results.isEmpty || results.first is! Map) {
        return null;
      }
      final location = Map<String, dynamic>.from(results.first as Map);
      final latitude = (location['latitude'] as num).toDouble();
      final longitude = (location['longitude'] as num).toDouble();
      final forecast = await _client
          .get(
            Uri.https('api.open-meteo.com', '/v1/forecast', {
              'latitude': '$latitude',
              'longitude': '$longitude',
              'current': 'temperature_2m,weather_code',
              'timezone': 'Asia/Seoul',
            }),
          )
          .timeout(const Duration(seconds: 8));
      final forecastJson = jsonDecode(utf8.decode(forecast.bodyBytes));
      final current = forecastJson is Map ? forecastJson['current'] : null;
      if (current is! Map) return null;
      final temperature = (current['temperature_2m'] as num).toDouble();
      final description = _describe((current['weather_code'] as num).toInt());
      final weather = WeatherInfo(
        temperature: temperature,
        description: description,
      );
      await preferences.setString(
        _cacheKey,
        jsonEncode({
          'address': address,
          'savedAt': DateTime.now().toIso8601String(),
          'temperature': temperature,
          'description': description,
        }),
      );
      return weather;
    } catch (_) {
      return null;
    }
  }

  String _describe(int code) {
    if (code == 0) return '맑음';
    if (code <= 3) return '구름';
    if (code == 45 || code == 48) return '안개';
    if (code <= 57) return '이슬비';
    if (code <= 67) return '비';
    if (code <= 77) return '눈';
    if (code <= 82) return '소나기';
    if (code <= 86) return '눈 소나기';
    return '뇌우';
  }
}
