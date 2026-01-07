import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/student_card.dart';
import 'timetable_grouped_student_panel.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../main.dart'; // rootScaffoldMessengerKey import
import '../../../models/student_time_block.dart';
import '../../../models/self_study_time_block.dart';
import '../../../widgets/app_snackbar.dart';
import '../../../models/class_info.dart';
import 'package:uuid/uuid.dart';
import '../views/makeup_view.dart';
import '../../../models/session_override.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../../../widgets/swipe_action_reveal.dart';
import '../../../services/consult_inquiry_demand_service.dart';
import '../../../services/consult_trial_lesson_service.dart';

class TimetableContentView extends StatefulWidget {
  final Widget timetableChild;
  final VoidCallback onRegisterPressed;
  final String splitButtonSelected;
  final bool isDropdownOpen;
  final ValueChanged<bool> onDropdownOpenChanged;
  final ValueChanged<String> onDropdownSelected;
  final int? selectedCellDayIndex;
  final DateTime? selectedCellStartTime;
  final DateTime? selectedDayDate; // 요일 클릭 시 선택된 날짜(주 기준)
  final DateTime viewDate; // 현재 보고 있는 날짜(주 이동 시에도 변경됨)
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo>)?
      onCellStudentsChanged;
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo>)?
      onCellSelfStudyStudentsChanged;
  final VoidCallback? clearSearch; // 추가: 외부에서 검색 리셋 요청
  final bool isSelectMode;
  final Set<String> selectedStudentIds;
  final void Function(String studentId, bool selected)? onStudentSelectChanged;
  final VoidCallback? onExitSelectMode; // 추가: 다중모드 종료 콜백
  final String? registrationModeType;
  final Set<String>? filteredStudentIds; // 추가: 필터링된 학생 ID 목록
  final Set<String>? filteredClassIds; // 추가: 필터링된 수업 ID 목록
  final void Function(ClassInfo classInfo)?
      onToggleClassFilter; // 수업카드 클릭 시 필터 토글
  final String? placeholderText; // 빈 셀 안내 문구 대체용
  final bool showRegisterControls;
  final Widget? header;
  /// 우측 학생 리스트에서 "선택(필터)"된 학생 id (카드 테두리 하이라이트 용)
  final String? highlightedStudentId;
  /// 우측 학생 카드 탭(토글) 콜백: 탭된 학생 id 전달
  final ValueChanged<String>? onStudentCardTap;
  // PERF: 셀 클릭 → 우측 리스트 첫 프레임까지 측정용 (기본 비활성)
  final bool enableCellRenderPerfTrace;
  final int cellRenderPerfToken;
  final int cellRenderPerfStartUs;
  final void Function(int token, int endUs)? onCellRenderPerfFrame;

  const TimetableContentView({
    Key? key,
    required this.timetableChild,
    required this.onRegisterPressed,
    required this.splitButtonSelected,
    required this.isDropdownOpen,
    required this.onDropdownOpenChanged,
    required this.onDropdownSelected,
    this.selectedCellDayIndex,
    this.selectedCellStartTime,
    this.selectedDayDate,
    required this.viewDate,
    this.onCellStudentsChanged,
    this.onCellSelfStudyStudentsChanged,
    this.clearSearch, // 추가
    this.isSelectMode = false,
    this.selectedStudentIds = const {},
    this.onStudentSelectChanged,
    this.onExitSelectMode,
    this.registrationModeType,
    this.filteredStudentIds, // 추가
    this.filteredClassIds,
    this.onToggleClassFilter,
    this.placeholderText,
    this.showRegisterControls = true,
    this.header,
    this.highlightedStudentId,
    this.onStudentCardTap,
    this.enableCellRenderPerfTrace = false,
    this.cellRenderPerfToken = 0,
    this.cellRenderPerfStartUs = 0,
    this.onCellRenderPerfFrame,
  }) : super(key: key);

  @override
  State<TimetableContentView> createState() => TimetableContentViewState();
}

class TimetableContentViewState extends State<TimetableContentView> {
  // 메모 오버레이가 사용할 전역 키 등을 두려면 이곳에 배치 가능 (현재 오버레이는 TimetableScreen에서 처리)
  // === 우측 학생 패널(셀/요일/검색) 헤더 위치 통일용 상수 ===
  // - 헤더가 "컨트롤(등록/검색) 바로 아래"에서 시작할 때의 여백(=세 패널 공통 기준)
  // - 눈으로 보면서 미세 조정하고 싶으면 이 값만 바꾸면 됨.
  //   (주차 위젯과 라인이 살짝 안 맞으면 1~5px 정도만 조정)
  static const double _kStudentPanelHeaderTopMargin = 22.0; // +3px fine-tune
  static const double _kStudentPanelHeaderBottomMargin = 10.0;
  static const double _kStudentPanelPaddingTop = 8.0; // 학생 패널 Padding(top)
  // 요일 선택(오버레이) 헤더만 미세 조정: 음수면 위로(상단 여백 감소), 양수면 아래로
  static const double _kDaySelectedOverlayTopFineTune = -44.0;

  // ✅ 컨트롤(등록/검색 Row)의 "실제 렌더링된 높이"를 측정해서
  // 요일 선택 오버레이의 시작 위치를 픽셀 단위로 맞추기 위한 키/상태
  final GlobalKey _studentControlsMeasureKey = GlobalKey();
  double _studentControlsMeasuredHeight = 0.0;
  bool _studentControlsMeasureScheduled = false;

