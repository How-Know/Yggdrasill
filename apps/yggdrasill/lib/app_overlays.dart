import 'package:flutter/material.dart';
import 'models/behavior_card_drag_payload.dart';
import 'models/textbook_drag_payload.dart';

typedef AsyncUiAction = Future<void> Function();
typedef RightSheetTestGradingStates = Map<String, String>;
typedef RightSheetTestGradingStatesChanged = void Function(
  RightSheetTestGradingStates states,
);
typedef RightSheetTestGradingAction = Future<void> Function(
  String action,
  RightSheetTestGradingStates states,
);

class RightSideSheetTestGradingSession {
  final String sessionId;
  final String title;
  final String studentName;
  final String groupHomeworkTitle;
  final List<Map<String, dynamic>> gradingPages;
  final List<Map<String, String>> overlayEntries;
  final RightSheetTestGradingStates initialStates;
  final RightSheetTestGradingStatesChanged? onStatesChanged;
  final RightSheetTestGradingAction? onAction;
  final Map<String, double> scoreByQuestionKey;

  const RightSideSheetTestGradingSession({
    required this.sessionId,
    required this.title,
    this.studentName = '',
    this.groupHomeworkTitle = '',
    required this.gradingPages,
    this.overlayEntries = const <Map<String, String>>[],
    this.initialStates = const <String, String>{},
    this.onStatesChanged,
    this.onAction,
    this.scoreByQuestionKey = const <String, double>{},
  });
}

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
final ValueNotifier<bool> hideGlobalMemoFloatingBanners =
    ValueNotifier<bool>(false);

/// 홈(수업 내용) 채점 모드 활성 시 true. FAB 숨김에 사용.
final ValueNotifier<bool> gradingModeActive = ValueNotifier<bool>(false);

/// 홈(수업 내용)에서 일괄 확인 FAB 노출 여부.
final ValueNotifier<bool> homeBatchConfirmFabVisible =
    ValueNotifier<bool>(false);

/// 홈(수업 내용)에서 현재 선택된 일괄 확인 대상 수.
final ValueNotifier<int> homeBatchConfirmPendingCount = ValueNotifier<int>(0);

/// 홈(수업 내용) 일괄 확인 실행 액션.
AsyncUiAction? homeBatchConfirmAction;

/// 전역 오른쪽 사이드시트 열림 방지 (성향 탭 등에서 사용)
final ValueNotifier<bool> blockRightSideSheetOpen = ValueNotifier<bool>(false);

/// 전역 오른쪽 사이드시트 엣지(호버/스와이프) 오픈 허용 여부.
final ValueNotifier<bool> rightSideSheetEdgeOpenEnabled =
    ValueNotifier<bool>(true);

/// 전역 오른쪽 사이드시트 열림 상태.
final ValueNotifier<bool> rightSideSheetOpen = ValueNotifier<bool>(false);

/// 우측 시트 테스트 채점 세션 데이터.
final ValueNotifier<RightSideSheetTestGradingSession?>
    rightSideSheetTestGradingSession =
    ValueNotifier<RightSideSheetTestGradingSession?>(null);

/// 전역 오른쪽 사이드시트 토글 액션.
AsyncUiAction? toggleRightSideSheetAction;

/// 전역 오른쪽 사이드시트 닫기 액션.
AsyncUiAction? closeRightSideSheetAction;

/// 교재 메뉴 카드 드래그 중인 payload.
/// - null: 드래그 비활성
/// - non-null: 학생 영역 드롭 대상 활성
final ValueNotifier<TextbookDragPayload?> activeTextbookDragPayload =
    ValueNotifier<TextbookDragPayload?>(null);

/// 교재 카드 드래그 피드백이 왼쪽 사이드시트 영역에 진입했는지 여부.
/// 리소스 화면의 피드백 UI 전환(축소/모양 변경)에 사용한다.
final ValueNotifier<bool> isTextbookDraggingOverLeftSideSheet =
    ValueNotifier<bool>(false);

/// 커리큘럼 행동 카드 드래그 중 payload.
/// - null: 드래그 비활성
/// - non-null: 학생 영역 드롭 대상 활성
final ValueNotifier<BehaviorCardDragPayload?> activeBehaviorCardDragPayload =
    ValueNotifier<BehaviorCardDragPayload?>(null);

/// 행동 카드 드래그 피드백이 왼쪽 사이드시트 영역에 진입했는지 여부.
final ValueNotifier<bool> isBehaviorDraggingOverLeftSideSheet =
    ValueNotifier<bool>(false);
