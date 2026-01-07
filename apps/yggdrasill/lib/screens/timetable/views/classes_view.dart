import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/operating_hours.dart';
import '../../../models/student_time_block.dart';
import '../../../models/student.dart';
import '../../../models/group_info.dart';
import '../../../services/data_manager.dart';
import '../../../models/education_level.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/app_snackbar.dart';
import 'components/timetable_cell.dart';
import '../components/timetable_drag_selector.dart';
import '../../../models/self_study_time_block.dart';
import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import '../../../models/session_override.dart';
import '../../../services/consult_inquiry_demand_service.dart';
import '../../../services/consult_trial_lesson_service.dart';

/// registrationModeType: 'student' | 'selfStudy' | null
typedef RegistrationModeType = String?;

// registrationMode 드래그는 PointerMove/Update가 매우 자주 호출된다.
// 과도한 print는 UI 스레드에서 콘솔 I/O로 직결되어 렉을 유발하므로 기본 OFF.
const bool _kRegistrationPerfDebug = false;

class _BlockRange {
  final DateTime start;
  final DateTime? end;
  const _BlockRange({required this.start, this.end});
}

// ✅ 성능: 셀 선택/하이라이트 변경으로 ClassesView가 rebuild 될 때,
// 주차 그리드(7일×타임슬롯)에서 매번 전체 블록을 반복 스캔하면(=O(슬롯수*블록수))
// 릴리즈에서도 0.5~1s 체감 지연이 생길 수 있다.
//
// weekStart + 필터 + studentTimeBlocksRevision 기준으로 “슬롯 → 활성 블록/오버레이/블라인드”를 캐시해
// 셀 클릭 시에는 O(1) lookup으로만 처리한다. (로직/결과는 동일)
class _ClassesWeekRenderCache {
  final String key;
  final DateTime weekStart; // date-only Monday
  final DateTime weekEnd; // exclusive (weekStart + 7d)

  final List<StudentTimeBlock> filteredStudentBlocks;
  final List<SelfStudyTimeBlock> filteredSelfStudyBlocks;
  final Map<String, StudentWithInfo> studentById;

  // key: slotKey(dayIdx,hour,minute)
  final Map<String, List<StudentTimeBlock>> activeStudentBlocksBySlotKey;
  final Map<String, List<SelfStudyTimeBlock>> selfStudyBlocksBySlotKey;

  // replace 원본 블라인드: dayIdx -> {'studentId|setId', ...}
  final Map<int, Set<String>> hiddenStudentSetPairsByDay;
  // setId를 못 찾는 예외 케이스: slotKey -> {studentId, ...}
  final Map<String, Set<String>> hiddenOriginalStudentIdsBySlotKey;

  // 보강/추가 오버레이(시각 표시): slotKey -> labels
  final Map<String, List<OverlayLabel>> makeupOverlaysBySlotKey;
  // 보강/추가 인원 가산(중복 제거용): slotKey -> {studentId, ...}
  final Map<String, Set<String>> makeupStudentIdsBySlotKey;

  const _ClassesWeekRenderCache({
    required this.key,
    required this.weekStart,
    required this.weekEnd,
    required this.filteredStudentBlocks,
    required this.filteredSelfStudyBlocks,
    required this.studentById,
    required this.activeStudentBlocksBySlotKey,
    required this.selfStudyBlocksBySlotKey,
    required this.hiddenStudentSetPairsByDay,
    required this.hiddenOriginalStudentIdsBySlotKey,
    required this.makeupOverlaysBySlotKey,
    required this.makeupStudentIdsBySlotKey,
  });
}

class ClassesView extends StatefulWidget {
  final List<OperatingHours> operatingHours;
  final Color breakTimeColor;
  final bool isRegistrationMode; // deprecated
  final RegistrationModeType registrationModeType;
  final int? selectedDayIndex;
  final int? selectedCellDayIndex;
  final DateTime? selectedCellStartTime;
  final void Function(int dayIdx, DateTime startTime)? onTimeSelected;
  final void Function(int dayIdx, List<DateTime> startTimes, List<StudentWithInfo> students)? onCellStudentsSelected;
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo> students)? onCellSelfStudyStudentsChanged;
  /// 문의(희망수업) 오버레이 라벨 클릭 시 호출 (예: 문의 노트로 이동)
  final void Function(String noteId)? onInquiryNoteTap;
  final ScrollController scrollController;
  final Set<String>? filteredStudentIds; // 추가: 필터된 학생 id 리스트
  final Set<String>? filteredClassIds; // 추가: 필터된 수업 id 리스트(__default_class__ 포함)
  final StudentWithInfo? selectedStudentWithInfo; // 변경: 학생+부가정보 통합 객체
  final StudentWithInfo? selectedSelfStudyStudent;
  final void Function(bool)? onSelectModeChanged; // 추가: 선택모드 해제 콜백
  final DateTime weekStartDate; // 월요일 날짜(해당 주 시작)
  /// 다중 선택(예: 희망 수업시간 선택 다이얼로그)에서 선택된 슬롯 하이라이트용
  /// 키 포맷: '$dayIdx-$hour:$minute' (dayIdx: 0=월..6=일)
  final Set<String>? selectedSlotKeys;

  const ClassesView({
    super.key,
    required this.operatingHours,
    this.breakTimeColor = const Color(0xFF424242),
    this.isRegistrationMode = false, // deprecated
    this.registrationModeType,
    this.selectedDayIndex,
    this.selectedCellDayIndex,
    this.selectedCellStartTime,
    this.onTimeSelected,
    this.onCellStudentsSelected,
    this.onCellSelfStudyStudentsChanged,
    this.onInquiryNoteTap,
    required this.scrollController,
    this.filteredStudentIds, // 추가
    this.filteredClassIds, // 추가
    this.selectedStudentWithInfo, // 변경
    this.selectedSelfStudyStudent,
    this.onSelectModeChanged, // 추가
    required this.weekStartDate,
    this.selectedSlotKeys,
  });

  @override
  State<ClassesView> createState() => _ClassesViewState();
}

class _ClassesViewState extends State<ClassesView> with TickerProviderStateMixin {
  String? _expandedCellKey;
  final Map<String, GlobalKey> _cellKeys = {};
  final Map<String, AnimationController> _animationControllers = {};
  final Map<String, Animation<double>> _animations = {};
  // 기존: final ScrollController _scrollController = ScrollController();
  // 변경: widget.scrollController 사용
  String? _hoveredCellKey;
  bool _hasScrolledToCurrentTime = false;
  int _lastOverlayTapMs = 0; // 오버레이(희망/시범) 라벨 탭 후 셀 탭 로직이 같이 타지 않도록 가드
  late final VoidCallback _inquiryDemandListener;
  late final VoidCallback _trialLessonListener;
  String? _weekRenderCacheKey;
  _ClassesWeekRenderCache? _weekRenderCache;

  bool _isClassAllowed(String? sessionTypeId) {
    final cids = widget.filteredClassIds;
    if (cids == null || cids.isEmpty) return true;
    if (sessionTypeId == null || sessionTypeId.isEmpty) {
      return cids.contains('__default_class__');
    }
    return cids.contains(sessionTypeId);
  }

  // 드래그 상태 변수 (UI 구조는 그대로, 상태만 추가)
  int? dragStartIdx;
  int? dragEndIdx;
  int? dragDayIdx;
  bool isDragging = false;
  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;