  final GlobalKey _dropdownButtonKey = GlobalKey();
  OverlayEntry? _dropdownOverlay;
  bool _showDeleteZone = false;
  Future<void> _showMakeupListDialog() async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF1F1F1F),
          insetPadding: const EdgeInsets.fromLTRB(42, 42, 42, 32),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            width: 1104, // 920 * 1.2
            height: 800, // 640 * 1.2
            child: const MakeupView(),
          ),
        );
      },
    );
  }

  String _searchQuery = '';
  List<StudentWithInfo> _searchResults = [];
  final TextEditingController _searchController =
      ImeAwareTextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _isSearchExpanded = false;
  String? _cachedSearchGroupedKey;
  Widget? _cachedSearchGroupedWidget;
  String? _cachedCellPanelKey;
  Widget? _cachedCellPanelWidget;
  // 보강(Replace) 원본 블라인드 키 캐시: studentId -> keys
  // (셀 클릭 시 블록마다 반복 계산되는 것을 방지)
  final Map<String, Set<String>> _makeupOriginalBlindKeysCache = {};
  int _lastPerfReportedToken = 0;
  bool isClassRegisterMode = false;
  // 변경 감지 리스너: 드래그로 수업 등록/삭제 시 바로 UI를 새로 그리기 위함
  late final VoidCallback _revListener;

  bool _isBlockAllowed(StudentTimeBlock b) {
    final cids = widget.filteredClassIds;
    if (cids == null || cids.isEmpty) return true;
    final sid = b.sessionTypeId;
    if (sid == null || sid.isEmpty) {
      return cids.contains('__default_class__');
    }
    return cids.contains(sid);
  }

  Set<String> _studentFilterSet() {
    return widget.filteredStudentIds?.toSet() ??
        DataManager.instance.students.map((s) => s.student.id).toSet();
  }

  int _unfilteredDefaultClassCount() {
    return DataManager.instance.studentTimeBlocks
        .where((b) => b.sessionTypeId == null)
        .map((b) => b.studentId)
        .toSet()
        .length;
  }

  int _countStudentsForClass(String? classId) {
    final students = _studentFilterSet();
    final blocks = DataManager.instance.studentTimeBlocks
        .where((b) {
          if (!_isBlockAllowed(b)) return false;
          if (!students.contains(b.studentId)) return false;
          if (classId == null) {
            return b.sessionTypeId == null;
          }
          return b.sessionTypeId == classId;
        })
        .map((b) => b.studentId)
        .toSet();
    return blocks.length;
  }

  String _weekdayLabel(int dayIdx) {
    const labels = ['월', '화', '수', '목', '금', '토', '일'];
    return labels[dayIdx.clamp(0, 6)];
  }

  @override
  void initState() {
    super.initState();
    DataManager.instance.loadClasses();
    // 수업/시간 블록 변경 시 검색 결과/캐시를 즉시 무효화하고 재빌드
    _revListener = () {
      setState(() {
        _cachedSearchGroupedKey = null;
        _cachedSearchGroupedWidget = null;
        _cachedCellPanelKey = null;
        _cachedCellPanelWidget = null;
        _makeupOriginalBlindKeysCache.clear();
      });
    };
    DataManager.instance.studentTimeBlocksRevision.addListener(_revListener);
    DataManager.instance.classAssignmentsRevision.addListener(_revListener);
    DataManager.instance.classesRevision.addListener(_revListener);
    // 보강/추가수업/희망수업/시범수업 카드도 우측 리스트에 즉시 반영되도록 리빌드 트리거 추가
    DataManager.instance.sessionOverridesNotifier.addListener(_revListener);
    ConsultInquiryDemandService.instance.slotsNotifier.addListener(_revListener);
    ConsultTrialLessonService.instance.slotsNotifier.addListener(_revListener);
    // 🧹 앱 시작 시 삭제된 수업의 sessionTypeId를 가진 블록들 정리
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // ✅ classes 로드가 완료되기 전에 cleanup이 실행되면,
      // 정상 classId(session_type_id)를 "고아"로 오판해 time block을 닫아버리는(end_date 입력) 문제가 발생할 수 있다.
      // → 여기서는 classes 로드를 다시 보장하고, classes가 비어있으면 cleanup을 스킵한다(안전 우선).
      try {
        await DataManager.instance.loadClasses();
      } catch (_) {}
      if (DataManager.instance.classes.isEmpty) {
        // 네트워크 지연/일시 실패/초기 빈 상태에서의 오판 방지
        return;
      }
      await cleanupOrphanedSessionTypeIds();
    });
    // 임시 진단: 특정 학생 블록 payload 덤프 (기본 비활성)
    const bool _kTimetableDebugDump = false;
    if (_kTimetableDebugDump) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        DataManager.instance.debugDumpStudentBlocks(
          dayIdx: 5,
          startHour: 16,
          startMinute: 0,
          studentId: 'fce51628-cc03-416f-9ee4-02d68cc3a10c',
        );
      });
    }
  }

  @override
  void dispose() {
    DataManager.instance.studentTimeBlocksRevision.removeListener(_revListener);
    DataManager.instance.classAssignmentsRevision.removeListener(_revListener);
    DataManager.instance.classesRevision.removeListener(_revListener);
    DataManager.instance.sessionOverridesNotifier.removeListener(_revListener);
    ConsultInquiryDemandService.instance.slotsNotifier.removeListener(_revListener);
    ConsultTrialLessonService.instance.slotsNotifier.removeListener(_revListener);
    // dispose 중에는 부모 setState를 유발하지 않도록 notify=false
    _removeDropdownMenu(false);
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _showDropdownMenu() {
    final RenderBox buttonRenderBox =
        _dropdownButtonKey.currentContext!.findRenderObject() as RenderBox;
    final Offset buttonPosition = buttonRenderBox.localToGlobal(Offset.zero);
    final Size buttonSize = buttonRenderBox.size;
    _dropdownOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: buttonPosition.dx,
        top: buttonPosition.dy + buttonSize.height + 4,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 140,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: Color(0xFF2A2A2A), width: 1), // 윤곽선이 티 안 나게
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ...['학생', '수업'].map((label) => _DropdownMenuHoverItem(
                      label: label,
                      selected: widget.splitButtonSelected == label,
                      onTap: () {
                        widget.onDropdownSelected(label);
                        _removeDropdownMenu();
                      },
                    )),
              ],
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_dropdownOverlay!);
  }

  void _removeDropdownMenu([bool notify = true]) {
    _dropdownOverlay?.remove();
    _dropdownOverlay = null;
    if (notify) {
      widget.onDropdownOpenChanged(false);
    }
  }

  // 외부에서 수업 등록 다이얼로그를 열 수 있도록 공개 메서드
  void openClassRegistrationDialog() {
    _showClassRegistrationDialog();
  }

  // 외부에서 검색 상태를 리셋할 수 있도록 public 메서드 제공
  void clearSearch() {
    if (_searchQuery.isNotEmpty || _searchResults.isNotEmpty) {
      setState(() {
        _searchQuery = '';
        _searchResults = [];
        _searchController.clear();
      });
    }
  }

  void _scheduleStudentControlsMeasure() {
    if (_studentControlsMeasureScheduled) return;
    _studentControlsMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _studentControlsMeasureScheduled = false;
      if (!mounted) return;
      final ctx = _studentControlsMeasureKey.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      final h = box?.size.height;
      if (h == null) return;
      if ((h - _studentControlsMeasuredHeight).abs() <= 0.5) return;
      setState(() => _studentControlsMeasuredHeight = h);
    });
  }

  // 시간 미선택 시 기본 스켈레톤
  Widget _buildTimeIdleSkeleton() {
    const levelBarColor = Color(0xFF223131);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 48,
          width: double.infinity,
          margin: const EdgeInsets.only(
            top: _kStudentPanelHeaderTopMargin,
            bottom: _kStudentPanelHeaderBottomMargin,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: levelBarColor,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: const Text(
            '시간',
            style: TextStyle(
                color: Color(0xFFEAF2F2),
                fontSize: 21,
                fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(15, 10, 12, 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1112),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: levelBarColor, width: 1),
            ),
            alignment: Alignment.center,
            child: const Text(
              '시간을 선택하면 상세 정보가 여기에 표시됩니다.',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 15,
                  fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  // 요일 선택 시 우측 수업 리스트 위로 덮어 그리는 오버레이 패널
  Widget _buildDaySelectedOverlayPanel() {
    final int dayIdx = widget.selectedCellDayIndex!; // 0=월
    final DateTime dayDate = widget.selectedDayDate!;
    final DateTime refDate = DateTime(dayDate.year, dayDate.month, dayDate.day);

    return ValueListenableBuilder<int>(
      valueListenable: DataManager.instance.studentTimeBlocksRevision,
      builder: (context, _, __) {
        // 해당 요일의 활성 블록 중 number가 없거나 1인 학생만 수집
        final weekStart = _weekMonday(refDate);
        final weekBlocks = DataManager.instance.getStudentTimeBlocksForWeek(weekStart);
        final blocksOfDay = weekBlocks.where((b) {
          if (b.dayIndex != dayIdx) return false;
          final start =
              DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
          final end = b.endDate != null
              ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
              : null;
          final active = !start.isAfter(refDate) &&
              (end == null || !end.isBefore(refDate));
          if (!active) return false;
          return (b.number == null || b.number == 1);
        }).toList();

        // 셀렉터: 필터가 있으면 필터 학생만
        final allStudents = widget.filteredStudentIds == null
            ? DataManager.instance.students
            : DataManager.instance.students
                .where((s) => widget.filteredStudentIds!.contains(s.student.id))
                .toList();
        // ✅ 성능: blocksOfDay(블록)마다 allStudents.firstWhere(O(N))를 하면
        // O(블록수 * 학생수)로 1~2초씩 멈출 수 있다. id→학생 맵으로 O(1) 조회.
        final Map<String, StudentWithInfo> studentById = {
          for (final s in allStudents) s.student.id: s,
        };

        // 그룹핑: key = 시간표상 수업 시작시간(HH:mm)
        final Map<String, List<StudentWithInfo>> groups = {};
        final Map<String, Set<String>> seenIdsByTime = {};
        for (final b in blocksOfDay) {
          final student = studentById[b.studentId];
          if (student == null) continue;
          if (student.student.id.isEmpty) continue;
          final key =
              '${b.startHour.toString().padLeft(2, '0')}:${b.startMinute.toString().padLeft(2, '0')}';
          groups.putIfAbsent(key, () => []);
          final seen = seenIdsByTime.putIfAbsent(key, () => <String>{});
          if (seen.add(student.student.id)) groups[key]!.add(student);
        }

        // 키 정렬: HH:mm 오름차순
        int toMinutes(String hhmm) {
          final parts = hhmm.split(':');
          final h = int.tryParse(parts[0]) ?? 0;
          final m = int.tryParse(parts[1]) ?? 0;
          return h * 60 + m;
        }

        // 보강/추가/희망/시범 카드도 요일 선택 리스트에 함께 노출
        final specialByTime = _specialCardsByTimeForDay(dayDate: dayDate, dayIdx: dayIdx);
        final sortedKeys = <String>{
          ...groups.keys,
          ...specialByTime.keys,
        }.toList()
          ..sort((a, b) => toMinutes(a).compareTo(toMinutes(b)));
        final totalCount = groups.values.fold<int>(0, (p, c) => p + c.length);

        return LayoutBuilder(
          builder: (context, constraints) {
            // 상단 라벨은 고정, 아래 학생 리스트만 스크롤 + 여유 공간으로 덮도록 변경
            final double visibleHeight =
                constraints.maxHeight.clamp(180.0, double.infinity);
            const double extraScrollSpace = 120.0;
            final double headerHeight = 48 + 10; // 컨테이너 높이 + bottom margin
            final double bodyMinHeight =
                (visibleHeight - headerHeight).clamp(120.0, double.infinity);

            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: double.infinity,
                height: visibleHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 고정 상단 라벨
                    Container(
                      height: 48,
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      decoration: BoxDecoration(
                        color: const Color(0xFF223131),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          Text(
                            '${dayDate.month}/${dayDate.day} ${_weekdayLabel(dayIdx)}',
                            style: const TextStyle(
                                color: Color(0xFFEAF2F2),
                                fontSize: 21,
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '총 $totalCount명',
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 15,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    // 스크롤 가능 본문 (여유 공간 추가로 아래 덮기)
                    SizedBox(
                      height: bodyMinHeight,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(15, 10, 12, 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B1112),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: const Color(0xFF223131), width: 1),
                        ),
                        child: Scrollbar(
                          child: SingleChildScrollView(
                            padding:
                                const EdgeInsets.only(bottom: extraScrollSpace),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ...sortedKeys.map((k) {
                                  final list = List<StudentWithInfo>.from(groups[k] ?? const <StudentWithInfo>[])
                                    ..sort((a, b) => a.student.name.compareTo(b.student.name));
                                  final extras = specialByTime[k] ?? const <Widget>[];
                                  final parts = k.split(':');
                                  final int hour = int.tryParse(parts[0]) ?? 0;
                                  final int minute =
                                      int.tryParse(parts[1]) ?? 0;
                                  return Padding(
                                    padding:
                                        const EdgeInsets.only(bottom: 16.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              k,
                                              style: const TextStyle(
                                                  color: Color(0xFFEAF2F2),
                                                  fontSize: 21,
                                                  fontWeight: FontWeight.w700),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(left: 14),
                                          child: Wrap(
                                            spacing: 6.4,
                                            runSpacing: 6.4,
                                            children: [
                                              ...extras,
                                              ...list.map((info) => _buildDraggableStudentCard(
                                                    info,
                                                    dayIndex: dayIdx,
                                                    startTime: DateTime(
                                                        dayDate.year,
                                                        dayDate.month,
                                                        dayDate.day,
                                                        hour,
                                                        minute),
                                                    cellStudents: list,
                                                  )),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                                if (sortedKeys.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.all(4.0),
                                    child: Text(
                                        widget.placeholderText ??
                                            '해당 요일에 등록된 항목이 없습니다.',
                                        style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 16)),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  double _daySelectedOverlayTopPadding(BuildContext context) {
    // ✅ 셀 선택/검색 패널과 동일하게:
    // (학생패널 top padding) + (컨트롤 "실측" 높이) + (공통 헤더 top margin)
    //
    // 컨트롤 높이가 아직 측정 전(0)인 첫 프레임에는 기존 추정치를 fallback으로 사용
    final measured = _studentControlsMeasuredHeight;
    if (measured > 0) {
      return (_kStudentPanelPaddingTop +
              measured +
              _kStudentPanelHeaderTopMargin +
              _kDaySelectedOverlayTopFineTune)
          .clamp(0.0, double.infinity);
    }

    final screenW = MediaQuery.of(context).size.width;
    final isNarrow = screenW <= 1600;
    final double estimatedControlsHeight;
    if (isNarrow) {
      final double t = ((screenW - 1200) / 400).clamp(0.0, 1.0);
      estimatedControlsHeight = 30 + (38 - 30) * t;
    } else {
      estimatedControlsHeight = 44;
    }
    return (_kStudentPanelPaddingTop +
            estimatedControlsHeight +
            _kStudentPanelHeaderTopMargin +
            _kDaySelectedOverlayTopFineTune)
        .clamp(0.0, double.infinity);
  }

  // timetable_content_view.dart에 아래 메서드 추가(클래스 내부)
  void updateCellStudentsAfterMove(int dayIdx, DateTime startTime) {
    final updatedBlocks = DataManager.instance.studentTimeBlocks
        .where((b) =>
            b.dayIndex == dayIdx &&
            b.startHour == startTime.hour &&
            b.startMinute == startTime.minute)
        .toList();
    final updatedStudents = DataManager.instance.students;
    final updatedCellStudents = updatedBlocks
        .map((b) => updatedStudents.firstWhere(
              (s) => s.student.id == b.studentId,
              orElse: () => StudentWithInfo(
                student: Student(
                    id: '',
                    name: '',
                    school: '',
                    grade: 0,
                    educationLevel: EducationLevel.elementary),
                basicInfo: StudentBasicInfo(studentId: ''),
              ),
            ))
        .toList();
    if (widget.onCellStudentsChanged != null) {
      widget.onCellStudentsChanged!(dayIdx, startTime, updatedCellStudents);
    }
  }

  // 다중 이동/수정 후
  void exitSelectModeIfNeeded() {
    if (widget.onExitSelectMode != null) {
      widget.onExitSelectMode!();
    }
  }

  // 등록모드에서 수업횟수만큼 등록이 끝나면 자동 종료
  void checkAndExitSelectModeAfterRegistration(int remaining) {
    if (remaining <= 0 && widget.onExitSelectMode != null) {
      widget.onExitSelectMode!();
    }
  }

  void _showClassRegistrationDialog(
      {ClassInfo? editTarget, int? editIndex}) async {
    final result = await showDialog<ClassInfo>(
      context: context,
      builder: (context) => _ClassRegistrationDialog(editTarget: editTarget),
    );
    if (result != null) {
      if (editTarget != null && editIndex != null) {
        // 수정: sessionTypeId 일괄 변경
        await updateSessionTypeIdForClass(editTarget.id, result.id);
        await DataManager.instance.updateClass(result);
      } else {
        await DataManager.instance.addClass(result);
      }
    }
  }

  void _onReorder(int oldIndex, int newIndex) async {
    // print('[DEBUG][_onReorder] 시작: oldIndex=$oldIndex, newIndex=$newIndex');
    final classes =
        List<ClassInfo>.from(DataManager.instance.classesNotifier.value);
    // print('[DEBUG][_onReorder] 원본 순서: ${classes.map((c) => c.name).toList()}');

    if (oldIndex < newIndex) newIndex--;
    final item = classes.removeAt(oldIndex);
    classes.insert(newIndex, item);
    // print('[DEBUG][_onReorder] 변경 후 순서: ${classes.map((c) => c.name).toList()}');

    // 즉시 UI 반영
    DataManager.instance.classesNotifier.value = List.unmodifiable(classes);

    // 저장 시 실패하면 이전 상태 복구
    try {
      await DataManager.instance
          .saveClassesOrder(classes, skipNotifierUpdate: false);
    } catch (error) {
      // print('[ERROR][_onReorder] DB 저장 실패: $error');
      await DataManager.instance.loadClasses();
    }
  }

  void _deleteClass(int idx) async {
    final classes = DataManager.instance.classesNotifier.value;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('수업 삭제', style: TextStyle(color: Colors.white)),
        content: const Text('정말로 이 수업을 삭제하시겠습니까?',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final classId = classes[idx].id;
      // ✅ UI는 즉시 반영 (백엔드 작업은 백그라운드에서)
      DataManager.instance.removeClassOptimistic(classId);
      if (mounted) {
        showAppSnackBar(context, '삭제 처리중...', useRoot: true);
      }
      unawaited(() async {
        try {
          await clearSessionTypeIdForClass(classId);
          await DataManager.instance.deleteClass(classId);
          if (mounted) {
            showAppSnackBar(context, '삭제되었습니다.', useRoot: true);
          }
        } catch (e) {
          // 실패 시 서버/로컬에서 다시 로드해서 상태 복구
          unawaited(DataManager.instance.loadStudentTimeBlocks());
          unawaited(DataManager.instance.loadClasses());
          if (mounted) {
            showAppSnackBar(context, '삭제 실패: $e', useRoot: true);
          }
        }
      }());
    }
  }

  @override
  Widget build(BuildContext context) {
    // 요일 오버레이 시작 위치를 맞추기 위해, 컨트롤 Row 높이를 매 프레임 실측
    _scheduleStudentControlsMeasure();
    return Row(
      children: [
        const SizedBox(width: 30),
        Expanded(
          flex: 4,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SizedBox(
                height: constraints.maxHeight,
                child: Column(
                  children: [
                    if (widget.header != null) widget.header!,
                    Expanded(child: widget.timetableChild),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 32),
        Expanded(
          flex: 1,
          child: Stack(
            children: [
              Column(
                children: [
                  // 학생 영역
                  Expanded(
                    flex: 1, // 1:1 비율로 수정
                    child: Padding(
                      padding: const EdgeInsets.only(
                          left: 4,
                          right: 8,
                          top: _kStudentPanelPaddingTop,
                          bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                              key: _studentControlsMeasureKey,
                              child: Builder(builder: (context) {
                                final screenW =
                                    MediaQuery.of(context).size.width;
                                final isNarrow = screenW <= 1600;
                                if (isNarrow) {
                                  // 좁은 화면: 좌우 1:1 영역으로 분할 + 화면 너비에 비례한 크기 조정
                                  final double t =
                                      ((screenW - 1200) / 400).clamp(0.0, 1.0);
                                  final double h = 30 +
                                      (38 - 30) *
                                          t; // 1200px에서 30 → 1600px에서 38
                                  final double regW =
                                      80 + (96 - 80) * t; // 등록 버튼 너비 80~96
                                  final double dropW =
                                      30 + (38 - 30) * t; // 드롭다운 30~38
                                  final double dividerLineH =
                                      16 + (22 - 16) * t; // 구분선 내부 라인 16~22
                                  final double searchW =
                                      120 + (160 - 120) * t; // 검색바 너비 120~160
                                  return Row(
                                    children: [
                                      Expanded(
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.start,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          mainAxisSize: MainAxisSize.max,
                                          children: [
                                            if (widget
                                                .showRegisterControls) ...[
                                              SizedBox(
                                                width: regW,
                                                height: h,
                                                child: Material(
                                                  color:
                                                      const Color(0xFF1976D2),
                                                  borderRadius:
                                                      const BorderRadius.only(
                                                    topLeft:
                                                        Radius.circular(32),
                                                    bottomLeft:
                                                        Radius.circular(32),
                                                    topRight:
                                                        Radius.circular(6),
                                                    bottomRight:
                                                        Radius.circular(6),
                                                  ),
                                                  child: InkWell(
                                                    borderRadius:
                                                        const BorderRadius.only(
                                                      topLeft:
                                                          Radius.circular(32),
                                                      bottomLeft:
                                                          Radius.circular(32),
                                                      topRight:
                                                          Radius.circular(6),
                                                      bottomRight:
                                                          Radius.circular(6),
                                                    ),
                                                    onTap: widget
                                                        .onRegisterPressed,
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .center,
                                                      mainAxisSize:
                                                          MainAxisSize.max,
                                                      children: const [
                                                        Icon(Icons.add,
                                                            color: Colors.white,
                                                            size: 16),
                                                        SizedBox(width: 6),
                                                        Text('등록',
                                                            style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 14,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold)),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              Container(
                                                height: h,
                                                width: 3.0,
                                                color: Colors.transparent,
                                                child: Center(
                                                  child: Container(
                                                    width: 2,
                                                    height: dividerLineH,
                                                    color: Colors.white
                                                        .withOpacity(0.1),
                                                  ),
                                                ),
                                              ),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 2.5),
                                                child: GestureDetector(
                                                  key: _dropdownButtonKey,
                                                  onTap: () {
                                                    if (_dropdownOverlay ==
                                                        null) {
                                                      widget
                                                          .onDropdownOpenChanged(
                                                              true);
                                                      _showDropdownMenu();
                                                    } else {
                                                      _removeDropdownMenu();
                                                    }
                                                  },
                                                  child: AnimatedContainer(
                                                    duration: const Duration(
                                                        milliseconds: 350),
                                                    width: dropW,
                                                    height: h,
                                                    decoration: ShapeDecoration(
                                                      color: const Color(
                                                          0xFF1976D2),
                                                      shape:
                                                          RoundedRectangleBorder(
                                                        borderRadius: widget
                                                                .isDropdownOpen
                                                            ? BorderRadius
                                                                .circular(50)
                                                            : const BorderRadius
                                                                .only(
                                                                topLeft: Radius
                                                                    .circular(
                                                                        6),
                                                                bottomLeft: Radius
                                                                    .circular(
                                                                        6),
                                                                topRight: Radius
                                                                    .circular(
                                                                        32),
                                                                bottomRight:
                                                                    Radius
                                                                        .circular(
                                                                            32),
                                                              ),
                                                      ),
                                                    ),
                                                    child: Center(
                                                      child: AnimatedRotation(
                                                        turns: widget
                                                                .isDropdownOpen
                                                            ? 0.5
                                                            : 0.0,
                                                        duration:
                                                            const Duration(
                                                                milliseconds:
                                                                    350),
                                                        curve: Curves.easeInOut,
                                                        child: const Icon(
                                                          Icons
                                                              .keyboard_arrow_down,
                                                          color: Colors.white,
                                                          size: 20,
                                                          key:
                                                              ValueKey('arrow'),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                            if (widget
                                                .showRegisterControls) ...[
                                              // 수업 등록 버튼 (협소 화면 추가 축소)
                                              SizedBox(
                                                width: regW,
                                                height: h,
                                                child: Material(
                                                  color:
                                                      const Color(0xFF1976D2),
                                                  borderRadius:
                                                      const BorderRadius.only(
                                                    topLeft:
                                                        Radius.circular(32),
                                                    bottomLeft:
                                                        Radius.circular(32),
                                                    topRight:
                                                        Radius.circular(6),
                                                    bottomRight:
                                                        Radius.circular(6),
                                                  ),
                                                  child: InkWell(
                                                    borderRadius:
                                                        const BorderRadius.only(
                                                      topLeft:
                                                          Radius.circular(32),
                                                      bottomLeft:
                                                          Radius.circular(32),
                                                      topRight:
                                                          Radius.circular(6),
                                                      bottomRight:
                                                          Radius.circular(6),
                                                    ),
                                                    onTap: widget
                                                        .onRegisterPressed,
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .center,
                                                      mainAxisSize:
                                                          MainAxisSize.max,
                                                      children: const [
                                                        Icon(Icons.add,
                                                            color: Colors.white,
                                                            size: 16),
                                                        SizedBox(width: 6),
                                                        Text('등록',
                                                            style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 14,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold)),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              // 구분선
                                              Container(
                                                height: h,
                                                width: 3.0,
                                                color: Colors.transparent,
                                                child: Center(
                                                  child: Container(
                                                    width: 2,
                                                    height: dividerLineH,
                                                    color: Colors.white
                                                        .withOpacity(0.1),
                                                  ),
                                                ),
                                              ),
                                              // 드롭다운 버튼
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 2.5),
                                                child: GestureDetector(
                                                  key: _dropdownButtonKey,
                                                  onTap: () {
                                                    if (_dropdownOverlay ==
                                                        null) {
                                                      widget
                                                          .onDropdownOpenChanged(
                                                              true);
                                                      _showDropdownMenu();
                                                    } else {
                                                      _removeDropdownMenu();
                                                    }
                                                  },
                                                  child: AnimatedContainer(
                                                    duration: const Duration(
                                                        milliseconds: 350),
                                                    width: dropW,
                                                    height: h,
                                                    decoration: ShapeDecoration(
                                                      color: const Color(
                                                          0xFF1976D2),
                                                      shape:
                                                          RoundedRectangleBorder(
                                                        borderRadius: widget
                                                                .isDropdownOpen
                                                            ? BorderRadius
                                                                .circular(50)
                                                            : const BorderRadius
                                                                .only(
                                                                topLeft: Radius
                                                                    .circular(
                                                                        6),
                                                                bottomLeft: Radius
                                                                    .circular(
                                                                        6),
                                                                topRight: Radius
                                                                    .circular(
                                                                        32),
                                                                bottomRight:
                                                                    Radius
                                                                        .circular(
                                                                            32),
                                                              ),
                                                      ),
                                                    ),
                                                    child: Center(
                                                      child: AnimatedRotation(
                                                        turns: widget
                                                                .isDropdownOpen
                                                            ? 0.5
                                                            : 0.0,
                                                        duration:
                                                            const Duration(
                                                                milliseconds:
                                                                    350),
                                                        curve: Curves.easeInOut,
                                                        child: const Icon(
                                                          Icons
                                                              .keyboard_arrow_down,
                                                          color: Colors.white,
                                                          size: 20,
                                                          key:
                                                              ValueKey('arrow'),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                            // 보강 버튼 (아이콘만, 등록 버튼 색상과 동일)
                                            SizedBox(
                                              height: h,
                                              child: Material(
                                                color: const Color(0xFF1976D2),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: InkWell(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  onTap: () {},
                                                  child: const Padding(
                                                    padding:
                                                        EdgeInsets.symmetric(
                                                            horizontal: 12.0),
                                                    child: Icon(
                                                        Icons
                                                            .event_repeat_rounded,
                                                        color: Colors.white,
                                                        size: 20),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            if (widget
                                                .showRegisterControls) ...[
                                              const SizedBox(width: 8),
                                              AnimatedContainer(
                                                duration: const Duration(
                                                    milliseconds: 250),
                                                height: h,
                                                width: _isSearchExpanded
                                                    ? searchW
                                                    : h,
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF2A2A2A),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          h / 2),
                                                  border: Border.all(
                                                      color: Colors.white
                                                          .withOpacity(0.2)),
                                                ),
                                                child: Row(
                                                  mainAxisAlignment:
                                                      _isSearchExpanded
                                                          ? MainAxisAlignment
                                                              .start
                                                          : MainAxisAlignment
                                                              .center,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.center,
                                                  children: [
                                                    IconButton(
                                                      visualDensity:
                                                          const VisualDensity(
                                                              horizontal: -4,
                                                              vertical: -4),
                                                      padding: _isSearchExpanded
                                                          ? const EdgeInsets
                                                              .only(left: 8)
                                                          : EdgeInsets.zero,
                                                      constraints:
                                                          const BoxConstraints(
                                                              minWidth: 32,
                                                              minHeight: 32),
                                                      icon: const Icon(
                                                          Icons.search,
                                                          color: Colors.white70,
                                                          size: 20),
                                                      onPressed: () {
                                                        setState(() {
                                                          _isSearchExpanded =
                                                              !_isSearchExpanded;
                                                        });
                                                        if (_isSearchExpanded) {
                                                          Future.delayed(
                                                              const Duration(
                                                                  milliseconds:
                                                                      50), () {
                                                            _searchFocusNode
                                                                .requestFocus();
                                                          });
                                                        } else {
                                                          setState(() {
                                                            _searchController
                                                                .clear();
                                                            _searchQuery = '';
                                                          });
                                                          FocusScope.of(context)
                                                              .unfocus();
                                                        }
                                                      },
                                                    ),
                                                    if (_isSearchExpanded)
                                                      const SizedBox(width: 10),
                                                    if (_isSearchExpanded)
                                                      SizedBox(
                                                        width: searchW - 50,
                                                        child: TextField(
                                                          controller:
                                                              _searchController,
                                                          focusNode:
                                                              _searchFocusNode,
                                                          style:
                                                              const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize:
                                                                      16.5),
                                                          decoration:
                                                              const InputDecoration(
                                                            hintText: '검색',
                                                            hintStyle: TextStyle(
                                                                color: Colors
                                                                    .white54,
                                                                fontSize: 16.5),
                                                            border: InputBorder
                                                                .none,
                                                            isDense: true,
                                                            contentPadding:
                                                                EdgeInsets.zero,
                                                          ),
                                                          onChanged:
                                                              _onSearchChanged,
                                                        ),
                                                      ),
                                                    if (_isSearchExpanded &&
                                                        _searchQuery.isNotEmpty)
                                                      IconButton(
                                                        visualDensity:
                                                            const VisualDensity(
                                                                horizontal: -4,
                                                                vertical: -4),
                                                        padding:
                                                            const EdgeInsets
                                                                .only(
                                                                right: 10),
                                                        constraints:
                                                            const BoxConstraints(
                                                                minWidth: 32,
                                                                minHeight: 32),
                                                        tooltip: '지우기',
                                                        icon: const Icon(
                                                            Icons.clear,
                                                            color:
                                                                Colors.white70,
                                                            size: 16),
                                                        onPressed: () {
                                                          setState(() {
                                                            _searchController
                                                                .clear();
                                                            _searchQuery = '';
                                                          });
                                                          FocusScope.of(context)
                                                              .requestFocus(
                                                                  _searchFocusNode);
                                                        },
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      // 우측 영역 제거: 모든 버튼을 왼쪽 정렬
                                    ],
                                  );
                                }
                                // 넓은 화면: 기존 레이아웃 유지
                                return Row(
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    if (widget.showRegisterControls) ...[
                                      SizedBox(
                                        width: 113,
                                        height: 44,
                                        child: Material(
                                          color: const Color(0xFF1976D2),
                                          borderRadius: const BorderRadius.only(
                                            topLeft: Radius.circular(32),
                                            bottomLeft: Radius.circular(32),
                                            topRight: Radius.circular(6),
                                            bottomRight: Radius.circular(6),
                                          ),
                                          child: InkWell(
                                            borderRadius:
                                                const BorderRadius.only(
                                              topLeft: Radius.circular(32),
                                              bottomLeft: Radius.circular(32),
                                              topRight: Radius.circular(6),
                                              bottomRight: Radius.circular(6),
                                            ),
                                            onTap: widget.onRegisterPressed,
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              mainAxisSize: MainAxisSize.max,
                                              children: const [
                                                Icon(Icons.add,
                                                    color: Colors.white,
                                                    size: 20),
                                                SizedBox(width: 8),
                                                Text('등록',
                                                    style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.bold)),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      Container(
                                        height: 44,
                                        width: 3.0,
                                        color: Colors.transparent,
                                        child: Center(
                                          child: Container(
                                            width: 2,
                                            height: 28,
                                            color:
                                                Colors.white.withOpacity(0.1),
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 2.5),
                                        child: GestureDetector(
                                          key: _dropdownButtonKey,
                                          onTap: () {
                                            if (_dropdownOverlay == null) {
                                              widget
                                                  .onDropdownOpenChanged(true);
                                              _showDropdownMenu();
                                            } else {
                                              _removeDropdownMenu();
                                            }
                                          },
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                                milliseconds: 350),
                                            width: 44,
                                            height: 44,
                                            decoration: ShapeDecoration(
                                              color: const Color(0xFF1976D2),
                                              shape: RoundedRectangleBorder(
                                                borderRadius: widget
                                                        .isDropdownOpen
                                                    ? BorderRadius.circular(50)
                                                    : const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(6),
                                                        bottomLeft:
                                                            Radius.circular(6),
                                                        topRight:
                                                            Radius.circular(32),
                                                        bottomRight:
                                                            Radius.circular(32),
                                                      ),
                                              ),
                                            ),
                                            child: Center(
                                              child: AnimatedRotation(
                                                turns: widget.isDropdownOpen
                                                    ? 0.5
                                                    : 0.0,
                                                duration: const Duration(
                                                    milliseconds: 350),
                                                curve: Curves.easeInOut,
                                                child: const Icon(
                                                  Icons.keyboard_arrow_down,
                                                  color: Colors.white,
                                                  size: 28,
                                                  key: ValueKey('arrow'),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    if (widget.showRegisterControls) ...[
                                      const SizedBox(width: 8),
                                      AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 250),
                                        height: 44,
                                        width: _isSearchExpanded ? 160 : 44,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2A2A2A),
                                          borderRadius:
                                              BorderRadius.circular(22),
                                          border: Border.all(
                                              color: Colors.white
                                                  .withOpacity(0.2)),
                                        ),
                                        child: Row(
                                          mainAxisAlignment: _isSearchExpanded
                                              ? MainAxisAlignment.start
                                              : MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            IconButton(
                                              visualDensity:
                                                  const VisualDensity(
                                                      horizontal: -4,
                                                      vertical: -4),
                                              padding: _isSearchExpanded
                                                  ? const EdgeInsets.only(
                                                      left: 8)
                                                  : EdgeInsets.zero,
                                              constraints: const BoxConstraints(
                                                  minWidth: 32, minHeight: 32),
                                              icon: const Icon(Icons.search,
                                                  color: Colors.white70,
                                                  size: 20),
                                              onPressed: () {
                                                setState(() {
                                                  _isSearchExpanded =
                                                      !_isSearchExpanded;
                                                });
                                                if (_isSearchExpanded) {
                                                  Future.delayed(
                                                      const Duration(
                                                          milliseconds: 50),
                                                      () {
                                                    _searchFocusNode
                                                        .requestFocus();
                                                  });
                                                } else {
                                                  setState(() {
                                                    _searchController.clear();
                                                    _searchQuery = '';
                                                  });
                                                  FocusScope.of(context)
                                                      .unfocus();
                                                }
                                              },
                                            ),
                                            if (_isSearchExpanded)
                                              const SizedBox(width: 10),
                                            if (_isSearchExpanded)
                                              Expanded(
                                                child: TextField(
                                                  controller: _searchController,
                                                  focusNode: _searchFocusNode,
                                                  style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 16.5),
                                                  decoration:
                                                      const InputDecoration(
                                                    hintText: '검색',
                                                    hintStyle: TextStyle(
                                                        color: Colors.white54,
                                                        fontSize: 16.5),
                                                    border: InputBorder.none,
                                                    isDense: true,
                                                    contentPadding:
                                                        EdgeInsets.zero,
                                                  ),
                                                  onChanged: _onSearchChanged,
                                                ),
                                              ),
                                            if (_isSearchExpanded &&
                                                _searchQuery.isNotEmpty)
                                              IconButton(
                                                visualDensity:
                                                    const VisualDensity(
                                                        horizontal: -4,
                                                        vertical: -4),
                                                padding: const EdgeInsets.only(
                                                    right: 10),
                                                constraints:
                                                    const BoxConstraints(
                                                        minWidth: 32,
                                                        minHeight: 32),
                                                tooltip: '지우기',
                                                icon: const Icon(Icons.clear,
                                                    color: Colors.white70,
                                                    size: 16),
                                                onPressed: () {
                                                  setState(() {
                                                    _searchController.clear();
                                                    _searchQuery = '';
                                                  });
                                                  FocusScope.of(context)
                                                      .requestFocus(
                                                          _searchFocusNode);
                                                },
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                );
                              })),
                          // 학생카드 리스트 위에 요일+시간 출력
                          Expanded(
                            child: _searchQuery.isNotEmpty &&
                                    _searchResults.isNotEmpty
                                ? _buildSearchResultPanel()
                                : (
                                    // 1) 셀 선택 시: 해당 시간 학생카드
                                    (widget.selectedCellDayIndex != null &&
                                            widget.selectedCellStartTime !=
                                                null)
                                        ? ValueListenableBuilder<int>(
                                            valueListenable: DataManager
                                                .instance
                                                .studentTimeBlocksRevision,
                                            builder: (context, _, __) {
                                              final int selDayIdx =
                                                  widget.selectedCellDayIndex ??
                                                      0; // 0=월
                                              // 셀 날짜 기준 refDate 산출
                                              // 주의: selectedCellStartTime의 "날짜"는 _selectedDate 기반으로 만들어져
                                              // 실제 요일 컬럼의 날짜와 다를 수 있다. (예: week=3주차인데 _selectedDate가 목요일이면,
                                              // 수요일 셀 refDate가 목요일로 잡혀 잘못된 블록이 활성로 판단됨)
                                              final selectedDate =
                                                  widget.selectedCellStartTime!;
                                              final DateTime weekStart =
                                                  DateTime(
                                                          widget.viewDate.year,
                                                          widget.viewDate.month,
                                                          widget.viewDate.day)
                                                      .subtract(Duration(
                                                          days: widget.viewDate
                                                                  .weekday -
                                                              DateTime.monday));
                                              final DateTime weekEnd = weekStart
                                                  .add(const Duration(days: 7));
                                              final DateTime cellYmd =
                                                  weekStart.add(Duration(
                                                      days: selDayIdx));
                                              final DateTime refDate = DateTime(
                                                  cellYmd.year,
                                                  cellYmd.month,
                                                  cellYmd.day);
                                              // ✅ 셀 클릭 시에는 "현재 보고 있는 주"에 겹치는 블록만 사용(week-cache)
                                              // 전체 히스토리(비활성 포함)를 매번 스캔하면 클릭마다 1s+ 지연이 생길 수 있다.
                                              final allBlocks = DataManager
                                                  .instance
                                                  .getStudentTimeBlocksForWeek(
                                                      refDate);
                                              final blocks = allBlocks
                                                  .where((b) =>
                                                      b.dayIndex == selDayIdx &&
                                                      b.startHour ==
                                                          selectedDate.hour &&
                                                      b.startMinute ==
                                                          selectedDate.minute)
                                                  .toList();
                                              bool _isActive(
                                                  StudentTimeBlock b) {
                                                final start = DateTime(
                                                    b.startDate.year,
                                                    b.startDate.month,
                                                    b.startDate.day);
                                                final end = b.endDate != null
                                                    ? DateTime(
                                                        b.endDate!.year,
                                                        b.endDate!.month,
                                                        b.endDate!.day)
                                                    : null;
                                                return !start
                                                        .isAfter(refDate) &&
                                                    (end == null ||
                                                        !end.isBefore(refDate));
                                              }

                                              final activeBlocks = blocks
                                                  .where(_isActive)
                                                  .toList();
                                              // 학생별(선택 dayIdx) 블록 인덱스: sessionOverride의 setId 추정용
                                              final Map<String,
                                                      List<StudentTimeBlock>>
                                                  blocksByStudentOnDay = {};
                                              for (final b in allBlocks) {
                                                if (b.dayIndex != selDayIdx)
                                                  continue;
                                                blocksByStudentOnDay
                                                    .putIfAbsent(
                                                        b.studentId,
                                                        () => <StudentTimeBlock>[])
                                                    .add(b);
                                              }
                                              // 보강 원본 블라인드(set_id 우선): 같은 날짜(YMD)의 replace 원본이 있으면 해당 (studentId,setId) 전체를 제외
                                              final DateTime cellDate =
                                                  DateTime(
                                                cellYmd.year,
                                                cellYmd.month,
                                                cellYmd.day,
                                                selectedDate.hour,
                                                selectedDate.minute,
                                              );
                                              final Set<String> hiddenPairs =
                                                  {};
                                              for (final ov in DataManager
                                                  .instance.sessionOverrides) {
                                                if (ov.reason !=
                                                    OverrideReason.makeup)
                                                  continue;
                                                if (ov.overrideType !=
                                                    OverrideType.replace)
                                                  continue;
                                                if (ov.status ==
                                                    OverrideStatus.canceled)
                                                  continue;
                                                final orig =
                                                    ov.originalClassDateTime;
                                                if (orig == null) continue;
                                                if (orig.isBefore(weekStart) ||
                                                    !orig.isBefore(weekEnd))
                                                  continue;
                                                final bool sameYmd = orig
                                                            .year ==
                                                        cellDate.year &&
                                                    orig.month ==
                                                        cellDate.month &&
                                                    orig.day == cellDate.day;
                                                if (!sameYmd) continue;
                                                String? setId = ov.setId;
                                                if (setId == null ||
                                                    setId.isEmpty) {
                                                  // 학생의 같은 요일 블록에서 원본 시간과 가장 가까운 블록의 setId 추정
                                                  final blocksByStudent =
                                                      blocksByStudentOnDay[
                                                              ov.studentId] ??
                                                          const <StudentTimeBlock>[];
                                                  if (blocksByStudent
                                                      .isNotEmpty) {
                                                    int origMin =
                                                        orig.hour * 60 +
                                                            orig.minute;
                                                    int bestDiff = 1 << 30;
                                                    for (final b
                                                        in blocksByStudent) {
                                                      final int bm =
                                                          b.startHour * 60 +
                                                              b.startMinute;
                                                      final int diff =
                                                          (bm - origMin).abs();
                                                      if (diff < bestDiff &&
                                                          b.setId != null &&
                                                          b.setId!.isNotEmpty) {
                                                        bestDiff = diff;
                                                        setId = b.setId;
                                                      }
                                                    }
                                                  }
                                                }
                                                if (setId != null &&
                                                    setId.isNotEmpty) {
                                                  hiddenPairs.add(
                                                      '${ov.studentId}|$setId');
                                                }
                                              }
                                              final studentIdSet =
                                                  (widget.filteredStudentIds ??
                                                          DataManager
                                                              .instance.students
                                                              .map((s) =>
                                                                  s.student.id)
                                                              .toList())
                                                      .toSet();
                                              final Map<String, DateTime?>
                                                  registrationDateByStudentId = {
                                                for (final s in DataManager
                                                    .instance.students)
                                                  s.student.id: s.basicInfo
                                                      .registrationDate,
                                              };
                                              List<StudentTimeBlock>
                                                  filteredBlocks = [];
                                              for (final b in activeBlocks) {
                                                if (!studentIdSet.contains(
                                                    b.studentId)) continue;
                                                if (!_isBlockAllowed(b))
                                                  continue;
                                                final pairKey =
                                                    '${b.studentId}|${b.setId ?? ''}';
                                                if (hiddenPairs
                                                    .contains(pairKey)) {
                                                  continue; // set_id 블라인드 적용
                                                }
                                                // 주차 계산 (등록일 기반)
                                                final reg =
                                                    registrationDateByStudentId[
                                                        b.studentId];
                                                if (reg == null) {
                                                  filteredBlocks.add(b);
                                                  continue;
                                                }
                                                DateTime toMonday(DateTime x) {
                                                  final off = x.weekday -
                                                      DateTime.monday;
                                                  return DateTime(x.year,
                                                          x.month, x.day)
                                                      .subtract(
                                                          Duration(days: off));
                                                }

                                                final week = (() {
                                                  final rm = toMonday(reg!);
                                                  final sm =
                                                      toMonday(selectedDate);
                                                  final diff =
                                                      sm.difference(rm).inDays;
                                                  return (diff >= 0
                                                          ? (diff ~/ 7)
                                                          : 0) +
                                                      1;
                                                })();
                                                final startMin =
                                                    b.startHour * 60 +
                                                        b.startMinute;
                                                final blind = _shouldBlindBlock(
                                                  studentId: b.studentId,
                                                  weekNumber: week,
                                                  weeklyOrder: b.weeklyOrder,
                                                  sessionTypeId:
                                                      b.sessionTypeId,
                                                  dayIdx: b.dayIndex,
                                                  startMin: startMin,
                                                );
                                                if (!blind)
                                                  filteredBlocks.add(b);
                                              }
                                              final blocksToUse =
                                                  filteredBlocks;
                                              final allStudents =
                                                  DataManager.instance.students;
                                              final students = widget
                                                          .filteredStudentIds ==
                                                      null
                                                  ? allStudents
                                                  : allStudents
                                                      .where((s) => widget
                                                          .filteredStudentIds!
                                                          .contains(
                                                              s.student.id))
                                                      .toList();
                                              final Map<String,
                                                      StudentWithInfo>
                                                  studentById = {
                                                for (final s in students)
                                                  s.student.id: s,
                                              };
                                              final cellStudents = blocksToUse
                                                  .map((b) =>
                                                      studentById[b.studentId])
                                                  .whereType<StudentWithInfo>()
                                                  .toList();
                                              // 학생별 최신 블록(생성시각 기준) 매핑: 번호/SET/색상 계산 시 재탐색 없이 사용
                                              final Map<String,
                                                      StudentTimeBlock>
                                                  blockOverrides = {};
                                              for (final b in blocksToUse) {
                                                final prev =
                                                    blockOverrides[b.studentId];
                                                if (prev == null ||
                                                    b.createdAt.isAfter(
                                                        prev.createdAt)) {
                                                  blockOverrides[b.studentId] =
                                                      b;
                                                }
                                              }

                                              return LayoutBuilder(
                                                builder:
                                                    (context, constraints) {
                                                  const double panelTopMargin =
                                                      _kStudentPanelHeaderTopMargin;
                                                  final double containerHeight =
                                                      (constraints.maxHeight -
                                                              panelTopMargin)
                                                          .clamp(120.0,
                                                              double.infinity);
                                                  return Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Container(
                                                        margin: const EdgeInsets
                                                            .only(
                                                            top:
                                                                panelTopMargin),
                                                        height: containerHeight,
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                horizontal: 0,
                                                                vertical: 0),
                                                        color:
                                                            Colors.transparent,
                                                        child: KeyedSubtree(
                                                          key: ValueKey(
                                                            'cell-${widget.selectedCellDayIndex}-${widget.selectedCellStartTime}-${DataManager.instance.studentTimeBlocksRevision.value}',
                                                          ),
                                                          child:
                                                              _buildCellPanelCached(
                                                            students:
                                                                cellStudents,
                                                            dayIdx: widget
                                                                .selectedCellDayIndex,
                                                            startTime: widget
                                                                .selectedCellStartTime,
                                                            maxHeight:
                                                                containerHeight,
                                                            isSelectMode: widget
                                                                .isSelectMode,
                                                            selectedIds: widget
                                                                .selectedStudentIds,
                                                            onSelectChanged: widget
                                                                .onStudentSelectChanged,
                                                            blockOverrides:
                                                                blockOverrides,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  );
                                                },
                                              );
                                            },
                                          )
                                        // 2) 요일만 선택 시: 해당 요일 등원 시간 그룹 순서대로
                                        : (widget.selectedCellDayIndex != null &&
                                                widget.selectedDayDate !=
                                                    null &&
                                                widget.selectedCellStartTime ==
                                                    null)
                                            // 요일 선택 시 실제 렌더링은 우측 Stack 오버레이에서 수행. 여기서는 레이아웃만 유지.
                                            ? LayoutBuilder(
                                                builder:
                                                    (context, constraints) {
                                                  return Container(
                                                    width: double.infinity,
                                                    height:
                                                        constraints.maxHeight,
                                                    color: Colors.transparent,
                                                  );
                                                },
                                              )
                                            : _buildTimeIdleSkeleton()),
                          ),
                          // 삭제 드롭존
                          if (_showDeleteZone)
                            Padding(
                              padding: const EdgeInsets.only(top: 16.0),
                              child: DragTarget<Map<String, dynamic>>(
                                onWillAccept: (data) => true,
                                onAccept: (data) async {
                                  final students = (data['students'] as List)
                                      .map((e) => e is StudentWithInfo
                                          ? e
                                          : e['student'] as StudentWithInfo)
                                      .toList();
                                  final oldDayIndex =
                                      data['oldDayIndex'] as int?;
                                  final oldStartTime =
                                      data['oldStartTime'] as DateTime?;
                                  // print('[삭제드롭존] onAccept 호출: students=${students.map((s) => s.student.id).toList()}, oldDayIndex=$oldDayIndex, oldStartTime=$oldStartTime');
                                  List<Future> futures = [];

                                  // 기존 수업 블록 삭제 로직
                                  for (final student in students) {
                                    // 1. 해당 학생+요일+시간 블록 1개 찾기 (setId 추출용)
                                    final targetBlock = DataManager
                                        .instance.studentTimeBlocks
                                        .firstWhere(
                                      (b) =>
                                          b.studentId == student.student.id &&
                                          b.dayIndex == oldDayIndex &&
                                          b.startHour == oldStartTime?.hour &&
                                          b.startMinute == oldStartTime?.minute,
                                      orElse: () => StudentTimeBlock(
                                        id: '',
                                        studentId: '',
                                        dayIndex: -1,
                                        startHour: 0,
                                        startMinute: 0,
                                        duration: Duration.zero,
                                        createdAt: DateTime(0),
                                        startDate: DateTime(0),
                                        setId: null,
                                        number: null,
                                      ),
                                    );
                                    if (targetBlock != null &&
                                        targetBlock.setId != null) {
                                      // setId+studentId로 모든 블록 삭제 (일괄 삭제)
                                      final allBlocks = DataManager
                                          .instance.studentTimeBlocks;
                                      final toDelete = allBlocks
                                          .where((b) =>
                                              b.setId == targetBlock.setId &&
                                              b.studentId == student.student.id)
                                          .toList();
                                      for (final b in toDelete) {
                                        futures.add(DataManager.instance
                                            .removeStudentTimeBlock(b.id));
                                      }
                                    }
                                    // setId가 없는 경우 단일 블록 삭제
                                    final blocks = DataManager
                                        .instance.studentTimeBlocks
                                        .where((b) =>
                                            b.studentId == student.student.id &&
                                            b.dayIndex == oldDayIndex &&
                                            b.startHour == oldStartTime?.hour &&
                                            b.startMinute ==
                                                oldStartTime?.minute)
                                        .toList();
                                    for (final block in blocks) {
                                      futures.add(DataManager.instance
                                          .removeStudentTimeBlock(block.id));
                                    }
                                  }

                                  await Future.wait(futures);
                                  await DataManager.instance.loadStudents();
                                  await DataManager.instance
                                      .loadStudentTimeBlocks();
                                  setState(() {
                                    _showDeleteZone = false;
                                  });
                                  // 스낵바 즉시 표시 (지연 제거)
                                  if (mounted) {
                                    showAppSnackBar(context,
                                        '${students.length}명 학생의 수업시간이 삭제되었습니다.',
                                        useRoot: true);
                                  }
                                  // 삭제 후 선택모드 종료 콜백 직접 호출
                                  if (widget.onExitSelectMode != null) {
                                    widget.onExitSelectMode!();
                                  }
                                },
                                builder:
                                    (context, candidateData, rejectedData) {
                                  final isHover = candidateData.isNotEmpty;
                                  return AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    width: double.infinity,
                                    height: 72,
                                    decoration: BoxDecoration(
                                      color: Colors.grey[900],
                                      border: Border.all(
                                        color: isHover
                                            ? Colors.red
                                            : Colors.grey[700]!,
                                        width: isHover ? 3 : 2,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Center(
                                      child: Icon(
                                        Icons.delete_outline,
                                        color: isHover
                                            ? Colors.red
                                            : Colors.white70,
                                        size: 36,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // 수업 영역
                  Expanded(
                    flex: 1,
                    child: Stack(
                      children: [
                        // 수업 리스트 (기존 내용)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.only(top: 12, right: 8),
                                  child: Row(
                                    children: [
                                      if (MediaQuery.of(context).size.width >
                                          1600) ...[
                                        const SizedBox(width: 6),
                                        // ✅ 수업 리스트 타이틀 아이콘: Material Design 3(비행기/Travel)
                                        const Icon(Symbols.flight,
                                            color: Color(0xFFEAF2F2), size: 28),
                                        const SizedBox(width: 10),
                                        const Text(
                                          '수업',
                                          style: TextStyle(
                                            color: Color(0xFFEAF2F2),
                                            fontSize: 25,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const Spacer(),
                                // ✅ 수업 추가 버튼: 타이틀 줄 오른쪽 정렬 + 기존 수업 등록 다이얼로그 연결
                                Padding(
                                  padding: const EdgeInsets.only(top: 8, right: 4),
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      tooltip: '수업 추가',
                                      onPressed: () => _showClassRegistrationDialog(),
                                      icon: const Icon(Icons.add_rounded),
                                      iconSize: 30,
                                      color: const Color(0xFFEAF2F2),
                                      padding: EdgeInsets.zero,
                                      splashRadius: 26,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ValueListenableBuilder<int>(
                                valueListenable: DataManager
                                    .instance.studentTimeBlocksRevision,
                                builder: (context, __, ___) {
                                  final int unassignedCount =
                                      _unfilteredDefaultClassCount();
                                  final filteredClassIds =
                                      widget.filteredClassIds ??
                                          const <String>{};

                                  return ValueListenableBuilder<
                                      List<ClassInfo>>(
                                    valueListenable:
                                        DataManager.instance.classesNotifier,
                                    builder: (context, classes, ____) {
                                      if (classes.isEmpty &&
                                          unassignedCount == 0) {
                                        return const Center(
                                          child: Text('등록된 수업이 없습니다.',
                                              style: TextStyle(
                                                  color: Colors.white38,
                                                  fontSize: 16)),
                                        );
                                      }

                                      // 정원(수업 카드) 카운트는 "보고 있는 날짜(refDate)" 기준으로 계산한다.
                                      // 주의: selectedCellStartTime의 날짜는 _selectedDate 기반으로 만들어져
                                      // 실제 셀(요일 컬럼)의 날짜와 다를 수 있으므로, selectedCellDayIndex를 이용해
                                      // 주의 월요일 + dayIndex로 실제 날짜를 계산한다.
                                      DateTime? _selectedCellDateOnly() {
                                        final idx = widget.selectedCellDayIndex;
                                        if (idx == null) return null;
                                        final monday = widget.viewDate.subtract(
                                          Duration(days: widget.viewDate.weekday - DateTime.monday),
                                        );
                                        return DateTime(monday.year, monday.month, monday.day)
                                            .add(Duration(days: idx));
                                      }

                                      final DateTime _baseRef =
                                          widget.selectedDayDate ??
                                              _selectedCellDateOnly() ??
                                              widget.viewDate;
                                      final DateTime _classCountRef =
                                          DateTime(_baseRef.year, _baseRef.month, _baseRef.day);

                                      return Column(
                                        children: [
                                          if (unassignedCount > 0) ...[
                                            _ClassCard(
                                              key: const ValueKey(
                                                  '__default_class__'),
                                              classInfo: ClassInfo(
                                                id: '__default_class__',
                                                name: '수업',
                                                description: '기본 수업',
                                                capacity: null,
                                                color: const Color(0xFF223131),
                                              ),
                                              onEdit: () {},
                                              onDelete: () {},
                                              reorderIndex: -1,
                                              registrationModeType:
                                                  widget.registrationModeType,
                                              studentCountOverride:
                                                  unassignedCount,
                                              refDate: _classCountRef,
                                              enableActions: false,
                                              showDragHandle: false,
                                              onFilterToggle: widget
                                                          .onToggleClassFilter !=
                                                      null
                                                  ? () =>
                                                      widget.onToggleClassFilter!(
                                                          ClassInfo(
                                                        id: '__default_class__',
                                                        name: '수업',
                                                        description: '기본 수업',
                                                        capacity: null,
                                                        color: const Color(
                                                            0xFF223131),
                                                      ))
                                                  : null,
                                              isFiltered:
                                                  filteredClassIds.contains(
                                                      '__default_class__'),
                                            ),
                                            const SizedBox(height: 12),
                                          ],
                                          Expanded(
                                            child: classes.isEmpty
                                                ? SizedBox.shrink()
                                                : ReorderableListView.builder(
                                                    padding: EdgeInsets.zero,
                                                    itemCount: classes.length,
                                                    buildDefaultDragHandles:
                                                        false,
                                                    onReorder: _onReorder,
                                                    proxyDecorator: (child,
                                                        index, animation) {
                                                      return Material(
                                                        color:
                                                            Colors.transparent,
                                                        child: Container(
                                                          margin:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  vertical: 0,
                                                                  horizontal:
                                                                      0),
                                                          child: child,
                                                        ),
                                                      );
                                                    },
                                                    itemBuilder:
                                                        (context, idx) {
                                                      final c = classes[idx];
                                                      final bool isFiltered = filteredClassIds.contains(c.id);
                                                      final card = _ClassCard(
                                                        classInfo: c,
                                                        onEdit: () => _showClassRegistrationDialog(
                                                          editTarget: c,
                                                          editIndex: idx,
                                                        ),
                                                        onDelete: () => _deleteClass(idx),
                                                        reorderIndex: idx,
                                                        registrationModeType: widget.registrationModeType,
                                                        studentCountOverride: null,
                                                        refDate: _classCountRef,
                                                        onFilterToggle: widget.onToggleClassFilter != null
                                                            ? () => widget.onToggleClassFilter!(c)
                                                            : null,
                                                        isFiltered: isFiltered,
                                                        showDragHandle: false,
                                                      );
                                                      return Padding(
                                                        key: ValueKey(c.id),
                                                        padding: const EdgeInsets.only(bottom: 12.0),
                                                        // ✅ 기본: 오래 눌러 수업 순서 이동(reorder)
                                                        // ✅ 단, 수업이 "선택(필터)"된 상태에서는 드래그=수업단위 이동(class-move)로 분기
                                                        child: isFiltered
                                                            ? card
                                                            : ReorderableDelayedDragStartListener(
                                                                index: idx,
                                                                child: card,
                                                              ),
                                                      );
                                                    },
                                                  ),
                                          ),
                                        ],
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (widget.selectedCellDayIndex != null &&
                  widget.selectedCellStartTime == null &&
                  widget.selectedDayDate != null)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: false,
                    child: Container(
                      color: Colors.transparent,
                      // 학생 패널과 동일한 좌우/하단 패딩을 적용해 폭/하단 정렬을 맞춤
                      padding: EdgeInsets.only(
                        left: 4,
                        right: 8,
                        bottom: 13, // 요일 선택 오버레이(초록 박스) 하단 외부 여백 +5
                        top: _daySelectedOverlayTopPadding(context),
                      ),
                      child: _buildDaySelectedOverlayPanel(),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 24),
      ],
    );
  }

  String _gradeLabelForStudent(EducationLevel level, int grade) {
    if (level == EducationLevel.elementary) return '초$grade';
    if (level == EducationLevel.middle) return '중$grade';
    if (level == EducationLevel.high) return '고$grade';
    return '기타';
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime _weekMonday(DateTime d) {
    final base = _dateOnly(d);
    return base.subtract(Duration(days: base.weekday - DateTime.monday));
  }

  // --- 특수 카드(보강/추가/희망/시범) 표시용 색상 ---
  static const Color _kMakeupBlue = Color(0xFF1976D2); // 보강(replace)
  static const Color _kAddGreen = Color(0xFF4CAF50); // 추가수업(add) / 시범수업(trial)
  static const Color _kInquiryOrange = Color(0xFFF2B45B); // 희망수업(inquiry)

  Widget _buildSpecialSlotCard({
    required String kind,
    required String title,
    required Color base,
    required int blockNumber,
  }) {
    // ✅ 학생카드와 동일한 레이아웃/패딩/라운드 + 배경색만 tint
    // - number(1..N)는 기존 blockNumber 위치에 표시
    // - 학교명 위치에는 kind(보강/추가/희망/시범)를 표시
    final nameStyle = const TextStyle(color: Color(0xFFEAF2F2), fontSize: 16, fontWeight: FontWeight.w600);
    final metaStyle = const TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500);
    final kindStyle = TextStyle(color: Colors.white.withOpacity(0.62), fontSize: 13, fontWeight: FontWeight.w700);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: base.withOpacity(0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.transparent, width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                // 인디케이터는 필요 없으므로 투명(자리/모양은 유지)
                Container(
                  width: 6,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: nameStyle,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('$blockNumber', style: metaStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  kind,
                  style: kindStyle,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _specialCardsForCell({
    required int dayIdx,
    required DateTime startTime,
  }) {
    final List<Widget> out = <Widget>[];
    final cellYmd = _cellDateOnlyForDayIndex(dayIdx);
    final cell = DateTime(cellYmd.year, cellYmd.month, cellYmd.day, startTime.hour, startTime.minute);
    final weekStart = _weekMonday(cellYmd);
    final int lessonMin = DataManager.instance.academySettings.lessonDuration;
    const int blockMinutes = 30;
    final int cellMin = cell.hour * 60 + cell.minute;

    // 1) 보강/추가수업(일회성): replacementClassDateTime이 셀 시간과 정확히 일치할 때만 표시
    for (final ov in DataManager.instance.sessionOverrides) {
      if (ov.reason != OverrideReason.makeup) continue;
      if (!(ov.overrideType == OverrideType.add || ov.overrideType == OverrideType.replace)) continue;
      if (ov.status == OverrideStatus.canceled) continue;
      final rep = ov.replacementClassDateTime;
      if (rep == null) continue;
      final bool sameYmd = rep.year == cell.year && rep.month == cell.month && rep.day == cell.day;
      if (!sameYmd) continue;
      final int durationMin = (ov.durationMinutes ?? lessonMin).clamp(0, 24 * 60);
      if (durationMin <= 0) continue;
      final int repStartMin = rep.hour * 60 + rep.minute;
      final int repEndMin = repStartMin + durationMin;
      if (!(cellMin >= repStartMin && cellMin < repEndMin)) continue;
      final int number = ((cellMin - repStartMin) ~/ blockMinutes) + 1;
      StudentWithInfo? s;
      try {
        s = DataManager.instance.students.firstWhere((x) => x.student.id == ov.studentId);
      } catch (_) {
        s = null;
      }
      final name = s?.student.name ?? '학생';
      if (ov.overrideType == OverrideType.replace) {
        out.add(_buildSpecialSlotCard(kind: '보강', title: name, base: _kMakeupBlue, blockNumber: number));
      } else {
        out.add(_buildSpecialSlotCard(kind: '추가', title: name, base: _kAddGreen, blockNumber: number));
      }
    }

    // 2) 희망수업(문의): startWeek <= 현재 주의 Monday인 슬롯만 표시
    final inquiry = ConsultInquiryDemandService.instance.slotsBySlotKeyForWeek(weekStart);
    for (final list in inquiry.values) {
      for (final s in list) {
        if (s.dayIndex != dayIdx) continue;
        final int base = s.hour * 60 + s.minute;
        final int end = base + lessonMin;
        if (!(cellMin >= base && cellMin < end)) continue;
        final int number = ((cellMin - base) ~/ blockMinutes) + 1;
        out.add(_buildSpecialSlotCard(kind: '희망', title: s.title, base: _kInquiryOrange, blockNumber: number));
      }
    }

    // 3) 시범수업(일회성): 해당 주에만 표시
    final trial = ConsultTrialLessonService.instance.slotsBySlotKeyForWeek(weekStart);
    for (final list in trial.values) {
      for (final s in list) {
        if (s.dayIndex != dayIdx) continue;
        final int base = s.hour * 60 + s.minute;
        final int end = base + lessonMin;
        if (!(cellMin >= base && cellMin < end)) continue;
        final int number = ((cellMin - base) ~/ blockMinutes) + 1;
        out.add(_buildSpecialSlotCard(kind: '시범', title: s.title, base: _kAddGreen, blockNumber: number));
      }
    }

    return out;
  }

  Map<String, List<Widget>> _specialCardsByTimeForDay({
    required DateTime dayDate,
    required int dayIdx,
  }) {
    final out = <String, List<Widget>>{};
    String hhmm(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    void add(int h, int m, Widget w) {
      final k = hhmm(h, m);
      (out[k] ??= <Widget>[]).add(w);
    }

    final ymd = _dateOnly(dayDate);
    final weekStart = _weekMonday(ymd);
    final int lessonMin = DataManager.instance.academySettings.lessonDuration;

    // 보강/추가수업
    for (final ov in DataManager.instance.sessionOverrides) {
      if (ov.reason != OverrideReason.makeup) continue;
      if (!(ov.overrideType == OverrideType.add || ov.overrideType == OverrideType.replace)) continue;
      if (ov.status == OverrideStatus.canceled) continue;
      final rep = ov.replacementClassDateTime;
      if (rep == null) continue;
      final repYmd = _dateOnly(rep);
      if (repYmd.year != ymd.year || repYmd.month != ymd.month || repYmd.day != ymd.day) continue;
      StudentWithInfo? s;
      try {
        s = DataManager.instance.students.firstWhere((x) => x.student.id == ov.studentId);
      } catch (_) {
        s = null;
      }
      final name = s?.student.name ?? '학생';
      // ✅ 요일 선택 리스트에서는 시작 슬롯(1번)만 표시
      if (ov.overrideType == OverrideType.replace) {
        add(rep.hour, rep.minute, _buildSpecialSlotCard(kind: '보강', title: name, base: _kMakeupBlue, blockNumber: 1));
      } else {
        add(rep.hour, rep.minute, _buildSpecialSlotCard(kind: '추가', title: name, base: _kAddGreen, blockNumber: 1));
      }
    }

    // 희망수업(문의)
    final inquiry = ConsultInquiryDemandService.instance.slotsBySlotKeyForWeek(weekStart);
    for (final list in inquiry.values) {
      for (final s in list) {
        if (s.dayIndex != dayIdx) continue;
        // ✅ 요일 선택 리스트에서는 시작 슬롯(1번)만 표시
        add(s.hour, s.minute, _buildSpecialSlotCard(kind: '희망', title: s.title, base: _kInquiryOrange, blockNumber: 1));
      }
    }

    // 시범수업
    final trial = ConsultTrialLessonService.instance.slotsBySlotKeyForWeek(weekStart);
    for (final list in trial.values) {
      for (final s in list) {
        if (s.dayIndex != dayIdx) continue;
        // ✅ 요일 선택 리스트에서는 시작 슬롯(1번)만 표시
        add(s.hour, s.minute, _buildSpecialSlotCard(kind: '시범', title: s.title, base: _kAddGreen, blockNumber: 1));
      }
    }

    return out;
  }

  DateTime _cellDateOnlyForDayIndex(int dayIdx) {
    final monday = _weekMonday(widget.viewDate);
    return monday.add(Duration(days: dayIdx));
  }

  StudentTimeBlock? _findActiveBlockForActions({
    required String studentId,
    required int dayIdx,
    required int hour,
    required int minute,
    required DateTime refDate,
    String? setId,
  }) {
    final ref = _dateOnly(refDate);
    final weekStart = _weekMonday(ref);
    final weekBlocks = DataManager.instance.getStudentTimeBlocksForWeek(weekStart);
    final candidates = weekBlocks.where((b) {
      if (b.studentId != studentId) return false;
      if (b.dayIndex != dayIdx) return false;
      if (b.startHour != hour) return false;
      if (b.startMinute != minute) return false;
      if (setId != null && setId.isNotEmpty && b.setId != setId) return false;
      final sd = _dateOnly(b.startDate);
      final ed = b.endDate == null ? null : _dateOnly(b.endDate!);
      return !sd.isAfter(ref) && (ed == null || !ed.isBefore(ref));
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<void> _showEditBlockDateRangeDialog(BuildContext context, StudentTimeBlock block) async {
    DateTime start = _dateOnly(block.startDate);
    DateTime? end = block.endDate == null ? null : _dateOnly(block.endDate!);

    String fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0B1112),
          title: const Text(
            '수업기간 수정',
            style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800),
          ),
          content: StatefulBuilder(
            builder: (ctx, setLocal) {
              Future<void> pickStart() async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: start,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked == null) return;
                setLocal(() => start = _dateOnly(picked));
              }

              Future<void> pickEnd() async {
                final initial = end ?? start;
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: initial,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked == null) return;
                setLocal(() => end = _dateOnly(picked));
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 76,
                        child: Text('시작', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                      ),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: pickStart,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.white.withOpacity(0.18)),
                            foregroundColor: const Color(0xFFEAF2F2),
                          ),
                          child: Text(fmt(start)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const SizedBox(
                        width: 76,
                        child: Text('종료', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                      ),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: end == null ? null : pickEnd,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.white.withOpacity(0.18)),
                            foregroundColor: const Color(0xFFEAF2F2),
                          ),
                          child: Text(end == null ? '없음(무기한)' : fmt(end!)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    value: end == null,
                    onChanged: (v) => setLocal(() => end = (v == true) ? null : start),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF33A373),
                    title: const Text('종료일 없음(무기한)', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '(${block.dayIndex} ${block.startHour.toString().padLeft(2, '0')}:${block.startMinute.toString().padLeft(2, '0')})',
                    style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('저장', style: TextStyle(color: Color(0xFF33A373), fontWeight: FontWeight.w800)),
            ),
          ],
        );
      },
    );

    if (ok != true) return;
    try {
      await DataManager.instance.updateStudentTimeBlockDateRange(
        block.id,
        startDate: start,
        endDate: end,
      );
      if (mounted) {
        showAppSnackBar(context, '수업기간이 수정되었습니다.', useRoot: true);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '수정 실패: $e', useRoot: true);
      }
    }
  }

  Future<void> _confirmAndDeleteBlock(
    BuildContext context,
    StudentTimeBlock block, {
    required DateTime refDate,
  }) async {
    final date = _dateOnly(refDate);
    final today = _dateOnly(DateTime.now());
    final bool isToday = date.year == today.year && date.month == today.month && date.day == today.day;
    final String dateLabel = '${date.month}/${date.day}';
    final String deleteStartLabel = isToday ? '내일부터' : '선택한 날짜($dateLabel)부터';
    final setId = (block.setId ?? '').trim();
    bool deleteFutureSegments = false;

    // 같은 setId의 "미래 세그먼트"가 있으면 사용자에게 범위를 확인
    if (setId.isNotEmpty) {
      final hasFuture = DataManager.instance.studentTimeBlocks.any((b) {
        if (b.studentId != block.studentId) return false;
        if ((b.setId ?? '').trim() != setId) return false;
        final sd = _dateOnly(b.startDate);
        return sd.isAfter(date);
      });
      if (hasFuture) {
        final choice = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0B1112),
            title: const Text('수업시간 삭제', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800)),
            content: Text(
              '$deleteStartLabel 수업시간을 삭제할까요?\n'
              '또한, 같은 수업(set_id)에 미래 시작 일정이 있습니다.\n\n'
              '- 이번 일정만: 선택 날짜까지 유지 후 종료(미래 일정 유지)\n'
              '- 미래도 삭제: 선택 날짜까지 유지 후 종료 + 미래 일정 삭제',
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, height: 1.35),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('이번 일정만', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('미래도 삭제', style: TextStyle(color: Color(0xFFB74C4C), fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        );
        if (choice == null) return;
        deleteFutureSegments = choice;
      } else {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0B1112),
            title: const Text('수업시간 삭제', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800)),
            content: Text(
              '$deleteStartLabel 해당 수업시간을 삭제할까요?\n'
              '(과거 수업기록/출석기록은 삭제하지 않고, 기간만 종료 처리됩니다)',
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('삭제', style: TextStyle(color: Color(0xFFB74C4C), fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        );
        if (ok != true) return;
      }
    } else {
      // setId가 없는 블록은 단일 종료로 처리
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF0B1112),
          title: const Text('수업시간 삭제', style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w800)),
          content: Text(
            '$deleteStartLabel 해당 수업시간을 삭제할까요?\n'
            '(과거 수업기록/출석기록은 삭제하지 않고, 기간만 종료 처리됩니다)',
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('삭제', style: TextStyle(color: Color(0xFFB74C4C), fontWeight: FontWeight.w900)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      if (setId.isNotEmpty) {
        await DataManager.instance.closeStudentTimeBlockSetAtDate(
          studentId: block.studentId,
          setId: setId,
          refDate: date,
          deleteFutureSegments: deleteFutureSegments,
        );
      } else {
        await DataManager.instance.bulkDeleteStudentTimeBlocks(
          [block.id],
          immediate: true,
          endDateOverride: isToday ? date : date.subtract(const Duration(days: 1)),
        );
      }
      if (mounted) {
        showAppSnackBar(
          context,
          deleteFutureSegments ? '삭제되었습니다. (미래 일정도 삭제됨)' : '삭제되었습니다.',
          useRoot: true,
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '삭제 실패: $e', useRoot: true);
      }
    }
  }

  // --- 학생카드 Draggable 래퍼 공통 함수 ---
  Widget _buildDraggableStudentCard(
    StudentWithInfo info, {
    int? dayIndex,
    DateTime? startTime,
    List<StudentWithInfo>? cellStudents,
    StudentTimeBlock? blockOverride,
    bool highlightBorder = false,
    VoidCallback? onTapCard,
  }) {
    // print('[DEBUG][_buildDraggableStudentCard] 호출: student=${info.student.name}, dayIndex=$dayIndex, startTime=$startTime');
    // 학생의 고유성을 보장하는 key 생성 (그룹이 있으면 그룹 id까지 포함)
    final cardKey = ValueKey(
      info.student.id + (info.student.groupInfo?.id ?? ''),
    );
    final isSelected = widget.selectedStudentIds.contains(info.student.id);
    final selectedStudents = cellStudents
            ?.where((s) => widget.selectedStudentIds.contains(s.student.id))
            .toList() ??
        [];
    final selectedCount = selectedStudents.length;
    DateTime _refDateFor(DateTime start) => (start.year > 1)
        ? DateTime(start.year, start.month, start.day)
        : DateTime.now();
    bool _isActive(StudentTimeBlock b, DateTime ref) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final ed = b.endDate != null
          ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
          : null;
      return !sd.isAfter(ref) && (ed == null || !ed.isBefore(ref));
    }

    // 해당 학생+시간의 StudentTimeBlock에서 활성 블록 기준 setId/색상/회차 결정
    String? setId = blockOverride?.setId;
    int? blockNumber = blockOverride?.number;
    Color? indicatorOverride;
    if (dayIndex != null && startTime != null) {
      final ref = _refDateFor(startTime);
      // 우선: 셀 선택 등에서 전달된 override 블록 기준으로 색상 계산(setId로 후보 제한)
      if (blockOverride != null) {
        indicatorOverride = DataManager.instance.getStudentClassColorAt(
          info.student.id,
          dayIndex,
          startTime,
          setId: setId,
          refDate: ref,
        );
      }
      // fallback: 메모리 블록 재탐색
      if (indicatorOverride == null) {
        final blocks = DataManager.instance.studentTimeBlocks
            .where((b) =>
                b.studentId == info.student.id &&
                b.dayIndex == dayIndex &&
                b.startHour == startTime.hour &&
                b.startMinute == startTime.minute &&
                _isActive(b, ref))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (blocks.isNotEmpty) {
          setId ??= blocks.first.setId;
          blockNumber ??= blocks.first.number;
        }
        indicatorOverride = DataManager.instance.getStudentClassColorAt(
          info.student.id,
          dayIndex,
          startTime,
          setId: setId,
          refDate: ref,
        );
      }
    }
    // 다중 선택 시 각 학생의 setId도 포함해서 넘김
    final studentsWithSetId = (isSelected && selectedCount > 1)
        ? selectedStudents.map((s) {
            String? sSetId;
            int? sNumber;
            if (dayIndex != null && startTime != null) {
              final ref = _refDateFor(startTime);
              final block = DataManager.instance.studentTimeBlocks
                  .where(
                    (b) =>
                        b.studentId == s.student.id &&
                        b.dayIndex == dayIndex &&
                        b.startHour == startTime.hour &&
                        b.startMinute == startTime.minute &&
                        _isActive(b, ref),
                  )
                  .toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
              if (block.isNotEmpty) {
                sSetId = block.first.setId;
                sNumber = block.first.number;
              }
            }
            return {'student': s, 'setId': sSetId, 'number': sNumber};
          }).toList()
        : [
            {'student': info, 'setId': setId, 'number': blockNumber}
          ];
    return Stack(
      children: [
        Builder(builder: (context) {
          final dragData = {
            'type': isClassRegisterMode ? 'register' : 'move',
            'students': studentsWithSetId,
            'student': info,
            'setId': setId,
            'oldDayIndex': dayIndex,
            'oldStartTime': startTime,
            'dayIndex': dayIndex,
            'startTime': startTime,
          };
          // print('[DEBUG][TT] Draggable dragData 준비: type=${dragData['type']}, setId=${dragData['setId']}, oldDayIndex=${dragData['oldDayIndex']}, oldStartTime=${dragData['oldStartTime']}, studentsCount=${(dragData['students'] as List).length});
          final core = LongPressDraggable<Map<String, dynamic>>(
            data: dragData,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            maxSimultaneousDrags: 1,
            hapticFeedbackOnStart: true,
            onDragStarted: () {
              // ✅ 단일 이동에서는 삭제 드롭존을 띄우지 않음(다중 이동에서만 필요)
              if ((studentsWithSetId).length <= 1) return;
              setState(() => _showDeleteZone = true);
            },
            onDraggableCanceled: (_, __) {
              setState(() {
                _showDeleteZone = false;
              });
              if (widget.onExitSelectMode != null) {
                widget.onExitSelectMode!();
              }
            },
            onDragEnd: (_) {
              setState(() {
                _showDeleteZone = false;
              });
            },
            feedback: _buildDragFeedback(selectedStudents, info),
            // ✅ 드래그 중 원본 카드가 투명해지면 스와이프 액션(수정/삭제)이 비쳐 보일 수 있어 입력만 막는다.
            childWhenDragging: AbsorbPointer(
              child: _buildSelectableStudentCard(
                info,
                selected: widget.selectedStudentIds.contains(info.student.id),
                isSelectMode: false,
                highlighted: highlightBorder,
                indicatorColorOverride: indicatorOverride,
                blockNumber: blockNumber,
              ),
            ),
            child: _buildSelectableStudentCard(
              info,
              selected: widget.selectedStudentIds.contains(info.student.id),
              isSelectMode: widget.isSelectMode,
              highlighted: highlightBorder,
              indicatorColorOverride: indicatorOverride,
              blockNumber: blockNumber,
              onTap: onTapCard,
              onToggleSelect: (next) {
                if (widget.onStudentSelectChanged != null) {
                  widget.onStudentSelectChanged!(info.student.id, next);
                }
              },
            ),
          );

          // 좌측 스와이프로 수정/삭제 액션 노출
          final bool canSwipe = !widget.isSelectMode && dayIndex != null && startTime != null;
          if (!canSwipe) return core;

          final DateTime refDate = _cellDateOnlyForDayIndex(dayIndex!);
          final StudentTimeBlock? targetBlock = blockOverride ??
              _findActiveBlockForActions(
                studentId: info.student.id,
                dayIdx: dayIndex!,
                hour: startTime!.hour,
                minute: startTime.minute,
                refDate: refDate,
                setId: setId,
              );
          if (targetBlock == null) return core;

          const double paneW = 140;
          final radius = BorderRadius.circular(12);
          final actionPane = Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Material(
                    color: const Color(0xFF223131),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: () async => _showEditBlockDateRangeDialog(context, targetBlock),
                      borderRadius: BorderRadius.circular(10),
                      splashFactory: NoSplash.splashFactory,
                      highlightColor: Colors.white.withOpacity(0.06),
                      hoverColor: Colors.white.withOpacity(0.03),
                      child: const SizedBox.expand(
                        child: Center(
                          child: Icon(Icons.edit_outlined, color: Color(0xFFEAF2F2), size: 18),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Material(
                    color: const Color(0xFFB74C4C),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: () async => _confirmAndDeleteBlock(context, targetBlock, refDate: refDate),
                      borderRadius: BorderRadius.circular(10),
                      splashFactory: NoSplash.splashFactory,
                      highlightColor: Colors.white.withOpacity(0.08),
                      hoverColor: Colors.white.withOpacity(0.04),
                      child: const SizedBox.expand(
                        child: Center(
                          child: Icon(Icons.delete_outline_rounded, color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );

          return SwipeActionReveal(
            enabled: true,
            actionPaneWidth: paneW,
            borderRadius: radius,
            actionPane: actionPane,
            child: core,
          );
        }),
      ],
    );
  }

  Widget _buildDragFeedback(
      List<StudentWithInfo> selectedStudents, StudentWithInfo mainInfo) {
    final count = selectedStudents.length;
    Widget buildCard(StudentWithInfo s) {
      final classColor =
          DataManager.instance.getStudentClassColor(s.student.id);
      final indicator = classColor ?? Colors.transparent;
      return Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF15171C),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF223131), width: 1),
        ),
        child: Row(
          children: [
            Container(
              width: 5,
              height: 22,
              decoration: BoxDecoration(
                color: indicator,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                s.student.name,
                style: const TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      );
    }

    if (count <= 1) {
      return Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 150,
          height: 56,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(width: 140, child: buildCard(mainInfo)),
          ),
        ),
      );
    }

    final showCount = count >= 4 ? 3 : count;
    final cards = List.generate(showCount, (i) {
      final s = selectedStudents[i];
      final opacity = (0.85 - i * 0.18).clamp(0.3, 1.0);
      return Positioned(
        left: i * 12.0,
        child: Opacity(
          opacity: opacity,
          child: SizedBox(width: 140, child: buildCard(s)),
        ),
      );
    }).toList();

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: 150,
        height: 56,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            ...cards,
            if (count >= 4)
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFF15171C),
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: const Color(0xFF223131), width: 1),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '+$count',
                    style: const TextStyle(
                      color: Color(0xFFEAF2F2),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- 학생카드 리스트(셀 선택/검색 결과) 공통 출력 함수 ---
  Widget _buildStudentCardList(List<StudentWithInfo> students,
      {String? dayTimeLabel}) {
    // 동일 학생 중복 카드 제거 (검색 결과 중복 노출 방지)
    final deduped = {
      for (final s in students) s.student.id: s,
    }.values.toList();

    if (deduped.isEmpty) {
      return const Center(
        child: Text('학생을 검색하거나 셀을 선택하세요.',
            style: TextStyle(color: Colors.white38, fontSize: 16)),
      );
    }
    // 1. 학생별로 해당 시간에 속한 StudentTimeBlock을 찾아 sessionTypeId로 분류
    // 종료된 블록이 섞여 색상/세션이 비는 문제를 막기 위해
    // 선택한 셀의 날짜(refDate) 기준으로 직접 활성 필터링
    final selectedDayIdx = widget.selectedCellDayIndex;
    final selectedStartTime = widget.selectedCellStartTime;
    final DateTime refDate = (() {
      if (selectedStartTime != null) {
        return DateTime(
          selectedStartTime.year,
          selectedStartTime.month,
          selectedStartTime.day,
        );
      }
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day);
    })();
    final allBlocks = DataManager.instance.getStudentTimeBlocksForWeek(refDate);

    bool _isActive(StudentTimeBlock b, DateTime ref) {
      final startDate =
          DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final endDate = b.endDate != null
          ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
          : null;
      return !startDate.isAfter(ref) &&
          (endDate == null || !endDate.isBefore(ref));
    }

    StudentTimeBlock? _pickLatestActiveBlock(String studentId) {
      final ref = refDate;
      final candidates = allBlocks.where((b) {
        final dayOk =
            selectedDayIdx == null ? true : b.dayIndex == selectedDayIdx;
        final timeOk = selectedStartTime == null
            ? true
            : (b.startHour == selectedStartTime?.hour &&
                b.startMinute == selectedStartTime?.minute);
        return b.studentId == studentId && dayOk && timeOk;
      }).toList();
      final active = candidates.where((b) => _isActive(b, ref)).toList();
      if (active.isEmpty) return null;
      // 세션이 있는 활성 블록을 우선, 동일 우선순위는 최신 startDate
      active.sort((a, b) {
        final sessScoreA = (a.sessionTypeId?.isNotEmpty ?? false) ? 1 : 0;
        final sessScoreB = (b.sessionTypeId?.isNotEmpty ?? false) ? 1 : 0;
        if (sessScoreA != sessScoreB) return sessScoreB.compareTo(sessScoreA);
        return b.startDate.compareTo(a.startDate);
      });
      return active.first;
    }

    final Map<String, String?> studentSessionTypeMap = {
      for (var s in deduped)
        s.student.id: (() {
          final block = _pickLatestActiveBlock(s.student.id);
          return block?.sessionTypeId;
        })()
    };
    final noSession = <StudentWithInfo>[];
    final sessionMap = <String, List<StudentWithInfo>>{};
    for (final s in deduped) {
      final sessionId = studentSessionTypeMap[s.student.id];
      if (sessionId == null || sessionId.isEmpty) {
        noSession.add(s);
      } else {
        sessionMap.putIfAbsent(sessionId, () => []).add(s);
      }
    }
    noSession.sort((a, b) => a.student.name.compareTo(b.student.name));
    final classCards = DataManager.instance.classes;
    final sessionOrder = classCards.map((c) => c.id).toList();
    final orderedSessionIds =
        sessionOrder.where((id) => sessionMap.containsKey(id)).toList();
    final unorderedSessionIds =
        sessionMap.keys.where((id) => !sessionOrder.contains(id)).toList();
    final allSessionIds = [...orderedSessionIds, ...unorderedSessionIds];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dayTimeLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 8.0, bottom: 8.0, left: 8.0),
            child: Text(
              dayTimeLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 20),
            ),
          ),
        if (noSession.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: Wrap(
              spacing: 0,
              runSpacing: 6.4,
              children: noSession
                  .map((info) => _buildDraggableStudentCard(
                        info,
                        dayIndex: widget.selectedCellDayIndex,
                        startTime: widget.selectedCellStartTime,
                        cellStudents: students,
                        highlightBorder:
                            (widget.highlightedStudentId ?? '') ==
                                info.student.id,
                        onTapCard: widget.onStudentCardTap == null
                            ? null
                            : () => widget.onStudentCardTap!(
                                  info.student.id,
                                ),
                      ))
                  .toList(),
            ),
          ),
        for (final sessionId in allSessionIds)
          if (sessionMap[sessionId] != null &&
              sessionMap[sessionId]!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 18.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Builder(builder: (context) {
                      final c = classCards.firstWhere(
                        (c) => c.id == sessionId,
                        orElse: () => ClassInfo(
                            id: '',
                            name: '',
                            color: null,
                            description: '',
                            capacity: null),
                      );
                      final String name = c.id.isEmpty ? '수업' : c.name;
                      final Color color = c.color ?? Colors.white70;
                      return Text(
                        name,
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w600,
                            fontSize: 17),
                      );
                    }),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6.4,
                    runSpacing: 6.4,
                    children: (() {
                      final sessionStudents = sessionMap[sessionId]!;
                      sessionStudents.sort(
                          (a, b) => a.student.name.compareTo(b.student.name));
                      return sessionStudents
                          .map((info) => _buildDraggableStudentCard(
                                info,
                                dayIndex: widget.selectedCellDayIndex,
                                startTime: widget.selectedCellStartTime,
                                cellStudents: students,
                                highlightBorder:
                                    (widget.highlightedStudentId ?? '') ==
                                        info.student.id,
                                onTapCard: widget.onStudentCardTap == null
                                    ? null
                                    : () => widget.onStudentCardTap!(
                                          info.student.id,
                                        ),
                              ))
                          .toList();
                    })(),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _buildSelectableStudentCard(
    StudentWithInfo info, {
    bool selected = false,
    Key? key,
    bool isSelectMode = false,
    ValueChanged<bool>? onToggleSelect,
    Color? indicatorColorOverride,
    int? blockNumber,
    bool highlighted = false,
    VoidCallback? onTap,
  }) {
    final nameStyle = const TextStyle(
        color: Color(0xFFEAF2F2), fontSize: 16, fontWeight: FontWeight.w600);
    final schoolStyle = const TextStyle(
        color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500);
    final schoolLabel =
        info.student.school.isNotEmpty ? info.student.school : '';
    // 주어진 override(요일/시간/SET 기준 색상)만 사용, 없으면 투명 처리해 다른 SET 색상 퍼짐을 방지
    final Color? classColor = indicatorColorOverride;
    final Color indicatorColor = classColor ?? Colors.transparent;
    final bool showBorder = selected || highlighted;
    return AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF33A373).withOpacity(0.18)
            : const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(12),
        // ✅ border 폭(=1)을 항상 유지해 하이라이트 시에도 다른 카드들이 "밀리지" 않게 한다.
        border: Border.all(
          color: showBorder ? const Color(0xFF33A373) : Colors.transparent,
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isSelectMode && onToggleSelect != null
              ? () => onToggleSelect(!selected)
              : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 28,
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          info.student.name,
                          style: nameStyle,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      if (blockNumber != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          '$blockNumber',
                          style: schoolStyle,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ],
                  ),
                ),
                if (schoolLabel.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Text(
                    schoolLabel,
                    style: schoolStyle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- 검색 결과를 요일/시간별로 그룹핑해서 보여주는 함수 ---
  Widget _buildGroupedStudentCardsByDayTime(List<StudentWithInfo> students,
      {bool showWeekdayInTimeLabel = false}) {
    // 검색 결과용 캐시: 요일선택 리스트와 동일한 UI이지만 매번 그룹핑/정렬을 방지
    if (showWeekdayInTimeLabel) {
      final rev = DataManager.instance.studentTimeBlocksRevision.value;
      final classRev = DataManager.instance.classesRevision.value;
      final classAssignRev =
          DataManager.instance.classAssignmentsRevision.value;
      final ids = students.map((s) => s.student.id).toList()..sort();
      final key = '$rev|$classRev|$classAssignRev|${ids.join(',')}';
      if (_cachedSearchGroupedKey == key &&
          _cachedSearchGroupedWidget != null) {
        return _cachedSearchGroupedWidget!;
      }
      final built = _buildGroupedStudentCardsByDayTimeInternal(students,
          showWeekdayInTimeLabel: showWeekdayInTimeLabel);
      _cachedSearchGroupedKey = key;
      _cachedSearchGroupedWidget = built;
      return built;
    }
    return _buildGroupedStudentCardsByDayTimeInternal(students,
        showWeekdayInTimeLabel: showWeekdayInTimeLabel);
  }

  Widget _buildGroupedStudentCardsByDayTimeInternal(
      List<StudentWithInfo> students,
      {bool showWeekdayInTimeLabel = false}) {
    // 학생이 속한 “활성” 시간블록을 (요일, 시간)별로 그룹핑
    // ✅ 주 이동(과거/미래)에서도 정확히 보이도록 "현재 보고 있는 주" 범위로 겹치는 블록만 사용한다.
    // - 서버 week-cache + 로컬 변경분 merge 결과를 사용
    final weekStart = _weekMonday(widget.viewDate);
    final blocks = DataManager.instance.getStudentTimeBlocksForWeek(weekStart);

    bool isActiveOn(DateTime day, StudentTimeBlock b) {
      final ref = DateTime(day.year, day.month, day.day);
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final ed = b.endDate == null
          ? null
          : DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day);
      return !sd.isAfter(ref) && (ed == null || !ed.isBefore(ref));
    }
    // Map<(dayIdx, startTime), List<StudentWithInfo>>
    final Map<String, List<StudentWithInfo>> grouped = {};
    // ✅ 성능: 기존은 "학생마다 blocks 전체 스캔"이라 검색 결과가 많으면 O(학생수*블록수)로 느려진다.
    // blocks를 1회 스캔해 studentId -> blocks 를 만들고, 학생 순서대로 그룹에 채워 UI 출력 순서를 유지한다.
    final Set<String> targetStudentIds =
        students.map((s) => s.student.id).toSet();
    final Map<String, List<StudentTimeBlock>> blocksByStudent = {};
    for (final b in blocks) {
      if (!targetStudentIds.contains(b.studentId)) continue;
      if (!(b.number == null || b.number == 1)) continue;
      final occDate = weekStart.add(Duration(days: b.dayIndex));
      if (!isActiveOn(occDate, b)) continue;
      blocksByStudent.putIfAbsent(b.studentId, () => <StudentTimeBlock>[]).add(b);
    }
    for (final student in students) {
      final studentBlocks = blocksByStudent[student.student.id];
      if (studentBlocks == null || studentBlocks.isEmpty) continue;
      for (final block in studentBlocks) {
        final key =
            '${block.dayIndex}-${block.startHour}:${block.startMinute.toString().padLeft(2, '0')}';
        grouped.putIfAbsent(key, () => []).add(student);
      }
    }
    // key를 요일/시간 순으로 정렬
    final sortedKeys = grouped.keys.toList()
      ..sort((a, b) {
        final aDay = int.parse(a.split('-')[0]);
        final aTime = a.split('-')[1];
        final bDay = int.parse(b.split('-')[0]);
        final bTime = b.split('-')[1];
        if (aDay != bDay) return aDay.compareTo(bDay);
        return aTime.compareTo(bTime);
      });
    if (grouped.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 32.0),
        child: Center(
          child: Text('검색된 학생이 시간표에 등록되어 있지 않습니다.',
              style: TextStyle(color: Colors.white38, fontSize: 16)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 0), // 셀선택 리스트와 동일하게 여백 제거
        ...sortedKeys.map((key) {
          final dayIdx = int.parse(key.split('-')[0]);
          final timeStr = key.split('-')[1];
          final hour = int.parse(timeStr.split(':')[0]);
          final min = int.parse(timeStr.split(':')[1]);
          final dayTimeLabel =
              '${_weekdayLabel(dayIdx)} ${hour.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
          final students = grouped[key]!;
          // 검색 결과(showWeekdayInTimeLabel=true)에서는 수업명 라벨을 숨기기 위해 조건부 계산
          String className = '';
          if (!showWeekdayInTimeLabel && students.isNotEmpty) {
            final studentId = students.first.student.id;
            final occDate = weekStart.add(Duration(days: dayIdx));
            final slotCandidates = blocks
                .where((b) =>
                    b.studentId == studentId &&
                    b.dayIndex == dayIdx &&
                    b.startHour == hour &&
                    b.startMinute == min &&
                    isActiveOn(occDate, b))
                .toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            if (slotCandidates.isNotEmpty) {
              final picked = slotCandidates.first;
              if (picked.sessionTypeId != null && picked.sessionTypeId!.isNotEmpty) {
                final classInfo = DataManager.instance.classes.firstWhere(
                  (c) => c.id == picked.sessionTypeId,
                  orElse: () => ClassInfo(
                      id: '',
                      name: '',
                      color: null,
                      description: '',
                      capacity: null),
                );
                className = classInfo.id.isEmpty ? '' : classInfo.name;
              }
            }
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      dayTimeLabel,
                      style: const TextStyle(
                          color: Color(0xFFEAF2F2),
                          fontSize: 21,
                          fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Wrap(
                    spacing: 6.4,
                    runSpacing: 6.4,
                    children: students
                        .map((info) => Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: _buildDraggableStudentCard(info,
                                  dayIndex: dayIdx,
                                  startTime: DateTime(0, 1, 1, hour, min)),
                            ))
                        .toList(),
                  ),
                ),
                if (className.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Text(
                      className,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          );
        }).toList(),
      ],
    );
  }

  Widget _buildCellPanelCached({
    required List<StudentWithInfo> students,
    required int? dayIdx,
    required DateTime? startTime,
    required double maxHeight,
    required bool isSelectMode,
    required Set<String> selectedIds,
    required void Function(String, bool)? onSelectChanged,
    required Map<String, StudentTimeBlock> blockOverrides,
  }) {
    final rev = DataManager.instance.studentTimeBlocksRevision.value;
    final classRev = DataManager.instance.classesRevision.value;
    final classAssignRev = DataManager.instance.classAssignmentsRevision.value;
    final ids = students.map((s) => s.student.id).toList()..sort();
    final highlightId = (widget.highlightedStudentId ?? '').trim();
    final key =
        '$rev|$classRev|$classAssignRev|$dayIdx|${startTime?.hour}:${startTime?.minute}|$isSelectMode|highlight=$highlightId|${ids.join(",")}|${selectedIds.join(",")}';
    if (_cachedCellPanelKey == key && _cachedCellPanelWidget != null) {
      return _cachedCellPanelWidget!;
    }
    final canDrag = dayIdx != null && startTime != null;
    final DateTime? refDateForActions = dayIdx == null ? null : _cellDateOnlyForDayIndex(dayIdx);
    final List<Widget> extras = (canDrag && dayIdx != null && startTime != null)
        ? _specialCardsForCell(dayIdx: dayIdx, startTime: startTime)
        : const <Widget>[];
    final built = TimetableGroupedStudentPanel(
      students: students,
      extraCards: extras.isEmpty ? null : extras,
      dayTimeLabel: _getDayTimeString(dayIdx, startTime),
      maxHeight: maxHeight,
      isSelectMode: isSelectMode,
      selectedStudentIds: selectedIds,
      onStudentSelectChanged: onSelectChanged,
      highlightedStudentId: widget.highlightedStudentId,
      onStudentCardTap: widget.onStudentCardTap,
      enableDrag: canDrag,
      dayIndex: canDrag ? dayIdx : null,
      startTime: canDrag ? startTime : null,
      isClassRegisterMode: isClassRegisterMode,
      onDragStart: () => setState(() => _showDeleteZone = true),
      onDragEnd: () => setState(() => _showDeleteZone = false),
      blockOverrides: blockOverrides,
      refDateForActions: refDateForActions,
      onEditTimeBlock: (ctx, student, block, refDate) async {
        await _showEditBlockDateRangeDialog(ctx, block);
      },
      onDeleteTimeBlock: (ctx, student, block, refDate) async {
        await _confirmAndDeleteBlock(ctx, block, refDate: refDate);
      },
    );
    _cachedCellPanelKey = key;
    _cachedCellPanelWidget = built;
    return built;
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
      _searchResults = DataManager.instance.students.where((student) {
        final nameMatch = student.student.name
            .toLowerCase()
            .contains(_searchQuery.toLowerCase());
        final schoolMatch = student.student.school
            .toLowerCase()
            .contains(_searchQuery.toLowerCase());
        final gradeMatch =
            student.student.grade.toString().contains(_searchQuery);
        return nameMatch || schoolMatch || gradeMatch;
      }).toList();
    });
  }

  void updateSearchQuery(String value) {
    if (_searchQuery == value) return;
    _searchController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _onSearchChanged(value);
  }

  Widget _buildSearchResultPanel() {
    final titleName =
        _searchResults.isNotEmpty ? _searchResults.first.student.name : '검색 결과';
    // 학교/과정/학년 요약
    String schoolLevelLabel = '';
    if (_searchResults.isNotEmpty) {
      final first = _searchResults.first;
      schoolLevelLabel =
          '${first.student.school} · ${_gradeLabelForStudent(first.student.educationLevel, first.student.grade)}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 48,
          width: double.infinity,
          margin: const EdgeInsets.only(
            top: _kStudentPanelHeaderTopMargin,
            bottom: _kStudentPanelHeaderBottomMargin,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: const Color(0xFF223131),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: Text(
                  titleName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
              if (schoolLevelLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  fit: FlexFit.loose,
                  child: Text(
                    schoolLevelLabel,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(15, 10, 12, 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1112),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF223131), width: 1),
            ),
            child: Scrollbar(
              child: SingleChildScrollView(
                primary: true,
                child: _buildGroupedStudentCardsByDayTime(_searchResults,
                    showWeekdayInTimeLabel: true),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --- 셀 클릭 시 검색 내역 초기화 ---
  @override
  void didUpdateWidget(covariant TimetableContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 셀 선택이 바뀌면 검색 내역 초기화
    if ((widget.selectedCellDayIndex != oldWidget.selectedCellDayIndex) ||
        (widget.selectedCellStartTime != oldWidget.selectedCellStartTime)) {
      clearSearch();
    }

    // PERF: 셀 클릭 → 우측 리스트 첫 프레임까지 측정(기본 OFF, 기능 영향 0)
    if (widget.enableCellRenderPerfTrace &&
        widget.onCellRenderPerfFrame != null &&
        widget.cellRenderPerfToken != oldWidget.cellRenderPerfToken &&
        widget.cellRenderPerfStartUs > 0) {
      final token = widget.cellRenderPerfToken;
      dev.Timeline.instantSync('TT cell selection updated', arguments: <String, Object?>{
        'token': token,
        'dayIdx': widget.selectedCellDayIndex ?? -1,
        'hour': widget.selectedCellStartTime?.hour ?? -1,
        'minute': widget.selectedCellStartTime?.minute ?? -1,
      });
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!widget.enableCellRenderPerfTrace) return;
        if (_lastPerfReportedToken == token) return;
        _lastPerfReportedToken = token;
        widget.onCellRenderPerfFrame!(token, DateTime.now().microsecondsSinceEpoch);
      });
    }
  }

  // 수업카드 수정 시 관련 StudentTimeBlock의 session_type_id 일괄 수정
  Future<void> updateSessionTypeIdForClass(
      String oldClassId, String newClassId) async {
    await DataManager.instance.bulkUpdateStudentTimeBlocksSessionTypeIdForClass(
      oldClassId,
      newSessionTypeId: newClassId,
    );
  }

  // 수업카드 삭제 시 관련 StudentTimeBlock의 session_type_id를 null로 초기화
  Future<void> clearSessionTypeIdForClass(String classId) async {
    await DataManager.instance.bulkUpdateStudentTimeBlocksSessionTypeIdForClass(
      classId,
      newSessionTypeId: null,
    );
  }

  // 🔍 고아 sessionTypeId 진단 함수
  Future<void> _diagnoseOrphanedSessionTypeIds() async {
    final allBlocks = DataManager.instance.studentTimeBlocks;
    final existingClassIds =
        DataManager.instance.classes.map((c) => c.id).toSet();

    // 모든 sessionTypeId 수집
    final allSessionTypeIds = allBlocks
        .where((b) => b.sessionTypeId != null && b.sessionTypeId!.isNotEmpty)
        .map((b) => b.sessionTypeId!)
        .toSet();

    // 고아 sessionTypeId 찾기
    final orphanedSessionTypeIds =
        allSessionTypeIds.where((id) => !existingClassIds.contains(id)).toSet();

    // 고아 블록들 찾기
    final orphanedBlocks = allBlocks.where((block) {
      return block.sessionTypeId != null &&
          block.sessionTypeId!.isNotEmpty &&
          !existingClassIds.contains(block.sessionTypeId);
    }).toList();

    // 고아 블록들을 sessionTypeId별로 그룹화
    final groupedOrphans = <String, List<StudentTimeBlock>>{};
    for (final block in orphanedBlocks) {
      final sessionTypeId = block.sessionTypeId!;
      groupedOrphans.putIfAbsent(sessionTypeId, () => []).add(block);
    }
  }

  // 🧹 삭제된 수업의 sessionTypeId를 가진 블록들을 정리하는 유틸리티 함수
  Future<void> cleanupOrphanedSessionTypeIds() async {
    final allBlocks = DataManager.instance.studentTimeBlocks;
    final existingClassIds =
        DataManager.instance.classes.map((c) => c.id).toSet();

    // sessionTypeId가 있지만 해당 수업이 존재하지 않는 블록들 찾기
    final orphanedBlocks = allBlocks.where((block) {
      return block.sessionTypeId != null &&
          block.sessionTypeId!.isNotEmpty &&
          !existingClassIds.contains(block.sessionTypeId);
    }).toList();

    if (orphanedBlocks.isNotEmpty) {
      try {
        // ✅ HOTFIX:
        // 기존 방식(삭제→재추가)은 bulkDeleteStudentTimeBlocks가 end_date를 입력하므로,
        // 간헐적으로 "사용자 조작 없이 블록이 닫히는" 문제를 유발할 수 있다.
        // → end_date를 건드리지 않고, class 연결(session_type_id)만 null로 정리한다.
        final orphanedClassIds = orphanedBlocks
            .map((b) => (b.sessionTypeId ?? '').trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList();
        for (final classId in orphanedClassIds) {
          await DataManager.instance.bulkUpdateStudentTimeBlocksClassIdForClass(
            classId,
            newClassId: null,
          );
        }
      } catch (e, stackTrace) {
        print('[ERROR][cleanupOrphanedSessionTypeIds] 정리 중 오류 발생: $e');
        print('[ERROR][cleanupOrphanedSessionTypeIds] 스택트레이스: $stackTrace');
      }
    }
  }

  // ===== 보강(Replace) 원본 블라인드 맵 =====
  // key: weekNumber|weeklyOrder|sessionTypeId|dayIndex|startMinuteRounded
  Set<String> _makeupOriginalBlindKeysFor(String studentId) {
    final keys = <String>{};
    // DEBUG (quiet)
    // print('[BLIND][map] building keys for student=$studentId');
    // 학생 등록일로 주차 계산
    final registrationDate = () {
      try {
        return DataManager.instance.students
            .firstWhere((s) => s.student.id == studentId)
            .basicInfo
            .registrationDate;
      } catch (_) {
        return null;
      }
    }();
    if (registrationDate == null) return keys;

    bool sameMinute(DateTime a, DateTime b) =>
        a.year == b.year &&
        a.month == b.month &&
        a.day == b.day &&
        a.hour == b.hour &&
        a.minute == b.minute;

    int computeWeekNumber(DateTime d) {
      DateTime toMonday(DateTime x) {
        final offset = x.weekday - DateTime.monday;
        return DateTime(x.year, x.month, x.day)
            .subtract(Duration(days: offset));
      }

      final regMon = toMonday(registrationDate);
      final sesMon = toMonday(d);
      final diff = sesMon.difference(regMon).inDays;
      final weeks = diff >= 0 ? (diff ~/ 7) : 0;
      return weeks + 1;
    }

    // 학생의 timeBlocks (weeklyOrder 추정용)
    final blocks = DataManager.instance.studentTimeBlocks
        .where((b) => b.studentId == studentId)
        .toList();

    int? weeklyOrderFor(DateTime original, String? setId) {
      if (setId != null) {
        try {
          return blocks.firstWhere((b) => b.setId == setId).weeklyOrder;
        } catch (_) {}
      }
      // 시간 근접 set 추정 (±30분)
      final dayIdx = (original.weekday - 1).clamp(0, 6);
      final origMin = original.hour * 60 + original.minute;
      int bestDiff = 1 << 30;
      int? bestOrder;
      for (final b in blocks.where((b) => b.dayIndex == dayIdx)) {
        final start = b.startHour * 60 + b.startMinute;
        final diff = (start - origMin).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestOrder = b.weeklyOrder;
        }
      }
      return bestOrder;
    }

    String keyOf(
        {required int week,
        required int? order,
        required String? sessionTypeId,
        required int dayIdx,
        required int startMin}) {
      final rounded = (startMin / 5).round() * 5; // 5분 단위 라운딩으로 근접 허용
      return '$week|${order ?? -1}|${sessionTypeId ?? 'null'}|$dayIdx|$rounded';
    }

    final overrides =
        DataManager.instance.getSessionOverridesForStudent(studentId);
    for (final ov in overrides) {
      if (ov.status == OverrideStatus.canceled) continue;
      if (ov.overrideType != OverrideType.replace) continue;
      final orig = ov.originalClassDateTime;
      if (orig == null) continue;
      final week = computeWeekNumber(orig);
      final order = weeklyOrderFor(orig, ov.setId);
      final dayIdx = (orig.weekday - 1).clamp(0, 6);
      final startMin = orig.hour * 60 + orig.minute;
      final sessionTypeId = ov.sessionTypeId; // 없을 수 있음
      keys.add(keyOf(
          week: week,
          order: order,
          sessionTypeId: sessionTypeId,
          dayIdx: dayIdx,
          startMin: startMin));
      // print('[BLIND][map] add key week=$week order=$order set=${ov.setId} stId=${sessionTypeId} day=$dayIdx start=$startMin orig=$orig');
    }
    // print('[BLIND][map] total keys=${keys.length}');
    return keys;
  }

  bool _shouldBlindBlock(
      {required String studentId,
      required int weekNumber,
      required int? weeklyOrder,
      required String? sessionTypeId,
      required int dayIdx,
      required int startMin}) {
    // ✅ 학생별 key 셋은 캐시한다(셀 클릭 시 블록마다 재계산 방지)
    final keys = _makeupOriginalBlindKeysCache.putIfAbsent(
        studentId, () => _makeupOriginalBlindKeysFor(studentId));
    final rounded = (startMin / 5).round() * 5;
    final key =
        '$weekNumber|${weeklyOrder ?? -1}|${sessionTypeId ?? 'null'}|$dayIdx|$rounded';
    final hit = keys.contains(key);
    // print('[BLIND][check] week=$weekNumber order=$weeklyOrder stId=$sessionTypeId day=$dayIdx start=$startMin -> rounded=$rounded hit=$hit');
    return hit;
  }
}

// 드롭다운 메뉴 항목 위젯
class _DropdownMenuHoverItem extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DropdownMenuHoverItem(
      {required this.label, required this.selected, required this.onTap});

  @override
  State<_DropdownMenuHoverItem> createState() => _DropdownMenuHoverItemState();
}

class _DropdownMenuHoverItemState extends State<_DropdownMenuHoverItem> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final highlight = _hovered || widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 140,
          height: 40,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          decoration: BoxDecoration(
            color: highlight
                ? const Color(0xFF383838).withOpacity(0.7)
                : Colors.transparent, // 학생등록 다이얼로그와 유사한 하이라이트
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            widget.label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

String _getDayTimeString(int? dayIdx, DateTime? startTime) {
  if (dayIdx == null || startTime == null) return '';
  const days = ['월', '화', '수', '목', '금', '토', '일'];
  final dayStr = (dayIdx >= 0 && dayIdx < days.length) ? days[dayIdx] : '';
  final hour = startTime.hour.toString().padLeft(2, '0');
  final min = startTime.minute.toString().padLeft(2, '0');
  return '$dayStr요일 $hour:$min';
}

// 수업 등록 다이얼로그 (그룹등록 다이얼로그 참고)
class _ClassRegistrationDialog extends StatefulWidget {
  final ClassInfo? editTarget;
  const _ClassRegistrationDialog({this.editTarget});
  @override
  State<_ClassRegistrationDialog> createState() =>
      _ClassRegistrationDialogState();
}

class _ClassRegistrationDialogState extends State<_ClassRegistrationDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _capacityController;
  Color? _selectedColor;
  bool _unlimitedCapacity = false;
  final FocusNode _nameFocusNode = FocusNode();
  bool _blinkName = false;
  bool _forceErrorName = false;
  // 없음 포함 총 24개 색상 (null + 기본 18 + 추가 5, 마지막은 짙은 네이비)
  final List<Color?> _colors = [
    null,
    ...Colors.primaries,
    const Color(0xFF33A373),
    const Color(0xFF9FB3B3),
    const Color(0xFF6B4EFF),
    const Color(0xFFD1A054),
    const Color(0xFF0F1A2D), // 짙은 네이비로 none과 구분
  ];

  @override
  void initState() {
    super.initState();
    _nameController =
        ImeAwareTextEditingController(text: widget.editTarget?.name ?? '');
    _descController = ImeAwareTextEditingController(
        text: widget.editTarget?.description ?? '');
    _capacityController = ImeAwareTextEditingController(
        text: widget.editTarget?.capacity?.toString() ?? '');
    _selectedColor = widget.editTarget?.color;
    _unlimitedCapacity = widget.editTarget?.capacity == null;
    _nameController.addListener(() {
      if (_nameController.text.isNotEmpty) {
        setState(() {
          _forceErrorName = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _capacityController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  Future<void> _triggerBlinkName() async {
    setState(() {
      _blinkName = true;
      _forceErrorName = true;
    });
    _nameFocusNode.requestFocus();
    await Future.delayed(const Duration(milliseconds: 160));
    setState(() {
      _blinkName = false;
    });
  }

  void _handleSave() {
    final name = _nameController.text.trim();
    final desc = _descController.text.trim();
    final capacity = _unlimitedCapacity
        ? null
        : int.tryParse(_capacityController.text.trim());
    if (name.isEmpty) {
      _triggerBlinkName();
      showAppSnackBar(context, '수업명을 입력하세요');
      return;
    }
    Navigator.of(context).pop(ClassInfo(
      id: widget.editTarget?.id ?? const Uuid().v4(),
      name: name,
      capacity: capacity,
      description: desc,
      color: _selectedColor,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0B1112),
      shape: RoundedRectangleBorder(
        borderRadius:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))
                .borderRadius,
        side: const BorderSide(color: Color(0xFF223131)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.editTarget == null ? '수업 등록' : '수업 수정',
                style: const TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 20,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              // 기본 정보
              _buildSectionHeader('기본 정보'),
              TextField(
                controller: _nameController,
                focusNode: _nameFocusNode,
                style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 15),
                decoration: _inputDecoration(
                  label: '수업명',
                  required: true,
                  hint: '예) 수학 A',
                  blink: _blinkName,
                  forceError: _forceErrorName,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _capacityController,
                      enabled: !_unlimitedCapacity,
                      style: const TextStyle(
                          color: Color(0xFFEAF2F2), fontSize: 15),
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration(
                        label: '정원',
                        hint: '숫자 입력',
                        disabled: _unlimitedCapacity,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _unlimitedCapacity,
                        onChanged: (v) =>
                            setState(() => _unlimitedCapacity = v ?? false),
                        checkColor: Colors.white,
                        activeColor: const Color(0xFF33A373),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4)),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      const Text('제한없음',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 14)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descController,
                style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 15),
                maxLines: 2,
                decoration: _inputDecoration(label: '설명', hint: '예) 주 2회 / 개인'),
              ),

              const SizedBox(height: 24),
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              // 색상 설정
              _buildSectionHeader('색상 설정'),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _colors.map((color) {
                  final isSelected = _selectedColor == color;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedColor = color),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: color ?? Colors.transparent,
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFEAF2F2)
                              : const Color(0xFF223131),
                          width: isSelected ? 2.5 : 1.4,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: color == null
                          ? const Center(
                              child: Icon(Icons.close_rounded,
                                  color: Colors.white54, size: 18))
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF9FB3B3),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 16),
                    ),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _handleSave,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF33A373),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(
                      widget.editTarget == null ? '등록' : '수정',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _buildSectionHeader(String title) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12, top: 4),
    child: Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFF33A373),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFEAF2F2),
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );
}

InputDecoration _inputDecoration({
  required String label,
  String? hint,
  bool disabled = false,
  bool required = false,
  bool blink = false,
  bool forceError = false,
}) {
  final baseColor = const Color(0xFF3A3F44).withOpacity(0.6);
  final errorColor = const Color(0xFFF04747);
  final isError = blink || forceError;
  final borderColor = isError ? errorColor : baseColor;
  return InputDecoration(
    labelText: required ? '$label *' : label,
    labelStyle: TextStyle(
        color: isError ? errorColor : const Color(0xFF9FB3B3), fontSize: 14),
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
    filled: true,
    fillColor: disabled
        ? const Color(0xFF15171C).withOpacity(0.6)
        : const Color(0xFF15171C),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: borderColor),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide:
          BorderSide(color: isError ? errorColor : const Color(0xFF33A373)),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: borderColor),
    ),
  );
}

// 수업카드 위젯 (그룹카드 스타일 참고)
class _ClassCard extends StatefulWidget {
  final ClassInfo classInfo;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final int reorderIndex;
  final String? registrationModeType;
  final int? studentCountOverride;
  final DateTime refDate;
  final bool enableActions;
  final bool showDragHandle;
  final VoidCallback? onFilterToggle;
  final bool isFiltered;
  const _ClassCard({
    Key? key,
    required this.classInfo,
    required this.onEdit,
    required this.onDelete,
    required this.reorderIndex,
    this.registrationModeType,
    this.studentCountOverride,
    required this.refDate,
    this.enableActions = true,
    this.showDragHandle = true,
    this.onFilterToggle,
    this.isFiltered = false,
  }) : super(key: key);
  @override
  State<_ClassCard> createState() => _ClassCardState();
}

class _ClassCardState extends State<_ClassCard> {
  bool _isHovering = false;

  Future<void> _handleStudentDrop(Map<String, dynamic> data) async {
    debugPrint(
        '[TT][class-drop][handle] class=${widget.classInfo.id} keys=${data.keys.toList()} type=${data['type']} hasStudentsList=${data['students'] is List}');
    // 다중이동: students 리스트가 있으면 병렬 처리
    final students = data['students'] as List<dynamic>?;
    if (students != null && students.isNotEmpty) {
      for (final entry in students) {
        final studentWithInfo = entry['student'] as StudentWithInfo?;
        final setId = entry['setId'] as String?;
        debugPrint(
            '[TT][class-drop][multi] class=${widget.classInfo.id} sid=${studentWithInfo?.student.id} setId=$setId oldDay=${data['oldDayIndex']} oldTime=${data['oldStartTime']}');
        if (studentWithInfo == null || setId == null) continue; // setId 없으면 스킵
        await _registerSingleStudent(studentWithInfo, setId: setId);
      }
      return;
    }
    // 기존 단일 등록 로직 (아래 함수로 분리)
    final studentWithInfo = data['student'] as StudentWithInfo?;
    String? setId = data['setId'] as String?;
    if (studentWithInfo == null) return;
    if (setId == null) {
      final oldDayIndex = data['oldDayIndex'] as int?;
      final oldStartTime = data['oldStartTime'] as DateTime?;
      final fallback = DataManager.instance.studentTimeBlocks.firstWhere(
        (b) =>
            b.studentId == studentWithInfo.student.id &&
            b.dayIndex == oldDayIndex &&
            b.startHour == oldStartTime?.hour &&
            b.startMinute == oldStartTime?.minute,
        orElse: () => StudentTimeBlock(
            id: '',
            studentId: '',
            dayIndex: -1,
            startHour: 0,
            startMinute: 0,
            duration: Duration.zero,
            createdAt: DateTime(0),
            startDate: DateTime(0),
            setId: null),
      );
      setId = fallback.setId;
    }
    debugPrint(
        '[TT][class-drop][single] class=${widget.classInfo.id} sid=${studentWithInfo.student.id} setId=$setId oldDay=${data['oldDayIndex']} oldTime=${data['oldStartTime']}');
    if (setId == null) return;
    await _registerSingleStudent(studentWithInfo, setId: setId);
    // await DataManager.instance.loadStudentTimeBlocks(); // 전체 reload 제거
    // print('[DEBUG][_handleStudentDrop] 단일 등록 완료: ${studentWithInfo.student.name}');
  }

  // 단일 학생 등록 로직 분리
  Future<void> _registerSingleStudent(StudentWithInfo studentWithInfo,
      {String? setId}) async {
    // setId가 확정되지 않은 경우 스킵
    if (setId == null) return;
    final bool isDefaultClass = widget.classInfo.id == '__default_class__';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final beforeLocal =
        List<StudentTimeBlock>.from(DataManager.instance.studentTimeBlocks);
    bool isOngoingOrFuture(StudentTimeBlock b) {
      final end = b.endDate != null
          ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
          : null;
      return end == null || !end.isBefore(today);
    }

    // 해당 set의 모든 블록을 한 번에 갱신(기존 모두 닫고 새 블록들을 한 번에 재생성)
    final allSetBlocks = DataManager.instance.studentTimeBlocks
        .where((b) =>
            b.studentId == studentWithInfo.student.id && b.setId == setId)
        .toList();
    final activeOrFutureBlocks = allSetBlocks.where(isOngoingOrFuture).toList();
    final blocksToUse =
        activeOrFutureBlocks.isNotEmpty ? activeOrFutureBlocks : allSetBlocks;
    if (blocksToUse.isEmpty) {
      print(
          '[TT][class-assign-bulk] skip: no blocks for set=$setId student=${studentWithInfo.student.id}');
      return;
    }

    // 기본 수업이면 sessionTypeId=null, 아니면 target class id로 일괄 설정
    final targetSession = isDefaultClass ? null : widget.classInfo.id;
    // 오늘 날짜 기준으로 새롭게 생성할 블록 목록
    final List<StudentTimeBlock> newBlocks = blocksToUse.map((b) {
      return StudentTimeBlock(
        id: const Uuid().v4(),
        studentId: b.studentId,
        dayIndex: b.dayIndex,
        startHour: b.startHour,
        startMinute: b.startMinute,
        duration: b.duration,
        createdAt: DateTime.now(),
        // 닫힌 시점 이후부터 새 수업으로 적용되도록 시작일은 오늘로 갱신
        startDate: today,
        endDate: null,
        setId: b.setId,
        number: b.number,
        sessionTypeId: targetSession,
        weeklyOrder: b.weeklyOrder,
      );
    }).toList();

    final beforeDump = blocksToUse
        .map((b) =>
            '${b.id}|sess=${b.sessionTypeId}|sd=${b.startDate.toIso8601String().split("T").first}|ed=${b.endDate?.toIso8601String().split("T").first ?? 'null'}')
        .join(',');
    print(
        '[TT][class-assign-bulk] class=${widget.classInfo.id} student=${studentWithInfo.student.id} set=$setId before=[$beforeDump] newSess=$targetSession count=${newBlocks.length} today=$today');

    final idsToClose = blocksToUse.map((b) => b.id).toList();
    try {
      // 1) 기존 set 블록 모두 end_date 처리 (즉시 반영, publish는 bulkAdd에서 처리)
      //    planned 재생성은 삭제-추가 연속 작업 동안 비활성화(skipPlannedRegen: true)하여 "활성 블록 없음" 오류를 피함
      await DataManager.instance.bulkDeleteStudentTimeBlocks(
        idsToClose,
        immediate: true,
        publish: false,
        skipPlannedRegen: true,
      );
      // 1.5) 낙관적 UI 반영: 닫힌 블록 제거 + 새 블록 추가 후 바로 퍼블리시
      final others = DataManager.instance.studentTimeBlocks
          .where((b) => !idsToClose.contains(b.id))
          .toList();
      final optimistic = [...others, ...newBlocks];
      print(
          '[TT][class-assign-bulk][optimistic] set=$setId student=${studentWithInfo.student.id} add=${newBlocks.length} close=${idsToClose.length}');
      DataManager.instance
          .applyStudentTimeBlocksOptimistic(optimistic, refDate: today);
      // 2) 새 블록 일괄 추가 (즉시 publish)
      await DataManager.instance.bulkAddStudentTimeBlocks(
        newBlocks,
        immediate: true,
        injectLocal: false,
        skipOverlapCheck:
            true, // 낙관적 반영으로 이미 로컬에 들어간 블록과의 중복 검사를 건너뛰어 서버 반영 막힘 방지
      );
      print(
          '[TT][class-assign-bulk][done] set=$setId student=${studentWithInfo.student.id} add=${newBlocks.length}');
    } catch (e, st) {
      print(
          '[TT][class-assign-bulk][error] set=$setId student=${studentWithInfo.student.id} err=$e\n$st');
      // 실패 시 로컬 상태 롤백
      DataManager.instance
          .applyStudentTimeBlocksOptimistic(beforeLocal, refDate: today);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.classInfo;
    final bool isDefaultClass = c.id == '__default_class__';
    final int studentCount = widget.studentCountOverride ??
        DataManager.instance.getStudentCountForClass(widget.classInfo.id, refDate: widget.refDate);
    // print('[DEBUG][_ClassCard.build] 전체 studentTimeBlocks=' + DataManager.instance.studentTimeBlocks.map((b) => '${b.studentId}:${b.sessionTypeId}').toList().toString());

    Widget buildCardBody() {
      return DragTarget<Map<String, dynamic>>(
      onWillAccept: (data) {
        // print('[DEBUG][DragTarget] onWillAccept: data= [33m$data [0m');
        if (data == null) return false;
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        bool isOngoingOrFuture(StudentTimeBlock b) {
          final end = b.endDate != null
              ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
              : null;
          return end == null || !end.isBefore(today);
        }

        debugPrint(
            '[TT][class-drop][will] class=${widget.classInfo.id} keys=${data.keys.toList()} type=${data['type']}'
            ' setId=${data['setId']} oldDay=${data['oldDayIndex']} oldTime=${data['oldStartTime']} studentsLen=${(data['students'] as List?)?.length}');
        final isMulti = data['students'] is List;
        if (isMulti) {
          final entries =
              (data['students'] as List).cast<Map<String, dynamic>>();
          // print('[DEBUG][onWillAccept] entries=$entries');
          for (final entry in entries) {
            final student = entry['student'] as StudentWithInfo?;
            String? setId = entry['setId'] as String?;
            if (student != null && setId == null) {
              final oldDayIndex = data['oldDayIndex'] as int?;
              final oldStartTime = data['oldStartTime'] as DateTime?;
              final fallback =
                  DataManager.instance.studentTimeBlocks.firstWhere(
                (b) =>
                    b.studentId == student.student.id &&
                    b.dayIndex == oldDayIndex &&
                    b.startHour == oldStartTime?.hour &&
                    b.startMinute == oldStartTime?.minute,
                orElse: () => StudentTimeBlock(
                    id: '',
                    studentId: '',
                    dayIndex: -1,
                    startHour: 0,
                    startMinute: 0,
                    duration: Duration.zero,
                    createdAt: DateTime(0),
                    startDate: DateTime(0),
                    setId: null),
              );
              setId = fallback.setId;
            }
            if (student == null || setId == null) return false;
            final blocks = (isDefaultClass
                    ? DataManager.instance.studentTimeBlocks
                        .where((b) => b.sessionTypeId == null)
                    : DataManager.instance.studentTimeBlocks
                        .where((b) => b.sessionTypeId == widget.classInfo.id))
                .where(isOngoingOrFuture)
                .toList();
            final alreadyRegistered = blocks.any(
                (b) => b.studentId == student.student.id && b.setId == setId);
            // print('[DEBUG][onWillAccept] alreadyRegistered=$alreadyRegistered for studentId=${student?.student.id}, setId=$setId');
            if (alreadyRegistered) return false;
          }
          return true;
        } else {
          final student = data['student'] as StudentWithInfo?;
          String? setId = data['setId'] as String?;
          // setId 누락 시 기존 블록에서 찾기(드롭 거부 방지)
          if (student != null && setId == null) {
            final oldDayIndex = data['oldDayIndex'] as int?;
            final oldStartTime = data['oldStartTime'] as DateTime?;
            final fallback = DataManager.instance.studentTimeBlocks.firstWhere(
              (b) =>
                  b.studentId == student.student.id &&
                  b.dayIndex == oldDayIndex &&
                  b.startHour == oldStartTime?.hour &&
                  b.startMinute == oldStartTime?.minute,
              orElse: () => StudentTimeBlock(
                  id: '',
                  studentId: '',
                  dayIndex: -1,
                  startHour: 0,
                  startMinute: 0,
                  duration: Duration.zero,
                  createdAt: DateTime(0),
                  startDate: DateTime(0),
                  setId: null),
            );
            setId = fallback.setId;
          }
          if (student == null || setId == null) return false;
          final blocks = (isDefaultClass
                  ? DataManager.instance.studentTimeBlocks
                      .where((b) => b.sessionTypeId == null)
                  : DataManager.instance.studentTimeBlocks
                      .where((b) => b.sessionTypeId == widget.classInfo.id))
              .where(isOngoingOrFuture)
              .toList();
          final alreadyRegistered = blocks.any(
              (b) => b.studentId == student.student.id && b.setId == setId);
          // print('[DEBUG][onWillAccept] (단일) studentId=${student.student.id}, setId=$setId, alreadyRegistered=$alreadyRegistered');
          if (alreadyRegistered) return false;
          return true;
        }
      },
      onAccept: (data) async {
        // print('[DEBUG][DragTarget] onAccept: data= [32m$data [0m');
        debugPrint(
            '[TT][class-drop][accept] class=${widget.classInfo.id} type=${data['type']}'
            ' setId=${data['setId']} oldDay=${data['oldDayIndex']} oldTime=${data['oldStartTime']} hasStudentsList=${data['students'] is List}');
        setState(() => _isHovering = false);
        await _handleStudentDrop(data);
      },
      onMove: (_) {
        // print('[DEBUG][DragTarget] onMove');
        setState(() => _isHovering = true);
      },
      onLeave: (_) {
        // print('[DEBUG][DragTarget] onLeave');
        setState(() => _isHovering = false);
      },
      builder: (context, candidateData, rejectedData) {
        // print('[DEBUG][DragTarget] builder: candidateData=$candidateData, rejectedData=$rejectedData, _isHovering=$_isHovering');
        final bool highlight = _isHovering || widget.isFiltered;
        final Color borderColor = highlight
            ? (c.color ?? const Color(0xFF223131))
            : Colors.transparent;
        final Color indicatorColor = c.color ?? const Color(0xFF223131);
        // class-move 드래그는 별도 UX로 다룰 예정(현재: 리스트 편집 UX 우선)
        final cardBody = Container(
          key: widget.key,
          decoration: BoxDecoration(
            color: const Color(0xFF15171C),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 2),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 10,
                        height: 36,
                        decoration: BoxDecoration(
                          color: indicatorColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: c.description.isNotEmpty
                              ? MainAxisAlignment.start
                              : MainAxisAlignment.center,
                          children: [
                            Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFEAF2F2),
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            c.description.isNotEmpty
                                ? Text(
                                    c.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        c.capacity == null
                            ? '$studentCount명'
                            : '$studentCount/${c.capacity}명',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        final baseBody = widget.onFilterToggle != null
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onFilterToggle,
                child: cardBody,
              )
            : cardBody;

        if (!widget.enableActions) {
          return baseBody;
        }

        const double paneW = 140;
        final radius = BorderRadius.circular(12);
        final actionPane = Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Material(
                  color: const Color(0xFF223131),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    onTap: widget.onEdit,
                    borderRadius: BorderRadius.circular(10),
                    splashFactory: NoSplash.splashFactory,
                    highlightColor: Colors.white.withOpacity(0.06),
                    hoverColor: Colors.white.withOpacity(0.03),
                    child: const SizedBox.expand(
                      child: Center(
                        child: Icon(Icons.edit_outlined, color: Color(0xFFEAF2F2), size: 18),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Material(
                  color: const Color(0xFFB74C4C),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    onTap: widget.onDelete,
                    borderRadius: BorderRadius.circular(10),
                    splashFactory: NoSplash.splashFactory,
                    highlightColor: Colors.white.withOpacity(0.08),
                    hoverColor: Colors.white.withOpacity(0.04),
                    child: const SizedBox.expand(
                      child: Center(
                        child: Icon(Icons.delete_outline_rounded, color: Colors.white, size: 18),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

        return SwipeActionReveal(
          enabled: true,
          actionPaneWidth: paneW,
          borderRadius: radius,
          actionPane: actionPane,
          child: baseBody,
        );
      },
    );
    }

    final card = buildCardBody();

    // class-move: 선택된 수업만 활성화 (스와이프 액션과의 충돌 방지를 위해 LongPress로 시작)
    if (widget.isFiltered && !isDefaultClass) {
      // ✅ 성능 최적화:
      // class-move payload(블록 목록)은 "선택된 수업"에서만 필요하다.
      // 기존처럼 모든 수업카드 빌드마다 전체 블록을 map/toList로 변환하면 셀 클릭마다 1s+ 지연이 생길 수 있다.
      final classBlocks = DataManager.instance.studentTimeBlocks
          .where((b) => b.sessionTypeId == c.id)
          .toList();
      if (classBlocks.isEmpty) return card;
      final dataPayload = {
        'type': 'class-move',
        'classId': c.id,
        'blocks': classBlocks
            .map((b) => {
                  'id': b.id,
                  'studentId': b.studentId,
                  'dayIndex': b.dayIndex,
                  'startHour': b.startHour,
                  'startMinute': b.startMinute,
                  'duration': b.duration.inMinutes,
                  'setId': b.setId,
                  'number': b.number,
                  'sessionTypeId': b.sessionTypeId,
                })
            .toList(),
      };
      final Color indicatorColor = c.color ?? const Color(0xFF223131);
      final feedback = Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.9,
          child: SizedBox(
            width: 220,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF15171C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: (c.color ?? const Color(0xFF223131)).withOpacity(0.55), width: 2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 10,
                    height: 32,
                    decoration: BoxDecoration(
                      color: indicatorColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFEAF2F2),
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          c.capacity == null ? '학생 ${studentCount}명' : '학생 ${studentCount}/${c.capacity}명',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      return LongPressDraggable<Map<String, dynamic>>(
        data: dataPayload,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        maxSimultaneousDrags: 1,
        hapticFeedbackOnStart: true,
        feedback: feedback,
        childWhenDragging: Opacity(opacity: 0.35, child: card),
        child: card,
      );
    }

    return card;
  }
}
