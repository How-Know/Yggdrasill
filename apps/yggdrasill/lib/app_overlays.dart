import 'package:flutter/material.dart';
import 'models/behavior_card_drag_payload.dart';
import 'models/exam_preset_drag_payload.dart';
import 'models/textbook_drag_payload.dart';

typedef AsyncUiAction = Future<void> Function();
typedef RightSheetTestGradingStates = Map<String, String>;
typedef RightSheetTestGradingStatesChanged = void Function(
  RightSheetTestGradingStates states,
);
typedef RightSheetTestGradingAction = Future<void> Function(
  String action,
  RightSheetTestGradingStates states,
  RightSheetTestGradingStates correctionStates,
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
  final RightSheetTestGradingStates initialCorrectionStates;
  final Map<String, int> correctionAttemptNumbers;
  final String baselineAttemptId;
  final RightSheetTestGradingStates baselineStates;
  final bool wrongOnlyDefault;
  final RightSheetTestGradingStatesChanged? onStatesChanged;
  final RightSheetTestGradingAction? onAction;
  final bool gradingLocked;
  final RightSheetTestGradingEditResetAction? onRequestEditReset;
  final bool closeSheetOnAction;
  final Map<String, double> scoreByQuestionKey;
  final String answerPathRaw;
  final String solutionPathRaw;
  final String answerViewerCacheKey;

  const RightSideSheetTestGradingSession({
    required this.sessionId,
    required this.title,
    this.studentName = '',
    this.groupHomeworkTitle = '',
    this.assignmentCode = '',
    required this.gradingPages,
    this.overlayEntries = const <Map<String, String>>[],
    this.initialStates = const <String, String>{},
    this.initialCorrectionStates = const <String, String>{},
    this.correctionAttemptNumbers = const <String, int>{},
    this.baselineAttemptId = '',
    this.baselineStates = const <String, String>{},
    this.wrongOnlyDefault = false,
    this.onStatesChanged,
    this.onAction,
    this.gradingLocked = false,
    this.onRequestEditReset,
    this.closeSheetOnAction = true,
    this.scoreByQuestionKey = const <String, double>{},
    this.answerPathRaw = '',
    this.solutionPathRaw = '',
    this.answerViewerCacheKey = '',
  });
}

class RightSideSheetPdfPanelSession {
  final String sessionId;
  final String title;
  final String answerPath;
  final String solutionPath;
  final String cacheKey;
  final bool showSolution;
  final int focusPageNumber;
  final int focusRequestId;
  final List<int> focusRect1k;
  final List<Map<String, String>> overlayEntries;

  const RightSideSheetPdfPanelSession({
    required this.sessionId,
    required this.title,
    required this.answerPath,
    this.solutionPath = '',
    this.cacheKey = '',
    this.showSolution = false,
    this.focusPageNumber = 0,
    this.focusRequestId = 0,
    this.focusRect1k = const <int>[],
    this.overlayEntries = const <Map<String, String>>[],
  });

  RightSideSheetPdfPanelSession copyWith({
    String? sessionId,
    String? title,
    String? answerPath,
    String? solutionPath,
    String? cacheKey,
    bool? showSolution,
    int? focusPageNumber,
    int? focusRequestId,
    List<int>? focusRect1k,
    List<Map<String, String>>? overlayEntries,
  }) {
    return RightSideSheetPdfPanelSession(
      sessionId: sessionId ?? this.sessionId,
      title: title ?? this.title,
      answerPath: answerPath ?? this.answerPath,
      solutionPath: solutionPath ?? this.solutionPath,
      cacheKey: cacheKey ?? this.cacheKey,
      showSolution: showSolution ?? this.showSolution,
      focusPageNumber: focusPageNumber ?? this.focusPageNumber,
      focusRequestId: focusRequestId ?? this.focusRequestId,
      focusRect1k: focusRect1k ?? this.focusRect1k,
      overlayEntries: overlayEntries ?? this.overlayEntries,
    );
  }
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

/// 왼쪽 출석 슬라이드시트가 차지하는 너비(열림·닫힘 애니메이션 중간값 포함).
final ValueNotifier<double> leftSideSheetClipWidthNotifier =
    ValueNotifier<double>(0);

/// 홈(수업 내용) 채점 모드 활성 시 true. FAB 숨김에 사용.
final ValueNotifier<bool> gradingModeActive = ValueNotifier<bool>(false);

/// 홈(수업 내용)에서 일괄 확인 FAB 노출 여부.
final ValueNotifier<bool> homeBatchConfirmFabVisible =
    ValueNotifier<bool>(false);

/// 홈(수업 내용)에서 현재 선택된 일괄 확인 대상 수.
final ValueNotifier<int> homeBatchConfirmPendingCount = ValueNotifier<int>(0);

/// 홈(수업 내용) 일괄 확인 실행 액션.
AsyncUiAction? homeBatchConfirmAction;

/// 홈 채점 모드 — 채점 이력 다이얼로그 실행 액션.
AsyncUiAction? homeGradingHistoryAction;

/// 시험모드 — 하단 FAB 시험 버튼에서 시험일정 다이얼로그 실행.
AsyncUiAction? examScheduleAction;

/// 시험모드 — 시험일정 다이얼로그 상단 기출 버튼 실행.
AsyncUiAction? examPastPapersAction;

/// 시험모드 — 시험일정 다이얼로그 상단 설정 버튼 실행.
AsyncUiAction? examSettingsAction;

/// 왼쪽 출석 슬라이드시트·홈(수업 내용)이 함께 보는 기준일 (date-only, 로컬).
final ValueNotifier<DateTime> attendanceAnchorDateNotifier =
    ValueNotifier<DateTime>(
  DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  ),
);

