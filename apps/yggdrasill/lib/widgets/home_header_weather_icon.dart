import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/home_weather_service.dart';

class HomeHeaderWeatherIcon extends StatefulWidget {
  final double iconSize;
  final Color color;

  const HomeHeaderWeatherIcon({
    super.key,
    this.iconSize = 34,
    this.color = Colors.white70,
  });

  @override
  State<HomeHeaderWeatherIcon> createState() => _HomeHeaderWeatherIconState();
}

class _HomeHeaderWeatherIconState extends State<HomeHeaderWeatherIcon> {
  static const Duration _refreshInterval = Duration(minutes: 20);
  late Future<HomeWeatherSnapshot> _weatherFuture;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _weatherFuture = HomeWeatherService.instance.loadCurrentWeather();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (!mounted) return;
      setState(() {
        _weatherFuture = HomeWeatherService.instance.loadCurrentWeather();
      });
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.iconSize;
    return FutureBuilder<HomeWeatherSnapshot>(
      future: _weatherFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildIcon(
            icon: Symbols.cloud_sync_rounded,
            tooltip: '날씨 정보를 불러오는 중',
            color: widget.color.withValues(alpha: 0.68),
            iconSize: iconSize,
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return _buildIcon(
            icon: Symbols.cloud_off_rounded,
            tooltip: '날씨 정보를 불러오지 못했습니다.',
            color: widget.color.withValues(alpha: 0.68),
            iconSize: iconSize,
          );
        }

        final weather = snapshot.data!;
        final usedFallback = weather.usedFallbackLocation;
        final localityName = weather.localityName.trim().isNotEmpty
            ? weather.localityName.trim()
            : (usedFallback ? '학원 기본 위치' : '현재 위치');
        final weatherLabel = _weatherLabelForCode(weather.weatherCode);
        final tooltipMessage = '현재 $localityName · '
            '${weather.temperatureC.toStringAsFixed(1)}°C · '
            '$weatherLabel'
            '${usedFallback ? ' (기본 위치 폴백)' : ''}';
        return _buildIcon(
          icon: _iconForWeatherCode(weather.weatherCode, weather.isDay),
          tooltip: tooltipMessage,
          color: widget.color,
          iconSize: iconSize,
        );
      },
    );
  }

  Widget _buildIcon({
    required IconData icon,
    required String tooltip,
    required Color color,
    required double iconSize,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: Icon(icon, color: color, size: iconSize),
    );
  }

  IconData _iconForWeatherCode(int weatherCode, bool isDay) {
    if (weatherCode == 0) {
      return isDay ? Symbols.sunny_rounded : Symbols.clear_night_rounded;
    }
    if (weatherCode >= 1 && weatherCode <= 3) {
      return isDay
          ? Symbols.partly_cloudy_day_rounded
          : Symbols.partly_cloudy_night_rounded;
    }
    if (weatherCode == 45 || weatherCode == 48) {
      return Symbols.foggy_rounded;
    }
    if ((weatherCode >= 51 && weatherCode <= 67) ||
        (weatherCode >= 80 && weatherCode <= 82)) {
      return Symbols.rainy_rounded;
    }
    if ((weatherCode >= 71 && weatherCode <= 77) ||
        weatherCode == 85 ||
        weatherCode == 86) {
      return Symbols.snowing_rounded;
    }
    if (weatherCode == 95 || weatherCode == 96 || weatherCode == 99) {
      return Symbols.thunderstorm_rounded;
    }
    return Symbols.cloudy_rounded;
  }

  String _weatherLabelForCode(int weatherCode) {
    if (weatherCode == 0) return '맑음';
    if (weatherCode >= 1 && weatherCode <= 3) return '구름 조금';
    if (weatherCode == 45 || weatherCode == 48) return '안개';
    if ((weatherCode >= 51 && weatherCode <= 67) ||
        (weatherCode >= 80 && weatherCode <= 82)) {
      return '비';
    }
    if ((weatherCode >= 71 && weatherCode <= 77) ||
        weatherCode == 85 ||
        weatherCode == 86) {
      return '눈';
    }
    if (weatherCode == 95 || weatherCode == 96 || weatherCode == 99) {
      return '뇌우';
    }
    return '흐림';
  }
}
