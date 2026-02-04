import 'package:flutter/material.dart';
import '../../models/group_info.dart';
import '../../models/operating_hours.dart';
import '../../models/student.dart';
import '../../services/data_manager.dart';
import '../../widgets/student_search_dialog.dart';
import '../../widgets/group_schedule_dialog.dart';
import '../../models/group_schedule.dart';
import '../../models/class_info.dart';
import 'components/timetable_header.dart';
import 'views/classes_view.dart';
import 'views/makeup_view.dart';
import 'views/schedule_view.dart';
import '../../models/student_time_block.dart';
import 'package:uuid/uuid.dart';
import '../../models/education_level.dart';
import 'package:morphable_shape/morphable_shape.dart';
import 'package:dimension/dimension.dart';
import 'components/timetable_content_view.dart';
import '../../widgets/app_snackbar.dart';
import 'package:flutter/services.dart';
import 'components/self_study_registration_view.dart';
import '../../models/self_study_time_block.dart';
import 'package:collection/collection.dart'; // Added for firstWhereOrNull
import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/schedule_store.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'components/timetable_top_bar.dart';
import 'components/timetable_search_field.dart';
import '../consult/consult_notes_screen.dart';
import '../../services/consult_note_controller.dart';
import '../../widgets/dark_panel_route.dart';
import '../../widgets/dialog_tokens.dart';
import 'dart:developer' as dev;

// 등록모드/드래그 선택은 이벤트가 매우 자주 발생한다.
// DEBUG 로그(특히 큰 리스트 toJson 출력)는 UI 스레드를 심하게 막아 렉/입력지연의 주 원인이 되므로 기본 OFF.
const bool _kRegistrationPerfDebug = false;
// PERF: 셀 클릭 → 우측 리스트 첫 프레임까지 측정(DevTools Timeline에서 확인)
// - 기본 OFF (기능 영향 0)
// - 켜려면: flutter run ... --dart-define=TT_CELL_PERF=true
const bool _kCellRenderPerfTrace =
    bool.fromEnvironment('TT_CELL_PERF', defaultValue: false);

enum TimetableViewType {
  classes,    // 수업
  schedule;   // 일정

  String get name {
    switch (this) {
      case TimetableViewType.classes:
        return '수업';
      case TimetableViewType.schedule:
        return '일정';
    }
  }
}

class MemoItem {
  final String id;
  final String original;
  final String summary;
  const MemoItem({required this.id, required this.original, required this.summary});
  MemoItem copyWith({String? id, String? original, String? summary}) => MemoItem(
    id: id ?? this.id,
    original: original ?? this.original,
    summary: summary ?? this.summary,
  );
}

class TimetableScreen extends StatefulWidget {
  const TimetableScreen({Key? key}) : super(key: key);

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _BlockRange {
  final DateTime start;
  final DateTime? end;
  _BlockRange({required this.start, this.end});
}

class _TimetableScreenState extends State<TimetableScreen> {
  DateTime _selectedDate = DateTime.now();
  List<GroupInfo> _groups = [];
  TimetableViewType _viewType = TimetableViewType.classes;
  List<OperatingHours> _operatingHours = [];
  final MenuController _menuController = MenuController();
  int? _selectedDayIndex = null;
  int? _selectedStartTimeHour;
  int? _selectedStartTimeMinute;
  DateTime? _selectedDayDate; // 요일 클릭 시 해당 날짜 (주 기준)
  bool _isStudentRegistrationMode = false;
  bool _isClassRegistrationMode = false;
  String _registrationButtonText = '등록';
  GroupInfo? _selectedGroup;
  GroupSchedule? _currentGroupSchedule;
  // SplitButton 관련 상태 추가
  String _splitButtonSelected = '학생';
  bool _isDropdownOpen = false;
  int _segmentIndex = 0; // 0: 모두, 1: 학년, 2: 학교, 3: 그룹
  // 클래스 멤버에 선택된 학생 상태 추가
  StudentWithInfo? _selectedStudentWithInfo; // 추가: 학생+부가정보 통합 객체
  // 학생 연속 등록을 위한 상태 변수 추가

  final ScrollController _timetableScrollController = ScrollController();
  bool _hasScrolledToCurrentTime = false;
  bool _hasScrolledOnTabClick = false; // 탭 클릭 시 스크롤 플래그 추가
  // 셀 선택 시 학생 리스트 상태 추가
  // 학생 리스트는 timetable_content_view.dart에서 계산
  int? _selectedCellDayIndex; // 셀 선택시 요일 인덱스
  // PERF: 셀 선택 → 우측 패널 렌더까지 측정용 토큰/타임스탬프
  int _cellRenderPerfToken = 0;
  int _cellRenderPerfStartUs = 0;
  final Map<int, dev.TimelineTask> _cellRenderPerfTasks = <int, dev.TimelineTask>{};
  final Map<int, int> _cellRenderPerfStartByToken = <int, int>{};
  final FocusNode _focusNode = FocusNode();
  // 필터 chips 상태
  Set<String> _selectedEducationLevels = {};
  Set<String> _selectedGrades = {};
  Set<String> _selectedSchools = {};
  Set<String> _selectedGroups = {};
  Set<String> _selectedClasses = {}; // 수업별 필터링 추가
  // 실제 적용된 필터 상태
  Map<String, Set<String>>? _activeFilter;
  // TimetableContentView의 검색 리셋 메서드에 접근하기 위한 key
  final GlobalKey<TimetableContentViewState> _contentViewKey = GlobalKey<TimetableContentViewState>();
  // 선택 모드 및 선택 학생 상태 추가
  bool _isSelectMode = false;
  Set<String> _selectedStudentIds = {};
  // ✅ 셀 선택 학생 리스트에서 학생 카드 클릭 시, 해당 학생만 시간표에 표시하는 "주차 필터"
  String? _weekStudentFilterId;
  // 자습 등록 모드 상태
  bool _isSelfStudyRegistrationMode = false;
  StudentWithInfo? _selectedSelfStudyStudent;
  // 자동종료 제거: 종료는 ESC/우클릭으로만 처리(커밋)
  final GlobalKey _registerDropdownKey = GlobalKey();
  OverlayEntry? _registerDropdownOverlay;
  final TextEditingController _headerSearchController = TextEditingController();

  void _beginCellRenderPerfTrace({
    required int dayIdx,
    required DateTime startTime,
  }) {
    if (!_kCellRenderPerfTrace) return;
    final token = _cellRenderPerfToken + 1;
    final startUs = DateTime.now().microsecondsSinceEpoch;
    _cellRenderPerfToken = token;
    _cellRenderPerfStartUs = startUs;

    final task = dev.TimelineTask(filterKey: 'timetable');
    task.start('TT cell→list first frame', arguments: <String, Object?>{
      'token': token,
      'dayIdx': dayIdx,
      'hour': startTime.hour,
      'minute': startTime.minute,
      'selectedDate': _selectedDate.toIso8601String(),
      'viewType': _viewType.name,
    });
    _cellRenderPerfTasks[token] = task;
    _cellRenderPerfStartByToken[token] = startUs;
  }

  void _finishCellRenderPerfTrace(int token, int endUs) {
    if (!_kCellRenderPerfTrace) return;
    final task = _cellRenderPerfTasks.remove(token);
    final startUs = _cellRenderPerfStartByToken.remove(token);
    if (task == null) return;
    final durMs = (startUs == null) ? null : (endUs - startUs) / 1000.0;
    task.finish(arguments: <String, Object?>{
      'token': token,
      if (durMs != null) 'dur_ms': durMs,
    });
  }

  void _toggleWeekStudentFilter(String studentId) {
    final id = studentId.trim();
    if (id.isEmpty) return;
    setState(() {
      _weekStudentFilterId = (_weekStudentFilterId == id) ? null : id;
    });
  }

