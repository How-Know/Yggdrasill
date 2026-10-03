import 'dart:async';

import 'package:flutter/material.dart';

import '../services/home_weather_service.dart';

class HomeHeaderWeatherIcon extends StatefulWidget {
  final double iconSize;
  final Color color;

  const HomeHeaderWeatherIcon({
    super.key,
    this.iconSize = 40,
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
            asset: 'assets/weather/cloud_sync.png',
            tooltip: '날씨 정보를 불러오는 중',
            color: widget.color.withValues(alpha: 0.68),
            iconSize: iconSize,
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return _buildIcon(
            asset: 'assets/weather/cloud_off.png',
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
          asset: _assetForWeatherCode(weather.weatherCode, weather.isDay),
          tooltip: tooltipMessage,
          color: widget.color,
          iconSize: iconSize,
        );
      },
    );
  }

  Widget _buildIcon({
    required String asset,
    required String tooltip,
    required Color color,
    required double iconSize,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        child: Image.asset(
          asset,
          width: iconSize,
          height: iconSize,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }

  /// Icons8 iOS 7 애니메이션. 원본은 100px이라 화면에서는 40으로만 줄여 그린다.
  String _assetForWeatherCode(int weatherCode, bool isDay) {
    if (weatherCode == 0) {
      return isDay ? 'assets/weather/sun.png' : 'assets/weather/clear_night.png';
    }
    if (weatherCode >= 1 && weatherCode <= 3) {
      return isDay
          ? 'assets/weather/partly_cloudy_day.png'
          : 'assets/weather/partly_cloudy_night.png';
    }
    if (weatherCode == 45 || weatherCode == 48) {
      return 'assets/weather/fog.png';
    }
    if ((weatherCode >= 51 && weatherCode <= 67) ||
        (weatherCode >= 80 && weatherCode <= 82)) {
      return 'assets/weather/rain.png';
    }
    if ((weatherCode >= 71 && weatherCode <= 77) ||
        weatherCode == 85 ||
        weatherCode == 86) {
      return 'assets/weather/snow.png';
    }
    if (weatherCode == 95 || weatherCode == 96 || weatherCode == 99) {
      return 'assets/weather/thunder.png';
    }
    return 'assets/weather/cloud.png';
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