  Future<_BlockRange?> _pickBlockRange(BuildContext context) async {
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
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
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
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
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
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
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

  @override
  void initState() {
    super.initState();
    _inquiryDemandListener = () {
      if (mounted) setState(() {});
    };
    ConsultInquiryDemandService.instance.slotsNotifier.addListener(_inquiryDemandListener);

    _trialLessonListener = () {
      if (mounted) setState(() {});
    };
    ConsultTrialLessonService.instance.slotsNotifier.addListener(_trialLessonListener);
  }

  Set<String> get dragHighlightKeys {
    if (!isDragging || dragDayIdx == null || dragStartIdx == null || dragEndIdx == null) return {};
    final start = dragStartIdx!;
    final end = dragEndIdx!;
    final day = dragDayIdx!;
    if (start <= end) {
      return {for (int i = start; i <= end; i++) '$day-$i'};
    } else {
      return {for (int i = end; i <= start; i++) '$day-$i'};
    }
  }

  void _onCellPanStart(int dayIdx, int blockIdx) {
    final timeBlocks = _generateTimeBlocks();
    final blockTime = timeBlocks[blockIdx].startTime;
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanStart] dayIdx=$dayIdx, blockIdx=$blockIdx, isDragging=$isDragging');
    }
    setState(() {
      dragStartIdx = blockIdx;
      dragEndIdx = blockIdx;
      dragDayIdx = dayIdx;
      isDragging = true;
    });
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanStart] dragStartIdx=$dragStartIdx, dragEndIdx=$dragEndIdx, dragDayIdx=$dragDayIdx, isDragging=$isDragging');
    }
  }

  void _onCellPanUpdate(int dayIdx, int blockIdx) {
    final timeBlocks = _generateTimeBlocks();
    final blockTime = timeBlocks[blockIdx].startTime;
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanUpdate] dayIdx=$dayIdx, blockIdx=$blockIdx, isDragging=$isDragging, dragDayIdx=$dragDayIdx');
    }
    if (!isDragging || dragDayIdx != dayIdx) return;
    if (dragEndIdx != blockIdx) {
      setState(() {
        dragEndIdx = blockIdx;
      });
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG][_onCellPanUpdate] dragEndIdx updated: $dragEndIdx');
      }
    }
  }

  void _onCellPanEnd(int dayIdx) async {
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd] 호출: dayIdx=$dayIdx, isDragging=$isDragging, dragDayIdx=$dragDayIdx, dragStartIdx=$dragStartIdx, dragEndIdx=$dragEndIdx');
    }
    if (!isDragging || dragDayIdx != dayIdx || dragStartIdx == null || dragEndIdx == null) {
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG][_onCellPanEnd] 드래그 종료 조건 미달, 드래그 상태 해제');
      }
      setState(() { isDragging = false; });
      return;
    }
    _BlockRange? range;
    final start = dragStartIdx!;
    final end = dragEndIdx!;
    final selectedIdxs = start <= end
        ? [for (int i = start; i <= end; i++) i]
        : [for (int i = end; i <= start; i++) i];
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd] selectedIdxs=$selectedIdxs');
    }
    setState(() {
      isDragging = false;
      dragStartIdx = null;
      dragEndIdx = null;
      dragDayIdx = null;
    });
    final mode = widget.registrationModeType;
    final timeBlocks = _generateTimeBlocks();
    List<DateTime> startTimes = selectedIdxs.map((blockIdx) => timeBlocks[blockIdx].startTime).toList();
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd] startTimes=$startTimes');
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd] mode=$mode, selectedStudentWithInfo=${widget.selectedStudentWithInfo}, startTimes.length=${startTimes.length}');
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] 진입: dayIdx=$dayIdx, startTimes=$startTimes, mode=$mode');
    }
    if (mode == 'student' && widget.selectedStudentWithInfo != null) {
      // 단일 슬롯은 "기준 수업시간(lessonDuration)"만큼 블록을 생성하는 클릭 로직과 동일해야 하므로
      // 상위 콜백으로 위임한다(등록모드에서는 콜백 쪽에서 pending 누적).
      if (startTimes.length <= 1) {
        if (widget.onCellStudentsSelected != null) {
          widget.onCellStudentsSelected!(dayIdx, startTimes, [widget.selectedStudentWithInfo!]);
        } else {
          await _handleCellStudentsSelected(dayIdx, startTimes, [widget.selectedStudentWithInfo!]);
        }
        return;
      }

      // 드래그(복수 슬롯) 등록은 사용자가 직접 선택한 셀들만 생성
      range = await _pickBlockRange(context);
      if (range == null) {
        showAppSnackBar(context, '등록이 취소되었습니다.');
        return;
      }
      final studentId = widget.selectedStudentWithInfo!.student.id;
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG][_onCellPanEnd] 드래그 등록 분기 진입');
      }
      final blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
        studentIds: [studentId],
        dayIndex: dayIdx,
        startTimes: startTimes,
        duration: const Duration(minutes: 30),
        startDate: range.start,
        endDate: range.end,
      );
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG][_onCellPanEnd] 드래그 등록 생성 블록: count=${blocks.length}, startTimes=$startTimes');
      }
      // 등록모드: 저장은 ESC/우클릭 종료 시 한 번에 upsert
      await DataManager.instance.bulkAddStudentTimeBlocksDeferred(blocks);
      if (widget.onCellStudentsSelected != null) {
        widget.onCellStudentsSelected!(dayIdx, startTimes, [widget.selectedStudentWithInfo!]);
      }
      return;
    }
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd] 방어로직 진입');
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd] 중복 체크 진입');
    }
    bool hasConflict = false;
    if (mode == 'student' && widget.selectedStudentWithInfo != null) {
      final studentId = widget.selectedStudentWithInfo!.student.id;
      final refDate = range?.start;
      if (refDate == null) {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_onCellPanEnd] 중복 체크: refDate null -> return');
        }
        return;
      }
      for (final startTime in startTimes) {
        if (_isStudentTimeOverlap(studentId, dayIdx, startTime, 30, refDate: refDate)) {
          if (_kRegistrationPerfDebug) {
            // ignore: avoid_print
            print('[DEBUG][_onCellPanEnd] 중복 체크: 이미 등록된 시간 startTime=$startTime');
          }
          hasConflict = true;
          break;
        }
      }
    }
    if (hasConflict) {
      if (mounted) {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_onCellPanEnd] 중복 체크: 스낵바 호출');
        }
        showAppSnackBar(context, '이미 등록된 시간입니다.', useRoot: true);
        if (widget.onSelectModeChanged != null) widget.onSelectModeChanged!(false);
      }
      return;
    }
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd] 기타 등록 분기 진입');
    }
    // [수정] 30분짜리 블록만 생성
    if (mode == 'student' && widget.selectedStudentWithInfo != null) {
      final studentId = widget.selectedStudentWithInfo!.student.id;
      final blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
        studentIds: [studentId],
        dayIndex: dayIdx,
        startTimes: startTimes,
        duration: const Duration(minutes: 30),
        startDate: range!.start,
        endDate: range!.end,
      );
      // 등록모드: 저장은 ESC/우클릭 종료 시 한 번에 upsert
      await DataManager.instance.bulkAddStudentTimeBlocksDeferred(blocks);
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] bulkAddStudentTimeBlocks 완료');
      }
      setState(() {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] setState 호출');
        }
      });
    }
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] onCellStudentsSelected 콜백 호출');
    }
    if (mode == 'student' && widget.selectedStudentWithInfo != null) {
      if (widget.onCellStudentsSelected != null) {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] 외부 콜백 호출');
        }
        widget.onCellStudentsSelected!(dayIdx, startTimes, [widget.selectedStudentWithInfo!]);
      } else {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] 내부 핸들러 호출');
        }
        final refDate = range?.start;
        await _handleCellStudentsSelected(dayIdx, startTimes, [widget.selectedStudentWithInfo!], refDate: refDate);
      }
    } else if (mode == 'selfStudy' && widget.selectedSelfStudyStudent != null) {
      if (widget.onCellStudentsSelected != null) {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] 외부 콜백 호출(자습)');
        }
        widget.onCellStudentsSelected!(dayIdx, startTimes, [widget.selectedSelfStudyStudent!]);
      } else {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] 내부 핸들러 호출(자습)');
        }
        await _handleCellStudentsSelected(dayIdx, startTimes, [widget.selectedSelfStudyStudent!]);
      }
    } else {
      if (_kRegistrationPerfDebug) {
        // ignore: avoid_print
        print('[DEBUG][_onCellPanEnd][${DateTime.now().toIso8601String()}] 등록 분기 진입 실패: mode=$mode, selectedStudentWithInfo=${widget.selectedStudentWithInfo}, selectedSelfStudyStudent=${widget.selectedSelfStudyStudent}');
      }
    }
  }

  @override
  void dispose() {
    ConsultInquiryDemandService.instance.slotsNotifier.removeListener(_inquiryDemandListener);
    ConsultTrialLessonService.instance.slotsNotifier.removeListener(_trialLessonListener);
    for (var controller in _animationControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // print('[DEBUG][ClassesView] build 호출, filteredStudentIds=${widget.filteredStudentIds}');
    if (!widget.isRegistrationMode && _hoveredCellKey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() { _hoveredCellKey = null; });
      });
    }
    // print('[DEBUG][ClassesView.build] isRegistrationMode=${widget.isRegistrationMode}, registrationModeType=${widget.registrationModeType}');
    final timeBlocks = _generateTimeBlocks();
    final double blockHeight = 90.0;
    return Stack(
      children: [
        SingleChildScrollView(
          controller: widget.scrollController,
          child: ValueListenableBuilder<int>(
            valueListenable: DataManager.instance.studentTimeBlocksRevision,
            builder: (context, __, ___) {
              final studentTimeBlocks = DataManager.instance.studentTimeBlocks;
              final lessonDuration = DataManager.instance.academySettings.lessonDuration;
              final String? _pendingStudentId = (widget.isRegistrationMode &&
                      widget.registrationModeType == 'student' &&
                      widget.selectedStudentWithInfo != null)
                  ? widget.selectedStudentWithInfo!.student.id
                  : null;
              final Set<String> _pendingSlotKeys = <String>{};
              if (_pendingStudentId != null) {
                for (final b in DataManager.instance.pendingStudentTimeBlocks) {
                  if (b.studentId != _pendingStudentId) continue;
                  _pendingSlotKeys.add(ConsultInquiryDemandService.slotKey(
                    b.dayIndex,
                    b.startHour,
                    b.startMinute,
                  ));
                }
              }
              final inquiryCountBySlot = ConsultInquiryDemandService.instance.countMapForWeekExpanded(
                widget.weekStartDate,
                lessonDurationMinutes: lessonDuration,
              );
              final inquirySlotsBySlotKey = ConsultInquiryDemandService.instance.slotsBySlotKeyForWeek(widget.weekStartDate);
              final trialCountBySlot = ConsultTrialLessonService.instance.countMapForWeekExpanded(
                widget.weekStartDate,
                lessonDurationMinutes: lessonDuration,
              );
              final trialSlotsBySlotKey = ConsultTrialLessonService.instance.slotsBySlotKeyForWeek(widget.weekStartDate);
              final selfStudyTimeBlocks = DataManager.instance.selfStudyTimeBlocks;
              final studentsWithInfo = DataManager.instance.students;
              final groups = DataManager.instance.groups;

              // --- week/필터/revision 기준 렌더 캐시 ---
              final DateTime weekStart = DateTime(
                widget.weekStartDate.year,
                widget.weekStartDate.month,
                widget.weekStartDate.day,
              );
              final DateTime weekEnd = weekStart.add(const Duration(days: 7)); // exclusive

              int _hashSortedIds(Set<String>? ids) {
                if (ids == null || ids.isEmpty) return 0;
                final list = ids.toList()..sort();
                return Object.hashAll(list);
              }

              final int stbRev = DataManager.instance.studentTimeBlocksRevision.value;
              final int studentFilterHash = _hashSortedIds(widget.filteredStudentIds);
              final int classFilterHash = _hashSortedIds(widget.filteredClassIds);
              final int ovHash = Object.hashAll(
                DataManager.instance.sessionOverrides.map((o) => Object.hash(
                      o.id,
                      o.version,
                      o.updatedAt.millisecondsSinceEpoch,
                    )),
              );
              final String cacheKey =
                  '$stbRev|${weekStart.toIso8601String().split("T").first}|sf=$studentFilterHash|cf=$classFilterHash|ov=$ovHash';

              _ClassesWeekRenderCache cache;
              if (_weekRenderCacheKey == cacheKey && _weekRenderCache != null) {
                cache = _weekRenderCache!;
              } else {
                final Map<String, StudentWithInfo> studentById = {
                  for (final s in studentsWithInfo) s.student.id: s,
                };

                // 학생 리스트 필터(학생/수업)
                final List<StudentTimeBlock> filteredStudentBlocks =
                    studentTimeBlocks.where((b) {
                  if (widget.filteredStudentIds != null &&
                      !widget.filteredStudentIds!.contains(b.studentId)) {
                    return false;
                  }
                  if (!_isClassAllowed(b.sessionTypeId)) return false;
                  return true;
                }).toList();

                // 자습 블록은 학생 필터만 적용(수업 필터가 있으면 제외)
                final List<SelfStudyTimeBlock> filteredSelfStudyBlocks =
                    (widget.filteredClassIds != null &&
                            widget.filteredClassIds!.isNotEmpty)
                        ? const <SelfStudyTimeBlock>[]
                        : (widget.filteredStudentIds == null
                            ? selfStudyTimeBlocks
                            : selfStudyTimeBlocks
                                .where((b) => widget.filteredStudentIds!
                                    .contains(b.studentId))
                                .toList());

                // slotKey -> active student blocks (week+date range 기준)
                final Map<String, List<StudentTimeBlock>> activeStudentBlocksBySlotKey =
                    <String, List<StudentTimeBlock>>{};
                for (final b in filteredStudentBlocks) {
                  final int d = b.dayIndex;
                  if (d < 0 || d > 6) continue;
                  // 해당 주의 실제 날짜에서 active 여부 확인
                  final DateTime dayDate = weekStart.add(Duration(days: d));
                  final DateTime target = DateTime(dayDate.year, dayDate.month, dayDate.day);
                  final DateTime sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
                  final DateTime? ed = b.endDate == null
                      ? null
                      : DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day);
                  if (sd.isAfter(target)) continue;
                  if (ed != null && ed.isBefore(target)) continue;

                  final int startMin = b.startHour * 60 + b.startMinute;
                  final int endMin = startMin + b.duration.inMinutes;
                  if (endMin <= startMin) continue;
                  int slotMin = ((startMin + 29) ~/ 30) * 30; // ceil to 30-min slot
                  while (slotMin < endMin) {
                    final int hh = slotMin ~/ 60;
                    final int mm = slotMin % 60;
                    final String sk = ConsultInquiryDemandService.slotKey(d, hh, mm);
                    (activeStudentBlocksBySlotKey[sk] ??= <StudentTimeBlock>[]).add(b);
                    slotMin += 30;
                  }
                }

                // slotKey -> selfStudy blocks (duration 기준, date-range 없음)
                final Map<String, List<SelfStudyTimeBlock>> selfStudyBlocksBySlotKey =
                    <String, List<SelfStudyTimeBlock>>{};
                // ✅ 셀 클릭(onTap)에서 자습 블록 수정 분기는 "전체 자습 블록"을 대상으로 한다(기존 로직 유지).
                for (final b in selfStudyTimeBlocks) {
                  final int d = b.dayIndex;
                  if (d < 0 || d > 6) continue;
                  final int startMin = b.startHour * 60 + b.startMinute;
                  final int endMin = startMin + b.duration.inMinutes;
                  if (endMin <= startMin) continue;
                  int slotMin = ((startMin + 29) ~/ 30) * 30;
                  while (slotMin < endMin) {
                    final int hh = slotMin ~/ 60;
                    final int mm = slotMin % 60;
                    final String sk = ConsultInquiryDemandService.slotKey(d, hh, mm);
                    (selfStudyBlocksBySlotKey[sk] ??= <SelfStudyTimeBlock>[]).add(b);
                    slotMin += 30;
                  }
                }

                // studentId/dayIndex -> blocks (setId 유추용, active 필터 없음: 기존 로직 유지)
                final Map<int, Map<String, List<StudentTimeBlock>>> blocksByStudentByDay =
                    <int, Map<String, List<StudentTimeBlock>>>{};
                for (final b in filteredStudentBlocks) {
                  final int d = b.dayIndex;
                  if (d < 0 || d > 6) continue;
                  final m = blocksByStudentByDay.putIfAbsent(d, () => <String, List<StudentTimeBlock>>{});
                  (m[b.studentId] ??= <StudentTimeBlock>[]).add(b);
                }

                // replace 원본 블라인드 캐시(요일 단위/슬롯 단위)
                final Map<int, Set<String>> hiddenPairsByDay = <int, Set<String>>{};
                final Map<String, Set<String>> hiddenOriginalBySlotKey =
                    <String, Set<String>>{};
                final DateTime nowL = DateTime.now();
                final int defaultLessonMinutes =
                    DataManager.instance.academySettings.lessonDuration;
                for (final ov in DataManager.instance.sessionOverrides) {
                  if (ov.reason != OverrideReason.makeup) continue;
                  if (ov.overrideType != OverrideType.replace) continue;
                  if (ov.status == OverrideStatus.canceled) continue;
                  final orig = ov.originalClassDateTime;
                  if (orig == null) continue;
                  if (orig.isBefore(weekStart) || !orig.isBefore(weekEnd)) continue;
                  final int d = (orig.weekday - 1).clamp(0, 6);

                  String? setId = ov.setId;
                  if (setId == null || setId.isEmpty) {
                    final blocksByStudent =
                        blocksByStudentByDay[d]?[ov.studentId] ?? const <StudentTimeBlock>[];
                    if (blocksByStudent.isNotEmpty) {
                      final int origMin = orig.hour * 60 + orig.minute;
                      int bestDiff = 1 << 30;
                      for (final b in blocksByStudent) {
                        final int bm = b.startHour * 60 + b.startMinute;
                        final int diff = (bm - origMin).abs();
                        if (diff < bestDiff && b.setId != null) {
                          bestDiff = diff;
                          setId = b.setId;
                        }
                      }
                    }
                  }

                  if (setId != null && setId.isNotEmpty) {
                    (hiddenPairsByDay[d] ??= <String>{})
                        .add('${ov.studentId}|$setId');
                  } else {
                    // fallback: 시작 슬롯에서만 숨김(기존 로직 유지)
                    final int minutes =
                        (ov.durationMinutes ?? defaultLessonMinutes).clamp(0, 24 * 60);
                    if (minutes <= 0) continue;
                    final DateTime origEnd = DateTime(
                      orig.year,
                      orig.month,
                      orig.day,
                      orig.hour,
                      orig.minute,
                    ).add(Duration(minutes: minutes));
                    if (nowL.isBefore(origEnd)) {
                      final String sk = ConsultInquiryDemandService.slotKey(d, orig.hour, orig.minute);
                      (hiddenOriginalBySlotKey[sk] ??= <String>{}).add(ov.studentId);
                    }
                  }
                }

                // 보강/추가 오버레이 + 인원 가산(학생 id)
                final Map<String, List<OverlayLabel>> makeupOverlaysBySlotKey =
                    <String, List<OverlayLabel>>{};
                final Map<String, Set<String>> makeupStudentIdsBySlotKey =
                    <String, Set<String>>{};
                for (final ov in DataManager.instance.sessionOverrides) {
                  if (ov.reason != OverrideReason.makeup) continue;
                  if (!(ov.overrideType == OverrideType.add ||
                      ov.overrideType == OverrideType.replace)) {
                    continue;
                  }
                  if (ov.status == OverrideStatus.canceled) continue;
                  final rep = ov.replacementClassDateTime;
                  if (rep == null) continue;
                  if (rep.isBefore(weekStart) || !rep.isBefore(weekEnd)) continue;
                  final int d = (rep.weekday - 1).clamp(0, 6);

                  final String skStart = ConsultInquiryDemandService.slotKey(d, rep.hour, rep.minute);

                  // 1) 오버레이: completed도 포함, canceled만 제외(기존 로직 유지)
                  bool isCompleted = false;
                  try {
                    final record = DataManager.instance.getAttendanceRecord(ov.studentId, rep);
                    if (record != null &&
                        record.arrivalTime != null &&
                        record.departureTime != null) {
                      isCompleted = true;
                    }
                  } catch (_) {}
                  final name = studentById[ov.studentId]?.student.name ?? '학생';
                  final label =
                      ov.overrideType == OverrideType.add ? '$name 추가수업' : '$name 보강';
                  (makeupOverlaysBySlotKey[skStart] ??= <OverlayLabel>[]).add(
                    OverlayLabel(text: label, type: ov.overrideType, isCompleted: isCompleted),
                  );

                  // 2) 인원 가산: planned만(=completed/canceled 제외), duration 범위 슬롯에 학생 id 추가
                  if (ov.status == OverrideStatus.completed) continue;
                  if (widget.filteredStudentIds != null &&
                      !widget.filteredStudentIds!.contains(ov.studentId)) {
                    continue;
                  }
                  final int durationMin =
                      (ov.durationMinutes ?? defaultLessonMinutes).clamp(0, 24 * 60);
                  if (durationMin <= 0) continue;
                  final int repStartMin = rep.hour * 60 + rep.minute;
                  final int repEndMin = repStartMin + durationMin;
                  int slotMin = ((repStartMin + 29) ~/ 30) * 30;
                  while (slotMin < repEndMin) {
                    final int hh = slotMin ~/ 60;
                    final int mm = slotMin % 60;
                    final String sk = ConsultInquiryDemandService.slotKey(d, hh, mm);
                    (makeupStudentIdsBySlotKey[sk] ??= <String>{}).add(ov.studentId);
                    slotMin += 30;
                  }
                }

                cache = _ClassesWeekRenderCache(
                  key: cacheKey,
                  weekStart: weekStart,
                  weekEnd: weekEnd,
                  filteredStudentBlocks: filteredStudentBlocks,
                  filteredSelfStudyBlocks: filteredSelfStudyBlocks,
                  studentById: studentById,
                  activeStudentBlocksBySlotKey: activeStudentBlocksBySlotKey,
                  selfStudyBlocksBySlotKey: selfStudyBlocksBySlotKey,
                  hiddenStudentSetPairsByDay: hiddenPairsByDay,
                  hiddenOriginalStudentIdsBySlotKey: hiddenOriginalBySlotKey,
                  makeupOverlaysBySlotKey: makeupOverlaysBySlotKey,
                  makeupStudentIdsBySlotKey: makeupStudentIdsBySlotKey,
                );
                _weekRenderCacheKey = cacheKey;
                _weekRenderCache = cache;
              }

              final filteredStudentBlocks = cache.filteredStudentBlocks;
              final filteredSelfStudyBlocks = cache.filteredSelfStudyBlocks;
              // 인원수 카운트 등 공통 계산에는 student blocks + (수업 필터 없을 때) selfStudy blocks만 사용
              final List<dynamic> filteredBlocks = <dynamic>[
                ...filteredStudentBlocks,
                ...filteredSelfStudyBlocks,
              ];
              // print('[DEBUG][ValueListenableBuilder] filteredBlocks.length=${filteredBlocks.length}, studentsWithInfo.length=${studentsWithInfo.length}, groups.length=${groups.length}, lessonDuration=$lessonDuration');
               return Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  if (!widget.isRegistrationMode) return;
                  _pointerDownPosition = event.position;
                  _pointerDownTime = DateTime.now();
                  setState(() {
                    isDragging = false;
                    dragStartIdx = null;
                    dragEndIdx = null;
                    dragDayIdx = null;
                  });
                },
                onPointerMove: (event) {
                  if (!widget.isRegistrationMode) return;
                  if (_pointerDownPosition == null) return;
                  final moveDistance = (event.position - _pointerDownPosition!).distance;
                  if (!isDragging && moveDistance > 10) {
                    // 드래그 시작! 단 한 번만
                    final box = context.findRenderObject() as RenderBox;
                    final local = box.globalToLocal(_pointerDownPosition!);
                    final blockIdx = (local.dy / blockHeight).floor();
                    final dayIdx = ((local.dx - 60) / ((box.size.width - 60) / 7)).floor();
                    setState(() {
                      isDragging = true;
                      dragStartIdx = blockIdx;
                      dragEndIdx = blockIdx;
                      dragDayIdx = dayIdx;
                    });
                    if (_kRegistrationPerfDebug) {
                      // ignore: avoid_print
                      print('[DEBUG][onPointerMove] 드래그 시작: dayIdx=$dayIdx, blockIdx=$blockIdx');
                    }
                  } else if (isDragging) {
                    final box = context.findRenderObject() as RenderBox;
                    final local = box.globalToLocal(event.position);
                    final blockIdx = (local.dy / blockHeight).floor();
                    final dayIdx = ((local.dx - 60) / ((box.size.width - 60) / 7)).floor();
                    _onCellPanUpdate(dayIdx, blockIdx);
                  }
                },
                onPointerUp: (event) {
                  if (_kRegistrationPerfDebug) {
                    // ignore: avoid_print
                    print('[DEBUG][onPointerUp] isDragging=$isDragging, dragDayIdx=$dragDayIdx, dragStartIdx=$dragStartIdx, dragEndIdx=$dragEndIdx');
                  }
                  if (!widget.isRegistrationMode) return;
                  // 드래그 시작 후라면 무조건 _onCellPanEnd 호출
                  if (isDragging && dragStartIdx != null && dragEndIdx != null) {
                    if (_kRegistrationPerfDebug) {
                      // ignore: avoid_print
                      print('[DEBUG][onPointerUp] _onCellPanEnd 호출');
                    }
                    _onCellPanEnd(dragDayIdx ?? 0); // dragDayIdx가 null이어도 0으로 호출
                  }
                  setState(() {
                    isDragging = false;
                    dragStartIdx = null;
                    dragEndIdx = null;
                    dragDayIdx = null;
                  });
                  _pointerDownPosition = null;
                  _pointerDownTime = null;
                },
                child: Column(
                  children: [
                    for (int blockIdx = 0; blockIdx < timeBlocks.length; blockIdx++)
                      Container(
                        height: blockHeight,
                        decoration: BoxDecoration(
                          color: timeBlocks[blockIdx].isBreakTime ? widget.breakTimeColor : Colors.transparent,
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.white.withOpacity(0.1),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            // Time indicator
                            SizedBox(
                              width: 60,
                              child: Row(
                                children: [
                                  if (blockIdx == _getCurrentTimeBlockIndex(timeBlocks))
                                    Container(
                                      width: 8,
                                      height: blockHeight - 10,
                                      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 0),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF33A373),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        timeBlocks[blockIdx].timeString,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Day columns
                            ...List.generate(7, (dayIdx) {
                              final cellKey = '$dayIdx-$blockIdx';
                              _cellKeys.putIfAbsent(cellKey, () => GlobalKey());
                              // ✅ 활성 블록/블라인드/오버레이는 week 캐시에서 O(1) 조회한다.
                              final String slotKey = ConsultInquiryDemandService.slotKey(
                                dayIdx,
                                timeBlocks[blockIdx].startTime.hour,
                                timeBlocks[blockIdx].startTime.minute,
                              );

                              final List<StudentTimeBlock> activeBlocks =
                                  cache.activeStudentBlocksBySlotKey[slotKey] ??
                                      const <StudentTimeBlock>[];
                              final Set<String> hiddenOriginalIds =
                                  cache.hiddenOriginalStudentIdsBySlotKey[slotKey] ??
                                      const <String>{};
                              final Set<String> hiddenPairs =
                                  cache.hiddenStudentSetPairsByDay[dayIdx] ??
                                      const <String>{};

                              final filteredActiveBlocks = activeBlocks.where((b) {
                                final sid = b.studentId;
                                final setId = b.setId ?? '';
                                if (hiddenOriginalIds.contains(sid)) return false;
                                if (hiddenPairs.contains('$sid|$setId')) return false;
                                return true;
                              }).toList();

                              final cellStudentWithInfos = filteredActiveBlocks
                                  .map((b) => cache.studentById[b.studentId])
                                  .whereType<StudentWithInfo>()
                                  .toList();

                              final List<OverlayLabel> makeupOverlays =
                                  cache.makeupOverlaysBySlotKey[slotKey] ??
                                      const <OverlayLabel>[];

                              final isExpanded = _expandedCellKey == cellKey;
                              final isDragHighlight = dragHighlightKeys.contains(cellKey);
                              final String _slotKey = slotKey;
                              final bool isSelectedCell =
                                  (widget.selectedCellDayIndex == dayIdx &&
                                      widget.selectedCellStartTime != null &&
                                      widget.selectedCellStartTime!.hour == timeBlocks[blockIdx].startTime.hour &&
                                      widget.selectedCellStartTime!.minute == timeBlocks[blockIdx].startTime.minute) ||
                                  (widget.selectedSlotKeys?.contains(
                                        _slotKey,
                                      ) ??
                                      false);
                              final bool isPendingHighlight = _pendingSlotKeys.contains(_slotKey);
                              bool isBreakTime = false;
                              // 휴식시간 표시 로직 (dayIdx == dayOfWeek로 정확히 매핑)
                              final op = widget.operatingHours.firstWhereOrNull((o) => o.dayOfWeek == dayIdx);
                              if (op != null) {
                                for (final breakTime in op.breakTimes) {
                                  final blockHour = timeBlocks[blockIdx].startTime.hour;
                                  final blockMinute = timeBlocks[blockIdx].startTime.minute;
                                  final breakStartHour = breakTime.startHour;
                                  final breakStartMinute = breakTime.startMinute;
                                  final breakEndHour = breakTime.endHour;
                                  final breakEndMinute = breakTime.endMinute;
                                  final blockMinutes = blockHour * 60 + blockMinute;
                                  final breakStartMinutes = breakStartHour * 60 + breakStartMinute;
                                  final breakEndMinutes = breakEndHour * 60 + breakEndMinute;
                                  if (blockMinutes >= breakStartMinutes && blockMinutes < breakEndMinutes) {
                                    isBreakTime = true;
                                    break;
                                  }
                                }
                              }
                              // 시:분만 비교하는 함수
                              bool isSameTime(dynamic block, DateTime gridTime) {
                                // block: StudentTimeBlock 또는 SelfStudyTimeBlock
                                if (block is StudentTimeBlock || block is SelfStudyTimeBlock) {
                                  return block.startHour == gridTime.hour && block.startMinute == gridTime.minute;
                                }
                                return false;
                              }
                              // 학생별 중복 없이, 요일+시:분이 같은 학생만 카운트
                              // - base: 정규 수업(블라인드/필터 적용 후)
                              // - + 보강/추가(planned): week 캐시에서 slotKey 기준으로 학생 id 추가(중복 제거)
                              final activeStudentIds =
                                  filteredActiveBlocks.map((b) => b.studentId).toSet();
                              final Set<String> countedStudentIds = Set.of(activeStudentIds);
                              final extraMakeupIds = cache.makeupStudentIdsBySlotKey[slotKey];
                              if (extraMakeupIds != null && extraMakeupIds.isNotEmpty) {
                                countedStudentIds.addAll(extraMakeupIds);
                              }
                              int activeStudentCount = countedStudentIds.length;

                              // 문의(희망시간) 예약 인원 가산: startWeek(해당 주 월요일) 이후의 모든 주차에 반영
                              final inquiryCount = inquiryCountBySlot[slotKey] ?? 0;
                              if (inquiryCount > 0) {
                                activeStudentCount += inquiryCount;
                              }
                              // 시범수업(일회성) 인원 가산: 선택한 주에서만 반영 + lessonDuration 범위로 확장된 map 사용
                              final trialCount = trialCountBySlot[slotKey] ?? 0;
                              if (trialCount > 0) {
                                activeStudentCount += trialCount;
                              }
                              final inquiryOverlays = (inquirySlotsBySlotKey[slotKey] ?? const <ConsultInquiryDemandSlot>[])
                                  .map((s) => InquiryOverlayLabel(noteId: s.sourceNoteId, text: s.title))
                                  .toList();
                              final trialOverlays = (trialSlotsBySlotKey[slotKey] ?? const <ConsultTrialLessonSlot>[])
                                  .map((s) => TrialOverlayLabel(noteId: s.sourceNoteId, text: s.title))
                                  .toList();
                              // // BLIND 진단 로그(요약) - 필요 시만 활성화
                              // if (_hiddenOriginalStudentIds.isNotEmpty || _hiddenStudentSetPairs.isNotEmpty || activeStudentIds.length < beforeIds.length) {
                              //   // ignore: avoid_print
                              //   print('[BLIND][cls] cell=$_cellDate hideIds=${_hiddenOriginalStudentIds} hidePairs=${_hiddenStudentSetPairs.length} before=${beforeIds.length} after=$activeStudentCount');
                              // }
                              Color? countColor;
                              if (activeStudentCount > 0) {
                                if (activeStudentCount < DataManager.instance.academySettings.defaultCapacity * 0.7) {
                                  // 쾌적
                                  countColor = const Color(0xFF1B6B63);
                                } else if (activeStudentCount >= DataManager.instance.academySettings.defaultCapacity) {
                                  // 혼잡
                                  countColor = const Color(0xFFF2B45B);
                                } else {
                                  // 보통
                                  countColor = const Color(0xFF212A31);
                                }
                              } else {
                                // 인원 0일 때도 쾌적 색상 사용
                                countColor = const Color(0xFF223131);
                              }
                              if (isDragHighlight) {
                                if (_kRegistrationPerfDebug) {
                                  // ignore: avoid_print
                                  print('[DEBUG][Cell] isDragHighlight: cellKey=$cellKey, dragHighlightKeys=$dragHighlightKeys');
                                }
                              }
                              return Expanded(
                                child: MouseRegion(
                                  onEnter: (_) {
                                    if (widget.isRegistrationMode) {
                                      setState(() {
                                        _hoveredCellKey = cellKey;
                                        if (_kRegistrationPerfDebug) {
                                          // ignore: avoid_print
                                          print('[DEBUG][MouseRegion] onEnter: cellKey=$cellKey, isRegistrationMode=${widget.isRegistrationMode}');
                                        }
                                      });
                                    }
                                  },
                                  onExit: (_) {
                                    if (widget.isRegistrationMode) {
                                      setState(() {
                                        if (_hoveredCellKey == cellKey) _hoveredCellKey = null;
                                        if (_kRegistrationPerfDebug) {
                                          // ignore: avoid_print
                                          print('[DEBUG][MouseRegion] onExit: cellKey=$cellKey, isRegistrationMode=${widget.isRegistrationMode}');
                                        }
                                      });
                                    }
                                  },
                                  child: GestureDetector(
                                    onTap: () async {
                                      // 오버레이(희망/시범) 라벨 탭과 셀 탭이 중복으로 처리되는 것을 방지
                                      final nowMs = DateTime.now().millisecondsSinceEpoch;
                                      if (nowMs - _lastOverlayTapMs < 250) return;
                                      // 기존 클릭 등록 로직
                                      final lessonDuration = DataManager.instance.academySettings.lessonDuration;
                                      final selectedStudentWithInfo = widget.selectedStudentWithInfo;
                                      final studentId = selectedStudentWithInfo?.student.id;
                                      if (_kRegistrationPerfDebug) {
                                        // ignore: avoid_print
                                        print('[DEBUG][Cell onTap] cellKey=$cellKey, isRegistrationMode=${widget.isRegistrationMode}, selectedStudentWithInfo=$selectedStudentWithInfo');
                                      }
                                      // 클릭한 셀의 시작 시간
                                      final startTime = timeBlocks[blockIdx].startTime;
                                      // lessonDuration만큼 생성될 모든 블록의 startTime 리스트 생성
                                      final blockCount = (lessonDuration / 30).ceil();
                                      final allStartTimes = List.generate(blockCount, (i) => startTime.add(Duration(minutes: 30 * i)));
                                      if (studentId != null && _isStudentTimeOverlap(studentId, dayIdx, timeBlocks[blockIdx].startTime, lessonDuration)) {
                                        if (_kRegistrationPerfDebug) {
                                          // ignore: avoid_print
                                          print('[DEBUG][셀 클릭 중복] showAppSnackBar 호출');
                                        }
                                        Future.microtask(() {
                                          try {
                                            showAppSnackBar(context, '이미 등록된 시간입니다.', useRoot: true);
                                          } catch (e, st) {
                                            if (_kRegistrationPerfDebug) {
                                              // ignore: avoid_print
                                              print('[DEBUG][showAppSnackBar 예외] $e\n$st');
                                            }
                                          }
                                        });
                                        return;
                                      }
                                      if (widget.isRegistrationMode && widget.onCellStudentsSelected != null && selectedStudentWithInfo != null) {
                                        if (_kRegistrationPerfDebug) {
                                          // ignore: avoid_print
                                          print('[DEBUG][등록시도] studentId=${selectedStudentWithInfo.student.id}, dayIdx=$dayIdx, startTime=${timeBlocks[blockIdx].startTime}');
                                        }
                                        widget.onCellStudentsSelected!(
                                          dayIdx,
                                          [timeBlocks[blockIdx].startTime],
                                          [selectedStudentWithInfo],
                                        );
                                      } else if (widget.onTimeSelected != null) {
                                        // 자습 블록이 있는 경우 자습 블록 수정 콜백 호출
                                        final selfStudyBlocks =
                                            cache.selfStudyBlocksBySlotKey[slotKey] ??
                                                const <SelfStudyTimeBlock>[];
                                        
                                        if (selfStudyBlocks.isNotEmpty && widget.onCellSelfStudyStudentsChanged != null) {
                                          final cellSelfStudyStudentWithInfos = selfStudyBlocks
                                              .map((b) => cache.studentById[b.studentId])
                                              .whereType<StudentWithInfo>()
                                              .toList();
                                          if (cellSelfStudyStudentWithInfos.isNotEmpty) {
                                            widget.onCellSelfStudyStudentsChanged!(
                                              dayIdx,
                                              timeBlocks[blockIdx].startTime,
                                              cellSelfStudyStudentWithInfos,
                                            );
                                          }
                                        }
                                        
                                        widget.onTimeSelected!(dayIdx, timeBlocks[blockIdx].startTime);
                                      }
                                      // 선택모드 해제: 셀 클릭 시 onSelectModeChanged(false) 호출
                                      if (widget.onSelectModeChanged != null) {
                                        widget.onSelectModeChanged!(false);
                                      }
                                    },
                                    child: TimetableCell(
                                      dayIdx: dayIdx,
                                      blockIdx: blockIdx,
                                      cellKey: cellKey,
                                      startTime: timeBlocks[blockIdx].startTime,
                                      endTime: timeBlocks[blockIdx].endTime,
                                       students: filteredActiveBlocks,
                                      isBreakTime: isBreakTime,
                                      isExpanded: isExpanded,
                                      isDragHighlight: isDragHighlight,
                                      // 등록모드에서는 pending 하이라이트만 사용(셀 선택 하이라이트 제거)
                                      isSelected: widget.isRegistrationMode ? false : isSelectedCell,
                                      isPendingHighlight: isPendingHighlight,
                                      onTap: null,
                                      countColor: countColor,
                                      activeStudentCount: activeStudentCount,
                                      cellStudentWithInfos: cellStudentWithInfos,
                                      groups: groups,
                                      cellWidth: 0, // 필요시 전달
                                      registrationModeType: widget.registrationModeType,
                                      operatingHours: widget.operatingHours,
                                       makeupOverlays: makeupOverlays,
                                      inquiryOverlays: inquiryOverlays,
                                      trialOverlays: trialOverlays,
                                      onInquiryOverlayTap: widget.onInquiryNoteTap == null
                                          ? null
                                          : (noteId) {
                                              _lastOverlayTapMs = DateTime.now().millisecondsSinceEpoch;
                                              widget.onInquiryNoteTap?.call(noteId);
                                            },
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  List<TimeBlock> _generateTimeBlocks() {
    final List<TimeBlock> blocks = [];
    if (widget.operatingHours.isNotEmpty) {
      final now = DateTime.now();
      // 모든 요일의 운영시간에서 가장 이른 startTime, 가장 늦은 endTime 찾기
      int minHour = 23, minMinute = 59, maxHour = 0, maxMinute = 0;
      for (final hours in widget.operatingHours) {
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
        // 각 요일별로 breakTime 체크
        // blocks는 시간 단위로만 생성, 요일별 breakTime은 셀에서 판단
        blocks.add(TimeBlock(
          startTime: currentTime,
          endTime: blockEndTime,
          isBreakTime: false, // 기본값 false, 실제 셀에서 판단
        ));
        currentTime = blockEndTime;
      }
    }
    return blocks;
  }

  // 주어진 시간에 수업 중인 학생 블록들을 가져오는 메서드
  List<StudentTimeBlock> _getActiveStudentBlocks(
    List<StudentTimeBlock> allBlocks,
    int dayIndex,
    DateTime checkTime,
    int lessonDurationMinutes,
    DateTime refDate,
  ) {
    return allBlocks.where((block) {
      if (block.dayIndex != dayIndex) return false;
      if (!_isBlockActiveOnDate(block, refDate)) return false;
      // 날짜 무시, 요일+시:분+duration만 비교
      final blockStart = block.startHour * 60 + block.startMinute;
      final blockEnd = blockStart + block.duration.inMinutes;
      final checkMinutes = checkTime.hour * 60 + checkTime.minute;
      return checkMinutes >= blockStart && checkMinutes < blockEnd;
    }).toList();
  }

  bool _isBlockActiveOnDate(dynamic block, DateTime date) {
    if (block is! StudentTimeBlock && block is! SelfStudyTimeBlock) return false;
    final target = DateTime(date.year, date.month, date.day);
    final startDate = block.startDate;
    final endDate = block.endDate;
    if (startDate == null) return false;
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = endDate != null ? DateTime(endDate.year, endDate.month, endDate.day) : null;
    return !start.isAfter(target) && (end == null || !end.isBefore(target));
  }

  // 학생의 기존 시간표와 (요일, 시작시간, 수업시간) 겹침 여부 체크
  bool _isStudentTimeOverlap(
    String studentId,
    int dayIndex,
    DateTime startTime,
    int lessonDurationMinutes, {
    DateTime? refDate,
  }) {
    // 수업 블록과 자습 블록 모두 체크
    final ref = refDate ?? startTime;
    final dateOnly = DateTime(ref.year, ref.month, ref.day);
    final studentBlocks = DataManager.instance.studentTimeBlocks
        .where((b) => b.studentId == studentId && _isBlockActiveOnDate(b, dateOnly))
        .toList();
    final selfStudyBlocks = DataManager.instance.selfStudyTimeBlocks
        .where((b) => b.studentId == studentId && _isBlockActiveOnDate(b, dateOnly))
        .toList();
    String _fmtStudentBlock(StudentTimeBlock b) =>
        '${b.id}|start=${b.startDate.toIso8601String().split("T").first}|end=${b.endDate?.toIso8601String().split("T").first}|day=${b.dayIndex}|t=${b.startHour}:${b.startMinute}';
    String _fmtSelfStudyBlock(SelfStudyTimeBlock b) =>
        '${b.id}|created=${b.createdAt.toIso8601String().split("T").first}|day=${b.dayIndex}|t=${b.startHour}:${b.startMinute}';
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_isStudentTimeOverlap] refDate=$dateOnly studentBlocks=${studentBlocks.map(_fmtStudentBlock).toList()} selfStudyBlocks=${selfStudyBlocks.map(_fmtSelfStudyBlock).toList()}');
    }
    
    final newStart = startTime.hour * 60 + startTime.minute;
    final newEnd = newStart + lessonDurationMinutes;
    
    // 수업 블록 체크
    for (final block in studentBlocks) {
      final blockStart = block.startHour * 60 + block.startMinute;
      final blockEnd = blockStart + block.duration.inMinutes;
      if (block.dayIndex == dayIndex && newStart < blockEnd && newEnd > blockStart) {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_isStudentTimeOverlap] 수업 블록 중복 감지: studentId=$studentId, dayIndex=$dayIndex, startTime=$startTime, block=${block.id}');
        }
        return true;
      }
    }
    
    // 자습 블록 체크
    for (final block in selfStudyBlocks) {
      final blockStart = block.startHour * 60 + block.startMinute;
      final blockEnd = blockStart + block.duration.inMinutes;
      if (block.dayIndex == dayIndex && newStart < blockEnd && newEnd > blockStart) {
        if (_kRegistrationPerfDebug) {
          // ignore: avoid_print
          print('[DEBUG][_isStudentTimeOverlap] 자습 블록 중복 감지: studentId=$studentId, dayIndex=$dayIndex, startTime=$startTime, block=${block.id}');
        }
        return true;
      }
    }
    
    if (_kRegistrationPerfDebug) {
      // ignore: avoid_print
      print('[DEBUG][_isStudentTimeOverlap] 중복 없음: studentId=$studentId, dayIndex=$dayIndex, startTime=$startTime, refDate=$dateOnly');
    }
    return false;
  }

  // [추가] 운영시간/휴식시간 체크 함수
  // dayIdx: 0(월)~6(일), op.dayOfWeek: 0(월)~6(일)로 가정
  bool _areAllTimesWithinOperatingAndBreak(int dayIdx, List<DateTime> times) {
    final op = widget.operatingHours.firstWhereOrNull((o) => o.dayOfWeek == dayIdx);
    if (op == null) return false;
    for (final t in times) {
      final tMinutes = t.hour * 60 + t.minute;
      final opStart = op.startHour * 60 + op.startMinute;
      final opEnd = op.endHour * 60 + op.endMinute;
      // 운영 종료 시간(opEnd) "미만"만 허용하도록 수정
      if (tMinutes < opStart || tMinutes >= opEnd) return false;
      for (final br in op.breakTimes) {
        final brStart = br.startHour * 60 + br.startMinute;
        final brEnd = br.endHour * 60 + br.endMinute;
        if (tMinutes >= brStart && tMinutes < brEnd) return false;
      }
    }
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 스크롤 이동 로직 완전 제거
  }

  void _tryScrollToCurrentTime() async {
    await Future.delayed(const Duration(milliseconds: 120));
    _scrollToCurrentTime();
  }

  void _scrollToCurrentTime() {
    final timeBlocks = _generateTimeBlocks();
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
    // 현재 시간이 운영시간 범위 내에 있는지 체크
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
    if (widget.scrollController.hasClients) {
      final maxOffset = widget.scrollController.position.maxScrollExtent;
      final minOffset = widget.scrollController.position.minScrollExtent;
      final scrollTo = targetOffset.clamp(minOffset, maxOffset);
      widget.scrollController.animateTo(
        scrollTo,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  Widget _buildExpandedStudentCards(List<StudentTimeBlock> cellBlocks, List<StudentWithInfo> studentsWithInfo, List<GroupInfo> groups, double cellWidth, bool isExpanded) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        setState(() {
          _expandedCellKey = null;
        });
      },
      child: Container(
        width: cellWidth,
        child: AnimatedScale(
          scale: isExpanded ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 1000),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: isExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 1000),
            child: Wrap(
              spacing: 5,
              runSpacing: 10,
              children: List.generate(cellBlocks.length, (i) {
                final block = cellBlocks[i];
                final studentWithInfo = studentsWithInfo.firstWhere((s) => s.student.id == block.studentId, orElse: () => StudentWithInfo(student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary, ), basicInfo: StudentBasicInfo(studentId: '')));
                // groupId는 StudentTimeBlock에서 제거됨. 학생의 현재 groupInfo를 사용.
                final studentWI = studentsWithInfo.firstWhere(
                  (s) => s.student.id == block.studentId,
                  orElse: () => StudentWithInfo(student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary), basicInfo: StudentBasicInfo(studentId: '')),
                );
                final groupInfo = studentWI.student.groupInfo;
                // 삭제된 학생이면 카드 자체를 렌더링하지 않음
                if (studentWithInfo.student.id.isEmpty) return const SizedBox.shrink();
                return GestureDetector(
                  onTapDown: (details) async {
                    final selected = await showMenu<String>(
                      context: context,
                      position: RelativeRect.fromLTRB(
                        details.globalPosition.dx,
                        details.globalPosition.dy,
                        details.globalPosition.dx + 1,
                        details.globalPosition.dy + 1,
                      ),
                      color: Colors.black,
                      items: [
                        const PopupMenuItem<String>(
                          value: 'edit',
                          child: Text('수정', style: TextStyle(color: Colors.white)),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('삭제', style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    );
                    if (selected == 'delete') {
                      try {
                        if (block.setId != null) {
                          final allBlocks = DataManager.instance.studentTimeBlocks;
                          // 같은 학생 id와 set_id를 모두 만족하는 블록만 삭제
                          final toDelete = allBlocks.where((b) => b.setId == block.setId && b.studentId == block.studentId).toList();
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[삭제드롭존] setId=${block.setId}, studentId=${block.studentId}, 삭제 대상 블록 개수: ${toDelete.length}');
                          }
                          for (final b in toDelete) {
                            if (_kRegistrationPerfDebug) {
                              // ignore: avoid_print
                              print('[삭제드롭존] 삭제 시도: block.id=${b.id}, block.setId=${b.setId}, block.studentId=${b.studentId}, block.dayIndex=${b.dayIndex}, block.startHour=${b.startHour}, block.startMinute=${b.startMinute}');
                            }
                            await DataManager.instance.removeStudentTimeBlock(b.id);
                          }
                        } else {
                          if (_kRegistrationPerfDebug) {
                            // ignore: avoid_print
                            print('[삭제드롭존] setId=null, 단일 삭제: block.id=${block.id}');
                          }
                          await DataManager.instance.removeStudentTimeBlock(block.id);
                        }
                      } catch (_) {}
                    }
                  },
                  child: SizedBox(
                    width: 109,
                    height: 39,
                    child: _StudentTimeBlockCard(student: studentWithInfo.student, groupInfo: groupInfo),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  // 기존 timetable_screen.dart의 onCellStudentsSelected와 동일하게 구현
  Future<void> _handleCellStudentsSelected(int dayIdx, List<DateTime> startTimes, List<StudentWithInfo> students, {DateTime? refDate}) async {
    if (students.isEmpty) return;
    final student = students.first.student;
    final range = await _pickBlockRange(context);
    if (range == null) {
      showAppSnackBar(context, '등록이 취소되었습니다.');
      return;
    }
    final blockMinutes = 30; // 한 블록 30분 기준
    List<DateTime> actualStartTimes = startTimes;
    // 클릭(단일 셀) 시에는 lessonDuration만큼 블록 생성
    if (startTimes.length == 1) {
      final lessonDuration = DataManager.instance.academySettings.lessonDuration;
      final blockCount = (lessonDuration / blockMinutes).ceil();
      actualStartTimes = List.generate(blockCount, (i) => startTimes.first.add(Duration(minutes: i * blockMinutes)));
    }
    // 중복 방어: 하나라도 겹치면 전체 등록 불가
    final allBlocks = DataManager.instance.studentTimeBlocks;
    bool hasConflict = false;
    for (final startTime in actualStartTimes) {
      final conflictBlock = allBlocks.firstWhereOrNull((b) =>
          b.studentId == student.id &&
          b.dayIndex == dayIdx &&
          b.startHour == startTime.hour &&
          b.startMinute == startTime.minute &&
          _isBlockActiveOnDate(b, refDate ?? range.start));
      if (conflictBlock != null) {
        showAppSnackBar(context, '이미 등록된 시간입니다.');
        hasConflict = true;
        break;
      }
    }
    if (hasConflict) return;
    final blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
      studentIds: [student.id],
      dayIndex: dayIdx,
      startTimes: actualStartTimes,
      duration: Duration(minutes: blockMinutes),
      startDate: range.start,
      endDate: range.end,
    );
    // DataManager를 통해 일관된 UI 업데이트 처리
    if (widget.isRegistrationMode && widget.registrationModeType == 'student') {
      await DataManager.instance.bulkAddStudentTimeBlocksDeferred(blocks);
    } else {
      await DataManager.instance.bulkAddStudentTimeBlocks(blocks);
    }
  }

}

class _StudentTimeBlockCard extends StatelessWidget {
  final Student student;
  final GroupInfo? groupInfo;
  const _StudentTimeBlockCard({required this.student, this.groupInfo});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 109,
      height: 39,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (groupInfo != null)
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: groupInfo!.color,
                  shape: BoxShape.circle,
                ),
                margin: const EdgeInsets.only(right: 4),
              ),
            Flexible(
              child: Text(
                student.name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TimeBlock {
  final DateTime startTime;
  final DateTime endTime;
  final bool isBreakTime;

  TimeBlock({
    required this.startTime,
    required this.endTime,
    this.isBreakTime = false,
  });

  String get timeString {
    return _formatTime(startTime);
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
} 

int _getCurrentTimeBlockIndex(List<TimeBlock> timeBlocks) {
  final now = DateTime.now();
  int currentIdx = 0;
  for (int i = 0; i < timeBlocks.length; i++) {
    final block = timeBlocks[i];
    if (block.startTime.hour < now.hour || (block.startTime.hour == now.hour && block.startTime.minute <= now.minute)) {
      currentIdx = i;
    }
  }
  // 운영시간 외일 때(현재 시간이 마지막 블록보다 늦음) 마지막 셀에 인디케이터
  final lastBlock = timeBlocks.isNotEmpty ? timeBlocks.last : null;
  if (lastBlock != null) {
    final nowMinutes = now.hour * 60 + now.minute;
    final lastMinutes = lastBlock.startTime.hour * 60 + lastBlock.startTime.minute;
    if (nowMinutes > lastMinutes) {
      return timeBlocks.length - 1;
    }
  }
  return currentIdx;
} 