DateTime attendanceDateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

bool isAttendanceAnchorToday(DateTime anchor) {
  final today = attendanceDateOnly(DateTime.now());
  return anchor.year == today.year &&
      anchor.month == today.month &&
      anchor.day == today.day;
}

void setAttendanceAnchorDate(DateTime date) {
  final normalized = attendanceDateOnly(date);
  final current = attendanceAnchorDateNotifier.value;
  if (current.year == normalized.year &&
      current.month == normalized.month &&
      current.day == normalized.day) {
    return;
  }
  attendanceAnchorDateNotifier.value = normalized;
}

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

/// 우측 채점 시트와 함께 왼쪽 작업 영역에 표시할 정답/해설 PDF 패널.
final ValueNotifier<RightSideSheetPdfPanelSession?>
    rightSideSheetPdfPanelSession =
    ValueNotifier<RightSideSheetPdfPanelSession?>(null);

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

/// 전역 오른쪽 사이드시트 채점 전용 열기 액션.
AsyncUiAction? openRightSideSheetGradingAction;

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

/// 시험(내신) 프리셋 카드 드래그 중 payload.
final ValueNotifier<ExamPresetDragPayload?> activeExamPresetDragPayload =
    ValueNotifier<ExamPresetDragPayload?>(null);

/// 시험 프리셋 카드 드래그 피드백이 왼쪽 사이드시트 영역에 진입했는지 여부.
final ValueNotifier<bool> isExamPresetDraggingOverLeftSideSheet =
    ValueNotifier<bool>(false);

/// 교재 탐색기 등 외부 화면 → 문제은행 탭으로 보낼 문항 핸드오프 요청.
/// - null: 대기 중 요청 없음
/// - non-null: 문제은행이 부트스트랩 시 소비하여 장바구니에 주입
class ProblemBankHandoffRequest {
  const ProblemBankHandoffRequest({required this.questionUids});

  final List<String> questionUids;
}

final ValueNotifier<ProblemBankHandoffRequest?> pendingProblemBankHandoff =
    ValueNotifier<ProblemBankHandoffRequest?>(null);

/// 메인 네비게이션(사이드바) 인덱스 전환 요청. (예: 외부 화면 → 학습 탭 3)
final ValueNotifier<int?> requestedMainNavIndex = ValueNotifier<int?>(null);

/// 학습 화면 내부 탭 전환 요청. (0: 커리큘럼, 1: 문제은행)
final ValueNotifier<int?> requestedLearningTab = ValueNotifier<int?>(null);

/// 외부 화면에서 선택한 문항 UID 목록을 문제은행 탭으로 보내 장바구니에 담는다.
/// 메인 탭(학습=3) → 학습 내부 탭(문제은행=1) 순으로 전환 요청을 발행한다.
void requestOpenQuestionsInProblemBank(List<String> questionUids) {
  final uids = questionUids
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
  if (uids.isEmpty) return;
  pendingProblemBankHandoff.value =
      ProblemBankHandoffRequest(questionUids: uids);
  requestedLearningTab.value = 1;
  requestedMainNavIndex.value = 3;
}
