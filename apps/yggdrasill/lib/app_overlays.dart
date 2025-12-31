import 'package:flutter/material.dart';

/// MaterialApp.builder에서 만든 최상위 Overlay(=Navigator 밖) 안에
/// "FAB 드롭다운 전용 레이어"를 만들기 위한 키.
///
/// 레이어 순서(낮음→높음):
/// - 화면(route)
/// - 메모 플로팅 배너
/// - (이 레이어) FAB 드롭다운
/// - 오른쪽 사이드시트(메모 슬라이드)
final GlobalKey<OverlayState> fabDropdownOverlayKey = GlobalKey<OverlayState>();













