import 'package:flutter/material.dart';
import 'models/textbook_drag_payload.dart';

/// MaterialApp.builder에서 만든 최상위 Overlay(=Navigator 밖) 안에
/// "FAB 드롭다운 전용 레이어"를 만들기 위한 키.
///
/// 레이어 순서(낮음→높음):
/// - 화면(route)
/// - 메모 플로팅 배너
/// - (이 레이어) FAB 드롭다운
/// - 오른쪽 사이드시트(메모 슬라이드)
final GlobalKey<OverlayState> fabDropdownOverlayKey = GlobalKey<OverlayState>();

/// 전역 메모 플로팅 배너 표시 여부 제어 (true면 숨김)
final ValueNotifier<bool> hideGlobalMemoFloatingBanners = ValueNotifier<bool>(false);

/// 전역 오른쪽 사이드시트 열림 방지 (성향 탭 등에서 사용)
final ValueNotifier<bool> blockRightSideSheetOpen = ValueNotifier<bool>(false);

/// 교재 메뉴 카드 드래그 중인 payload.
/// - null: 드래그 비활성
/// - non-null: 학생 영역 드롭 대상 활성
final ValueNotifier<TextbookDragPayload?> activeTextbookDragPayload =
    ValueNotifier<TextbookDragPayload?>(null);

/// 교재 카드 드래그 피드백이 왼쪽 사이드시트 영역에 진입했는지 여부.
/// 리소스 화면의 피드백 UI 전환(축소/모양 변경)에 사용한다.
final ValueNotifier<bool> isTextbookDraggingOverLeftSideSheet =
    ValueNotifier<bool>(false);














