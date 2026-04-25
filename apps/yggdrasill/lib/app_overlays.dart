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
typedef RightSheetTestGradingEditResetAction = Future<bool> Function();

class RightSheetGradingSearchResult {
  final String studentId;
  final String homeworkItemId;
  final String assignmentCode;
  final String studentName;
  final String groupHomeworkTitle;
  final String homeworkTitle;
  final bool hasTextbookLink;
  final bool isTestHomework;
  final bool isSubmitted;

  const RightSheetGradingSearchResult({
    required this.studentId,
    required this.homeworkItemId,
    required this.assignmentCode,
    required this.studentName,
    required this.groupHomeworkTitle,
    required this.homeworkTitle,
    required this.hasTextbookLink,
    required this.isTestHomework,
    required this.isSubmitted,
  });
}

typedef RightSheetGradingSearchRunAction
    = Future<List<RightSheetGradingSearchResult>> Function(String query);
typedef RightSheetGradingSearchSuggestAction
    = Future<List<RightSheetGradingSearchResult>> Function(String query);
typedef RightSheetGradingSearchOpenAction = Future<void> Function(
  RightSheetGradingSearchResult result,
);

class RightSideSheetTestGradingSession {
  final String sessionId;
  final String title;
  final String studentName;
  final String groupHomeworkTitle;
  final String assignmentCode;
  final List<Map<String, dynamic>> gradingPages;
  final List<Map<String, String>> overlayEntries;
  final RightSheetTestGradingStates initialStates;
  final RightSheetTestGradingStatesChanged? onStatesChanged;
  final RightSheetTestGradingAction? onAction;
  final bool gradingLocked;
  final RightSheetTestGradingEditResetAction? onRequestEditReset;
  final Map<String, double> scoreByQuestionKey;

  const RightSideSheetTestGradingSession({
    required this.sessionId,
    required this.title,
    this.studentName = '',
    this.groupHomeworkTitle = '',
    this.assignmentCode = '',
    required this.gradingPages,
    this.overlayEntries = const <Map<String, String>>[],
    this.initialStates = const <String, String>{},
    this.onStatesChanged,
    this.onAction,
    this.gradingLocked = false,
    this.onRequestEditReset,
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

/// 답지바로가기 > 채점 탭이 현재 활성화(가시) 상태인지.
/// - `true` 이면 우측 시트의 너비를 확장해 채점 UI가 답답하지 않도록 한다.
/// - 다른 탭(교재 등) 으로 이동하거나 시트가 닫히면 `false` 로 되돌려야 한다.
final ValueNotifier<bool> rightSideSheetGradingTabActive =
    ValueNotifier<bool>(false);

/// 우측 시트 채점 검색 실행 액션.
RightSheetGradingSearchRunAction? rightSheetGradingSearchRunAction;

/// 우측 시트 채점 검색 추천 액션.
RightSheetGradingSearchSuggestAction? rightSheetGradingSearchSuggestAction;

/// 우측 시트 채점 검색 결과 오픈 액션.
RightSheetGradingSearchOpenAction? rightSheetGradingSearchOpenAction;

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