  Future<void> _openInquiryNote(String noteId) async {
    final id = noteId.trim();
    if (id.isEmpty) return;
    // 문의 노트 화면이 열려있으면 "노트 전환"만 요청한다.
    ConsultNoteController.instance.requestOpen(id);
    if (ConsultNoteController.instance.isScreenOpen) return;
    try {
      final nav = Navigator.of(context, rootNavigator: true);
      await nav.push(DarkPanelRoute<void>(child: const ConsultNotesScreen()));
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, '문의 노트를 열 수 없습니다.', useRoot: true);
      }
    }
  }

  Future<_BlockRange?> _pickBlockEffectiveRange(BuildContext context) async {
    final today = DateTime.now();
    String _pad(int v) => v.toString().padLeft(2, '0');
    DateTime startDate = DateTime(today.year, today.month, today.day);
    DateTime endDate = startDate;
    bool hasEnd = false;
    final green = const Color(0xFF66BB6A);

    final startYearC = TextEditingController(text: startDate.year.toString());
    final startMonthC = TextEditingController(text: _pad(startDate.month));
    final startDayC = TextEditingController(text: _pad(startDate.day));
    final endYearC = TextEditingController(text: endDate.year.toString());
    final endMonthC = TextEditingController(text: _pad(endDate.month));
    final endDayC = TextEditingController(text: _pad(endDate.day));
    final startYearFocus = FocusNode();
    final startMonthFocus = FocusNode();
    final startDayFocus = FocusNode();
    final endYearFocus = FocusNode();
    final endMonthFocus = FocusNode();
    final endDayFocus = FocusNode();

    void _syncControllers() {
      startYearC.text = startDate.year.toString();
      startMonthC.text = _pad(startDate.month);
      startDayC.text = _pad(startDate.day);
      endYearC.text = endDate.year.toString();
      endMonthC.text = _pad(endDate.month);
      endDayC.text = _pad(endDate.day);
    }

    void _applyFromPicker(bool isStart, DateTime d, void Function(void Function()) setState) {
      setState(() {
        if (isStart) {
          startDate = DateTime(d.year, d.month, d.day);
          if (!hasEnd) endDate = startDate;
        } else {
          endDate = DateTime(d.year, d.month, d.day);
        }
        _syncControllers();
      });
    }

    Future<void> _pickDate(bool isStart, void Function(void Function()) setState) async {
      final initial = isStart ? startDate : endDate;
      final picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        builder: (ctx, child) {
          return Theme(
            data: Theme.of(ctx).copyWith(
              colorScheme: ColorScheme.dark(
                primary: green,
                onPrimary: Colors.white,
                surface: Color(0xFF0B1112),
                onSurface: Colors.white,
              ),
              dialogBackgroundColor: const Color(0xFF0B1112),
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
      );
      if (picked != null) {
        _applyFromPicker(isStart, picked, setState);
      }
    }

    InputDecoration _decoration(String label, {String? suffix}) => InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 12),
          suffixText: suffix,
          suffixStyle: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 12),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: Color(0xFF223131)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: green),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        );

    Widget _dateFields({
      required bool isStart,
      required void Function(void Function()) setState,
    }) {
      final date = isStart ? startDate : endDate;
      final yController = isStart ? startYearC : endYearC;
      final mController = isStart ? startMonthC : endMonthC;
      final dController = isStart ? startDayC : endDayC;
      final yFocus = isStart ? startYearFocus : endYearFocus;
      final mFocus = isStart ? startMonthFocus : endMonthFocus;
      final dFocus = isStart ? startDayFocus : endDayFocus;
      return Row(
        children: [
          Expanded(
            child: TextField(
              keyboardType: TextInputType.number,
              focusNode: yFocus,
              controller: yController,
              style: const TextStyle(color: Color(0xFFEAF2F2)),
              decoration: _decoration(isStart ? '시작 년도' : '종료 년도', suffix: '년'),
              onChanged: (v) {
                final year = int.tryParse(v);
                if (year != null && year > 0) {
                  if (isStart) {
                    startDate = DateTime(year, startDate.month, startDate.day);
                    if (!hasEnd) endDate = startDate;
                  } else {
                    endDate = DateTime(year, endDate.month, endDate.day);
                  }
                }
              },
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: TextField(
              keyboardType: TextInputType.number,
              focusNode: mFocus,
              controller: mController,
              style: const TextStyle(color: Color(0xFFEAF2F2)),
              decoration: _decoration('월', suffix: '월'),
              onChanged: (v) {
                final month = int.tryParse(v);
                if (month != null && month >= 1 && month <= 12) {
                  if (isStart) {
                    startDate = DateTime(startDate.year, month, startDate.day);
                    if (!hasEnd) endDate = startDate;
                  } else {
                    endDate = DateTime(endDate.year, month, endDate.day);
                  }
                }
              },
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: TextField(
              keyboardType: TextInputType.number,
              focusNode: dFocus,
              controller: dController,
              style: const TextStyle(color: Color(0xFFEAF2F2)),
              decoration: _decoration('일', suffix: '일'),
              onChanged: (v) {
                final day = int.tryParse(v);
                if (day != null && day >= 1 && day <= 31) {
                  if (isStart) {
                    startDate = DateTime(startDate.year, startDate.month, day);
                    if (!hasEnd) endDate = startDate;
                  } else {
                    endDate = DateTime(endDate.year, endDate.month, day);
                  }
                }
              },
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => _pickDate(isStart, setState),
            icon: const Icon(Icons.calendar_today, color: Color(0xFFEAF2F2), size: 18),
            splashRadius: 18,
          ),
        ],
      );
    }

    return showDialog<_BlockRange>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Color(0xFF223131)),
              ),
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              title: const Text('효력 기간 설정', style: TextStyle(color: Color(0xFFEAF2F2), fontSize: 18, fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(color: Color(0xFF223131), height: 1),
                  const SizedBox(height: 12),
                  Theme(
                    data: Theme.of(context).copyWith(
                      splashFactory: NoSplash.splashFactory,
                      highlightColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                      focusColor: Colors.transparent,
                    ),
                    child: Column(
                      children: [
                        RadioListTile<bool>(
                          value: false,
                          groupValue: hasEnd,
                          onChanged: (v) => setState(() {
                            hasEnd = v ?? false;
                            if (!hasEnd) endDate = startDate;
                            _syncControllers();
                          }),
                          title: const Text('종료기간 없음', style: TextStyle(color: Color(0xFFEAF2F2))),
                          activeColor: green,
                          enableFeedback: false,
                        ),
                        RadioListTile<bool>(
                          value: true,
                          groupValue: hasEnd,
                          onChanged: (v) => setState(() {
                            hasEnd = v ?? true;
                            _syncControllers();
                          }),
                          title: const Text('종료기간 있음', style: TextStyle(color: Color(0xFFEAF2F2))),
                          activeColor: green,
                          enableFeedback: false,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('시작일', style: TextStyle(color: Color(0xFFEAF2F2), fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  _dateFields(isStart: true, setState: setState),
                  if (hasEnd) ...[
                    const SizedBox(height: 16),
                    const Text('종료일', style: TextStyle(color: Color(0xFFEAF2F2), fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    _dateFields(isStart: false, setState: setState),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소', style: TextStyle(color: Color(0xFFEAF2F2))),
                ),
                TextButton(
                  onPressed: () {
                    if (!hasEnd) {
                      Navigator.of(context).pop(_BlockRange(start: startDate, end: null));
                      return;
                    }
                    if (endDate.isBefore(startDate)) {
                      showAppSnackBar(context, '종료일은 시작일 이후여야 합니다.', useRoot: true);
                      return;
                    }
                    Navigator.of(context).pop(_BlockRange(start: startDate, end: endDate));
                  },
                  child: Text('확인', style: TextStyle(color: green, fontWeight: FontWeight.w600)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _isBlockActiveOnDate(StudentTimeBlock block, DateTime date) {
    final target = DateTime(date.year, date.month, date.day);
    final start = DateTime(block.startDate.year, block.startDate.month, block.startDate.day);
    final end = block.endDate != null
        ? DateTime(block.endDate!.year, block.endDate!.month, block.endDate!.day)
        : null;
    return !start.isAfter(target) && (end == null || !end.isBefore(target));
  }
  String? _selectedClassId; // 학생 검색 다이얼로그에서 선택된 수업(session_type_id)
  String _headerSearchQuery = '';

  List<StudentTimeBlock> _applySelectedClassId(List<StudentTimeBlock> blocks) {
    if (_selectedClassId == null || _selectedClassId!.isEmpty) {
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG][_applySelectedClassId] skip (selectedClassId is null/empty), blocks=${blocks.length}');
      }
      return blocks;
    }
    final mapped = blocks.map((b) => b.copyWith(sessionTypeId: _selectedClassId)).toList();
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_applySelectedClassId] selectedClassId=$_selectedClassId, before=${blocks.take(5).map((b)=>'${b.id}:${b.sessionTypeId}:${b.setId}').toList()}, after=${mapped.take(5).map((b)=>'${b.id}:${b.sessionTypeId}:${b.setId}').toList()}');
    }
    return mapped;
  }

  // 메모 슬라이드 상태
  final ValueNotifier<bool> _isMemoOpen = ValueNotifier(false);
  final ValueNotifier<List<MemoItem>> _memos = ValueNotifier<List<MemoItem>>([]);

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadOperatingHours();
    // ✅ 주 이동(과거/미래)에서도 정확히 렌더링되도록, 현재 주의 time blocks를 미리 로드
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(DataManager.instance.ensureStudentTimeBlocksForWeek(_selectedDate));
    });
    // 일정 스토어 초기화
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScheduleStore.instance.load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 운영시간 로드 후에만 스크롤 이동하도록 변경 (여기서는 호출하지 않음)
    // if (!_hasScrolledToCurrentTime) {
    //   WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentTime());
    //   _hasScrolledToCurrentTime = true;
    // }
  }

  void _scrollToCurrentTime({bool preferAnimate = false}) {
    final timeBlocks = _generateTimeBlocks();
    if (timeBlocks.isEmpty) return;
    // 현재 시간
    final now = TimeOfDay.now();
    int currentIdx = 0;
    for (int i = 0; i < timeBlocks.length; i++) {
      final block = timeBlocks[i];
      if (block.startTime.hour < now.hour || (block.startTime.hour == now.hour && block.startTime.minute <= now.minute)) {
        currentIdx = i;
      }
    }
    final blockHeight = 90.0;
    final visibleRows = 5;
    final firstBlock = timeBlocks.isNotEmpty ? timeBlocks.first : null;
    final lastBlock = timeBlocks.isNotEmpty ? timeBlocks.last : null;
    int scrollIdx = currentIdx;
    if (firstBlock != null && lastBlock != null) {
      final nowMinutes = now.hour * 60 + now.minute;
      final firstMinutes = firstBlock.startTime.hour * 60 + firstBlock.startTime.minute;
      final lastMinutes = lastBlock.startTime.hour * 60 + lastBlock.startTime.minute;
      if (nowMinutes < firstMinutes) {
        scrollIdx = 0;
      } else if (nowMinutes > lastMinutes) {
        scrollIdx = timeBlocks.length - 1;
      }
    }
    final targetOffset = (scrollIdx - (visibleRows ~/ 2)) * blockHeight;
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][Timetable] scrollToCurrentTime: blocks=${timeBlocks.length}, currentIdx=$currentIdx, targetOffset=$targetOffset');
    }
    if (_timetableScrollController.hasClients) {
      final maxOffset = _timetableScrollController.position.maxScrollExtent;
      final minOffset = _timetableScrollController.position.minScrollExtent;
      final scrollTo = targetOffset.clamp(minOffset, maxOffset);
      final cur = _timetableScrollController.offset;
      final delta = (scrollTo - cur).abs();
      // ✅ 성능: 긴 거리 이동은 animateTo가 프레임 부하를 유발할 수 있어 jumpTo로 처리
      // (짧은 거리만 부드럽게 애니메이션)
      if (preferAnimate) {
        // ✅ 첫 진입 UX: "순간이동" 대신 부드럽게 이동
        // ✅ 성능: 거리 기반으로 duration을 짧게(최대 420ms) 제한
        // 너무 짧으면 시각적으로 "점프"처럼 느껴질 수 있어 최소 시간을 조금 올린다.
        final ms = (240 + (delta / (blockHeight * 20) * 220)).clamp(240, 520).round();
        _timetableScrollController.animateTo(
          scrollTo,
          duration: Duration(milliseconds: ms),
          curve: Curves.easeOutCubic,
        );
      } else {
        _timetableScrollController.jumpTo(scrollTo);
      }
    } else {
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG][Timetable] scroll controller has no clients yet');
      }
    }
  }

  List<TimeBlock> _generateTimeBlocks() {
    // ClassesView의 _generateTimeBlocks 로직 복사
    final List<TimeBlock> blocks = [];
    if (_operatingHours.isNotEmpty) {
      final now = DateTime.now();
      int minHour = 23, minMinute = 59, maxHour = 0, maxMinute = 0;
      for (final hours in _operatingHours) {
        if (hours.startHour < minHour || (hours.startHour == minHour && hours.startMinute < minMinute)) {
          minHour = hours.startHour;
          minMinute = hours.startMinute;
        }
        if (hours.endHour > maxHour || (hours.endHour == maxHour && hours.endMinute > maxMinute)) {
          maxHour = hours.endHour;
          maxMinute = hours.endMinute;
        }
      }
      var currentTime = DateTime(now.year, now.month, now.day, minHour, minMinute);
      final endTime = DateTime(now.year, now.month, now.day, maxHour, maxMinute);
      while (currentTime.isBefore(endTime)) {
        final blockEndTime = currentTime.add(const Duration(minutes: 30));
        blocks.add(TimeBlock(
          startTime: currentTime,
          endTime: blockEndTime,
          isBreakTime: false,
        ));
        currentTime = blockEndTime;
      }
    }
    return blocks;
  }

  String? _initialPlaceholderText() {
    // 운영시간 외면 안내 문구 교체, 운영시간이면 null(기본 문구) 유지
    final now = DateTime.now();
    final dayIdx = (now.weekday - DateTime.monday).clamp(0, 6);
    if (_operatingHours.length > dayIdx) {
      final op = _operatingHours[dayIdx];
      final start = DateTime(now.year, now.month, now.day, op.startHour, op.startMinute);
      final end = DateTime(now.year, now.month, now.day, op.endHour, op.endMinute);
      final within = now.isAfter(start) && now.isBefore(end);
      if (!within) return '운영시간이 아닙니다.';
    }
    return null;
  }

  Future<void> _loadData() async {
    await DataManager.instance.loadGroups();
    if (!mounted) return;
    setState(() {
      _groups = List.from(DataManager.instance.groups);
    });
  }

  Future<void> _loadOperatingHours() async {
    final hours = await DataManager.instance.getOperatingHours();
    if (!mounted) return;
    setState(() {
      _operatingHours = hours;
    });
    // 운영시간 로드 후 스크롤 및 자동 선택 로그
    if (!_hasScrolledToCurrentTime) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentTime(preferAnimate: true));
      _hasScrolledToCurrentTime = true;
    }
    // 운영시간 내라면 현재 시간 셀 자동 선택 (그리드 타임블록에 스냅)
    if (_selectedCellDayIndex == null || _selectedStartTimeHour == null || _selectedStartTimeMinute == null) {
      final now = DateTime.now();
      final dayIdx = (now.weekday - DateTime.monday).clamp(0, 6);
      if (_operatingHours.length > dayIdx) {
        final op = _operatingHours[dayIdx];
        final start = DateTime(now.year, now.month, now.day, op.startHour, op.startMinute);
        final end = DateTime(now.year, now.month, now.day, op.endHour, op.endMinute);
        final within = now.isAfter(start) && now.isBefore(end);
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][Timetable] auto-select check: now=$now start=$start end=$end within=$within');
        }
        if (within) {
          // 1) 해당 날짜의 타임블록 생성
          final blocks = _generateTimeBlocks();
          if (blocks.isNotEmpty) {
            // 2) now 이하 중 가장 가까운 블록 인덱스 선택(없으면 0, 크면 마지막)
            final nowTod = TimeOfDay(hour: now.hour, minute: now.minute);
            int currentIdx = 0;
            for (int i = 0; i < blocks.length; i++) {
              final b = blocks[i];
              final h = b.startTime.hour;
              final m = b.startTime.minute;
              if (h < nowTod.hour || (h == nowTod.hour && m <= nowTod.minute)) {
                currentIdx = i;
              }
            }
            // 경계 보정
            final first = blocks.first.startTime;
            final last = blocks.last.startTime;
            if (now.isBefore(first)) currentIdx = 0;
            if (now.isAfter(last)) currentIdx = blocks.length - 1;

            final chosen = blocks[currentIdx].startTime;
            setState(() {
              _selectedCellDayIndex = dayIdx;
              _selectedStartTimeHour = chosen.hour;
              _selectedStartTimeMinute = chosen.minute;
            });
            if (_kRegistrationPerfDebug) {
              // ignore: avoid_print
              print('[DEBUG][Timetable] auto-selected(snapped): dayIdx=$_selectedCellDayIndex time=${_selectedStartTimeHour}:${_selectedStartTimeMinute}');
            }
          }
        }
      }
    }
  }

  void _handleDateChanged(DateTime date) {
    setState(() {
      _selectedDate = date;
      // 주차 이동 시, 요일이 선택되어 있으면 새 주 기준으로 선택 날짜를 재계산
      if (_selectedDayIndex != null) {
        final monday = _selectedDate.subtract(Duration(days: _selectedDate.weekday - DateTime.monday));
        _selectedDayDate = DateTime(monday.year, monday.month, monday.day).add(Duration(days: _selectedDayIndex!));
      } else {
        _selectedDayDate = null;
      }
    });
    // ✅ 주 이동 시 해당 주 time blocks 프리로드(비동기, 중복 호출은 내부에서 방지)
    unawaited(DataManager.instance.ensureStudentTimeBlocksForWeek(date));
  }

  void _handleStudentMenu() {
    setState(() {
      _registrationButtonText = '학생';
    });
  }

  void _handleRegistrationButton() async {
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG] _handleRegistrationButton 진입: _isStudentRegistrationMode=$_isStudentRegistrationMode');
    }
    // 학생 수업시간 등록 모드 진입 시 다이얼로그 띄우기
    // ✅ 상단 '+ 추가' 버튼은 "학생 수업시간 등록"만 지원한다. (드롭다운 제거)
    // 다이얼로그 표시가 느려지는 원인: 여기서 동기화(loadStudents/loadStudentTimeBlocks)를 await 하면
    // 네트워크/DB I/O 때문에 1~2초 이상 블로킹될 수 있다.
    // → 다이얼로그는 즉시 띄우고, 동기화는 첫 프레임 렌더 이후 백그라운드로 돌린다.
    final dialogFuture = showDialog<dynamic>(
      context: context,
      barrierDismissible: true,
      builder: (context) => StudentSearchDialog(isSelfStudyMode: false),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ✅ 전체 student_time_blocks reload는 비용이 크고(700~1000+ row 파싱/리빌드),
      // 등록 중 사용자 입력(클릭/ESC)이 "먹히지 않는" 체감 렉의 주요 원인이 될 수 있다.
      // - 비어있을 때만 전체 로드
      // - 그 외에는 현재 주만 프리로드(경량)로 충분
      if (DataManager.instance.studentTimeBlocks.isEmpty) {
        unawaited(DataManager.instance.loadStudentTimeBlocks());
      } else {
        unawaited(DataManager.instance.ensureStudentTimeBlocksForWeek(_selectedDate));
      }
      unawaited(DataManager.instance.loadStudents());
    });
    final selectedStudent = await dialogFuture;
    StudentWithInfo? studentWithInfo;
    String? preselectedClassId;
    if (selectedStudent != null) {
      Student? selected;
      if (selectedStudent is Map && selectedStudent['student'] is Student) {
        selected = selectedStudent['student'] as Student;
        preselectedClassId = selectedStudent['classId'] as String?;
      } else if (selectedStudent is Student) {
        selected = selectedStudent;
      }
      if (selected != null) {
        // 항상 students에서 StudentWithInfo를 찾아서 사용
        studentWithInfo = DataManager.instance.students.firstWhere(
          (s) => s.student.id == selected!.id,
          orElse: () => StudentWithInfo(student: selected!, basicInfo: StudentBasicInfo(studentId: selected!.id)),
        );
        // 만약 students에 없다면 loadStudents를 강제로 다시 불러오고 재시도
        if (studentWithInfo.student.id != selected!.id) {
          await DataManager.instance.loadStudents();
          studentWithInfo = DataManager.instance.students.firstWhere(
            (s) => s.student.id == selected!.id,
            orElse: () => StudentWithInfo(student: selected!, basicInfo: StudentBasicInfo(studentId: selected!.id)),
          );
        }
      }
      final studentId = studentWithInfo?.student.id;
      setState(() {
        _isStudentRegistrationMode = true;
        _isClassRegistrationMode = false;
        _selectedStudentWithInfo = studentWithInfo != null ? studentWithInfo : null;
        // 사전 선택된 수업이 있으면 기록 (이후 블록 생성 시 사용)
        if (preselectedClassId != null && preselectedClassId!.isNotEmpty) {
          _selectedClassId = preselectedClassId;
          if (_kRegistrationPerfDebug) {
            // ignore: avoid_print
            print('[DEBUG][학생선택] preselectedClassId 적용: $_selectedClassId');
          }
        }
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][setState:학생선택] _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo, _selectedClassId=$_selectedClassId');
        }
      });
      // ESC 등 키 입력 포커스를 다시 메인 타임테이블로 돌려 등록 취소/종료가 동작하도록 한다.
      _focusNode.requestFocus();
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG] 학생 선택 후 등록모드 진입: _isStudentRegistrationMode=$_isStudentRegistrationMode');
      }
    } else {
      setState(() {
        _isStudentRegistrationMode = false;
        _isClassRegistrationMode = false;
        _selectedStudentWithInfo = null;
        
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][setState:학생선택취소] _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
        }
      });
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG] 학생 선택 취소: _isStudentRegistrationMode=$_isStudentRegistrationMode');
      }
    }
  }

  void _showRegisterDropdownMenu() {
    final renderBox = _registerDropdownKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    _registerDropdownOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx,
        top: offset.dy + size.height + 4,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 140,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2A2A2A)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: ['학생', '수업'].map((label) {
                final selected = _splitButtonSelected == label;
                return InkWell(
                  onTap: () {
                    setState(() {
                      _splitButtonSelected = label;
                      _isDropdownOpen = false;
                    });
                    _removeRegisterDropdownMenu(notify: false);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF383838) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_registerDropdownOverlay!);
  }

  void _removeRegisterDropdownMenu({bool notify = true}) {
    _registerDropdownOverlay?.remove();
    _registerDropdownOverlay = null;
    if (notify) {
      setState(() {
        _isDropdownOpen = false;
      });
    }
  }

  Widget _buildHeaderRegisterControls() {
    const double controlHeight = 48;
    const double mainButtonWidth = 130; // ✅ 내부 오른쪽 여백(10)만큼 너비도 같이 증가
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: mainButtonWidth,
          height: controlHeight,
          child: Material(
            color: const Color(0xFF1B6B63),
            borderRadius: BorderRadius.circular(controlHeight / 2), // ✅ 알약
            child: InkWell(
              borderRadius: BorderRadius.circular(controlHeight / 2),
              onTap: _handleRegistrationButton,
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: const [
                    Icon(Icons.add, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '추가',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderSearchField() {
    return TimetableSearchField(
      controller: _headerSearchController,
      hasText: _headerSearchQuery.isNotEmpty,
      onChanged: (value) {
        setState(() => _headerSearchQuery = value);
        _contentViewKey.currentState?.updateSearchQuery(value);
      },
      onClear: () {
        _headerSearchController.clear();
        setState(() => _headerSearchQuery = '');
        _contentViewKey.currentState?.updateSearchQuery('');
      },
    );
  }

  Widget _buildHeaderActionRow() {
    const double spacing = 12;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeaderFilterButton(),
        const SizedBox(width: spacing),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: IntrinsicWidth(
            child: _HeaderSelectButton(
              isSelectMode: _isSelectMode,
              onModeChanged: (selecting) {
                setState(() {
                  _isSelectMode = selecting;
                  if (!selecting) {
                    _selectedStudentIds.clear();
                  }
                });
              },
              onSelectAll: _handleSelectAllStudents,
            ),
          ),
        ),
        const SizedBox(width: spacing),
        _buildHeaderSearchField(),
      ],
    );
  }

  Widget _buildHeaderFilterButton() {
    const double controlHeight = 48;
    final bool hasFilter = _activeFilter != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(controlHeight / 2),
        onTap: _activeFilter == null ? _showFilterDialog : _clearFilter,
        child: Container(
          width: controlHeight,
          height: controlHeight,
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(controlHeight / 2),
            border: Border.all(color: Colors.transparent),
          ),
          child: Stack(
            children: [
              Center(
                child: Icon(
                  hasFilter ? Icons.filter_alt : Icons.filter_alt_outlined,
                  color: hasFilter ? const Color(0xFFEAF2F2) : Colors.white70,
                  size: 22,
                ),
              ),
              if (hasFilter)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFFEAF2F2),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleSelectAllStudents() {
    if (_selectedCellDayIndex != null && _selectedStartTimeHour != null && _selectedStartTimeMinute != null) {
      final cellStudents = _getCellStudents(_selectedCellDayIndex!, _selectedStartTimeHour!, _selectedStartTimeMinute!);
      setState(() {
        _selectedStudentIds = cellStudents.map((s) => s.student.id).toSet();
      });
    }
  }

  void _resetSearch() {
    if (_headerSearchQuery.isNotEmpty) {
      setState(() => _headerSearchQuery = '');
      _headerSearchController.clear();
      _contentViewKey.currentState?.updateSearchQuery('');
    }
  }

  void _showGroupScheduleDialog() {
    showDialog(
      context: context,
      builder: (context) => GroupScheduleDialog(
        groupInfo: _selectedGroup!,
        onScheduleSelected: (schedule) {
          Navigator.of(context).pop();
          setState(() {
            _currentGroupSchedule = schedule;
            _isClassRegistrationMode = true;
            _isStudentRegistrationMode = false;
          });
        },
      ),
    );
  }

  // TimetableHeader 요일 클릭 콜백
  void _onDayHeaderSelected(int dayIndex) {
    // 선택한 주의 월요일 기준 실제 날짜 계산 후 상태 반영
    final monday = _selectedDate.subtract(Duration(days: _selectedDate.weekday - DateTime.monday));
    final dayDate = DateTime(monday.year, monday.month, monday.day).add(Duration(days: dayIndex));
    // 검색창 리셋
    _resetSearch();
    setState(() {
      _selectedDayIndex = dayIndex;
      _selectedCellDayIndex = dayIndex; // 내용 패널이 요일 기준으로 보이도록
      _selectedStartTimeHour = null; // 시간 선택 해제하여 요일 모드로 전환
      _selectedStartTimeMinute = null;
      _selectedDayDate = dayDate;
    });
  }

  void _showFilterDialog() async {
    final students = DataManager.instance.students;
    final groups = DataManager.instance.groups;
    final classes = DataManager.instance.classesNotifier.value; // 수업 데이터 추가
    // 학년 chips
    final educationLevels = ['초등', '중등', '고등'];
    final grades = [
      '초1', '초2', '초3', '초4', '초5', '초6',
      '중1', '중2', '중3',
      '고1', '고2', '고3', 'N수',
    ];
    // 학교 chips (학생 정보 기준, 중복 제거)
    final schools = students
        .map((s) => s.student.school.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    // 그룹 chips (등록된 그룹명)
    final groupNames = groups.map((g) => g.name.trim()).where((n) => n.isNotEmpty).toList()
      ..sort();
    // 수업 chips (등록된 수업명)
    final classNames = classes.map((c) => c.name.trim()).where((n) => n.isNotEmpty).toList()
      ..sort();
    // chips 임시 상태 변수
    Set<String> tempSelectedEducationLevels = Set.from(_selectedEducationLevels);
    Set<String> tempSelectedGrades = Set.from(_selectedGrades);
    Set<String> tempSelectedSchools = Set.from(_selectedSchools);
    Set<String> tempSelectedGroups = Set.from(_selectedGroups);
    Set<String> tempSelectedClasses = Set.from(_selectedClasses);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: kDlgBorder),
              ),
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              title: const Text(
                '필터',
                style: TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900),
              ),
              content: SizedBox(
                width: 640,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Divider(color: kDlgBorder, height: 1),
                      const SizedBox(height: 18),

                      const YggDialogSectionHeader(icon: Icons.school_outlined, title: '학년'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ...educationLevels.map((level) => YggDialogFilterChip(
                                label: level,
                                selected: tempSelectedEducationLevels.contains(level),
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      tempSelectedEducationLevels.add(level);
                                    } else {
                                      tempSelectedEducationLevels.remove(level);
                                    }
                                  });
                                },
                              )),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ...grades.map((grade) => YggDialogFilterChip(
                                label: grade,
                                selected: tempSelectedGrades.contains(grade),
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      tempSelectedGrades.add(grade);
                                    } else {
                                      tempSelectedGrades.remove(grade);
                                    }
                                  });
                                },
                              )),
                        ],
                      ),
                      const SizedBox(height: 20),

                      const YggDialogSectionHeader(icon: Icons.location_city_outlined, title: '학교'),
                      if (schools.isEmpty)
                        const Text(
                          '등록된 학교 정보가 없습니다.',
                          style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ...schools.map((school) => YggDialogFilterChip(
                                  label: school,
                                  selected: tempSelectedSchools.contains(school),
                                  onSelected: (selected) {
                                    setState(() {
                                      if (selected) {
                                        tempSelectedSchools.add(school);
                                      } else {
                                        tempSelectedSchools.remove(school);
                                      }
                                    });
                                  },
                                )),
                          ],
                        ),
                      const SizedBox(height: 20),

                      const YggDialogSectionHeader(icon: Icons.groups_2_outlined, title: '그룹'),
                      if (groupNames.isEmpty)
                        const Text(
                          '등록된 그룹이 없습니다.',
                          style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ...groupNames.map((group) => YggDialogFilterChip(
                                  label: group,
                                  selected: tempSelectedGroups.contains(group),
                                  onSelected: (selected) {
                                    setState(() {
                                      if (selected) {
                                        tempSelectedGroups.add(group);
                                      } else {
                                        tempSelectedGroups.remove(group);
                                      }
                                    });
                                  },
                                )),
                          ],
                        ),
                      const SizedBox(height: 20),

                      const YggDialogSectionHeader(icon: Icons.class_outlined, title: '수업'),
                      if (classNames.isEmpty)
                        const Text(
                          '등록된 수업이 없습니다.',
                          style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ...classNames.map((className) => YggDialogFilterChip(
                                  label: className,
                                  selected: tempSelectedClasses.contains(className),
                                  onSelected: (selected) {
                                    setState(() {
                                      if (selected) {
                                        tempSelectedClasses.add(className);
                                      } else {
                                        tempSelectedClasses.remove(className);
                                      }
                                    });
                                  },
                                )),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      tempSelectedEducationLevels.clear();
                      tempSelectedGrades.clear();
                      tempSelectedSchools.clear();
                      tempSelectedGroups.clear();
                      tempSelectedClasses.clear();
                    });
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: kDlgTextSub,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                  child: const Text('초기화'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    foregroundColor: kDlgTextSub,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  ),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () {
                    // chips 상태를 부모에 반영
                    _selectedEducationLevels = Set.from(tempSelectedEducationLevels);
                    _selectedGrades = Set.from(tempSelectedGrades);
                    _selectedSchools = Set.from(tempSelectedSchools);
                    _selectedGroups = Set.from(tempSelectedGroups);
                    _selectedClasses = Set.from(tempSelectedClasses);
                    _activeFilter = {
                      'educationLevels': Set.from(tempSelectedEducationLevels),
                      'grades': Set.from(tempSelectedGrades),
                      'schools': Set.from(tempSelectedSchools),
                      'groups': Set.from(tempSelectedGroups),
                      'classes': Set.from(tempSelectedClasses),
                    };
                    Navigator.of(context).pop(true);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: kDlgAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('적용',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                ),
              ],
            );
          },
        );
      },
    );
    // 다이얼로그 닫힌 후, 적용 시 화면 리빌드
    if (result == true) {
      setState(() {});
    }
  }

  void _clearFilter() {
    setState(() {
      _activeFilter = null;
      _selectedEducationLevels.clear();
      _selectedGrades.clear();
      _selectedSchools.clear();
      _selectedGroups.clear();
      _selectedClasses.clear();
    });
  }

  @override
  void dispose() {
    _removeRegisterDropdownMenu(notify: false);
    _headerSearchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _endRegistrationMode({bool flushPlanned = true}) async {
    final currentStudentName = _selectedStudentWithInfo?.student.name ?? '학생';
    if (flushPlanned) {
      // 대기 중 블록/예정 재계산을 모두 실행
      await DataManager.instance.flushPendingTimeBlocks();
      await DataManager.instance.flushPendingPlannedRegens();
    }
    setState(() {
      _isStudentRegistrationMode = false;
      _isClassRegistrationMode = false;
      _selectedStudentWithInfo = null;
      _selectedDayIndex = null;
      _selectedStartTimeHour = null;
      _selectedStartTimeMinute = null;
    });
    return;
  }

  Future<void> _cancelRegistrationMode() async {
    // 저장하지 않고(서버 upsert 없음) pending만 폐기
    final sid = _selectedStudentWithInfo?.student.id;
    if (sid != null && sid.isNotEmpty) {
      await DataManager.instance.discardPendingTimeBlocks(sid);
    }
    setState(() {
      _isStudentRegistrationMode = false;
      _isClassRegistrationMode = false;
      _selectedStudentWithInfo = null;
      _selectedDayIndex = null;
      _selectedStartTimeHour = null;
      _selectedStartTimeMinute = null;
    });
  }

  void exitSelectMode() {
    setState(() {
      _isSelectMode = false;
      _selectedStudentIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 테스트 전용 플래그로 autofocus를 제어 (기본 동작은 유지)
    const bool kDisableTimetableKbAutofocus = bool.fromEnvironment('DISABLE_TIMETABLE_KB_AUTOFOCUS', defaultValue: false);
    return RawKeyboardListener(
      focusNode: _focusNode,
      autofocus: !kDisableTimetableKbAutofocus,
      onKey: (event) async {
        if (event is! RawKeyDownEvent) return;
        // 등록모드 키 동작 통일
        // - ESC: 취소(저장 안 함)
        // - Enter/우클릭: 완료 및 저장
        if (_isStudentRegistrationMode || _isClassRegistrationMode) {
          final currentStudentName = _selectedStudentWithInfo?.student.name ?? '학생';
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape) {
            await _cancelRegistrationMode();
            if (mounted) {
              showAppSnackBar(context, '$currentStudentName 학생의 등록을 취소했습니다.', useRoot: true);
            }
            return;
          }
          if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
            await _endRegistrationMode(flushPlanned: true);
            if (mounted) {
              showAppSnackBar(context, '$currentStudentName 학생의 등록을 저장했습니다.', useRoot: true);
            }
            return;
          }
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          _resetSearch();
          // 선택모드 해제: 셀 클릭 시 자동으로 선택모드 false
          if (_isSelectMode) {
            setState(() {
              _isSelectMode = false;
              if (_kRegistrationPerfDebug) {
                // ignore: avoid_print
                print('[DEBUG][TimetableScreen] 선택모드 해제(셀 클릭): _isSelectMode=$_isSelectMode, _selectedCellDayIndex=$_selectedCellDayIndex, _selectedStartTimeHour=$_selectedStartTimeHour, _selectedStartTimeMinute=$_selectedStartTimeMinute');
              }
            });
          }
        },
        onSecondaryTap: () async {
          if (_isStudentRegistrationMode || _isClassRegistrationMode) {
            final currentStudentName = _selectedStudentWithInfo?.student.name ?? '학생';
            await _endRegistrationMode(flushPlanned: true);
            if (mounted) {
              showAppSnackBar(context, '$currentStudentName 학생의 등록을 저장했습니다.', useRoot: true);
            }
          }
        },
        child: Stack(
          children: [
            Scaffold(
              backgroundColor: const Color(0xFF0B1112),
              body: Container(
                constraints: const BoxConstraints.expand(),
                color: const Color(0xFF0B1112), // 프로그램 전체 배경색
                child: Column(
                  children: [
                    SizedBox(height: 5), // TimetableHeader 위 여백을 5로 수정
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TimetableTopBar(
                        registerControls: _buildHeaderRegisterControls(),
                        selectedIndex: (_viewType == TimetableViewType.classes) ? 0 : 1,
                        onTabSelected: (i) {
                          setState(() {
                            _viewType = (i == 0) ? TimetableViewType.classes : TimetableViewType.schedule;
                          });

                          if ((i == 0) && !_hasScrolledOnTabClick) {
                            WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentTime(preferAnimate: true));
                            _hasScrolledOnTabClick = true;
                          }
                        },
                        actionRow: _buildHeaderActionRow(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _buildContent(),
                    ),
                    const SizedBox(height: 0),
                  ],
                ),
              ),
            ),
            // 메모 전역 오버레이가 main.dart에서 렌더링되므로 여기선 제거
          ],
        ),
      ),
    );
  }

  Future<void> _onAddMemo(BuildContext context) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const _MemoInputDialog(),
    );
    if (text == null || text.trim().isEmpty) return;
    // 1) 즉시 로컬에 임시 추가(요약 대기 표시)
    final pending = MemoItem(
      id: UniqueKey().toString(),
      original: text.trim(),
      summary: '요약 중...'
    );
    _memos.value = [pending, ..._memos.value];
    // 2) 요약 호출
    try {
      final summary = await _summarize(text.trim());
      _memos.value = _memos.value.map((m) => m.id == pending.id ? m.copyWith(summary: summary) : m).toList();
    } catch (e) {
      _memos.value = _memos.value.map((m) => m.id == pending.id ? m.copyWith(summary: '(요약 실패) ${m.original}') : m).toList();
    }
  }

  Future<void> _onEditMemo(BuildContext context, MemoItem item) async {
    final edited = await showDialog<_MemoEditResult>(
      context: context,
      builder: (context) => _MemoEditDialog(initial: item.original),
    );
    if (edited == null) return;
    // 저장
    if (edited.action == _MemoEditAction.delete) {
      _memos.value = _memos.value.where((m) => m.id != item.id).toList();
      return;
    }
    if (edited.text.trim().isEmpty) return;
    final newOriginal = edited.text.trim();
    // 일단 즉시 반영(요약은 비동기)
    _memos.value = _memos.value.map((m) => m.id == item.id ? m.copyWith(original: newOriginal, summary: '요약 중...') : m).toList();
    try {
      final summary = await _summarize(newOriginal);
      _memos.value = _memos.value.map((m) => m.id == item.id ? m.copyWith(summary: summary) : m).toList();
    } catch (_) {
      _memos.value = _memos.value.map((m) => m.id == item.id ? m.copyWith(summary: '(요약 실패) $newOriginal') : m).toList();
    }
  }

  Future<String> _summarize(String text) async {
    // 1) 설정(SharedPreferences) 우선
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getString('openai_api_key') ?? '';
    // 2) 빌드타임 define 보조
    final defined = const String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
    final apiKey = persisted.isNotEmpty ? persisted : defined;
    if (apiKey.isEmpty) {
      // 오프라인/키 미설정 시, 간단 요약 대체
      return _toSingleSentence(text, maxChars: 60);
    }
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = jsonEncode({
      'model': 'gpt-4o-mini',
      'messages': [
        {
          'role': 'system',
          'content': '너는 텍스트를 한 문장으로 간결하게 요약하는 비서다. 한국어로 한 문장만 출력하고, 줄바꿈 없이 60자 이내로 핵심만 담아라.'
        },
        {
          'role': 'user',
          'content': '다음 텍스트를 한 문장(최대 60자)으로 간결하게 요약해줘. 불필요한 수식어/군더더기 금지:\n$text'
        }
      ],
      'temperature': 0.2,
      'max_tokens': 80,
    });
    final res = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: body,
    );
    if (res.statusCode != 200) {
      throw Exception('GPT 요약 실패(${res.statusCode})');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = json['choices'] as List<dynamic>?;
    final content = choices != null && choices.isNotEmpty
        ? (choices.first['message']?['content'] as String? ?? '')
        : '';
    if (content.isEmpty) return _toSingleSentence(text, maxChars: 60);
    return _toSingleSentence(content, maxChars: 60);
  }

  String _toSingleSentence(String raw, {int maxChars = 60}) {
    // 1) 줄바꿈 제거 및 공백 정리
    var s = raw.replaceAll('\n', ' ').replaceAll('\r', ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 2) 한 문장만: 종결부호가 여러 번이면 첫 종결까지만
    final endIdx = _firstSentenceEndIndex(s);
    if (endIdx != -1) s = s.substring(0, endIdx + 1);
    // 3) 길이 제한: 종결부호 이전으로 우선 자르기, 없으면 말줄임
    if (s.runes.length <= maxChars) return s;
    final clipped = _clipRunes(s, maxChars);
    // 종결부호가 있으면 거기까지, 없으면 …
    final clippedEnd = _firstSentenceEndIndex(clipped);
    if (clippedEnd != -1) return clipped.substring(0, clippedEnd + 1);
    return clipped + '…';
  }

  int _firstSentenceEndIndex(String s) {
    // 한국어 문장 종결부호/패턴 우선 탐색
    final patterns = ['다.', '요.', '니다.', '함.', '.', '!', '?'];
    int best = -1;
    for (final p in patterns) {
      final idx = s.indexOf(p);
      if (idx != -1) {
        final end = idx + p.length - 1; // 마지막 문자 인덱스
        if (best == -1 || end < best) best = end;
      }
    }
    return best;
  }

  String _clipRunes(String s, int maxChars) {
    final it = s.runes.iterator;
    final buf = StringBuffer();
    int count = 0;
    while (it.moveNext()) {
      buf.writeCharCode(it.current);
      count++;
      if (count >= maxChars) break;
    }
    return buf.toString();
  }

  Widget _buildContent() {
    switch (_viewType) {
      case TimetableViewType.classes:
        final Set<String>? filteredStudentIds = _activeFilter == null
          ? null
          : _filteredStudents.map((s) => s.student.id).toSet();
        final Set<String>? timetableFilteredStudentIds = _weekStudentFilterId == null
            ? filteredStudentIds
            : <String>{_weekStudentFilterId!};
        final Set<String> filteredClassIds = _classIdsFromFilter(_activeFilter);
        return TimetableContentView(
          key: _contentViewKey, // 추가: 검색 리셋을 위해 key 부여
          filteredStudentIds: filteredStudentIds, // 필터링 정보 전달
          filteredClassIds: filteredClassIds,
          highlightedStudentId: _weekStudentFilterId,
          onStudentCardTap: _toggleWeekStudentFilter,
          onToggleClassFilter: _toggleClassQuickFilter,
          selectedDayDate: _selectedDayDate, // 요일 클릭 시 선택 날짜 전달
          viewDate: _selectedDate,
          // PERF: 셀 클릭→우측 리스트 첫 프레임까지 측정(기본 OFF)
          enableCellRenderPerfTrace: _kCellRenderPerfTrace,
          cellRenderPerfToken: _cellRenderPerfToken,
          cellRenderPerfStartUs: _cellRenderPerfStartUs,
          onCellRenderPerfFrame: _finishCellRenderPerfTrace,
          header: Padding(
            padding: const EdgeInsets.only(left: 0, right: 0, top: 20, bottom: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TimetableHeader(
                    selectedDate: _selectedDate,
                    onDateChanged: _handleDateChanged,
                    selectedDayIndex: _isStudentRegistrationMode ? null : _selectedDayIndex,
                    onDaySelected: _onDayHeaderSelected,
                    isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
                  ),
                ),
              ],
            ),
          ),
          timetableChild: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF0B1112),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                if (_isStudentRegistrationMode && _selectedStudentWithInfo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                    child: Builder(
                      builder: (context) {
                        final studentWithInfo = _selectedStudentWithInfo!;
                        final studentId = studentWithInfo.student.id;
                final dm = DataManager.instance;
                final now = DateTime.now();
                final today = DateTime(now.year, now.month, now.day);
                final pendingSetIds = dm.pendingStudentTimeBlocks
                    .where((b) => b.studentId == studentId)
                    .map((b) => (b.setId ?? '').trim())
                    .where((s) => s.isNotEmpty)
                    .toSet();
                final allOpenOrFutureSetIds = dm.studentTimeBlocks
                    .where((b) {
                      if (b.studentId != studentId) return false;
                      final setId = (b.setId ?? '').trim();
                      if (setId.isEmpty) return false;
                      final end = b.endDate != null
                          ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
                          : null;
                      // 오늘 이전에 완전히 종료된 이력은 제외
                      if (end != null && end.isBefore(today)) return false;
                      return true;
                    })
                    .map((b) => (b.setId ?? '').trim())
                    .where((s) => s.isNotEmpty)
                    .toSet();
                final existingSetIds = allOpenOrFutureSetIds.difference(pendingSetIds);

                final existingCount = existingSetIds.length;
                final pendingCount = pendingSetIds.length;

                final actionButtons = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: '취소 (ESC)',
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final currentStudentName = _selectedStudentWithInfo?.student.name ?? '학생';
                          await _cancelRegistrationMode();
                          if (mounted) {
                            showAppSnackBar(context, '$currentStudentName 학생의 등록을 취소했습니다.', useRoot: true);
                          }
                        },
                        icon: const Icon(Icons.close_rounded, size: 20),
                        label: const Text('취소'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white.withOpacity(0.85),
                          side: const BorderSide(color: Color(0xFF223131)),
                          // 태블릿/터치 환경: 최소 터치 타겟 크게(기존 대비 약 1.5배)
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          minimumSize: const Size(0, 50),
                          shape: const StadiumBorder(),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '저장 (Enter / 우클릭)',
                      child: FilledButton.icon(
                        onPressed: () async {
                          final currentStudentName = _selectedStudentWithInfo?.student.name ?? '학생';
                          await _endRegistrationMode(flushPlanned: true);
                          if (mounted) {
                            showAppSnackBar(context, '$currentStudentName 학생의 등록을 저장했습니다.', useRoot: true);
                          }
                        },
                        icon: const Icon(Icons.check_rounded, size: 20),
                        label: const Text('저장'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF33A373),
                          foregroundColor: Colors.white,
                          // 태블릿/터치 환경: 최소 터치 타겟 크게(기존 대비 약 1.5배)
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          minimumSize: const Size(0, 50),
                          shape: const StadiumBorder(),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                      ),
                    ),
                  ],
                );

                final countCapsule = Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111418),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF223131)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${studentWithInfo.student.name} · 수업시간 등록',
                        style: const TextStyle(
                          color: Color(0xFFEAF2F2),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.05,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          Text(
                            '기존 $existingCount',
                            style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.0),
                          ),
                          Text('•', style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 12, height: 1.0)),
                          Text(
                            '추가 $pendingCount',
                            style: const TextStyle(color: Color(0xFF33A373), fontSize: 12.5, fontWeight: FontWeight.w800, height: 1.0),
                          ),
                          Text('•', style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 12, height: 1.0)),
                          Text(
                            'ESC 취소',
                            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12.2, fontWeight: FontWeight.w600, height: 1.0),
                          ),
                          Text('•', style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 12, height: 1.0)),
                          const Text(
                            'Enter/우클릭 저장',
                            style: TextStyle(color: Color(0xFF33A373), fontSize: 12.2, fontWeight: FontWeight.w700, height: 1.0),
                          ),
                        ],
                      ),
                    ],
                  ),
                );

                // ✅ 가운데(카운트 캡슐) / 오른쪽(취소·저장 버튼) 분리 정렬
                // - 카운트 캡슐은 화면 기준 정중앙
                // - 버튼은 오른쪽 끝 정렬
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // 화면이 좁으면 겹침을 피하기 위해 버튼을 다음 줄로 내려준다.
                      final bool narrow = constraints.maxWidth < 620;
                      if (narrow) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Center(child: countCapsule),
                            const SizedBox(height: 10),
                            Align(alignment: Alignment.centerRight, child: actionButtons),
                          ],
                        );
                      }

                      return SizedBox(
                        width: double.infinity,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Align(alignment: Alignment.center, child: countCapsule),
                            Align(alignment: Alignment.centerRight, child: actionButtons),
                          ],
                        ),
                      );
                    },
                  ),
                );
                      },
                    ),
                  ),
                const SizedBox(height: 0),
                Expanded(
                  child: ClassesView(
                    operatingHours: _operatingHours,
                    breakTimeColor: const Color(0xFF424242),
                    isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode || _isSelfStudyRegistrationMode,
                    registrationModeType: _isSelfStudyRegistrationMode ? 'selfStudy' : (_isStudentRegistrationMode ? 'student' : null),
                    selectedDayIndex: _selectedDayIndex,
                    selectedCellDayIndex: _selectedCellDayIndex,
                    selectedCellStartTime: (_selectedStartTimeHour != null && _selectedStartTimeMinute != null)
                        ? DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, _selectedStartTimeHour!, _selectedStartTimeMinute!)
                        : null,
                    filteredClassIds: filteredClassIds.isEmpty ? null : filteredClassIds,
                    onInquiryNoteTap: (noteId) => unawaited(_openInquiryNote(noteId)),
                    onTimeSelected: (dayIdx, startTime) {
                      _beginCellRenderPerfTrace(dayIdx: dayIdx, startTime: startTime);
                      setState(() {
                        _selectedCellDayIndex = dayIdx;
                        _selectedStartTimeHour = startTime.hour;
                        _selectedStartTimeMinute = startTime.minute;
                      });
                    },
                    onCellStudentsSelected: (dayIdx, startTimes, students) async {
                      if (_kRegistrationPerfDebug) {
                        // ignore: avoid_print
                        print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 호출: dayIdx=$dayIdx, startTimes=$startTimes, startTimes.length=${startTimes.length}, students=$students, _isSelfStudyRegistrationMode=$_isSelfStudyRegistrationMode, _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedSelfStudyStudent=${_selectedSelfStudyStudent?.student.name}, _selectedStudentWithInfo=${_selectedStudentWithInfo?.student.name}');
                      }
                      // 셀 클릭 시 검색 리셋
                      _resetSearch();
                      if (startTimes.isNotEmpty) {
                        _beginCellRenderPerfTrace(
                          dayIdx: dayIdx,
                          startTime: startTimes.first,
                        );
                      }
                      setState(() {
                        _selectedCellDayIndex = dayIdx;
                        _selectedStartTimeHour = startTimes.isNotEmpty ? startTimes.first.hour : null;
                        _selectedStartTimeMinute = startTimes.isNotEmpty ? startTimes.first.minute : null;
                      });
                      // 자습 등록 모드 처리
                      if (_isSelfStudyRegistrationMode && _selectedSelfStudyStudent != null) {
                        if (_kRegistrationPerfDebug) {
                          // ignore: avoid_print
                          print('[DEBUG][onCellStudentsSelected] 자습 등록 분기 진입');
                        }
                        final studentId = _selectedSelfStudyStudent!.student.id;
                        final blockMinutes = 30; // 자습 블록 길이(분)
                        List<DateTime> actualStartTimes = startTimes;
                        // 클릭(단일 셀) 시에는 30분 블록 1개 생성
                        if (startTimes.length == 1) {
                          actualStartTimes = [startTimes.first];
                        }
                        
                        // 수업 블록과의 중복 체크
                        bool hasConflict = false;
                        for (final startTime in actualStartTimes) {
                          final dateOnly = DateTime(startTime.year, startTime.month, startTime.day);
                          final conflictingBlocks = DataManager.instance.studentTimeBlocks.where((b) {
                            if (b.studentId != studentId || b.dayIndex != dayIdx) return false;
                            if (!_isBlockActiveOnDate(b, dateOnly)) return false;
                            final blockStartMinutes = b.startHour * 60 + b.startMinute;
                            final blockEndMinutes = blockStartMinutes + b.duration.inMinutes;
                            final checkStartMinutes = startTime.hour * 60 + startTime.minute;
                            final checkEndMinutes = checkStartMinutes + blockMinutes;
                            return checkStartMinutes < blockEndMinutes && checkEndMinutes > blockStartMinutes;
                          }).toList();
                          
                          if (conflictingBlocks.isNotEmpty) {
                            hasConflict = true;
                            break;
                          }
                        }
                        
                        if (hasConflict) {
                          showAppSnackBar(context, '이미 등록된 수업시간과 겹칩니다. 자습시간을 등록할 수 없습니다.', useRoot: true);
                          return;
                        }
                        
                        if (_kRegistrationPerfDebug) {
                          // ignore: avoid_print
                          print('[DEBUG][onCellStudentsSelected] 생성할 자습 블록 actualStartTimes: $actualStartTimes');
                        }
                        final blocks = SelfStudyTimeBlockFactory.createBlocksWithSetIdAndNumber(
                          studentId: studentId,
                          dayIndex: dayIdx,
                          startTimes: actualStartTimes,
                          duration: Duration(minutes: blockMinutes),
                        );
                        if (_kRegistrationPerfDebug) {
                          // ignore: avoid_print
                          print('[DEBUG][onCellStudentsSelected] SelfStudyTimeBlock 생성: count=${blocks.length}');
                        }
                        for (final block in blocks) {
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected] addSelfStudyTimeBlock 호출: setId=${block.setId} number=${block.number} day=${block.dayIndex} start=${block.startHour}:${block.startMinute}');
                          }
                          await DataManager.instance.addSelfStudyTimeBlock(block);
                        }
                        setState(() {
                          _isSelfStudyRegistrationMode = false;
                          _selectedSelfStudyStudent = null;
                        });
                        showAppSnackBar(context, '자습 시간이 등록되었습니다.', useRoot: true);
                        return;
                      }
                      // 학생 등록 모드에서만 동작
                      if (_isStudentRegistrationMode && _selectedStudentWithInfo != null) {
                        final studentWithInfo = _selectedStudentWithInfo!;
                        final student = studentWithInfo.student;
                        
                        if (startTimes.length > 1) {
                          // 드래그 등록 분기:
                          // - 블록 생성/등록(=pending 누적)은 ClassesView에서 처리
                          // - 등록모드에서는 서버 리로드(loadStudentTimeBlocks)를 호출하면 pending이 사라질 수 있으므로 금지
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 분기 진입: startTimes.length=${startTimes.length} student=${student.id}/${student.name}');
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 분기 return');
                          }
                          return;
                        } else if (startTimes.length == 1) {
                          // 클릭 등록 분기: 블록 생성/등록부터 수행
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 분기 진입: startTimes.length=${startTimes.length} student=${student.id}/${student.name}');
                          }
                          final blockMinutes = 30; // 한 블록 30분 기준
                          final lessonDuration = DataManager.instance.academySettings.lessonDuration;
                          final blockCount = (lessonDuration / blockMinutes).ceil();
                          List<DateTime> actualStartTimes = List.generate(blockCount, (i) => startTimes.first.add(Duration(minutes: i * blockMinutes)));
                          
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected] 생성할 블록 actualStartTimes: $actualStartTimes');
                          }
                          // 효력 기간 입력
                          final range = await _pickBlockEffectiveRange(context);
                          if (range == null) {
                            showAppSnackBar(context, '등록이 취소되었습니다.', useRoot: true);
                            return;
                          }
                          // --- 중복 방어 강화: 하나라도 겹치면 전체 등록 불가 ---
                          final allBlocks = DataManager.instance.studentTimeBlocks;
                          // ⚠️ startTimes는 "시간표 그리드"에서 생성된 DateTime(오늘 날짜 기반)일 수 있어,
                          // 중복 체크는 반드시 "등록 효력 시작일(range.start)" 기준으로 수행해야 한다.
                          final effectiveDate = DateTime(range.start.year, range.start.month, range.start.day);
                          bool hasConflict = false;
                          for (final startTime in actualStartTimes) {
                            final conflictBlock = allBlocks.firstWhereOrNull((b) =>
                              b.studentId == student.id &&
                              b.dayIndex == dayIdx &&
                              b.startHour == startTime.hour &&
                              b.startMinute == startTime.minute &&
                              _isBlockActiveOnDate(b, effectiveDate));
                            if (conflictBlock != null) {
                              hasConflict = true;
                              break;
                            }
                          }
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected] 클릭 등록 중복체크 결과: hasConflict=$hasConflict');
                          }
                          if (hasConflict) {
                            showAppSnackBar(context, '이미 등록된 시간입니다.', useRoot: true);
                            return;
                          }
                          // --- 기존 로직 ---
                          var blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
                            studentIds: [student.id],
                            dayIndex: dayIdx,
                            startTimes: actualStartTimes,
                            duration: Duration(minutes: blockMinutes),
                            startDate: range.start,
                            endDate: range.end,
                          );
                          blocks = _applySelectedClassId(blocks);
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected] StudentTimeBlock 생성: count=${blocks.length}');
                          }
                          if (_isStudentRegistrationMode) {
                            // 등록모드: 로컬에만 추가, 서버 업서트/regen은 모드 종료 시 일괄 처리
                            await DataManager.instance.bulkAddStudentTimeBlocksDeferred(blocks);
                            if (_kRegistrationPerfDebug) {
                              final allBlocksAfter = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
                              // ignore: avoid_print
                              print('[DEBUG][onCellStudentsSelected] (defer) 로컬 저장 후 blocksCount=${allBlocksAfter.length}');
                            }
                          } else {
                            // 일반 모드: 즉시 업서트
                            await DataManager.instance.bulkAddStudentTimeBlocks(blocks, immediate: true);
                            if (_kRegistrationPerfDebug) {
                              // ignore: avoid_print
                              print('[DEBUG][onCellStudentsSelected] loadStudentTimeBlocks 호출');
                            }
                            await DataManager.instance.loadStudentTimeBlocks();
                            if (_kRegistrationPerfDebug) {
                              final allBlocksAfter = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
                              // ignore: avoid_print
                              print('[DEBUG][onCellStudentsSelected] 저장 후 blocksCount=${allBlocksAfter.length}');
                            }
                          }
                          final usedCount = DataManager.instance.getStudentSetCount(student.id);
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected] set_id 개수(수업차감) -> getStudentSetCount: $usedCount');
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 setState 전: _isStudentRegistrationMode=$_isStudentRegistrationMode');
                          }
                          setState(() {
                    
                            
                            if (false) { // 자동 종료 로직 비활성화
                              if (_kRegistrationPerfDebug) {
                                // ignore: avoid_print
                                print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록모드 종료');
                              }
                              _isStudentRegistrationMode = false;
                              _selectedStudentWithInfo = null;
                              _selectedDayIndex = null;
                              _selectedStartTimeHour = null;
                              _selectedStartTimeMinute = null;
                            }
                          });
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 setState 후: _isStudentRegistrationMode=$_isStudentRegistrationMode');
                          }
                          
                          if (false && mounted) { // 자동 종료 로직 비활성화
                            showAppSnackBar(context, '${student.name} 학생의 수업시간 등록이 완료되었습니다.', useRoot: true);
                          }
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 분기 완료');
                          }
                        }
                      }
                    },
                    scrollController: _timetableScrollController,
                    // filteredStudentIds 정의 추가
                    filteredStudentIds: timetableFilteredStudentIds,
                    selectedStudentWithInfo: _selectedStudentWithInfo,
                    selectedSelfStudyStudent: _selectedSelfStudyStudent,
                    onSelectModeChanged: (selecting) {
                      setState(() {
                        _isSelectMode = selecting;
                        if (!selecting) _selectedStudentIds.clear();
                        if (_kRegistrationPerfDebug) {
                          // ignore: avoid_print
                          print('[DEBUG][TimetableScreen][ClassesView] onSelectModeChanged: $selecting, _isSelectMode=$_isSelectMode');
                        }
                      });
                    },
                    weekStartDate: _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1)),
                  ),
                ),
                SizedBox(height: 24), // 시간표 위젯 하단 내부 여백 추가
              ],
            ),
          ),
          onRegisterPressed: () {
            if (_splitButtonSelected == '학생') {
              _handleRegistrationButton();
            } else if (_splitButtonSelected == '수업') {
              // 수업 등록 다이얼로그로 연결
              _contentViewKey.currentState?.openClassRegistrationDialog();
            } else if (_splitButtonSelected == '보강') {
              // TODO: 보강 등록 모드 구현
            }
          },
          splitButtonSelected: _splitButtonSelected,
          isDropdownOpen: _isDropdownOpen,
          onDropdownOpenChanged: (open) {
            setState(() {
              _isDropdownOpen = open;
            });
          },
          onDropdownSelected: (value) {
            setState(() {
              _splitButtonSelected = value;
            });
          },
          selectedCellDayIndex: _selectedCellDayIndex,
          selectedCellStartTime: _selectedStartTimeHour != null && _selectedStartTimeMinute != null ? DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, _selectedStartTimeHour!, _selectedStartTimeMinute!) : null,
          placeholderText: _initialPlaceholderText(),
          onCellStudentsChanged: (dayIdx, startTime, students) {
            setState(() {
              _selectedCellDayIndex = dayIdx;
              _selectedStartTimeHour = startTime.hour;
              _selectedStartTimeMinute = startTime.minute;
              // 학생 리스트는 timetable_content_view.dart에서 계산
            });
          },
          onCellSelfStudyStudentsChanged: (dayIdx, startTime, students) {
            setState(() {
              _selectedCellDayIndex = dayIdx;
              _selectedStartTimeHour = startTime.hour;
              _selectedStartTimeMinute = startTime.minute;
              // 자습 학생 리스트는 timetable_content_view.dart에서 계산
            });
          },
          clearSearch: _resetSearch, // 추가: 검색 리셋 콜백 전달
          isSelectMode: _isSelectMode,
          selectedStudentIds: _selectedStudentIds,
          onStudentSelectChanged: (id, selected) {
            setState(() {
              if (selected) {
                _selectedStudentIds.add(id);
              } else {
                _selectedStudentIds.remove(id);
              }
              if (_kRegistrationPerfDebug) {
                // ignore: avoid_print
                print('[DEBUG][TimetableScreen] onStudentSelectChanged: $id, $selected, _selectedStudentIds=$_selectedStudentIds');
              }
            });
          },
          onExitSelectMode: exitSelectMode, // 콜백 전달
          showRegisterControls: false,
        );
      // 보강 탭 제거됨
      case TimetableViewType.schedule:
        return ScheduleView(
          selectedDate: _selectedDate,
          onDateSelected: (d) => _handleDateChanged(d),
        );
    }
  }

  Widget _buildClassView() {
    print('[DEBUG][_buildClassView] _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
    final Set<String>? filteredStudentIds = _activeFilter == null
        ? null
        : _filteredStudents.map((s) => s.student.id).toSet();
    final Set<String>? timetableFilteredStudentIds = _weekStudentFilterId == null
        ? filteredStudentIds
        : <String>{_weekStudentFilterId!};
    return Column(
      children: [
        // 상단 UI (월정보, 세그먼트, 선택, 필터 버튼 등)
        TimetableHeader(
          selectedDate: _selectedDate,
          onDateChanged: _handleDateChanged,
          selectedDayIndex: _isStudentRegistrationMode ? null : _selectedDayIndex,
          onDaySelected: _onDayHeaderSelected,
          isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
        ),
        // 등록 안내문구/카운트
        if (_isStudentRegistrationMode && _selectedStudentWithInfo != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Builder(
              builder: (context) {
                final studentWithInfo = _selectedStudentWithInfo!;
                final studentId = studentWithInfo.student.id;
                final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList();
                final setIds = blocks.map((b) => b.setId).toSet();
                final registeredCount = setIds.length;
                final nextLessonNumber = registeredCount + 1;
                return Text(
                  '${studentWithInfo.student.name} 학생: ${nextLessonNumber}번째 수업시간 등록',
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                );
              },
            ),
          ),
        // 시간표 본문
        Expanded(
          child: ClassesView(
            scrollController: _timetableScrollController,
            operatingHours: _operatingHours,
            breakTimeColor: const Color(0xFF424242),
            isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
            weekStartDate: _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1)),
            selectedDayIndex: _isStudentRegistrationMode ? null : _selectedDayIndex,
            selectedCellDayIndex: _selectedCellDayIndex,
            selectedCellStartTime: (_selectedStartTimeHour != null && _selectedStartTimeMinute != null)
                ? DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, _selectedStartTimeHour!, _selectedStartTimeMinute!)
                : null,
            onInquiryNoteTap: (noteId) => unawaited(_openInquiryNote(noteId)),
            onTimeSelected: (int dayIdx, DateTime startTime) {
              print('[DEBUG][onTimeSelected] 셀 클릭: dayIdx=$dayIdx, startTime=$startTime');
              setState(() {
                _selectedCellDayIndex = dayIdx;
                _selectedStartTimeHour = startTime.hour;
                _selectedStartTimeMinute = startTime.minute;
                print('[DEBUG][onTimeSelected][setState후] _selectedCellDayIndex=$_selectedCellDayIndex, _selectedStartTimeHour=$_selectedStartTimeHour, _selectedStartTimeMinute=$_selectedStartTimeMinute');
              });
            },
            onCellStudentsSelected: (int dayIdx, List<DateTime> startTimes, List<StudentWithInfo> students) async {
              print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 호출: dayIdx=$dayIdx, startTimes=$startTimes, startTimes.length=${startTimes.length}, students=$students, _isSelfStudyRegistrationMode=$_isSelfStudyRegistrationMode, _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedSelfStudyStudent=${_selectedSelfStudyStudent?.student.name}, _selectedStudentWithInfo=${_selectedStudentWithInfo?.student.name}');
              // 셀 클릭 시 검색 리셋
              _resetSearch();
              setState(() {
                _selectedCellDayIndex = dayIdx;
                _selectedStartTimeHour = startTimes.isNotEmpty ? startTimes.first.hour : null;
                _selectedStartTimeMinute = startTimes.isNotEmpty ? startTimes.first.minute : null;
              });
              // 학생 등록 모드에서만 동작
              if (_isStudentRegistrationMode && _selectedStudentWithInfo != null) {
                final studentWithInfo = _selectedStudentWithInfo!;
                final student = studentWithInfo.student;
                final blockMinutes = 30;
                List<DateTime> actualStartTimes = startTimes;
                if (startTimes.length > 1) {
                  // 드래그 등록 분기: 블록 생성/등록/중복체크/스낵바 모두 건너뛰고 상태만 갱신
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 분기 진입: startTimes=$startTimes, startTimes.length=${startTimes.length}');
                  final allBlocksAfter = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
                  final setIds = allBlocksAfter.map((b) => b.setId).toSet();
                  final usedCount = setIds.length;
                  print('[DEBUG][onCellStudentsSelected] 드래그 등록 상태: usedCount=$usedCount');
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 setState 전: , _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
                  setState(() {
            
                    print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 setState 후: , _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
                    if (false) { // 자동 종료 로직 비활성화
                      print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 등록모드 종료');
                      _isStudentRegistrationMode = false;
                      _selectedStudentWithInfo = null;
                      _selectedDayIndex = null;
                      _selectedStartTimeHour = null;
                      _selectedStartTimeMinute = null;
                    }
                  });
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 return');
                  return;
                }
                if (startTimes.length == 1) {
                  // 클릭 등록 분기: 기존대로 블록 생성/중복체크/등록
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 분기 진입: startTimes=$startTimes, startTimes.length=${startTimes.length}');
                  final studentWithInfo = _selectedStudentWithInfo!;
                  final student = studentWithInfo.student;
                  final blockMinutes = 30; // 한 블록 30분 기준
                  List<DateTime> actualStartTimes = startTimes;
                  final lessonDuration = DataManager.instance.academySettings.lessonDuration;
                  final blockCount = (lessonDuration / blockMinutes).ceil();
                  actualStartTimes = List.generate(blockCount, (i) => startTimes.first.add(Duration(minutes: i * blockMinutes)));
                  print('[DEBUG][onCellStudentsSelected] 클릭 등록 생성할 블록 actualStartTimes: $actualStartTimes');
                  final allBlocks = DataManager.instance.studentTimeBlocks;
                  bool hasConflict = false;
                  for (final startTime in actualStartTimes) {
                    // startTimes는 내부 그리드(DateTime.now 기반)라 날짜가 의미 없을 수 있어,
                    // 현재 화면의 선택 날짜(_selectedDate) 기준으로만 활성 중복을 판단한다.
                    final dateOnly = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
                    final conflictBlock = allBlocks.firstWhereOrNull((b) =>
                      b.studentId == student.id &&
                      b.dayIndex == dayIdx &&
                      b.startHour == startTime.hour &&
                      b.startMinute == startTime.minute &&
                      _isBlockActiveOnDate(b, dateOnly));
                    if (conflictBlock != null) {
                      hasConflict = true;
                      print('[DEBUG][onCellStudentsSelected] 클릭 등록 중복 블록 발견: $conflictBlock');
                      break;
                    }
                  }
                  if (hasConflict) {
                    print('[DEBUG][onCellStudentsSelected] 클릭 등록 중복 SnackBar 발생');
                    showAppSnackBar(context, '이미 등록된 시간입니다.', useRoot: true);
                    return;
                  }
                  var blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
                    studentIds: [student.id],
                    dayIndex: dayIdx,
                    startTimes: actualStartTimes,
                    duration: Duration(minutes: blockMinutes),
                  );
                  blocks = _applySelectedClassId(blocks);
                  print('[DEBUG][onCellStudentsSelected] 클릭 등록 생성된 블록: ${blocks.map((b) => b.toJson()).toList()}');
                  // 한번에 추가하여 UI가 동시에 갱신되도록 처리
                  await DataManager.instance.bulkAddStudentTimeBlocks(blocks, immediate: true);
                  print('[DEBUG][onCellStudentsSelected] 클릭 등록 loadStudentTimeBlocks 호출');
                  await DataManager.instance.loadStudentTimeBlocks();
                  final allBlocksAfter = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
                  final setIds = allBlocksAfter.map((b) => b.setId).toSet();
                  final usedCount = setIds.length;
                  print('[DEBUG][onCellStudentsSelected] 클릭 등록 상태: usedCount=$usedCount');
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 setState 전: , _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
                  setState(() {
            
                    print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 setState 후: , _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
                    if (false) { // 자동 종료 로직 비활성화
                      print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 등록모드 종료');
                      _isStudentRegistrationMode = false;
                      _selectedStudentWithInfo = null;
                      _selectedDayIndex = null;
                      _selectedStartTimeHour = null;
                      _selectedStartTimeMinute = null;
                    }
                  });
                  if (false && mounted) { // 자동 종료 로직 비활성화
                    print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 완료 스낵바');
                    showAppSnackBar(context, '\x1b[33m${student.name}\x1b[0m 학생의 수업시간 등록이 완료되었습니다.', useRoot: true);
                  }
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 return');
                }
              }
            },
            filteredStudentIds: timetableFilteredStudentIds, // 추가: 필터 적용
            selectedStudentWithInfo: _selectedStudentWithInfo, // 추가
            onCellSelfStudyStudentsChanged: (dayIdx, startTime, students) {
              // 자습 블록 수정 로직은 TimetableContentView에서 처리
            },
          ),
        ),
      ],
    );
  }

  Future<void> _handleTimeSelection(int dayIdx, DateTime startTime) async {
    print('[DEBUG] _handleTimeSelection called: dayIdx= [33m$dayIdx [0m, startTime= [33m$startTime [0m, _isStudentRegistrationMode=$_isStudentRegistrationMode, ');
    if (_isStudentRegistrationMode) {
      // 학생 등록: 이미 선택된 학생(_selectedStudentWithInfo)로 바로 등록
      final studentWithInfo = _selectedStudentWithInfo;
      print('[DEBUG] _selectedStudentWithInfo: $studentWithInfo');
      if (studentWithInfo != null) {
        // 2. 시간블록 추가 (팩토리 사용, 단일 등록도 일관성 있게)
        final range = await _pickBlockEffectiveRange(context);
        if (range == null) {
          showAppSnackBar(context, '등록이 취소되었습니다.', useRoot: true);
          return;
        }
        var blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
          studentIds: [studentWithInfo.student.id],
          dayIndex: dayIdx,
          startTimes: [startTime],
          duration: Duration(minutes: DataManager.instance.academySettings.lessonDuration),
          startDate: range.start,
          endDate: range.end,
        );
        blocks = _applySelectedClassId(blocks);
        await DataManager.instance.addStudentTimeBlock(blocks.first);
        print('[DEBUG] StudentTimeBlock 등록 완료: ${blocks.first}');
        // 스낵바 출력
        if (mounted) {
          print('[DEBUG] 스낵바 출력');
          showAppSnackBar(context, '${studentWithInfo.student.name} 학생의 시간이 등록되었습니다.', useRoot: true);
        } else {
          print('[DEBUG] context not mounted, 스낵바 출력 불가');
        }
      } else {
        print('[DEBUG] studentWithInfo == null, 등록 실패');
      }
      setState(() {
        // 등록모드 유지, 다음 셀 선택 대기 (자동 종료 안함)
        // 등록 완료되어도 계속 등록 모드 유지
      });
      // 마지막 등록 후 안내
      if (false) { // 마지막 등록 후 안내 로직 비활성화
        if (mounted && _selectedStudentWithInfo != null) {
          showAppSnackBar(context, '${_selectedStudentWithInfo!.student.name} 학생의 수업시간 등록이 완료되었습니다.', useRoot: true);
        }
      }
      return;
    }
    if (_isClassRegistrationMode && _currentGroupSchedule != null) {
      print('[DEBUG] 클래스 등록모드 진입');
      // 기존 클래스 등록 로직은 유지
      final updatedSchedule = _currentGroupSchedule!.copyWith(
        startTime: startTime,
        dayIndex: dayIdx,
      );
      if (_currentGroupSchedule!.createdAt == _currentGroupSchedule!.updatedAt) {
        await DataManager.instance.addGroupSchedule(updatedSchedule);
        print('[DEBUG] 새 클래스 스케줄 등록');
      } else {
        await DataManager.instance.updateGroupSchedule(updatedSchedule);
        print('[DEBUG] 기존 클래스 스케줄 수정');
      }
      await DataManager.instance.applyGroupScheduleToStudents(updatedSchedule);
      setState(() {
        print('[DEBUG] setState: 클래스 등록모드 종료');
        _isClassRegistrationMode = false;
        _currentGroupSchedule = null;
        _selectedDayIndex = null;
        _selectedStartTimeHour = null;
        _selectedStartTimeMinute = null;
      });
      if (mounted) {
        print('[DEBUG] 클래스 스낵바 출력');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_selectedGroup!.name} 클래스 시간이 등록되었습니다.'),
            backgroundColor: const Color(0xFF1976D2),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 80, left: 20, right: 20),
          ),
        );
      } else {
        print('[DEBUG] context not mounted, 클래스 스낵바 출력 불가');
      }
    }
  }

  // --- 필터 학생 getter 및 변환 함수 복구 ---
  List<StudentWithInfo> get _filteredStudents {
    final all = DataManager.instance.students;
    final f = _activeFilter;
    if (f == null) return all;
    final filtered = all.where((s) {
      final student = s.student;
      final info = s.basicInfo;
      if (f['educationLevels']!.isNotEmpty) {
        final levelStr = _educationLevelToKor(student.educationLevel);
        if (!f['educationLevels']!.contains(levelStr)) return false;
      }
      if (f['grades']!.isNotEmpty) {
        final gradeStr = _gradeToKor(student.educationLevel, student.grade);
        if (!f['grades']!.contains(gradeStr)) return false;
      }
      if (f['schools']!.isNotEmpty && !f['schools']!.contains(student.school)) return false;
      if (f['groups']!.isNotEmpty && (student.groupInfo == null || !f['groups']!.contains(student.groupInfo!.name))) return false;
      
      // 수업별 필터링 추가
      if (f['classes']!.isNotEmpty) {
        final classes = DataManager.instance.classesNotifier.value;
        final selectedClassIds = f['classes']!.map((className) {
          final classInfo = classes.firstWhereOrNull((c) => c.name == className);
          return classInfo?.id ?? (className == '수업' ? '__default_class__' : null);
        }).where((id) => id != null).cast<String>().toSet();

        if (selectedClassIds.isNotEmpty) {
          final studentBlocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
          final hasMatchingClass = studentBlocks.any((block) =>
            (block.sessionTypeId == null && selectedClassIds.contains('__default_class__')) ||
            (block.sessionTypeId != null && selectedClassIds.contains(block.sessionTypeId)));
          if (!hasMatchingClass) return false;
        }
      }
      
      return true;
    }).toList();
    print('[DEBUG] 필터 적용 결과: ${filtered.map((s) => s.student.name).toList()}');
    return filtered;
  }

  Set<String> _classIdsFromFilter(Map<String, Set<String>>? f) {
    if (f == null || !(f['classes']?.isNotEmpty ?? false)) return {};
    final classes = DataManager.instance.classesNotifier.value;
    final ids = f['classes']!
        .map((name) => classes.firstWhereOrNull((c) => c.name == name)?.id)
        .whereType<String>()
        .toSet();
    // 기본 수업(세션 null) 필터 지원: 이름이 '수업'이거나 id가 '__default_class__'인 경우 포함
    if (f['classes']!.contains('수업') || f['classes']!.contains('__default_class__')) {
      ids.add('__default_class__');
    }
    return ids;
  }

  bool _isFilterEmptyExceptClasses(Map<String, Set<String>> f) {
    return (f['educationLevels']?.isEmpty ?? true) &&
        (f['grades']?.isEmpty ?? true) &&
        (f['schools']?.isEmpty ?? true) &&
        (f['groups']?.isEmpty ?? true);
  }

  void _toggleClassQuickFilter(ClassInfo classInfo) {
    final className = classInfo.name.isNotEmpty ? classInfo.name : '수업';
    final current = _activeFilter;
    final currentClasses = current?['classes'] ?? <String>{};
    final onlyThisClassActive = current != null &&
        _isFilterEmptyExceptClasses(current) &&
        currentClasses.length == 1 &&
        currentClasses.contains(className);

    setState(() {
      if (onlyThisClassActive) {
        _activeFilter = null;
        _selectedClasses.clear();
      } else {
        _selectedEducationLevels.clear();
        _selectedGrades.clear();
        _selectedSchools.clear();
        _selectedGroups.clear();
        _selectedClasses = {className};
        _activeFilter = {
          'educationLevels': <String>{},
          'grades': <String>{},
          'schools': <String>{},
          'groups': <String>{},
          'classes': {className},
        };
      }
    });
  }

  String _educationLevelToKor(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary: return '초등';
      case EducationLevel.middle: return '중등';
      case EducationLevel.high: return '고등';
    }
  }

  String _gradeToKor(EducationLevel level, int grade) {
    if (level == EducationLevel.elementary) return '초$grade';
    if (level == EducationLevel.middle) return '중$grade';
    if (level == EducationLevel.high) {
      if (grade >= 1 && grade <= 3) return '고$grade';
      if (grade == 0) return 'N수';
    }
    return '';
  }

  // dayIdx, startTime에 해당하는 학생 리스트 반환
  List<StudentWithInfo> _getCellStudents(int dayIdx, int startHour, int startMinute) {
    final blocks = DataManager.instance.studentTimeBlocks.where((b) {
      //print('[DEBUG][_getCellStudents] 비교: b.dayIndex=${b.dayIndex} == $dayIdx, b.startHour=${b.startHour} == $startHour, b.startMinute=${b.startMinute} == $startMinute, b.studentId=${b.studentId}');
      return b.dayIndex == dayIdx && b.startHour == startHour && b.startMinute == startMinute;
    }).toList();
    final students = DataManager.instance.students;
    final result = blocks.map((b) =>
      students.firstWhere(
        (s) => s.student.id == b.studentId,
        orElse: () => StudentWithInfo(
          student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
          basicInfo: StudentBasicInfo(studentId: ''),
        ),
      )
    ).toList();
    //print('[DEBUG][_getCellStudents] dayIdx=$dayIdx, startHour=$startHour, startMinute=$startMinute, blockCount=${blocks.length}, studentIds=${result.map((s) => s.student.id).toList()}');
    return result;
  }

  void _handleSelfStudyRegistration() {
    showDialog(
      context: context,
      builder: (context) => SelfStudyRegistrationDialog(
        onStudentSelected: (student) {
          setState(() {
            _isSelfStudyRegistrationMode = true;
            _selectedSelfStudyStudent = student;
            print('[DEBUG][setState] _selectedSelfStudyStudent:  [33m$_selectedSelfStudyStudent [0m');
          });
        },
      ),
    ).then((value) {
      if (value != null) {
        setState(() {
          _isSelfStudyRegistrationMode = true;
          _selectedSelfStudyStudent = value;
          if (_kRegistrationPerfDebug) {
            // ignore: avoid_print
            print('[DEBUG][TimetableScreen] showDialog 반환값: $value');
          }
        });
      }
    });
  }
}

class _HeaderSelectButton extends StatefulWidget {
  const _HeaderSelectButton({
    Key? key,
    required this.isSelectMode,
    this.onModeChanged,
    this.onSelectAll,
  }) : super(key: key);

  final bool isSelectMode;
  final ValueChanged<bool>? onModeChanged;
  final VoidCallback? onSelectAll;

  @override
  State<_HeaderSelectButton> createState() => _HeaderSelectButtonState();
}

class _HeaderSelectButtonState extends State<_HeaderSelectButton> {
  static const double _height = 48;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      layoutBuilder: (currentChild, previousChildren) => currentChild ?? const SizedBox.shrink(),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: widget.isSelectMode ? _buildExpanded() : _buildSelectButton(),
    );
  }

  Widget _buildSelectButton() {
    return _pillButton(
      key: const ValueKey('select'),
      width: 78,
      child: const Text(
        '선택',
        style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 16),
      ),
      onTap: () => widget.onModeChanged?.call(true),
    );
  }

  Widget _buildExpanded() {
    return Row(
      key: const ValueKey('expanded'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _pillButton(
          width: 64.4,
          child: const Text(
            '모두',
            style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 16),
          ),
          onTap: widget.onSelectAll ?? () {},
        ),
        const SizedBox(width: 8),
        _pillButton(
          width: 48,
          child: const Icon(Icons.close, color: Colors.white, size: 20),
          onTap: () => widget.onModeChanged?.call(false),
        ),
      ],
    );
  }

  Widget _pillButton({
    required Widget child,
    required VoidCallback onTap,
    required double width,
    Key? key,
  }) {
    return SizedBox(
      key: key,
      height: _height,
      width: width,
      child: Material(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(_height / 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(_height / 2),
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _MemoSlideOverlay extends StatefulWidget {
  final ValueListenable<bool> isOpenListenable;
  final ValueListenable<List<MemoItem>> memosListenable;
  final Future<void> Function(BuildContext context) onAddMemo;
  final Future<void> Function(BuildContext context, MemoItem item) onEditMemo;
  const _MemoSlideOverlay({
    Key? key,
    required this.isOpenListenable,
    required this.memosListenable,
    required this.onAddMemo,
    required this.onEditMemo,
  }) : super(key: key);

  @override
  State<_MemoSlideOverlay> createState() => _MemoSlideOverlayState();
}

class _MemoSlideOverlayState extends State<_MemoSlideOverlay> {
  bool _hoveringEdge = false;
  bool _panelHovered = false;
  Timer? _closeTimer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double panelWidth = 75;
        return Stack(
          children: [
            // 우측 24px 호버 감지영역
            Positioned(
              right: 0,
              top: kToolbarHeight, // 상단 앱바 영역 비차단
              bottom: 0, // 하단까지 확장
              width: 24,
              child: MouseRegion(
                onEnter: (_) {
                  _hoveringEdge = true;
                  _setOpen(true);
                  _cancelCloseTimer();
                },
                onExit: (_) {
                  _hoveringEdge = false;
                  _scheduleMaybeClose();
                },
                child: const SizedBox.shrink(),
              ),
            ),
            // 패널 본체
            ValueListenableBuilder<bool>(
              valueListenable: widget.isOpenListenable,
              builder: (context, open, _) {
                return AnimatedPositioned(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  right: open ? 0 : -panelWidth,
                  top: kToolbarHeight,
                  bottom: 0,
                  width: panelWidth,
                  child: MouseRegion(
                    onEnter: (_) {
                      _panelHovered = true;
                      _cancelCloseTimer();
                    },
                    onExit: (_) {
                      _panelHovered = false;
                      _scheduleMaybeClose();
                    },
                    child: _MemoPanel(
                      memosListenable: widget.memosListenable,
                      onAddMemo: () => widget.onAddMemo(context),
                      onEditMemo: (item) => widget.onEditMemo(context, item),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  void _setOpen(bool value) {
    if (widget.isOpenListenable is ValueNotifier<bool>) {
      (widget.isOpenListenable as ValueNotifier<bool>).value = value;
    }
  }

  void _scheduleMaybeClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 220), () {
      if (!_hoveringEdge && !_panelHovered) {
        _setOpen(false);
      }
    });
  }

  void _cancelCloseTimer() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }
}

class _MemoPanel extends StatelessWidget {
  final ValueListenable<List<MemoItem>> memosListenable;
  final VoidCallback onAddMemo;
  final void Function(MemoItem item) onEditMemo;
  const _MemoPanel({required this.memosListenable, required this.onAddMemo, required this.onEditMemo});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF18181A),
        border: Border(left: BorderSide(color: Color(0xFF2A2A2A), width: 1)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          // 상단 + 버튼
          SizedBox(
            height: 40,
            child: IconButton(
              onPressed: onAddMemo,
              icon: const Icon(Icons.add, color: Colors.white, size: 22),
              tooltip: '+ 메모 추가',
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          // 메모 리스트
          Expanded(
            child: ValueListenableBuilder<List<MemoItem>>(
              valueListenable: memosListenable,
              builder: (context, memos, _) {
                if (memos.isEmpty) {
                  return const Center(
                    child: Text('메모 없음', style: TextStyle(color: Colors.white24, fontSize: 12)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: memos.length,
                  itemBuilder: (context, index) {
                    final m = memos[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                      child: Tooltip(
                        message: m.summary, // 호버: 요약본 표시
                        waitDuration: const Duration(milliseconds: 200),
                        child: InkWell(
                          onTap: () => onEditMemo(m),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              m.original,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.2),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoInputDialog extends StatefulWidget {
  const _MemoInputDialog();
  @override
  State<_MemoInputDialog> createState() => _MemoInputDialogState();
}

class _MemoInputDialogState extends State<_MemoInputDialog> {
  final TextEditingController _controller = ImeAwareTextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('메모 추가', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 380,
        child: TextField(
          controller: _controller,
          minLines: 4,
          maxLines: 8,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '메모를 입력하세요',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  final text = _controller.text.trim();
                  if (text.isEmpty) return;
                  setState(() => _saving = true);
                  // 다이얼로그는 텍스트 반환만, 실제 저장은 상위에서 처리
                  Navigator.of(context).pop(text);
                },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

enum _MemoEditAction { save, delete }
class _MemoEditResult {
  final _MemoEditAction action;
  final String text;
  const _MemoEditResult(this.action, this.text);
}

class _MemoEditDialog extends StatefulWidget {
  final String initial;
  const _MemoEditDialog({required this.initial});
  @override
  State<_MemoEditDialog> createState() => _MemoEditDialogState();
}

class _MemoEditDialogState extends State<_MemoEditDialog> {
  late TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = ImeAwareTextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('메모 보기/수정', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          minLines: 6,
          maxLines: 12,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(const _MemoEditResult(_MemoEditAction.delete, '')),
          style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: Colors.red),
          child: const Text('삭제'),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() => _saving = true);
                  final text = _controller.text;
                  Navigator.of(context).pop(_MemoEditResult(_MemoEditAction.save, text));
                },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}


class SelfStudyRegistrationDialog extends StatefulWidget {
  final ValueChanged<StudentWithInfo> onStudentSelected;
  const SelfStudyRegistrationDialog({Key? key, required this.onStudentSelected}) : super(key: key);

  @override
  State<SelfStudyRegistrationDialog> createState() => _SelfStudyRegistrationDialogState();
}

class _SelfStudyRegistrationDialogState extends State<SelfStudyRegistrationDialog> {
  String _searchQuery = '';
  final TextEditingController _searchController = ImeAwareTextEditingController();
  List<StudentWithInfo> get _eligibleStudents => DataManager.instance.getSelfStudyEligibleStudents();
  List<StudentWithInfo> get _searchResults {
    if (_searchQuery.isEmpty) return [];
    final results = _eligibleStudents.where((student) {
      final nameMatch = student.student.name.toLowerCase().contains(_searchQuery.toLowerCase());
      final schoolMatch = student.student.school.toLowerCase().contains(_searchQuery.toLowerCase());
      final gradeMatch = student.student.grade.toString().contains(_searchQuery);
      return nameMatch || schoolMatch || gradeMatch;
    }).toList();
    print('[DEBUG][SelfStudyRegistrationDialog] 자습 등록 가능 학생 검색 결과: ' + results.map((s) => s.student.name).toList().toString());
    return results;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('자습 등록', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                labelText: '학생 이름 또는 학교 검색',
                labelStyle: const TextStyle(color: Colors.white70),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 120,
              child: _searchQuery.isEmpty
                  ? const Center(child: Text('학생을 검색하세요.', style: TextStyle(color: Colors.white38, fontSize: 15)))
                  : _searchResults.isEmpty
                      ? const Center(child: Text('검색 결과가 없습니다.', style: TextStyle(color: Colors.white38, fontSize: 15)))
                      : Scrollbar(
                          thumbVisibility: true,
                          child: ListView.separated(
                            itemCount: _searchResults.length,
                            separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
                            itemBuilder: (context, idx) {
                              final info = _searchResults[idx];
                              return ListTile(
                                title: Text(info.student.name, style: const TextStyle(color: Colors.white)),
                                subtitle: Text('${info.student.school} / ${info.student.grade}학년', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                                onTap: () {
                                  print('[DEBUG][SelfStudyRegistrationDialog] 학생 선택:  [33m${info.student.name} [0m');
                                  Navigator.of(context).pop(info); // 반드시 StudentWithInfo 반환
                                },
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}

class _DropdownMenuButton extends StatefulWidget {
  final bool isOpen;
  final ValueChanged<bool> onOpenChanged;
  final ValueChanged<String> onSelected;
  const _DropdownMenuButton({required this.isOpen, required this.onOpenChanged, required this.onSelected});

  @override
  State<_DropdownMenuButton> createState() => _DropdownMenuButtonState();
}

class _DropdownMenuButtonState extends State<_DropdownMenuButton> with SingleTickerProviderStateMixin {
  final GlobalKey _buttonKey = GlobalKey();
  OverlayEntry? _overlayEntry;
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() {
    _controller.dispose();
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _toggleDropdown() {
    if (_overlayEntry == null) {
      _controller.forward();
      _overlayEntry = _createOverlayEntry();
      Overlay.of(context).insert(_overlayEntry!);
      widget.onOpenChanged(true);
    } else {
      _controller.reverse();
      _removeOverlay();
      widget.onOpenChanged(false);
    }
  }

  OverlayEntry _createOverlayEntry() {
    RenderBox renderBox = _buttonKey.currentContext!.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    return OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx,
        top: offset.dy + size.height + 4,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24), // 상하좌우 여백 24
            decoration: BoxDecoration(
              color: const Color(0xFF1F1F1F), // 학생카드와 동일한 색상
              borderRadius: BorderRadius.circular(16),
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
                ...['학생', '그룹', '보강', '일정'].map((label) =>
                  FadeTransition(
                    opacity: _controller,
                    child: ScaleTransition(
                      scale: _controller,
                      child: _DropdownMenuItem(
                        label: label,
                        onTap: () {
                          widget.onSelected(label);
                          _toggleDropdown();
                        },
                        width: 84, // 30% 줄임 (120 -> 84)
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _buttonKey,
      onTap: _toggleDropdown,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        width: 44,
        height: 44,
        decoration: ShapeDecoration(
          color: const Color(0xFF1976D2),
          shape: RectangleShapeBorder(
            borderRadius: widget.isOpen
              ? DynamicBorderRadius.all(DynamicRadius.circular(50.toPercentLength))
              : DynamicBorderRadius.only(
                  topLeft: DynamicRadius.circular(6.toPXLength),
                  bottomLeft: DynamicRadius.circular(6.toPXLength),
                  topRight: DynamicRadius.circular(32.toPXLength),
                  bottomRight: DynamicRadius.circular(32.toPXLength),
                ),
          ),
        ),
        child: Center(
          child: AnimatedRotation(
            turns: widget.isOpen ? 0.5 : 0.0, // 0.5turn = 180도
            duration: const Duration(milliseconds: 350),
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
    );
  }
}

// 학생카드 하위 버튼 스타일과 동일하게
class _DropdownMenuItem extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final double width;
  const _DropdownMenuItem({required this.label, required this.onTap, this.width = 84});

  @override
  State<_DropdownMenuItem> createState() => _DropdownMenuItemState();
}

class _DropdownMenuItemState extends State<_DropdownMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: widget.width,
          height: 38, // 기존 48에서 20% 감소
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14), // 높이 줄임
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFF353545) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            widget.label,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }
}

// 버튼이 원형/네모로 바뀔 때만 바운스 효과 적용하는 위젯
class _BouncyDropdownButton extends StatefulWidget {
  final bool isOpen;
  final Widget child;
  const _BouncyDropdownButton({required this.isOpen, required this.child});

  @override
  State<_BouncyDropdownButton> createState() => _BouncyDropdownButtonState();
}

class _BouncyDropdownButtonState extends State<_BouncyDropdownButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  bool _prevIsOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.08)
        .chain(CurveTween(curve: Curves.elasticOut))
        .animate(_controller);
    _prevIsOpen = widget.isOpen;
  }

  @override
  void didUpdateWidget(covariant _BouncyDropdownButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOpen != widget.isOpen) {
      if (widget.isOpen) {
        _controller.forward(from: 0);
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: widget.child,
    );
  }
}

