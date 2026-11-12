// Unit tree authoring + VLM analysis dialog (coordinate-only redesign).
//
// After the pivot away from client-side cropping, this dialog no longer
// decodes/stores/exports per-problem PNGs. Instead it:
//
//   1. Loads the unit tree from `textbook_metadata.payload` and lets the
//      operator edit 대/중단원 names and A/B/C start/end pages (unchanged).
//   2. Runs the VLM problem-number detection for one 소단원 at a time,
//      accumulating the normalised bounding boxes in memory.
//   3. Renders the body PDF with `PdfViewer.file` + `pageOverlaysBuilder`
//      so the user can visually confirm the detected regions on the real
//      PDF — two pages per row (layoutPages) so spreads are easier to
//      review.
//   4. Supports **manual fine-tuning**: click a bbox → drag its four
//      corner handles → the stored `item_region_1k` is overridden. Missing
//      problems are added by two drags (number box, then body box).
//   5. Saves the coordinates (no images) via `TextbookCropUploader` in
//      `regions_only` mode as soon as analysis or an edit finishes.
//   6. "크롭 확정" hands the 소단원 to `TextbookWorkflowRunner`, which runs
//      본문 추출 → 정답·해설 위치 → V2 검수 in the background. The result is
//      reviewed in the 작업 화면 (`ProblemRoadmapScreen` workflow mode).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/textbook_book_registry.dart';
import '../../services/textbook_crop_uploader.dart';
import '../../services/textbook_pdf_page_renderer.dart';
import '../../services/textbook_pdf_service.dart';
import '../../services/textbook_problem_review_service.dart';
import '../../services/textbook_series_catalog.dart';
import '../../services/textbook_vlm_answer_service.dart';
import '../../services/textbook_vlm_range_runner.dart';
import '../../services/textbook_vlm_test_service.dart';
import '../../services/textbook_stage_batch_service.dart';
import '../../services/textbook_workflow_runner.dart';
import '../../services/textbook_workflow_service.dart';
import '../../services/problem_bank_service.dart';
import '../problem_roadmap/problem_roadmap_screen.dart';
import 'textbook_authoring_stage_dialog.dart';
import 'textbook_toc_autofill.dart';

class TextbookUnitAuthoringDialog extends StatefulWidget {
  const TextbookUnitAuthoringDialog({
    super.key,
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    this.linkId,
  });

  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final int? linkId;

  static Future<void> show(
    BuildContext context, {
    required String academyId,
    required String bookId,
    required String bookName,
    required String gradeLabel,
    int? linkId,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => TextbookUnitAuthoringDialog(
        academyId: academyId,
        bookId: bookId,
        bookName: bookName,
        gradeLabel: gradeLabel,
        linkId: linkId,
      ),
    );
  }

  @override
  State<TextbookUnitAuthoringDialog> createState() =>
      _TextbookUnitAuthoringDialogState();
}

class _TextbookUnitAuthoringDialogState
    extends State<TextbookUnitAuthoringDialog> {
  static const _kBg = Color(0xFF000000);
  static const _kPanel = Color(0xFF1C1C1E);
  static const _kCard = Color(0xFF2C2C2E);
  static const _kBorder = Color(0x22FFFFFF);
  static const _kText = Color(0xFFEAF2F2);
  static const _kTextSub = Color(0xFF9FB3B3);
  static const _kMuted = Color(0xFF6E7E7E);
  static const _kAccent = Color(0xFF33A373);
  static const _kChipSelected = Color(0xFF1B6B63);
  static const _kDanger = Color(0xFFE57373);
  static const _kWarn = Color(0xFFE0B35A);
  static const _kInfo = Color(0xFF64B5F6);

  static const int _kAnalysisLongEdgePx = 1500;

  final _registry = TextbookBookRegistry();
  final _pdfService = TextbookPdfService();
  final _vlmService = TextbookVlmTestService();
  final _cropUploader = TextbookCropUploader();
  final _pbService = ProblemBankService();
  final _workflowService = TextbookWorkflowService();
  final _supa = Supabase.instance.client;

  /// 소단원 작업 상태(`textbook_subunit_workflows`), stateKey 기준.
  Map<String, TextbookSubunitWorkflow> _workflows =
      const <String, TextbookSubunitWorkflow>{};

  /// 소단원별 저장된 크롭 수, 그중 본문(문제은행 문항)이 연결된 수, 그 본문 중 검수를 마친 수(stateKey 기준).
  /// 예전 원스톱으로 본문만 뽑아 둔 소단원("기존 추출"·"검수 완료")을 가르는 데 쓴다.
  Map<String, ({int crops, int bodies, int reviewed})> _bodyCounts =
      const <String, ({int crops, int bodies, int reviewed})>{};

  /// 크롭 수정이 끝나면 잠깐 기다렸다 저장한다(핸들을 여러 번 끌 때 한 번만).
  final Map<String, Timer> _autoSaveTimers = <String, Timer>{};
  final Set<String> _autoSavePending = <String>{};

  /// 수동 크롭 그리기: 첫 드래그는 번호 상자, 두 번째 드래그는 본문 상자.
  /// 좌표는 쪽 크기로 나눈 0..1 값이다(확대해도 그대로).
  bool _manualDrawMode = false;
  int? _manualNumberPage;
  Rect? _manualNumberBox;
  int? _manualDragPage;
  Offset? _manualDragStart;
  Rect? _manualDragRect;

  PdfDocument? _bodyDocument;
  String? _bodyLocalPath;
  String? _pdfLoadError;
  bool _loadingPdf = false;
  final _viewerController = PdfViewerController();

  bool _loadingPayload = true;
  String? _payloadError;
  String _seriesKey = kTextbookSeriesCatalog.first.key;
  final List<_BigUnitEdit> _bigUnits = <_BigUnitEdit>[];
  Map<String, _SpecialUnitView> _specialUnitByMid =
      const <String, _SpecialUnitView>{};

  bool _tocParsing = false;
  String? _tocStatus;

  // ── 개념원리(wonri) 단일 패스 ─────────────────────────────────────────
  //
  // 개념원리는 한 소단원 페이지 안에 개념/개념원리 익히기/필수유형/확인 체크
  // (/연습문제)가 섞여 순서대로 나온다. 그래서 분석 단위는 카테고리가 아니라
  // **소단원 행** 이고 (focus.subKey = 'W<rowIndex>'), VLM 은 그 페이지 범위를
  // 한 번만 훑으면서 문항마다 category 를 붙인다. 저장 시 카테고리를
  // sub_key(A~D)로 매핑해 분리 업로드한다 — 이후 정답/해설/문제은행 흐름은
  // 쎈과 동일하다.
  static const Map<String, String> _kWonriSubKeyByCategory = {
    'concept_drill': 'A', // 개념원리 익히기
    'type_example': 'B', // 필수유형
    'check': 'C', // 확인 체크
    'exercise': 'D', // 연습문제 (STEP1/STEP2/실력 UP)
    // 특강 — 필수유형과 같은 지면 구성(예제+본문 "풀이"+하단 확인체크)이지만
    // 번호가 01부터 새로 시작해 B와 충돌하므로 전용 슬롯으로 분리한다.
    'special_lecture': 'E',
  };
  static const Map<String, String> _kWonriCategoryBySubKey = {
    'A': 'concept_drill',
    'B': 'type_example',
    'C': 'check',
    'D': 'exercise',
    'E': 'special_lecture',
  };
  static const Map<String, String> _kWonriCategoryShortNames = {
    'concept_drill': '익히기',
    'type_example': '필수유형',
    'check': '확인체크',
    'exercise': '연습문제',
    'special_lecture': '특강',
  };

  /// 개념원리에서 crop 을 sub_index(소단원 순번)로 분리 저장하는 슬롯.
  /// B(필수유형)·E(특강)는 번호가 소단원마다 01부터 새로 시작해 분리가 필수다.
  /// (추출 런은 이와 별개로 전 카테고리를 소단원별로 나눈다 —
  ///  `_workOrderFor` 참고.)
  static const Set<String> _kWonriPerSubUnitKeys = {'B', 'E'};

  // ── 중등 개념원리(wonri_middle) 단일 패스 ────────────────────────────
  static const Map<String, String> _kWonriMiddleSubKeyByCategory = {
    'middle_concept_check': 'A',
    'middle_core_problem': 'B',
    'middle_exam_problem': 'C',
    'middle_unit_review': 'D',
    'middle_descriptive': 'E',
    'middle_calculation': 'F',
  };
  static const Map<String, String> _kWonriMiddleCategoryBySubKey = {
    'A': 'middle_concept_check',
    'B': 'middle_core_problem',
    'C': 'middle_exam_problem',
    'D': 'middle_unit_review',
    'E': 'middle_descriptive',
    'F': 'middle_calculation',
  };
  static const Map<String, String> _kWonriMiddleCategoryShortNames = {
    'middle_concept_check': '확인하기',
    'middle_core_problem': '핵심문제',
    'middle_exam_problem': '시험문제',
    'middle_unit_review': '중단원 마무리',
    'middle_descriptive': '서술형 대비',
    'middle_calculation': '계산력 강화',
  };

  /// 통합 해설 매칭 키를 `소단원 행 + category + 번호`로 유지한다.
  /// D/E도 중단원 말미의 전용 행 순번을 사용해 crop/run/정답 동기화 키가
  /// 서로 달라지는 일을 막는다.
  static const Set<String> _kWonriMiddlePerSubUnitKeys = {
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
  };

  // ── 개념+유형(gaeyu) 단일 패스 ────────────────────────────────────────
  //
  // 구조는 개념원리와 같지만 코너가 여섯 개이고, 번호 리셋 단위가 코너마다
  // 다르다. 자세한 규칙은 textbook_series_catalog.dart 의 번호 규칙 주석 참고.
  static const Map<String, String> _kGaeyuSubKeyByCategory = {
    'concept_check': 'A', // 개념확인
    'essential_problem': 'B', // 필수 문제 + 따름 문제
    'step_drill': 'C', // 쏙쏙 개념 익히기 (STEP1)
    'unit_drill': 'D', // 탄탄 단원 다지기 (STEP2)
    'descriptive': 'E', // 쓱쓱 서술형 완성하기 (STEP3)
    'extra_practice': 'F', // 한 번 더 연습
  };
  static const Map<String, String> _kGaeyuCategoryBySubKey = {
    'A': 'concept_check',
    'B': 'essential_problem',
    'C': 'step_drill',
    'D': 'unit_drill',
    'E': 'descriptive',
    'F': 'extra_practice',
  };
  static const Map<String, String> _kGaeyuCategoryShortNames = {
    'concept_check': '개념확인',
    'essential_problem': '필수 문제',
    'step_drill': '쏙쏙',
    'unit_drill': '탄탄',
    'descriptive': '쓱쓱 서술형',
    'extra_practice': '한 번 더 연습',
  };

  /// 개념+유형에서 crop 을 sub_index(소단원 순번)로 분리 저장하는 슬롯.
  /// 필수 문제(B)·쏙쏙(C)·한 번 더 연습(F)은 번호가 소단원마다 1부터 새로
  /// 시작한다. 개념확인(A)은 번호에 본문 페이지가 들어가 이미 유일하고,
  /// 탄탄(D)·쓱쓱(E)은 중단원마다 한 번뿐이라 0을 쓴다.
  static const Set<String> _kGaeyuPerSubUnitKeys = {'B', 'C', 'F'};

  /// 한 소단원 안에서 같은 코너가 여러 지면 블록으로 나뉘고 블록마다 번호가
  /// 1부터 다시 시작하는 슬롯. 이때만 번호 앞에 본문 인쇄 페이지를 붙여
  /// "10-1", "15-1" 처럼 구분한다 (정답 파일도 P.10 / P.15 로 나눠 인쇄된다).
  static const Set<String> _kGaeyuBlockScopedKeys = {'C', 'F'};

  // ── 개념+유형 고등(gaeyu_high) 단일 패스 ──────────────────────────────
  //
  // 소단원 행 하나에 네 코너가 모두 들어 있다. 게이트웨이
  // GAEYU_HIGH_SECTION_BY_SUB_KEY 와 짝이다.
  static const Map<String, String> _kGaeyuHighSubKeyByCategory = {
    'high_concept_check': 'A', // 개념 Check
    'high_example': 'B', // 필수예제
    'high_problem': 'C', // 문제 (01-1 …)
    'high_exercise': 'D', // 연습문제
  };
  static const Map<String, String> _kGaeyuHighCategoryBySubKey = {
    'A': 'high_concept_check',
    'B': 'high_example',
    'C': 'high_problem',
    'D': 'high_exercise',
  };
  static const Map<String, String> _kGaeyuHighCategoryShortNames = {
    'high_concept_check': '개념 Check',
    'high_example': '필수예제',
    'high_problem': '문제',
    'high_exercise': '연습문제',
  };

  /// 네 슬롯 모두 소단원 행마다 번호가 새로 시작한다.
  static const Set<String> _kGaeyuHighPerSubUnitKeys = {'A', 'B', 'C', 'D'};

  /// 개념 Check 는 소단원 안에서도 개념 블록마다 1부터 다시 시작한다. 해설
  /// 박스가 "개념 Check 8쪽" 처럼 블록 단위라 블록 시작 쪽을 접두어로 붙인다.
  /// 블록이 하나뿐이어도 붙여서 번호 모양을 하나로 맞춘다.
  static const Set<String> _kGaeyuHighBlockScopedKeys = {'A'};

  // ── 수력충전(suryeok) 단일 패스 ──────────────────────────────────────
  //
  // 소단원 행 하나가 통째로 한 코너다. 개념 체크는 유형 문제와 번호열을
  // 공유하므로(27번 다음이 개념 체크 28번) 슬롯을 나누지 않고 같은 A 에 담고
  // 문항이름으로만 구분한다. 슬롯을 쪼개면 정답 파일의 한 줄짜리 번호열이
  // 두 스코프로 갈려 매칭이 어긋난다.
  static const Map<String, String> _kSuryeokSubKeyByCategory = {
    'type_problem': 'A', // 유형 문제
    'concept_check': 'A', // 개념 체크 (같은 번호열)
    'unit_review': 'B', // 단원 마무리 평가
  };
  static const Map<String, String> _kSuryeokCategoryBySubKey = {
    'A': 'type_problem',
    'B': 'unit_review',
  };
  // 고쟁이 슬롯 → 탐지 섹션. 게이트웨이 GOJAENGI_SECTION_BY_SUB_KEY 와 짝이다.
  static const Map<String, String> _kGojaengiSectionBySubKey = {
    'A': 'core_type', // STEP1 핵심 유형
    'B': 'advanced_type', // STEP2 심화 유형
    'C': 'top_type', // STEP3 최고난도 유형
    'D': 'creative_type', // 창의융합 유형
    'E': 'mid_unit_test', // 워크북 중단원 TEST
    'F': 'big_unit_test', // 워크북 대단원 TEST
  };

  static const Map<String, String> _kSuryeokCategoryShortNames = {
    'type_problem': '유형 문제',
    'concept_check': '개념 체크',
    'unit_review': '단원 마무리',
  };

  /// 수력충전은 두 슬롯 모두 소단원 행마다 번호가 01부터 다시 시작한다.
  static const Set<String> _kSuryeokPerSubUnitKeys = {'A', 'B'};

  Map<String, String> get _conceptSubKeyByCategory => switch (_seriesKey) {
        'wonri_middle' => _kWonriMiddleSubKeyByCategory,
        'gaeyu' => _kGaeyuSubKeyByCategory,
        'gaeyu_high' => _kGaeyuHighSubKeyByCategory,
        'suryeok' => _kSuryeokSubKeyByCategory,
        _ => _kWonriSubKeyByCategory,
      };
  Map<String, String> get _conceptCategoryBySubKey => switch (_seriesKey) {
        'wonri_middle' => _kWonriMiddleCategoryBySubKey,
        'gaeyu' => _kGaeyuCategoryBySubKey,
        'gaeyu_high' => _kGaeyuHighCategoryBySubKey,
        'suryeok' => _kSuryeokCategoryBySubKey,
        _ => _kWonriCategoryBySubKey,
      };
  Map<String, String> get _conceptCategoryShortNames => switch (_seriesKey) {
        'wonri_middle' => _kWonriMiddleCategoryShortNames,
        'gaeyu' => _kGaeyuCategoryShortNames,
        'gaeyu_high' => _kGaeyuHighCategoryShortNames,
        'suryeok' => _kSuryeokCategoryShortNames,
        _ => _kWonriCategoryShortNames,
      };
  Set<String> get _conceptPerSubUnitKeys => switch (_seriesKey) {
        'wonri_middle' => _kWonriMiddlePerSubUnitKeys,
        'gaeyu' => _kGaeyuPerSubUnitKeys,
        'gaeyu_high' => _kGaeyuHighPerSubUnitKeys,
        'suryeok' => _kSuryeokPerSubUnitKeys,
        _ => _kWonriPerSubUnitKeys,
      };

  /// 개념서에서 분석/저장 단위가 되는 소단원 행 포커스(`W<idx>`)인지.
  bool _isWonriRowFocus(_SubFocus focus) =>
      _currentSeries().hasSubUnitRows && focus.subKey.startsWith('W');

  _SubUnitRowEdit? _wonriRowFor(_SubFocus focus) {
    if (!_isWonriRowFocus(focus)) return null;
    final index = int.tryParse(focus.subKey.substring(1));
    if (index == null || index < 0) return null;
    if (focus.bigIndex < 0 || focus.bigIndex >= _bigUnits.length) return null;
    final big = _bigUnits[focus.bigIndex];
    if (focus.midIndex < 0 || focus.midIndex >= big.middles.length) {
      return null;
    }
    final rows = big.middles[focus.midIndex].subUnitRows;
    return index < rows.length ? rows[index] : null;
  }

  bool _isSuryeokSkillTestFocus(_SubFocus focus) {
    bool matches(String name) {
      final compact = name.replaceAll(RegExp(r'\s+'), '');
      return compact.contains('실력향상테스트') || compact.contains('학교시험대비');
    }

    final row = _wonriRowFor(focus);
    if (row != null && matches(row.nameCtrl.text)) return true;
    if (focus.bigIndex < 0 || focus.bigIndex >= _bigUnits.length) return false;
    final big = _bigUnits[focus.bigIndex];
    if (matches(big.nameCtrl.text)) return true;
    if (focus.midIndex < 0 || focus.midIndex >= big.middles.length) {
      return false;
    }
    return matches(big.middles[focus.midIndex].nameCtrl.text);
  }

  /// raw_page 가 페이지 범위에 속하는 소단원 행의 포커스 키(`W<idx>`).
  /// DB에 저장된 크롭(sub_key A~D)을 소단원 작업 단위로 복원할 때 쓴다.
  String? _wonriRowSubKeyForPage(int bigIndex, int midIndex, int? rawPage) {
    if (rawPage == null || rawPage <= 0) return null;
    if (bigIndex < 0 || bigIndex >= _bigUnits.length) return null;
    final big = _bigUnits[bigIndex];
    if (midIndex < 0 || midIndex >= big.middles.length) return null;
    final rows = big.middles[midIndex].subUnitRows;
    for (var i = 0; i < rows.length; i += 1) {
      final start = _positiveInt(rows[i].startCtrl.text);
      final end = _positiveInt(rows[i].endCtrl.text);
      if (start == null || end == null) continue;
      if (rawPage >= start && rawPage <= end) return 'W$i';
    }
    return null;
  }

  /// 분석에 실제로 쓸 페이지 범위.
  /// 개념원리 소단원 포커스면 소단원 행의 범위, 아니면 슬롯(A~C) 입력 범위.
  (int?, int?) _focusRange(_SubFocus focus) {
    if (_isWonriRowFocus(focus)) {
      final row = _wonriRowFor(focus);
      if (row == null) return (null, null);
      return (
        _positiveInt(row.startCtrl.text),
        _positiveInt(row.endCtrl.text),
      );
    }
    if (focus.bigIndex < 0 || focus.bigIndex >= _bigUnits.length) {
      return (null, null);
    }
    final big = _bigUnits[focus.bigIndex];
    if (focus.midIndex < 0 || focus.midIndex >= big.middles.length) {
      return (null, null);
    }
    final mid = big.middles[focus.midIndex];
    if (mid.subs.isEmpty) return (null, null);
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    return (_positiveInt(sub.startCtrl.text), _positiveInt(sub.endCtrl.text));
  }

  /// 문항의 개념서 카테고리. VLM 이 붙인 category 를 우선하고,
  /// 없으면 라벨 → 페이지 section 순으로 보정한다.
  String _wonriCategoryOfItem(TextbookVlmItem item, String pageSection) {
    if (_seriesKey == 'suryeok') {
      // 수력충전은 지면을 어느 슬롯에 넣을지 운영자가 이미 정해 두었으므로
      // 슬롯이 곧 코너다. 단원 마무리 평가는 첫 지면에만 머리말이 인쇄돼서
      // 이어지는 지면을 모델이 유형 문제로 보내는데, 그대로 두면 그 문항들이
      // 소단원 슬롯으로 새고 답지 블록("단원 마무리 평가")을 못 찾는다.
      if (pageSection == 'unit_review') return 'unit_review';
      if (pageSection == 'type_problem') {
        return item.category == 'concept_check'
            ? 'concept_check'
            : 'type_problem';
      }
      return _kSuryeokSubKeyByCategory.containsKey(item.category)
          ? item.category
          : '';
    }
    if (_conceptSubKeyByCategory.containsKey(item.category)) {
      return item.category;
    }
    if (_seriesKey == 'wonri_middle') {
      return _kWonriMiddleSubKeyByCategory.containsKey(pageSection)
          ? pageSection
          : '';
    }
    if (_seriesKey == 'gaeyu_high') {
      return _kGaeyuHighSubKeyByCategory.containsKey(pageSection)
          ? pageSection
          : '';
    }
    if (_seriesKey == 'gaeyu') {
      final label = item.label.trim();
      // "연습" 은 구버전 크롭 복원용. 현재 저장 라벨은 "서술형 연습" 이다.
      if (label == '예제' ||
          label == '유제' ||
          label == '서술형 연습' ||
          label == '연습') {
        return 'descriptive';
      }
      if (_kGaeyuSubKeyByCategory.containsKey(pageSection)) return pageSection;
      return '';
    }
    final label = item.label.trim();
    if (label == '필수' || label == '필수유형') return 'type_example';
    if (label == '특강') return 'special_lecture';
    if (label == '개념원리 익히기') return 'concept_drill';
    if (label == '확인 체크' || label == '확인체크') return 'check';
    const exerciseLabels = {
      'STEP1',
      'STEP2',
      '실력',
      '실력 UP',
      '실력UP',
      '연습문제',
      '수능기출',
      '수능 기출',
      '평가원기출',
      '평가원 기출',
      '교육청기출',
      '교육청 기출',
    };
    if (exerciseLabels.contains(label)) return 'exercise';
    if (_kWonriSubKeyByCategory.containsKey(pageSection)) return pageSection;
    return '';
  }

  /// 개념서 "문항이름" — 쎈의 난이도 자리를 대체하는 사람이 읽는 라벨.
  /// 카테고리(익히기/필수유형/확인 체크)는 그대로, 연습문제는 구간 라벨
  /// (STEP1/STEP2/실력 UP/수능·평가원·교육청 기출)을 쓰고 없으면 "연습문제".
  String _wonriItemName(
    String category,
    String rawLabel, {
    String itemRole = '',
  }) {
    if (_seriesKey == 'wonri_middle') {
      return _wonriMiddleItemName(category, rawLabel, itemRole);
    }
    if (_seriesKey == 'gaeyu') return _gaeyuItemName(category, rawLabel);
    if (_seriesKey == 'gaeyu_high') {
      // 연습문제의 "실력" 구간은 이름으로, 출처 배지(교육청 등)는 label 로 둔다.
      if (category == 'high_exercise' && rawLabel.contains('실력')) {
        return '연습문제 실력';
      }
      return _kGaeyuHighCategoryShortNames[category] ?? '';
    }
    if (_seriesKey == 'suryeok') {
      // 유형 문제의 이름은 코너가 아니라 지면의 유형명이고, 그것은
      // content_group(유형 01 / 지수법칙의 표현)에 따로 저장된다.
      switch (category) {
        case 'concept_check':
          return '개념 체크';
        case 'unit_review':
          return '단원 마무리 평가';
        default:
          return '';
      }
    }
    switch (category) {
      case 'concept_drill':
        return '개념원리 익히기';
      case 'type_example':
        return '필수유형';
      case 'check':
        return '확인 체크';
      case 'special_lecture':
        return '특강';
      case 'exercise':
        // 원시 라벨(STEP1/실력/수능기출)과 이미 정제된 표기(실력 UP/수능 기출)를
        // 모두 받아 동일하게 매핑한다 (저장된 크롭 복원 시 idempotent).
        switch (rawLabel.trim()) {
          case 'STEP1':
            return 'STEP1';
          case 'STEP2':
            return 'STEP2';
          case '실력':
          case '실력 UP':
          case '실력UP':
            return '실력 UP';
          case '수능기출':
          case '수능 기출':
            return '수능 기출';
          case '평가원기출':
          case '평가원 기출':
            return '평가원 기출';
          case '교육청기출':
          case '교육청 기출':
            return '교육청 기출';
          default:
            return '연습문제';
        }
      default:
        return '';
    }
  }

  String _wonriMiddleItemName(
    String category,
    String rawLabel,
    String itemRole,
  ) {
    switch (category) {
      case 'middle_concept_check':
        return '개념원리 확인하기';
      case 'middle_core_problem':
        if (itemRole == 'representative') return '핵심문제 대표 예제';
        if (itemRole == 'follow_up') return '핵심문제 확인';
        return '핵심문제 익히기';
      case 'middle_exam_problem':
        return '이런 문제가 시험에 나온다';
      case 'middle_unit_review':
        switch (rawLabel.replaceAll(' ', '').toUpperCase()) {
          case 'STEP1':
            return 'STEP 1 기본';
          case 'STEP2':
            return 'STEP 2 발전';
          case 'STEP3':
            return 'STEP 3 실력 UP';
          default:
            return '중단원 마무리하기';
        }
      case 'middle_descriptive':
        if (itemRole == 'descriptive_example') return '서술형 예시 문항';
        return '서술형 대비 문제';
      case 'middle_calculation':
        return '계산력 강화하기';
      default:
        return '';
    }
  }

  /// 개념+유형에서 그 코너에 실제로 인쇄되는 라벨만 남긴다.
  /// 난이도(상/중/하)는 탄탄에만, 갈래(예제/유제/서술형 연습)는 쓱쓱에만 있다.
  /// 쏙쏙 이어지는 지면을 탄탄으로 오해한 판독이 없는 난이도를 붙이는 일을 막는다.
  String _gaeyuLabelForCategory(String category, String rawLabel) {
    final label = rawLabel.trim();
    if (label.isEmpty) return '';
    if (category == 'unit_drill') {
      return const {'상', '중', '하'}.contains(label) ? label : '';
    }
    if (category == 'descriptive') {
      return const {'예제', '유제', '서술형 연습', '연습'}.contains(label) ? label : '';
    }
    return '';
  }

  /// 개념+유형 "문항이름". 쓱쓱 서술형만 갈래(예제/유제/연습해 보자)까지
  /// 구분해 붙이고, 탄탄의 "중요"는 난이도(label)와 별개로 함께 표기한다.
  String _gaeyuItemName(String category, String rawLabel) {
    switch (category) {
      case 'concept_check':
        return '개념확인';
      case 'essential_problem':
        return '필수 문제';
      case 'step_drill':
        return '쏙쏙 개념 익히기';
      case 'unit_drill':
        return '탄탄 단원 다지기';
      case 'extra_practice':
        return '한 번 더 연습';
      case 'descriptive':
        switch (rawLabel.trim()) {
          case '예제':
            return '쓱쓱 서술형 예제';
          case '유제':
            return '쓱쓱 서술형 유제';
          // "연습" 은 구버전 크롭 복원용. 현재 저장 라벨은 "서술형 연습" 이다.
          case '서술형 연습':
          case '연습':
            return '쓱쓱 서술형 연습';
          default:
            return '쓱쓱 서술형 완성하기';
        }
      default:
        return '';
    }
  }

  _SubFocus? _focus;

  // Per-sub VLM state. Keyed by '<big>/<mid>/<sub>' so switching tabs keeps
  // previously computed results visible.
  final Map<String, _SubRunState> _subStates = <String, _SubRunState>{};

  // Manual item_region overrides. Outer key = state key, inner key = problem
  // key (rawPage + ':' + 0-based order). When present, the stored value
  // wins over the VLM's original `item.itemRegion`.
  final Map<String, Map<String, List<int>>> _manualEdits =
      <String, Map<String, List<int>>>{};

  final Set<String> _batchSelection = <String>{};
  final Map<String, String> _pbExtractStatusBySub = <String, String>{};
  final Map<String, TextbookStageScopeStatus> _stageStatusBySub =
      <String, TextbookStageScopeStatus>{};
  bool _loadingStageStatuses = false;
  bool _batchRunning = false;
  int _batchDone = 0;
  int _batchTotal = 0;
  String _batchStatus = '';

  // Single-selection for the corner-handle editor. Null ⇒ no handles drawn.
  String? _selectedProblemKey;

  @override
  void initState() {
    super.initState();
    TextbookWorkflowRunner.instance.addListener(_onRunnerChanged);
    _loadPayload();
  }

  @override
  void dispose() {
    TextbookWorkflowRunner.instance.removeListener(_onRunnerChanged);
    for (final t in _autoSaveTimers.values) {
      t.cancel();
    }
    _bodyDocument?.dispose();
    for (final big in _bigUnits) {
      big.dispose();
    }
    super.dispose();
  }

  /// 실행기가 이 교재에서 돌리던 소단원이 끝나면 DB 상태와 진행 배지를 다시 읽는다.
  Set<String> _activeRunKeys = const <String>{};

  void _onRunnerChanged() {
    if (!mounted) return;
    final prefix = '${widget.bookId}|${widget.gradeLabel}|';
    final active = <String>{
      for (final s in TextbookWorkflowRunner.instance.states)
        if (s.active && s.key.startsWith(prefix)) s.key,
    };
    final finished = _activeRunKeys.difference(active);
    _activeRunKeys = active;
    setState(() {});
    if (finished.isNotEmpty) {
      unawaited(_loadWorkflows());
      unawaited(_loadStageStatuses());
      unawaited(_loadPbExtractRuns());
    }
  }

  // ------------------------------------------------------------ payload

  Future<void> _loadPayload() async {
    setState(() {
      _loadingPayload = true;
      _payloadError = null;
    });
    try {
      final row = await _registry.loadPayload(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
      final specialUnitByMid = await _loadSpecialUnitViews();
      final payload = row == null
          ? null
          : (row['payload'] is Map
              ? Map<String, dynamic>.from(row['payload'] as Map)
              : null);
      final series = (payload?['series'] as String?)?.trim().isNotEmpty == true
          ? (payload!['series'] as String).trim()
          : kTextbookSeriesCatalog.first.key;
      final entry = textbookSeriesByKey(series) ?? kTextbookSeriesCatalog.first;
      final loaded = bigUnitsFromPayload(payload, seriesKey: entry.key);
      final editable = <_BigUnitEdit>[];
      for (final big in loaded) {
        final bigEdit = _BigUnitEdit(bigName: big.bigName);
        for (final mid in big.middles) {
          final midEdit = _MidUnitEdit(series: entry, midName: mid.midName);
          for (final subUnit in mid.subUnits) {
            final row = _SubUnitRowEdit(
              name: subUnit.name,
              isExercise: subUnit.isExercise,
            );
            if (subUnit.startPage != null) {
              row.startCtrl.text = '${subUnit.startPage}';
            }
            if (subUnit.endPage != null) {
              row.endCtrl.text = '${subUnit.endPage}';
            }
            if (subUnit.answerStartPage != null) {
              row.answerStartCtrl.text = '${subUnit.answerStartPage}';
            }
            if (subUnit.solutionStartPage != null) {
              row.solutionStartCtrl.text = '${subUnit.solutionStartPage}';
            }
            midEdit.subUnitRows.add(row);
          }
          for (final sub in mid.subs) {
            for (final slot in midEdit.subs) {
              if (slot.preset.key == sub.subKey) {
                slot.startCtrl.text =
                    sub.startPage == null ? '' : '${sub.startPage}';
                slot.endCtrl.text = sub.endPage == null ? '' : '${sub.endPage}';
                slot.answerStartCtrl.text =
                    sub.answerStartPage == null ? '' : '${sub.answerStartPage}';
                slot.solutionStartCtrl.text = sub.solutionStartPage == null
                    ? ''
                    : '${sub.solutionStartPage}';
                break;
              }
            }
          }
          // 개념서: 소단원 행이 있으면 카테고리 슬롯 페이지를 소단원에서 유도한
          // 값으로 맞춘다 (payload 의 슬롯 값이 비었거나 어긋난 경우 대비).
          if (entry.hasSubUnitRows && midEdit.subUnitRows.isNotEmpty) {
            _recalcSubUnitSlotPages(midEdit);
          }
          bigEdit.middles.add(midEdit);
        }
        if (bigEdit.middles.isEmpty) {
          bigEdit.middles.add(_MidUnitEdit(series: entry));
        }
        editable.add(bigEdit);
      }
      if (editable.isEmpty) {
        final newBig = _BigUnitEdit();
        newBig.middles.add(_MidUnitEdit(series: entry));
        editable.add(newBig);
      }
      if (!mounted) return;
      setState(() {
        _seriesKey = entry.key;
        _bigUnits
          ..clear()
          ..addAll(editable);
        _specialUnitByMid = specialUnitByMid;
        _loadingPayload = false;
        _focus = null;
      });
      unawaited(_loadPbExtractRuns());
      unawaited(_loadExistingCrops());
      unawaited(_loadStageStatuses());
      unawaited(_loadWorkflows(resume: true));
      unawaited(_ensurePdf());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPayload = false;
        _payloadError = '$e';
      });
    }
  }

  Future<Map<String, _SpecialUnitView>> _loadSpecialUnitViews() async {
    try {
      final rows = await _supa
          .from('textbook_units')
          .select(
            'unit_key,name,display_start_page,display_end_page,order_index',
          )
          .match(<String, Object>{
        'academy_id': widget.academyId,
        'book_id': widget.bookId,
        'grade_label': widget.gradeLabel,
        'unit_level': 'small',
      }).like('unit_key', '%/SPECIAL:E:%');
      final out = <String, _SpecialUnitView>{};
      final pattern = RegExp(r'^B:(\d+)/M:(\d+)/SPECIAL:E(?:[:/]|$)');
      for (final raw in (rows as List<dynamic>)) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        final match = pattern.firstMatch('${row['unit_key'] ?? ''}');
        if (match == null) continue;
        final bigOrder = int.tryParse(match.group(1) ?? '');
        final midOrder = int.tryParse(match.group(2) ?? '');
        if (bigOrder == null || midOrder == null) continue;
        final start = _asIntValue(row['display_start_page']);
        final end = _asIntValue(row['display_end_page']) ?? start;
        if (start == null) continue;
        out['$bigOrder|$midOrder'] = _SpecialUnitView(
          name: '${row['name'] ?? '특강'}'.trim().isEmpty
              ? '특강'
              : '${row['name']}'.trim(),
          startPage: start,
          endPage: end ?? start,
        );
      }
      return out;
    } catch (_) {
      // 정규화 마이그레이션 전 환경에서는 기존 편집 트리를 유지한다.
      return const <String, _SpecialUnitView>{};
    }
  }

  int? _asIntValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  /// 낮을수록 "덜 끝난" 상태. 같은 sub_key 의 여러 소단원 런을 하나의 배지로
  /// 합칠 때 가장 낮은 값을 남긴다.
  static int _extractStatusRank(String status) {
    switch (status.trim().toLowerCase()) {
      case 'failed':
      case 'cancelled':
        return 0;
      case 'idle':
        return 1;
      case 'queued':
        return 2;
      case 'extracting':
        return 3;
      case 'review_required':
        return 4;
      case 'completed':
        return 5;
      default:
        return 1;
    }
  }

  Future<void> _loadPbExtractRuns() async {
    try {
      final rows = await _pbService.listTextbookPdfExtractRuns(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
      if (!mounted) return;
      setState(() {
        _pbExtractStatusBySub.clear();
        for (final row in rows) {
          final focus = _focusForPbExtractRun(row);
          if (focus.bigIndex < 0 || focus.midIndex < 0) continue;
          // 개념원리는 A/B/C/D/E 런을 소단원 행(W<idx>)으로 다시 합친다.
          // 같은 W 행 안에서는 가장 덜 끝난 상태를 남겨 진행 중 카테고리가
          // 완료 상태 뒤에 숨지 않게 한다.
          final key = _stateKeyFor(focus);
          final next = '${row['status'] ?? 'idle'}';
          final prev = _pbExtractStatusBySub[key];
          if (prev == null ||
              _extractStatusRank(next) < _extractStatusRank(prev)) {
            _pbExtractStatusBySub[key] = next;
          }
        }
      });
    } catch (_) {
      // 상태 배지는 보조 정보라 로딩 실패가 오서링 흐름을 막으면 안 된다.
    }
  }

  _SubFocus _focusForPbExtractRun(Map<String, dynamic> row) {
    final bigIndex = int.tryParse('${row['big_order'] ?? ''}') ?? -1;
    final midIndex = int.tryParse('${row['mid_order'] ?? ''}') ?? -1;
    var subKey = '${row['sub_key'] ?? ''}';
    if (_currentSeries().hasSubUnitRows) {
      final subIndex = int.tryParse('${row['sub_index'] ?? ''}') ?? 0;
      subKey = 'W$subIndex';
    }
    return _SubFocus(
      bigIndex: bigIndex,
      midIndex: midIndex,
      subKey: subKey,
    );
  }

  List<_SubFocus> _allSubFocuses() {
    final out = <_SubFocus>[];
    for (var b = 0; b < _bigUnits.length; b += 1) {
      final big = _bigUnits[b];
      for (var m = 0; m < big.middles.length; m += 1) {
        if (_currentSeries().hasSubUnitRows) {
          final rows = big.middles[m].subUnitRows;
          for (var s = 0; s < rows.length; s += 1) {
            out.add(_SubFocus(bigIndex: b, midIndex: m, subKey: 'W$s'));
          }
          continue;
        }
        for (final sub in big.middles[m].subs) {
          out.add(_SubFocus(
            bigIndex: b,
            midIndex: m,
            subKey: sub.preset.key,
          ));
        }
      }
    }
    return out;
  }

  Map<String, dynamic> _stageScopePayload(_SubFocus focus) {
    final payload = <String, dynamic>{
      'big_order': focus.bigIndex,
      'mid_order': focus.midIndex,
      'sub_key': focus.subKey,
    };
    if (_isWonriRowFocus(focus)) {
      final row = _wonriRowFor(focus);
      final displayStart =
          row == null ? null : _positiveInt(row.startCtrl.text);
      final displayEnd = row == null ? null : _positiveInt(row.endCtrl.text);
      final rawStart =
          displayStart == null ? null : _rawPageForDisplayPage(displayStart);
      final rawEnd =
          displayEnd == null ? null : _rawPageForDisplayPage(displayEnd);
      if (rawStart != null && rawEnd != null) {
        payload.addAll(<String, dynamic>{
          'scope_kind': 'wonri_sub_unit',
          'unit_row_index': _wonriRowIndex(focus) ?? 0,
          'body_start_page': rawStart,
          'body_end_page': rawEnd,
        });
      }
    }
    return payload;
  }

  Future<void> _loadStageStatuses() async {
    final focuses = _allSubFocuses();
    if (focuses.isEmpty) return;
    setState(() => _loadingStageStatuses = true);
    try {
      final statuses = await _pdfService.fetchStageStatuses(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        scopes: [for (final focus in focuses) _stageScopePayload(focus)],
      );
      if (!mounted) return;
      setState(() {
        _stageStatusBySub
          ..clear()
          ..addEntries(statuses.map((s) {
            final focus = _SubFocus(
              bigIndex: s.bigOrder,
              midIndex: s.midOrder,
              subKey: s.subKey,
            );
            return MapEntry(_stateKeyFor(focus), s);
          }));
        _loadingStageStatuses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingStageStatuses = false);
      debugPrint('[textbook-stage-status] load failed: $e');
    }
  }

  Future<void> _loadExistingCrops() async {
    try {
      // 한 번에 1000행까지만 오므로 쪽 단위로 끝까지 읽는다(큰 교재는 크롭이 1000개를 넘는다).
      Future<List<dynamic>> fetch(bool withSource) async {
        const pageSize = 1000;
        final out = <dynamic>[];
        for (var from = 0;; from += pageSize) {
          final page = await _supa
              .from('textbook_problem_crops')
              .select('id, raw_page, display_page, section, problem_number, label, '
                  'item_name, is_set_header, set_from, set_to, content_group_kind, '
                  'content_group_label, content_group_title, content_group_order, '
                  'column_index, bbox_1k, item_region_1k, companion_regions, '
                  'big_order, mid_order, sub_key, sub_index, pb_question_uid, '
                  'textbook_problem_analyses(math_status, quality_status)'
                  '${withSource ? ', region_source' : ''}')
              .eq('academy_id', widget.academyId)
              .eq('book_id', widget.bookId)
              .eq('grade_label', widget.gradeLabel)
              .order('big_order', ascending: true)
              .order('mid_order', ascending: true)
              .order('sub_key', ascending: true)
              .order('raw_page', ascending: true)
              .order('problem_number', ascending: true)
              .order('id', ascending: true)
              .range(from, from + pageSize - 1);
          out.addAll(page);
          if (page.length < pageSize) return out;
        }
      }
      List<dynamic> rows;
      try {
        rows = await fetch(true);
      } on PostgrestException catch (e) {
        if (!e.message.contains('region_source')) rethrow;
        rows = await fetch(false);
      }
      final byFocus = <String, List<Map<String, dynamic>>>{};
      for (final row in rows.cast<Map<String, dynamic>>()) {
        final bigIndex = int.tryParse('${row['big_order'] ?? ''}') ?? -1;
        final midIndex = int.tryParse('${row['mid_order'] ?? ''}') ?? -1;
        if (bigIndex < 0 || midIndex < 0) continue;
        var subKey = '${row['sub_key'] ?? ''}';
        // 개념서: DB의 sub_key 는 문제 카테고리지만 작업 단위는 소단원
        // 행이므로, raw_page 가 속한 소단원 행(W<idx>)으로 재매핑한다.
        if (_currentSeries().hasSubUnitRows) {
          final rawPage = int.tryParse('${row['raw_page'] ?? ''}');
          final wonriKey = _wonriRowSubKeyForPage(bigIndex, midIndex, rawPage);
          if (wonriKey == null) continue;
          subKey = wonriKey;
        }
        final focus = _SubFocus(
          bigIndex: bigIndex,
          midIndex: midIndex,
          subKey: subKey,
        );
        byFocus
            .putIfAbsent(_stateKeyFor(focus), () => <Map<String, dynamic>>[])
            .add(row);
      }
      final bodyCounts = <String, ({int crops, int bodies, int reviewed})>{};
      for (final entry in byFocus.entries) {
        var crops = 0;
        var bodies = 0;
        var reviewed = 0;
        for (final row in entry.value) {
          if (row['is_set_header'] == true) continue;
          crops += 1;
          if ('${row['pb_question_uid'] ?? ''}'.trim().isEmpty) continue;
          bodies += 1;
          if (textbookCropReviewApproved(row)) reviewed += 1;
        }
        bodyCounts[entry.key] = (crops: crops, bodies: bodies, reviewed: reviewed);
      }
      if (!mounted) return;
      setState(() {
        _bodyCounts = bodyCounts;
        for (final entry in byFocus.entries) {
          final focus = _focusFromStateKey(entry.key);
          if (focus == null) continue;
          final state = _ensureSubState(focus);
          if (state.running ||
              state.uploading ||
              state.pageResults.isNotEmpty) {
            continue;
          }
          state.uploadResult = TextbookCropBatchResult(
            upserted: entry.value.length,
            bucket: 'textbook-crops',
            rows: entry.value,
          );
          state.manualItems.clear();
          state.pageResults
            ..clear()
            ..addAll(_pageRowsFromSavedCrops(
              entry.value,
              focus,
              manualOut: state.manualItems,
            ));
          // 서버에서 읽어 온 것이지 이번에 올린 게 아니다.
          state.dirty = false;
          state.phase = '저장된 영역 ${entry.value.length}건';
          state.error = null;
        }
      });
    } catch (e) {
      // 저장된 영역 복원은 보조 기능이다. 실패해도 신규 분석 흐름은 유지한다.
      debugPrint('[textbook-stage1] saved crops load failed: $e');
    }
  }

  _SubFocus? _focusFromStateKey(String key) {
    final parts = key.split('/');
    if (parts.length != 3) return null;
    final bigIndex = int.tryParse(parts[0]);
    final midIndex = int.tryParse(parts[1]);
    if (bigIndex == null || midIndex == null) return null;
    if (bigIndex < 0 || bigIndex >= _bigUnits.length) return null;
    if (midIndex < 0 || midIndex >= _bigUnits[bigIndex].middles.length) {
      return null;
    }
    return _SubFocus(
      bigIndex: bigIndex,
      midIndex: midIndex,
      subKey: parts[2],
    );
  }

  // 단원분석/VLM 추출에서는 입력 페이지를 PDF raw page 로 그대로 사용한다.
  // textbook_metadata.page_offset 은 학습앱 표시용 보정값이며 추출 범위에는 적용하지 않는다.
  int _rawPageForDisplayPage(int displayPage) => displayPage;

  int _displayPageForRawPage(int rawPage) => rawPage;

  List<_PageAnalysisRow> _pageRowsFromSavedCrops(
    List<Map<String, dynamic>> rows,
    _SubFocus focus, {
    Set<TextbookVlmItem>? manualOut,
  }) {
    int? asIntN(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    }

    final byPage = <int, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final rawPage = asIntN(row['raw_page']);
      if (rawPage == null || rawPage <= 0) continue;
      byPage.putIfAbsent(rawPage, () => <Map<String, dynamic>>[]).add(row);
    }
    final out = <_PageAnalysisRow>[];
    for (final entry in byPage.entries) {
      final first = entry.value.first;
      final items = <TextbookVlmItem>[];
      for (final row in entry.value) {
        // 개념원리 W 포커스에서는 행마다 실제 카테고리 sub_key(A~D)가
        // 다르므로 DB 행의 sub_key 를 우선 사용한다.
        final item = _vlmItemFromSavedCrop(
          row,
          '${row['sub_key'] ?? ''}'.trim().isEmpty
              ? focus.subKey
              : '${row['sub_key']}'.trim(),
        );
        items.add(item);
        if ('${row['region_source'] ?? ''}' == 'manual') manualOut?.add(item);
      }
      out.add(_PageAnalysisRow.success(
        rawPage: entry.key,
        displayPage:
            asIntN(first['display_page']) ?? _displayPageForRawPage(entry.key),
        section: '${first['section'] ?? _sectionForSubKey(focus.subKey)}',
        pageKind: 'problem_page',
        notes: 'saved_crops',
        items: items,
      ));
    }
    out.sort((a, b) => a.rawPage.compareTo(b.rawPage));
    return out;
  }

  /// 저장된 crop 의 problem_number 에서 **지면에 인쇄된 번호**를 되돌린다.
  ///
  /// 개념+유형 쏙쏙(C)·한 번 더 연습(F)은 한 소단원에 블록이 여러 번 나와서
  /// 저장할 때 번호 앞에 본문 페이지를 붙인다("10-1"). 복원 때 그 값을 그대로
  /// 인쇄 번호 자리에 넣으면 다시 저장·시드를 만들 때 접두어가 한 번 더 붙어
  /// "10-10-1" 이 된다. 그러면 업로드 행과 키가 어긋나 시드가 통째로 비고,
  /// 그 코너는 정답·해설 단계 스코프에서 사라진다 (소단원이 1/3 완료로 멈춤).
  String _printedNumberFromSavedCrop(Map<String, dynamic> row, String subKey) {
    final number = '${row['problem_number'] ?? ''}'.trim();
    if (_seriesKey == 'gaeyu_high') {
      // 개념 Check 의 접두어는 블록 시작 쪽이라 이 문항의 쪽과 다를 수 있다.
      // 인쇄 번호에 하이픈이 없는 코너라 접두어는 그대로 벗긴다.
      if (!_kGaeyuHighBlockScopedKeys.contains(subKey.toUpperCase())) {
        return number;
      }
      return RegExp(r'^\d+-(\d+)$').firstMatch(number)?.group(1) ?? number;
    }
    if (_seriesKey != 'gaeyu') return number;
    if (!_kGaeyuBlockScopedKeys.contains(subKey.toUpperCase())) return number;
    final match = RegExp(r'^(\d+)-(.+)$').firstMatch(number);
    if (match == null) return number;
    final page = int.tryParse('${row['display_page'] ?? ''}') ??
        int.tryParse('${row['raw_page'] ?? ''}');
    // 접두어가 이 문항의 지면과 같을 때만 벗긴다. 그래야 진짜 하이픈 번호를
    // 실수로 자르지 않는다.
    if (page == null || int.tryParse(match.group(1)!) != page) return number;
    return match.group(2)!;
  }

  TextbookVlmItem _vlmItemFromSavedCrop(
    Map<String, dynamic> row,
    String subKey,
  ) {
    final section = '${row['section'] ?? _sectionForSubKey(subKey)}';
    // 개념+유형 고등의 C 는 "문제"(01-1 …)라 필수예제 유형명을 지녀야 한다.
    final isMastery =
        _seriesKey != 'gaeyu_high' && (subKey == 'C' || section == 'mastery');
    final rawKind = '${row['content_group_kind'] ?? 'none'}'.trim();
    final groupKind =
        isMastery || rawKind != 'type' && rawKind != 'basic_subtopic'
            ? 'none'
            : rawKind;
    return TextbookVlmItem.fromMap(<String, dynamic>{
      'number': _printedNumberFromSavedCrop(row, subKey),
      // 개념원리는 난이도(label)가 비어 있고 문항이름(item_name)에 값이 있다.
      // 복원 시 문항이름을 라벨 자리에 실어 뱃지/재저장이 그대로 동작하게 한다.
      'label': const {'wonri', 'wonri_middle'}.contains(_seriesKey)
          ? ('${row['item_name'] ?? ''}'.trim().isNotEmpty
              ? row['item_name']
              : row['label'])
          : row['label'],
      // 개념서: DB 의 section(=카테고리) 또는 sub_key 에서 category 복원.
      if (_currentSeries().hasSubUnitRows)
        'category': _conceptSubKeyByCategory.containsKey(section)
            ? section
            : (_conceptCategoryBySubKey[subKey.toUpperCase()] ?? ''),
      if ('${row['item_name'] ?? ''}'.contains('서술형 예시'))
        'item_role': 'descriptive_example'
      else if ('${row['item_name'] ?? ''}'.contains('대표 예제'))
        'item_role': 'representative'
      else if ('${row['item_name'] ?? ''}'.contains('핵심문제 확인'))
        'item_role': 'follow_up',
      'companion_regions': row['companion_regions'],
      'is_set_header': row['is_set_header'],
      'set_range': <String, dynamic>{
        'from': row['set_from'],
        'to': row['set_to'],
      },
      'content_group_kind': groupKind,
      'content_group_label':
          groupKind == 'none' ? '' : row['content_group_label'],
      'content_group_title':
          groupKind == 'none' ? '' : row['content_group_title'],
      'content_group_order':
          groupKind == 'none' ? null : row['content_group_order'],
      'column': row['column_index'],
      'bbox': row['bbox_1k'],
      'item_region': row['item_region_1k'],
    });
  }

  /// 유형 머리말이 유형이 바뀔 때만 인쇄돼, 머리말 없는 이어지는 문항이 직전
  /// 유형을 승계해야 하는 슬롯인지. 쎈/RPM 은 B(유형 뽀개기)뿐이고, 고쟁이는
  /// A(중등 핵심·발전, 고등 유형 배지)와 B(유형 배지) 둘 다다. 고쟁이
  /// D(창의융합)는 문항마다 배지가 따로 붙으므로 승계하면 안 된다.
  bool _carriesTypeGroup(String subKey) {
    if (isGojaengiSeries(_seriesKey)) return subKey == 'A' || subKey == 'B';
    return subKey == 'B';
  }

  _ResolvedContentGroup _rawContentGroupForItem(
    TextbookVlmItem item,
    String subKey,
    String section,
  ) {
    if (_seriesKey != 'gaeyu_high' && (subKey == 'C' || section == 'mastery')) {
      return const _ResolvedContentGroup.none();
    }
    final kind = item.contentGroupKind.trim();
    if (kind != 'type' && kind != 'basic_subtopic') {
      return const _ResolvedContentGroup.none();
    }
    final label = item.contentGroupLabel.trim();
    final title = item.contentGroupTitle.trim();
    if (label.isEmpty && title.isEmpty) {
      return const _ResolvedContentGroup.none();
    }
    return _ResolvedContentGroup(
      kind: kind,
      label: label,
      title: title,
      order: item.contentGroupOrder,
    );
  }

  _ResolvedContentGroup _effectiveContentGroupForItem({
    required _SubFocus focus,
    required _SubRunState state,
    required int rawPage,
    required int itemIndex,
  }) {
    // 수력충전은 소단원 행(W) 전체가 유형 문제라 행 단위로 유형을 승계한다.
    // 유형 머리말은 유형이 바뀔 때만 인쇄되므로, 지면이 넘어가도 직전 유형이
    // 이어진다. 개념 체크는 그 유형을 잇지 않고 이름만 개념 체크로 둔다.
    final carrySeries = _seriesKey == 'suryeok';
    if (!carrySeries && !_carriesTypeGroup(focus.subKey)) {
      return const _ResolvedContentGroup.none();
    }
    _ResolvedContentGroup? lastGroup;
    final rows = state.pageResults.where((row) => row.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in rows) {
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        final isTarget = row.rawPage == rawPage && i == itemIndex;
        if (carrySeries &&
            _wonriCategoryOfItem(item, row.section) != 'type_problem') {
          if (isTarget) {
            return _wonriCategoryOfItem(item, row.section) == 'concept_check'
                ? const _ResolvedContentGroup.suryeokConceptCheck()
                : const _ResolvedContentGroup.none();
          }
          continue;
        }
        final rawGroup =
            _rawContentGroupForItem(item, focus.subKey, row.section);
        if (rawGroup.kind == 'type') lastGroup = rawGroup;
        if (isTarget) {
          return rawGroup.kind == 'type'
              ? rawGroup
              : (lastGroup ?? const _ResolvedContentGroup.none());
        }
      }
    }
    return const _ResolvedContentGroup.none();
  }

  String? _requiredTypeGroupError(_SubFocus focus, _SubRunState state) {
    const seriesWithTypeHeaders = {'ssen', 'rpm', 'gojaengi', 'gojaengi_high'};
    if (!seriesWithTypeHeaders.contains(_seriesKey) ||
        !_carriesTypeGroup(focus.subKey)) {
      return null;
    }
    final items = state.pageResults
        .where((row) => row.ok)
        .expand((row) => row.items)
        .toList(growable: false);
    if (items.isEmpty) return null;
    final hasType = items.any((item) {
      final group = _rawContentGroupForItem(
        item,
        focus.subKey,
        _sectionForSubKey(focus.subKey),
      );
      return group.kind == 'type';
    });
    return hasType
        ? null
        : '${focus.subKey}단계 유형명을 하나도 추출하지 못했습니다. 유형명 포함 재분석이 필요합니다.';
  }

  String _sectionForSubKey(String subKey) {
    if (_seriesKey == 'wonri_middle') {
      return _kWonriMiddleCategoryBySubKey[subKey] ?? 'unknown';
    }
    // 개념원리는 슬롯 의미가 문제집(쎈/RPM)과 다르다.
    // 게이트웨이 vlm_detect_prompt.js 의 WONRI_SECTION_BY_SUB_KEY 와 동일하게 유지.
    if (_seriesKey == 'wonri') {
      switch (subKey) {
        case 'A':
          return 'concept_drill'; // 개념원리 익히기
        case 'B':
          return 'type_example'; // 필수유형
        case 'C':
          return 'check'; // 확인 체크
        case 'D':
          return 'exercise'; // 연습문제 (STEP1/STEP2/실력 UP)
        default:
          return 'unknown';
      }
    }
    // 게이트웨이 SURYEOK_SECTION_BY_SUB_KEY 와 동일하게 유지.
    if (_seriesKey == 'suryeok') {
      return _kSuryeokCategoryBySubKey[subKey] ?? 'unknown';
    }
    // 게이트웨이 GAEYU_HIGH_SECTION_BY_SUB_KEY 와 동일하게 유지.
    if (_seriesKey == 'gaeyu_high') {
      return _kGaeyuHighCategoryBySubKey[subKey] ?? 'unknown';
    }
    // 게이트웨이 GOJAENGI_SECTION_BY_SUB_KEY 와 동일하게 유지.
    if (isGojaengiSeries(_seriesKey)) {
      return _kGojaengiSectionBySubKey[subKey] ?? 'unknown';
    }
    switch (subKey) {
      case 'A':
        return 'basic_drill';
      case 'B':
        return 'type_practice';
      case 'C':
        return 'mastery';
      default:
        return 'unknown';
    }
  }

  String _sectionForFocus(_SubFocus focus) {
    // 소단원 행 기반 시리즈의 실제 포커스 키는 A/B가 아니라 W0, W1...이다.
    // 수력충전 단원마무리 행(W)의 힌트를 _sectionForSubKey에 바로 넘기면
    // unknown이 되어, 이어지는 지면의 특수 라벨이 모두 제거된다.
    if (_seriesKey == 'suryeok' && _isWonriRowFocus(focus)) {
      final row = _wonriRowFor(focus);
      if (row?.isExercise != true) return 'type_problem';
      return _isSuryeokSkillTestFocus(focus) ? 'skill_test' : 'unit_review';
    }
    return _sectionForSubKey(focus.subKey);
  }

  bool _isRpmAConceptPage(
    _SubFocus focus,
    int rawPage,
    int rawStartPage,
  ) {
    return _seriesKey == 'rpm' &&
        focus.subKey == 'A' &&
        (rawPage - rawStartPage).isEven;
  }

  TextbookVlmDetectResult _rpmAConceptPageResult(int rawPage) {
    return TextbookVlmDetectResult(
      rawPage: rawPage,
      displayPage: _displayPageForRawPage(rawPage),
      pageOffset: 0,
      pageOffsetFound: false,
      section: 'basic_drill',
      pageKind: 'concept_page',
      conceptDrillHeaderVisible: false,
      layout: 'unknown',
      items: const <TextbookVlmItem>[],
      notes: 'rpm_a_concept_page_by_alternation',
      model: 'deterministic_series_rule',
      elapsedMs: 0,
      finishReason: 'RULE',
    );
  }

  // ------------------------------------------------------- 목차 자동 인식
  //
  // 등록 위저드와 동일한 흐름: 본문 PDF의 목차 페이지 범위 + 페이지 보정을
  // 입력받아 VLM 으로 단원 트리를 읽고, 단원 이름과 페이지 범위를 자동으로
  // 채운다. 신규행으로 추가한(위저드를 거치지 않은) 책도 여기서 쓸 수 있다.
  // 적용 후 "단원 구조 저장"을 눌러야 Supabase 에 반영된다.

  Future<void> _runTocAutoParse() async {
    if (_tocParsing) return;
    final doc = await _ensurePdf();
    if (doc == null) {
      _toast(
        '본문 PDF를 불러오지 못했습니다'
        '${_pdfLoadError == null ? '' : ': $_pdfLoadError'}',
        error: true,
      );
      return;
    }
    if (!mounted) return;
    // 이미 입력된 트리가 있으면 덮어쓰기 확인.
    final hasContent = _bigUnits.any((b) =>
        b.nameCtrl.text.trim().isNotEmpty ||
        b.middles.any((m) => m.nameCtrl.text.trim().isNotEmpty));
    if (hasContent) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('기존 트리 덮어쓰기',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          content: const Text(
            '목차 자동 인식은 현재 단원 트리를 새 결과로 교체합니다. 계속할까요?\n'
            '(저장 전까지는 Supabase 에 반영되지 않습니다)',
            style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: _kAccent),
              child: const Text('덮어쓰기'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final range = await showTocRangeDialog(context);
    if (range == null) return;
    setState(() {
      _tocParsing = true;
      _tocStatus = '목차 페이지 렌더링 중...';
    });
    try {
      final start = range.start.clamp(1, doc.pages.length);
      final end = range.end.clamp(start, doc.pages.length);
      final images = <Uint8List>[];
      for (var page = start; page <= end; page += 1) {
        images.add(await renderPdfPageToPng(
          document: doc,
          pageNumber: page,
          longEdgePx: kTocRenderLongEdgePx,
        ));
        if (!mounted) return;
        setState(() => _tocStatus = '목차 페이지 렌더링 중... ($page / $end)');
      }
      if (!mounted) return;
      setState(() => _tocStatus = 'VLM 목차 분석 중... (${images.length}페이지)');
      final result = await _vlmService.parseToc(
        pageImages: images,
        series: _seriesKey,
      );
      if (!mounted) return;
      final applied = await _applyTocResult(
        result,
        document: doc,
        tocPageOffset: range.pageOffset,
      );
      final failureDetail = applied != null
          ? ''
          : await describeTocAutofillFailure(
              result,
              pageImages: images,
              startPage: start,
            );
      if (!mounted) return;
      setState(() {
        _tocParsing = false;
        _tocStatus = applied == null
            ? '실패: 목차에서 단원을 찾지 못했습니다.$failureDetail'
            : '목차 인식 완료 · 대단원 ${applied.$1}개 / 중단원 ${applied.$2}개 · '
                '페이지 자동 입력됨(보정 ${range.pageOffset >= 0 ? '+' : ''}'
                '${range.pageOffset}) — 검토 후 "단원 구조 저장"을 누르세요'
                '${applied.$3}'
                '${result.notes.isEmpty ? '' : ' · ${result.notes}'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tocParsing = false;
        _tocStatus = '실패: $e';
      });
    }
  }

  /// 고쟁이 워크북 지면을 훑어 E(중단원 TEST)·F(대단원 TEST) 쪽 범위를 채운다.
  ///
  /// 목차에는 워크북 두 묶음의 시작 쪽만 인쇄돼 있어서 대단원·중단원별 범위는
  /// 지면 머리말을 읽어야 나온다. 상태줄에 덧붙일 문구를 돌려준다.
  Future<String> _autofillWorkbookRanges(
    List<TocAutofillBigUnit> tree, {
    required TextbookTocParseResult toc,
    required PdfDocument document,
    required int tocPageOffset,
  }) async {
    final printedStart = toc.workbookMidTestPage ?? toc.workbookBigTestPage;
    if (_seriesKey != 'gojaengi' || printedStart == null) return '';
    final startRaw = printedStart + tocPageOffset;
    if (startRaw < 1 || startRaw > document.pages.length) {
      return ' · 워크북 시작 쪽($printedStart)이 PDF 범위를 벗어나 건너뜀';
    }
    final report = await autofillGojaengiWorkbookRanges(
      tree,
      workbookStartPage: startRaw,
      workbookEndPage: document.pages.length,
      classify: (rawPages) async {
        final images = <TextbookRpmSectionImage>[];
        for (final rawPage in rawPages) {
          images.add(TextbookRpmSectionImage(
            rawPage: rawPage,
            bytes: await renderPdfPageToPng(
              document: document,
              pageNumber: rawPage,
              longEdgePx: 1100,
            ),
          ));
        }
        final result = await _vlmService.classifyGojaengiWorkbookPages(
          images: images,
        );
        return result.pages;
      },
      onProgress: (message) {
        if (mounted) setState(() => _tocStatus = message);
      },
    );
    if (report.isEmpty) return ' · 워크북 묶음 머리말을 하나도 못 읽었습니다';
    return ' · 워크북 중단원 TEST ${report.midTestCount}개 / '
        '대단원 TEST ${report.bigTestCount}개 쪽 자동 입력'
        '${report.unmatched.isEmpty ? '' : ' · 짝 못 찾음: ${report.unmatched.join(', ')}'}';
  }

  /// VLM 목차 결과를 단원 트리에 반영한다. (대단원 수, 중단원 수) 를 반환.
  ///
  /// 이름 정리와 페이지 자동 채움은 [buildTocAutofillTree] (공용 로직) 가
  /// 처리한다. 개념원리(wonri)는 소단원 행을 payload 용으로 보존하고,
  /// A~D 슬롯 페이지를 소단원 범위에서 유도해 입력칸까지 채운다
  /// (A/B/C = 일반 소단원 전체 범위, D = 연습문제 행 범위).
  Future<(int, int, String)?> _applyTocResult(
    TextbookTocParseResult toc, {
    required PdfDocument document,
    int tocPageOffset = 0,
  }) async {
    final entry = _currentSeries();
    final hasSubUnitRows = entry.hasSubUnitRows;
    final tree = buildTocAutofillTree(
      toc,
      subUnitRows: hasSubUnitRows,
      seriesKey: _seriesKey,
      tocPageOffset: tocPageOffset,
      lastRawPage: document.pages.length,
    );
    if (tree.isEmpty) return null;
    var partStatus = '';
    if (_seriesKey == 'wonri_middle') {
      final report = await autofillWonriMiddleSubUnitRanges(
        tree,
        classify: (rawPages) async {
          final images = <TextbookRpmSectionImage>[];
          for (final rawPage in rawPages) {
            images.add(TextbookRpmSectionImage(
              rawPage: rawPage,
              bytes: await renderPdfPageToPng(
                document: document,
                pageNumber: rawPage,
                longEdgePx: 1100,
              ),
            ));
          }
          final result = await _vlmService.classifyWonriMiddleStructurePages(
            images: images,
          );
          return result.pages;
        },
        onProgress: (message) {
          if (mounted) setState(() => _tocStatus = message);
        },
      );
      partStatus = ' · 본문 소단원 ${report.subUnitCount}개 자동 보완'
          '${report.calculationPageCount > 0 ? ' · 계산력 강화 ${report.calculationPageCount}지면 확인' : ''}'
          '${report.incompleteMids.isEmpty ? '' : ' · 소단원 머리말 미확인: ${report.incompleteMids.join(', ')}'}';
    }
    final partSeries = kProblemBookSectionParts.containsKey(_seriesKey);
    if (partSeries) {
      final report = await autofillProblemBookPartRanges(
        tree,
        series: _seriesKey,
        classify: (rawPages) async {
          final images = <TextbookRpmSectionImage>[];
          for (final rawPage in rawPages) {
            images.add(TextbookRpmSectionImage(
              rawPage: rawPage,
              bytes: await renderPdfPageToPng(
                document: document,
                pageNumber: rawPage,
                longEdgePx: 1100,
              ),
            ));
          }
          final result = await _vlmService.classifyProblemBookSections(
            images: images,
            series: _seriesKey,
          );
          return result.pages;
        },
        onProgress: (message) {
          if (mounted) setState(() => _tocStatus = message);
        },
      );
      final seriesName = _currentSeries().displayName;
      final slotLabel =
          kProblemBookSectionParts[_seriesKey]!.map((p) => p[0]).join('/');
      if (report.incompleteMids.isNotEmpty) {
        partStatus = ' · $seriesName 경계 미확인: '
            '${report.incompleteMids.join(', ')}';
      } else {
        partStatus = ' · $seriesName '
            '$slotLabel ${report.completedMids}개 중단원 자동 분리';
      }
      partStatus += await _autofillWorkbookRanges(
        tree,
        toc: toc,
        document: document,
        tocPageOffset: tocPageOffset,
      );
    }
    final newBigs = <_BigUnitEdit>[];
    for (final big in tree) {
      final bigEdit = _BigUnitEdit(bigName: big.name);
      for (final mid in big.midUnits) {
        final midEdit = _MidUnitEdit(series: entry, midName: mid.name);
        if (hasSubUnitRows) {
          for (final sub in mid.subUnits) {
            final row = _SubUnitRowEdit(
              name: sub.name,
              isExercise: sub.isExercise,
            );
            if (sub.startPage != null) row.startCtrl.text = '${sub.startPage}';
            if (sub.endPage != null) row.endCtrl.text = '${sub.endPage}';
            midEdit.subUnitRows.add(row);
          }
          _recalcSubUnitSlotPages(midEdit);
        }
        if (partSeries) {
          for (final slot in midEdit.subs) {
            final range = mid.rpmPartRanges[slot.preset.key];
            if (range == null) continue;
            slot.startCtrl.text = '${range.startPage}';
            slot.endCtrl.text = '${range.endPage}';
          }
        }
        bigEdit.middles.add(midEdit);
      }
      if (bigEdit.middles.isEmpty) {
        bigEdit.middles.add(_MidUnitEdit(series: entry));
      }
      newBigs.add(bigEdit);
    }
    var midCount = 0;
    for (final big in newBigs) {
      midCount += big.middles.length;
    }
    setState(() {
      for (final big in _bigUnits) {
        big.dispose();
      }
      _bigUnits
        ..clear()
        ..addAll(newBigs);
      _focus = null;
      _selectedProblemKey = null;
    });
    return (newBigs.length, midCount, partStatus);
  }

  Future<void> _saveTree({bool silent = false}) async {
    final payload = _buildBigUnitInputs();
    try {
      await _registry.saveUnitPayload(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        seriesKey: _seriesKey,
        bigUnits: payload,
      );
      if (_seriesKey == 'wonri') {
        await _rebuildSpecialUnits();
      }
      if (!mounted) return;
      if (!silent) _toast('단원 구조를 Supabase에 저장했어요.');
    } catch (e) {
      if (!mounted) return;
      if (!silent) _toast('저장 실패: $e', error: true);
    }
  }

  /// 특강(E) 크롭에서 정규화 특강 소단원을 (재)생성해 학생/학습앱 트리에
  /// 반영한다. 최초 마이그레이션과 달리 재추출 후에도 반복 호출 가능하다.
  Future<void> _rebuildSpecialUnits() async {
    if (_seriesKey != 'wonri') return;
    try {
      await _supa.rpc('textbook_rebuild_special_units', params: {
        'p_book_id': widget.bookId,
        'p_grade_label': widget.gradeLabel,
      });
    } catch (_) {
      // 정규화 트리 동기화 실패가 오서링 흐름을 막지는 않는다.
    }
  }

  /// 중단원 이름에 맞는 슬롯 구성으로 맞춘다. 고쟁이는 "대단원 TEST" 행만
  /// F 슬롯을, 나머지 중단원은 A~E 를 갖는다. 이름을 고쳐 쓰면 슬롯이 따라
  /// 바뀌어야 하므로 이름 입력 때마다 다시 맞춘다.
  void _syncTrailingMidSlots() {
    final series = _currentSeries();
    if (series.trailingMidSlotKeys.isEmpty) return;
    for (final big in _bigUnits) {
      for (final mid in big.middles) {
        mid.applyPreset(series);
      }
    }
  }

  /// 소단원 행들의 페이지에서 카테고리 슬롯 페이지를 유도해 입력칸을 갱신한다.
  /// 시리즈가 지정한 마무리 슬롯(개념원리 D 연습문제, 개념+유형 D·E 단원
  /// 다지기·서술형 완성하기)은 마무리 행 범위를, 나머지 슬롯은 일반 소단원 행
  /// 전체 범위를 쓴다.
  void _recalcSubUnitSlotPages(_MidUnitEdit mid) {
    final unitEndSlotKeys = _currentSeries().unitEndSlotKeys;
    int? lessonStart;
    int? lessonEnd;
    int? exerciseStart;
    int? exerciseEnd;
    for (final row in mid.subUnitRows) {
      if (row.nameCtrl.text.trim().contains('특강')) continue;
      final start = _positiveInt(row.startCtrl.text);
      final end = _positiveInt(row.endCtrl.text);
      if (row.isExercise) {
        if (start != null) {
          exerciseStart = exerciseStart == null
              ? start
              : (start < exerciseStart ? start : exerciseStart);
        }
        if (end != null) {
          exerciseEnd = exerciseEnd == null
              ? end
              : (end > exerciseEnd ? end : exerciseEnd);
        }
      } else {
        if (start != null) {
          lessonStart = lessonStart == null
              ? start
              : (start < lessonStart ? start : lessonStart);
        }
        if (end != null) {
          lessonEnd =
              lessonEnd == null ? end : (end > lessonEnd ? end : lessonEnd);
        }
      }
    }
    for (final slot in mid.subs) {
      final isExerciseSlot = unitEndSlotKeys.contains(slot.preset.key);
      final start = isExerciseSlot ? exerciseStart : lessonStart;
      final end = isExerciseSlot ? exerciseEnd : lessonEnd;
      slot.startCtrl.text = start == null ? '' : '$start';
      slot.endCtrl.text = end == null ? '' : '$end';
    }
  }

  List<BigUnitInput> _buildBigUnitInputs() {
    final out = <BigUnitInput>[];
    for (var i = 0; i < _bigUnits.length; i += 1) {
      final big = _bigUnits[i];
      final midList = <MidUnitInput>[];
      for (var m = 0; m < big.middles.length; m += 1) {
        final mid = big.middles[m];
        // 개념서: 저장 직전에 소단원 행 → 카테고리 슬롯 페이지를 다시 유도해
        // 슬롯 입력칸과 payload 가 항상 소단원 입력과 일치하게 한다.
        if (_currentSeries().hasSubUnitRows && mid.subUnitRows.isNotEmpty) {
          _recalcSubUnitSlotPages(mid);
        }
        final subUnitList = <SubUnitInput>[];
        var order = 0;
        for (final row in mid.subUnitRows) {
          final name = row.nameCtrl.text.trim();
          if (name.isEmpty) continue;
          subUnitList.add(SubUnitInput(
            order: order,
            name: name,
            startPage: _positiveInt(row.startCtrl.text),
            endPage: _positiveInt(row.endCtrl.text),
            answerStartPage: _positiveInt(row.answerStartCtrl.text),
            solutionStartPage: _positiveInt(row.solutionStartCtrl.text),
            isExercise: row.isExercise,
          ));
          order += 1;
        }
        final subList = <SubSectionInput>[];
        for (var s = 0; s < mid.subs.length; s += 1) {
          final sub = mid.subs[s];
          subList.add(SubSectionInput(
            order: s,
            subKey: sub.preset.key,
            displayName: sub.preset.displayName,
            startPage: _positiveInt(sub.startCtrl.text),
            endPage: _positiveInt(sub.endCtrl.text),
            answerStartPage: _positiveInt(sub.answerStartCtrl.text),
            solutionStartPage: _positiveInt(sub.solutionStartCtrl.text),
          ));
        }
        midList.add(MidUnitInput(
          midOrder: m,
          midName: mid.nameCtrl.text.trim(),
          subs: subList,
          subUnits: subUnitList,
        ));
      }
      out.add(BigUnitInput(
        bigOrder: i,
        bigName: big.nameCtrl.text.trim(),
        middles: midList,
      ));
    }
    return out;
  }

  // ------------------------------------------------------------ pdf load

  Future<PdfDocument?> _ensurePdf() async {
    if (_bodyDocument != null) return _bodyDocument;
    if (_loadingPdf) return null;
    setState(() {
      _loadingPdf = true;
      _pdfLoadError = null;
    });
    try {
      final target = await _pdfService.requestDownloadUrl(
        linkId: widget.linkId,
        academyId: widget.academyId,
        fileId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        kind: 'body',
        requireMigratedStorage: true,
      );
      final url = target.url;
      if (url.isEmpty) throw Exception('empty_download_url');

      final tempDir = await getTemporaryDirectory();
      final safeBook = widget.bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File(p.join(
        tempDir.path,
        'auth_${safeBook}_${widget.gradeLabel}_body.pdf',
      ));
      final res = await http.get(Uri.parse(url));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('pdf_download_failed(${res.statusCode})');
      }
      await file.writeAsBytes(res.bodyBytes, flush: true);
      final doc = await PdfDocument.openFile(file.path);
      if (!mounted) {
        doc.dispose();
        return null;
      }
      setState(() {
        _bodyDocument = doc;
        _bodyLocalPath = file.path;
        _loadingPdf = false;
      });
      return doc;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _loadingPdf = false;
        _pdfLoadError = '$e';
      });
      return null;
    }
  }

  // ------------------------------------------------------------ analysis

  String _stateKeyFor(_SubFocus focus) =>
      '${focus.bigIndex}/${focus.midIndex}/${focus.subKey}';

  List<_SubFocus> _selectedBatchFocuses() {
    final out = <_SubFocus>[];
    for (var b = 0; b < _bigUnits.length; b += 1) {
      final big = _bigUnits[b];
      for (var m = 0; m < big.middles.length; m += 1) {
        for (final focus in _midBatchFocuses(b, m)) {
          if (_batchSelection.contains(_stateKeyFor(focus))) {
            out.add(focus);
          }
        }
      }
    }
    return out;
  }

  List<_SubFocus> _midBatchFocuses(int bigIndex, int midIndex) {
    final mid = _bigUnits[bigIndex].middles[midIndex];
    // 개념서: 배치 실행 단위는 카테고리 슬롯이 아니라 소단원 행이다.
    if (_currentSeries().hasSubUnitRows) {
      return [
        for (var s = 0; s < mid.subUnitRows.length; s += 1)
          _SubFocus(bigIndex: bigIndex, midIndex: midIndex, subKey: 'W$s'),
      ];
    }
    return [
      for (final sub in mid.subs)
        _SubFocus(
          bigIndex: bigIndex,
          midIndex: midIndex,
          subKey: sub.preset.key,
        ),
    ];
  }

  void _toggleBatchSub(_SubFocus focus, bool selected) {
    setState(() {
      final key = _stateKeyFor(focus);
      if (selected) {
        _batchSelection.add(key);
        _focus = focus;
        _selectedProblemKey = null;
      } else {
        _batchSelection.remove(key);
        if (_focus != null &&
            _focus!.bigIndex == focus.bigIndex &&
            _focus!.midIndex == focus.midIndex &&
            _focus!.subKey == focus.subKey &&
            _batchSelection.isNotEmpty) {
          final next = _selectedBatchFocuses().first;
          _focus = next;
          _selectedProblemKey = null;
        }
      }
    });
  }

  void _toggleBatchMid(int bigIndex, int midIndex, bool selected) {
    final focuses = _midBatchFocuses(bigIndex, midIndex);
    setState(() {
      for (final focus in focuses) {
        final key = _stateKeyFor(focus);
        if (selected) {
          _batchSelection.add(key);
        } else {
          _batchSelection.remove(key);
        }
      }
      if (selected && focuses.isNotEmpty) {
        _focus = focuses.first;
        _selectedProblemKey = null;
      } else if (_focus != null && _batchSelection.isNotEmpty) {
        final next = _selectedBatchFocuses().first;
        _focus = next;
        _selectedProblemKey = null;
      }
    });
  }

  bool? _midBatchValue(int bigIndex, int midIndex) {
    final focuses = _midBatchFocuses(bigIndex, midIndex);
    if (focuses.isEmpty) return false;
    final selected = focuses
        .where((focus) => _batchSelection.contains(_stateKeyFor(focus)))
        .length;
    if (selected == 0) return false;
    if (selected == focuses.length) return true;
    return null;
  }

  _SubRunState _ensureSubState(_SubFocus focus) {
    final key = _stateKeyFor(focus);
    return _subStates.putIfAbsent(key, () => _SubRunState());
  }

  Map<String, List<int>> _ensureManualEdits(_SubFocus focus) {
    return _manualEdits.putIfAbsent(
      _stateKeyFor(focus),
      () => <String, List<int>>{},
    );
  }

  String _problemKey(int rawPage, int orderIndex) => '$rawPage:$orderIndex';

  /// Returns the currently effective item_region for a problem: the manual
  /// edit if present, else the VLM original (possibly null).
  List<int>? _effectiveItemRegion({
    required _SubFocus focus,
    required int rawPage,
    required int orderIndex,
    required TextbookVlmItem item,
  }) {
    final edits = _manualEdits[_stateKeyFor(focus)];
    final edited = edits?[_problemKey(rawPage, orderIndex)];
    if (edited != null && edited.length == 4) return edited;
    return item.itemRegion;
  }

  List<int>? _effectiveNumberBbox(
    TextbookVlmItem item,
    List<int>? itemRegion,
  ) {
    final bbox = item.bbox;
    if (_seriesKey != 'gaeyu' ||
        bbox == null ||
        bbox.length != 4 ||
        itemRegion == null ||
        itemRegion.length != 4) {
      return bbox;
    }
    final byMax = bbox[2];
    final bxMin = bbox[1];
    final bxMax = bbox[3];
    final ryMin = itemRegion[0];
    final rxMin = itemRegion[1];
    final bboxIsAboveBody = byMax < ryMin - 2;
    final bboxIsInBodyColumn = bxMin >= rxMin - 4 && bxMax > rxMin;
    if (!bboxIsAboveBody || !bboxIsInBodyColumn) return bbox;

    final number = item.number.trim();
    final width = RegExp(r'[가-힣]').hasMatch(number)
        ? 54
        : (number.length * 11).clamp(30, 50);
    final right = (rxMin - 7).clamp(0, 1000);
    final left = (right - width).clamp(0, 1000);
    final top = ryMin.clamp(0, 1000);
    final bottom = (ryMin + 22).clamp(top + 1, 1000);
    return <int>[top, left, bottom, right];
  }

  Future<String?> _expectedStartNumberForFocus(_SubFocus focus) async {
    // 4자리 연속 번호(0001~)는 쎈/RPM A 파트 전용 개념이다.
    if (focus.subKey != 'A' ||
        _seriesKey == 'wonri' ||
        _seriesKey == 'suryeok') {
      return null;
    }
    try {
      final rows = await _supa
          .from('textbook_problem_crops')
          .select('problem_number,set_to,big_order,mid_order,sub_key')
          .eq('academy_id', widget.academyId)
          .eq('book_id', widget.bookId)
          .eq('grade_label', widget.gradeLabel)
          .limit(5000);
      var maxPrevious = 0;
      for (final raw in rows) {
        if (!_cropRowIsBeforeFocus(raw, focus)) continue;
        final value = _problemNumberEndValue(raw);
        if (value != null && value > maxPrevious) {
          maxPrevious = value;
        }
      }
      if (maxPrevious <= 0 || maxPrevious >= 9999) return null;
      return _formatBasicDrillNumber(maxPrevious + 1);
    } catch (e) {
      debugPrint('[textbook-stage1] expected start lookup failed: $e');
      return null;
    }
  }

  bool _cropRowIsBeforeFocus(Map<dynamic, dynamic> row, _SubFocus focus) {
    final bigOrder = int.tryParse('${row['big_order'] ?? ''}');
    final midOrder = int.tryParse('${row['mid_order'] ?? ''}');
    if (bigOrder == null || midOrder == null) return false;
    if (bigOrder != focus.bigIndex) return bigOrder < focus.bigIndex;
    if (midOrder != focus.midIndex) return midOrder < focus.midIndex;
    return _subOrderOf('${row['sub_key'] ?? ''}') < _subOrderOf(focus.subKey);
  }

  int _subOrderOf(String subKey) {
    switch (subKey.trim()) {
      case 'A':
        return 0;
      case 'B':
        return 1;
      case 'C':
        return 2;
      case 'D':
        return 3;
      default:
        return 99;
    }
  }

  int? _problemNumberEndValue(Map<dynamic, dynamic> row) {
    final setTo = int.tryParse('${row['set_to'] ?? ''}');
    if (setTo != null && setTo > 0 && setTo <= 9999) return setTo;
    final rawNumber = '${row['problem_number'] ?? ''}';
    final matches = RegExp(r'\d+').allMatches(rawNumber);
    var out = 0;
    for (final match in matches) {
      final value = int.tryParse(match.group(0) ?? '');
      if (value != null && value > out && value <= 9999) {
        out = value;
      }
    }
    return out > 0 ? out : null;
  }

  String _formatBasicDrillNumber(int value) => value.toString().padLeft(4, '0');

  String? _expectedStartNumberForPage(
    _SubFocus focus,
    _SubRunState state,
    int rawPage,
    String? expectedStartNumber,
  ) {
    if (focus.subKey != 'A' || expectedStartNumber == null) return null;
    final alreadySawProblemBeforePage = state.pageResults.any((row) =>
        row.ok &&
        row.rawPage < rawPage &&
        row.section == 'basic_drill' &&
        row.items.isNotEmpty);
    return alreadySawProblemBeforePage ? null : expectedStartNumber;
  }

  Future<void> _runFocusedAnalysis(_SubFocus focus) async {
    final series = _currentSeries();
    if (!series.supportsProblemExtraction) {
      // 지면 카테고리 프롬프트가 없는 시리즈로 분석하면 다른 교재 규칙이
      // 적용돼 잘못된 크롭이 저장된다. 목차·단원 구조 입력까지만 허용한다.
      _toast(
        '${series.displayName} 문항 추출은 아직 준비 중입니다. '
        '목차·단원 구조 입력까지만 사용하세요.',
        error: true,
      );
      return;
    }
    final (displayStartPage, displayEndPage) = _focusRange(focus);
    if (displayStartPage == null ||
        displayEndPage == null ||
        displayEndPage < displayStartPage) {
      _toast('시작/끝 페이지를 먼저 입력하세요', error: true);
      return;
    }
    if (_cropLocked(focus)) {
      _toast('${_subFocusLabel(focus)}은(는) 크롭을 확정했습니다. 다시 열기 후 분석하세요',
          error: true);
      return;
    }
    final rawStartPage = _rawPageForDisplayPage(displayStartPage);
    final rawEndPage = _rawPageForDisplayPage(displayEndPage);
    final doc = await _ensurePdf();
    if (doc == null) return;
    final state = _ensureSubState(focus);
    if (state.running) return;
    final expectedStartNumber = await _expectedStartNumberForFocus(focus);
    // 사람이 그리거나 고친 문항은 다시 분석해도 남긴다. 핸들 수정은 문항 순서가
    // 바뀌면 엉뚱한 문항을 가리키므로 먼저 문항에 굳혀 둔다.
    _bakeManualEdits(focus, state);
    final keptManual = [
      for (final row in state.pageResults.where((r) => r.ok))
        for (final item in row.items)
          if (state.manualItems.contains(item)) (row, item),
    ];
    // 취소·실패하면 분석 전 결과로 되돌린다(자동 저장이 반쪽 결과를 올리지 않게).
    final previousRows = List<_PageAnalysisRow>.of(state.pageResults);
    final previousDirty = state.dirty;
    void restorePrevious(String phase, {String? error}) {
      setState(() {
        state.pageResults
          ..clear()
          ..addAll(previousRows);
        state.running = false;
        state.dirty = previousDirty;
        state.error = error;
        state.phase = phase;
      });
    }

    _autoSaveTimers.remove(_stateKeyFor(focus))?.cancel();
    setState(() {
      state.running = true;
      state.cancelled = false;
      state.pageResults.clear();
      state.progress = RangeProgress(
        cursor: rawStartPage,
        total: rawEndPage - rawStartPage + 1,
        done: 0,
        failed: 0,
        failedPages: <int>{},
      );
      state.phase = '페이지 렌더링/분석 중...';
      state.error = null;
      _selectedProblemKey = null;
    });

    Future<Uint8List> render({
      required int rawPage,
      required int longEdgePx,
    }) {
      return renderPdfPageToPng(
        document: doc,
        pageNumber: rawPage,
        longEdgePx: longEdgePx,
      );
    }

    Future<TextbookVlmDetectResult> detect({
      required Uint8List imageBytes,
      required int rawPage,
    }) async {
      if (_isRpmAConceptPage(focus, rawPage, rawStartPage)) {
        return _rpmAConceptPageResult(rawPage);
      }
      final result = await _vlmService.detectProblemsOnPage(
        imageBytes: imageBytes,
        rawPage: rawPage,
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        // 개념서(개념원리·개념+유형)는 단일 패스: 카테고리 힌트 없이 페이지의
        // 모든 문항을 감지하고 문항별 category 를 받는다.
        sectionHint: _seriesKey == 'suryeok'
            ? _sectionForFocus(focus)
            : _currentSeries().hasSubUnitRows
                ? null
                : _sectionForSubKey(focus.subKey),
        expectedStartNumber: _expectedStartNumberForPage(
          focus,
          state,
          rawPage,
          expectedStartNumber,
        ),
        series: _seriesKey,
      );
      if (_seriesKey == 'rpm' && focus.subKey == 'A' && result.items.isEmpty) {
        throw StateError(
          'rpm_a_expected_problem_page_empty: raw_page=$rawPage',
        );
      }
      return result;
    }

    try {
      final finalProgress = await runRangeAnalysis(
        startPage: rawStartPage,
        endPage: rawEndPage,
        analysisLongEdgePx: _kAnalysisLongEdgePx,
        renderer: render,
        detector: detect,
        isCancelled: () => state.cancelled,
        onPageSuccess: (outcome) async {
          state.pageResults.add(_PageAnalysisRow.success(
            rawPage: outcome.rawPage,
            displayPage: outcome.result.displayPage,
            section: outcome.result.section,
            pageKind: outcome.result.pageKind,
            conceptDrillHeaderVisible: outcome.result.conceptDrillHeaderVisible,
            notes: outcome.result.notes,
            items: outcome.result.items,
          ));
          // 개념원리는 전체 소단원 결과를 모은 뒤 헤더 경계를 판정해야 한다.
          // 페이지별 스트리밍 중 즉시 가드를 적용하면 뒤 페이지의 헤더가
          // 도착하기 전에 앞 문항을 영구 삭제하게 된다.
          if (_seriesKey != 'wonri') _applyScopeGuards(focus);
          if (!mounted) return;
          setState(() {});
        },
        onPageFailure: (f) {
          debugPrint('[textbook-stage1] page failed '
              'raw=${f.rawPage} attempts=${f.attempts} error=${f.error}');
          state.pageResults.add(_PageAnalysisRow.failure(
            rawPage: f.rawPage,
            error: '${f.error}',
          ));
          if (!mounted) return;
          setState(() {});
        },
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            state.progress = progress;
          });
        },
      );
      if (!mounted) return;
      if (state.cancelled) {
        restorePrevious('취소 · 이전 결과 유지');
        return;
      }
      if (_currentSeries().hasSubUnitRows) _applyScopeGuards(focus);
      _restoreManualItems(state, keptManual);
      final typeGroupError = _requiredTypeGroupError(focus, state);
      setState(() {
        state.running = false;
        state.markDirty();
        state.error = finalProgress.lastError ?? typeGroupError;
        state.phase = finalProgress.failed > 0
            ? '일부 실패'
            : (typeGroupError == null ? '완료' : '유형명 누락');
      });
      _scheduleAutoSave(focus, delay: Duration.zero);
    } catch (e) {
      if (!mounted) return;
      restorePrevious('실패 · 이전 결과 유지', error: '$e');
    }
  }

  void _cancelFocused(_SubFocus focus) {
    final state = _ensureSubState(focus);
    state.cancelled = true;
    setState(() {
      state.phase = '취소 요청...';
    });
  }

  Future<void> _retryFailedForFocus(_SubFocus focus) async {
    final state = _ensureSubState(focus);
    final failed = state.progress?.failedPages ?? const <int>{};
    if (failed.isEmpty || _cropLocked(focus)) return;
    final doc = await _ensurePdf();
    if (doc == null) return;
    final expectedStartNumber = await _expectedStartNumberForFocus(focus);
    final rawStartPage = _rawStartPageForFocus(focus);
    _bakeManualEdits(focus, state);
    setState(() {
      state.running = true;
      state.cancelled = false;
      state.phase = '실패 페이지 재분석...';
    });

    Future<Uint8List> render({
      required int rawPage,
      required int longEdgePx,
    }) {
      return renderPdfPageToPng(
        document: doc,
        pageNumber: rawPage,
        longEdgePx: longEdgePx,
      );
    }

    Future<TextbookVlmDetectResult> detect({
      required Uint8List imageBytes,
      required int rawPage,
    }) async {
      if (rawStartPage != null &&
          _isRpmAConceptPage(focus, rawPage, rawStartPage)) {
        return _rpmAConceptPageResult(rawPage);
      }
      final result = await _vlmService.detectProblemsOnPage(
        imageBytes: imageBytes,
        rawPage: rawPage,
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        sectionHint: _seriesKey == 'suryeok'
            ? _sectionForFocus(focus)
            : _currentSeries().hasSubUnitRows
                ? null
                : _sectionForSubKey(focus.subKey),
        expectedStartNumber: _expectedStartNumberForPage(
          focus,
          state,
          rawPage,
          expectedStartNumber,
        ),
        series: _seriesKey,
      );
      if (_seriesKey == 'rpm' && focus.subKey == 'A' && result.items.isEmpty) {
        throw StateError(
          'rpm_a_expected_problem_page_empty: raw_page=$rawPage',
        );
      }
      return result;
    }

    try {
      final finalProgress = await retryFailedPages(
        pages: failed.toList()..sort(),
        analysisLongEdgePx: _kAnalysisLongEdgePx,
        renderer: render,
        detector: detect,
        isCancelled: () => state.cancelled,
        onPageSuccess: (outcome) async {
          // 실패한 지면에 사람이 먼저 그려 둔 문항은 새 결과에 다시 얹는다.
          final keptManual = [
            for (final r in state.pageResults
                .where((r) => r.rawPage == outcome.rawPage && r.ok))
              for (final it in r.items)
                if (state.manualItems.contains(it)) (r, it),
          ];
          state.pageResults.removeWhere((r) => r.rawPage == outcome.rawPage);
          state.pageResults.add(_PageAnalysisRow.success(
            rawPage: outcome.rawPage,
            displayPage: outcome.result.displayPage,
            section: outcome.result.section,
            pageKind: outcome.result.pageKind,
            conceptDrillHeaderVisible: outcome.result.conceptDrillHeaderVisible,
            notes: outcome.result.notes,
            items: outcome.result.items,
          ));
          _restoreManualItems(state, keptManual);
          if (_seriesKey != 'wonri') _applyScopeGuards(focus);
          if (!mounted) return;
          setState(() {});
        },
        onPageFailure: (f) {
          debugPrint('[textbook-stage1-retry] page failed '
              'raw=${f.rawPage} attempts=${f.attempts} error=${f.error}');
          state.pageResults.removeWhere((r) => r.rawPage == f.rawPage && !r.ok);
          state.pageResults.add(_PageAnalysisRow.failure(
            rawPage: f.rawPage,
            error: '${f.error}',
          ));
          if (!mounted) return;
          setState(() {});
        },
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            state.progress = progress;
          });
        },
      );
      if (!mounted) return;
      if (_currentSeries().hasSubUnitRows) _applyScopeGuards(focus);
      final typeGroupError = _requiredTypeGroupError(focus, state);
      setState(() {
        state.running = false;
        state.markDirty();
        state.error = finalProgress.lastError ?? typeGroupError;
        state.phase = finalProgress.failed > 0
            ? '재분석 일부 실패'
            : (typeGroupError == null ? '재분석 완료' : '유형명 누락');
      });
      if (!state.cancelled) _scheduleAutoSave(focus, delay: Duration.zero);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.running = false;
        state.error = '$e';
        state.phase = '재분석 실패';
      });
    }
  }

  void _applyScopeGuards(_SubFocus focus) {
    final state = _ensureSubState(focus);
    if (state.pageResults.isEmpty) return;
    // 가드는 AI 판독을 바로잡는 규칙이다. 사람이 그리거나 고친 문항은 빼 두었다가
    // 그대로 되돌린다.
    _bakeManualEdits(focus, state);
    final manual = [
      for (final row in state.pageResults.where((r) => r.ok))
        for (final item in row.items)
          if (state.manualItems.contains(item)) (row, item),
    ];
    for (var r = 0; r < state.pageResults.length && manual.isNotEmpty; r += 1) {
      final row = state.pageResults[r];
      if (!row.ok || !row.items.any(state.manualItems.contains)) continue;
      state.pageResults[r] = row.withItems([
        for (final it in row.items)
          if (!state.manualItems.contains(it)) it,
      ]);
    }
    try {
      _applyAiScopeGuards(focus, state);
    } finally {
      _restoreManualItems(state, manual);
    }
  }

  void _applyAiScopeGuards(_SubFocus focus, _SubRunState state) {
    late final List<_PageAnalysisRow> guarded;
    if (_seriesKey == 'wonri') {
      // 개념원리 일반 소단원은 정확한 "개념원리 익히기" 헤더가 처음
      // 확인되기 전까지 전부 개념 페이지다. 연습문제 행은 STEP 구조라 제외.
      final row = _wonriRowFor(focus);
      if (row == null || row.isExercise) return;
      guarded = _guardWonriRowsBeforeConceptDrillHeader(state.pageResults);
    } else if (_seriesKey == 'wonri_middle') {
      // 중단원 마무리 행은 D(STEP 1~3) 뒤에 E(서술형)가 오는 고정 구조다.
      // STEP 머리말이 반복되지 않는 연속 지면을 단독 판독하면 C로 돌아가는
      // 경우가 있으므로 행 경계와 앞 지면의 STEP을 함께 사용해 되돌린다.
      final row = _wonriRowFor(focus);
      if (row == null) return;
      guarded = row.isExercise
          ? _guardWonriMiddleUnitEndRows(state.pageResults)
          : _guardWonriMiddleSubUnitCorners(state.pageResults);
    } else if (_seriesKey == 'gaeyu') {
      // 순서가 중요하다. 개념 번호 오인식을 먼저 걷어내야 번호 역행 가드가
      // 가짜 번호를 기준선으로 삼아 다음 지면의 진짜 문항을 지우지 않는다.
      guarded = _guardGaeyuStepNumberRewind(
        _guardGaeyuEssentialNumberOrder(
          _guardGaeyuStepOnEssentialPage(
            _guardGaeyuStepOrder(
              _guardGaeyuExtraPracticeContinuation(state.pageResults),
            ),
          ),
        ),
      );
    } else if (_seriesKey == 'suryeok') {
      guarded = _guardSuryeokNumberRewind(state.pageResults);
    } else if (_seriesKey == 'gaeyu_high') {
      // 코너마다 머리말이 분명하고 번호 모양("01", "01-1", "1")이 달라서
      // 지면을 넘나드는 보정이 필요 없다. 실력 구간 승계는 저장 때 한다.
      return;
    } else if (isGojaengiSeries(_seriesKey)) {
      // 고쟁이는 세 자리 연속 번호라 쎈 A의 4자리 basic_drill 가드를 타면
      // 본문 문항이 통째로 개념 지면으로 비워진다.
      return;
    } else {
      // basic_drill(4자리 번호) 가드는 쎈/RPM A 파트 전용.
      if (focus.subKey != 'A') return;
      guarded = _guardBasicDrillRows(
        state.pageResults,
        startRawPage: _rawStartPageForFocus(focus),
      );
    }
    if (_samePageRows(state.pageResults, guarded)) return;
    state.pageResults
      ..clear()
      ..addAll(guarded);
  }

  /// 핸들로 고친 영역을 문항에 굳히고 사람 손 문항으로 표시한다. 그 뒤로는 지면 안
  /// 문항 순서가 바뀌어도 수정이 그 문항을 따라간다.
  void _bakeManualEdits(_SubFocus focus, _SubRunState state) {
    final edits = _manualEdits.remove(_stateKeyFor(focus));
    if (edits == null || edits.isEmpty) return;
    for (var r = 0; r < state.pageResults.length; r += 1) {
      final row = state.pageResults[r];
      if (!row.ok) continue;
      var changed = false;
      final items = <TextbookVlmItem>[];
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        final edited = edits[_problemKey(row.rawPage, i)];
        if (edited == null || edited.length != 4) {
          items.add(item);
          continue;
        }
        final baked = _itemWithRegion(item, edited);
        state.manualItems
          ..remove(item)
          ..add(baked);
        items.add(baked);
        changed = true;
      }
      if (changed) state.pageResults[r] = row.withItems(items);
    }
  }

  TextbookVlmItem _itemWithRegion(TextbookVlmItem it, List<int> region) =>
      TextbookVlmItem(
        number: it.number,
        label: it.label,
        category: it.category,
        itemRole: it.itemRole,
        companionRegions: it.companionRegions,
        isImportant: it.isImportant,
        isSetHeader: it.isSetHeader,
        setFrom: it.setFrom,
        setTo: it.setTo,
        contentGroupKind: it.contentGroupKind,
        contentGroupLabel: it.contentGroupLabel,
        contentGroupTitle: it.contentGroupTitle,
        contentGroupOrder: it.contentGroupOrder,
        column: it.column,
        bbox: it.bbox,
        itemRegion: region,
      );

  bool _sameProblem(TextbookVlmItem a, TextbookVlmItem b) =>
      a.number.trim() == b.number.trim() &&
      a.category == b.category &&
      a.isSetHeader == b.isSetHeader;

  /// 지면 읽는 순서(단 → 위에서 아래)로 끼워 넣을 자리.
  int _readingOrderIndex(List<TextbookVlmItem> items, TextbookVlmItem item) {
    (int, int) keyOf(TextbookVlmItem it) {
      final box = it.itemRegion ?? it.bbox;
      return (it.column ?? 0, box == null || box.length != 4 ? 0 : box[0]);
    }

    final k = keyOf(item);
    for (var i = 0; i < items.length; i += 1) {
      final o = keyOf(items[i]);
      if (o.$1 > k.$1 || (o.$1 == k.$1 && o.$2 > k.$2)) return i;
    }
    return items.length;
  }

  /// 사람 손 문항을 지면 결과에 되돌린다. 같은 번호의 AI 문항은 뺀다.
  void _restoreManualItems(
    _SubRunState state,
    List<(_PageAnalysisRow, TextbookVlmItem)> kept,
  ) {
    if (kept.isEmpty) return;
    for (final (source, item) in kept) {
      final idx = state.pageResults
          .indexWhere((r) => r.rawPage == source.rawPage && r.ok);
      final current = idx < 0 ? null : state.pageResults[idx];
      final items = <TextbookVlmItem>[
        for (final it in current?.items ?? const <TextbookVlmItem>[])
          if (!identical(it, item) && !_sameProblem(it, item)) it,
      ];
      items.insert(_readingOrderIndex(items, item), item);
      final next = current?.withItems(items) ??
          _PageAnalysisRow.success(
            rawPage: source.rawPage,
            displayPage: source.displayPage,
            section: source.section,
            pageKind: 'problem_page',
            notes: 'manual_crops',
            items: items,
          );
      if (idx < 0) {
        state.pageResults
          ..removeWhere((r) => r.rawPage == source.rawPage)
          ..add(next);
      } else {
        state.pageResults[idx] = next;
      }
      state.manualItems.add(item);
    }
    state.pageResults.sort((a, b) => a.rawPage.compareTo(b.rawPage));
  }

  List<_PageAnalysisRow> _guardWonriMiddleUnitEndRows(
    List<_PageAnalysisRow> rows,
  ) {
    final guard = TextbookWonriMiddleUnitEndGuard();
    final guardedByPage = <int, _PageAnalysisRow>{};
    final successful = rows.where((row) => row.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));

    for (final row in successful) {
      var changed = 0;
      final items = <TextbookVlmItem>[];
      for (final item in row.items) {
        final normalized = guard.normalize(
          item,
          pageSection: row.section,
        );
        if (!identical(normalized, item)) changed += 1;
        items.add(normalized);
      }
      final section = guard.sectionForPage(row.section, items);
      if (section != row.section) changed += 1;
      guardedByPage[row.rawPage] = changed == 0
          ? row
          : _PageAnalysisRow.success(
              rawPage: row.rawPage,
              displayPage: row.displayPage,
              section: section,
              pageKind: row.pageKind,
              conceptDrillHeaderVisible: row.conceptDrillHeaderVisible,
              notes: _appendGuardNote(
                row.notes,
                'wonri_middle_unit_end_continuation_fixed=$changed',
              ),
              items: items,
            );
    }

    return <_PageAnalysisRow>[
      for (final row in rows) guardedByPage[row.rawPage] ?? row,
    ];
  }

  List<_PageAnalysisRow> _guardWonriMiddleSubUnitCorners(
    List<_PageAnalysisRow> rows,
  ) {
    final successful = rows.where((row) => row.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    final repaired = repairWonriMiddleSubUnitCorners(
      [for (final row in successful) row.items],
      pageSections: [for (final row in successful) row.section],
    );
    final guardedByPage = <int, _PageAnalysisRow>{};
    for (var i = 0; i < successful.length; i += 1) {
      final row = successful[i];
      final items = repaired[i];
      if (identical(items, row.items)) continue;
      final counts = <String, int>{};
      for (final item in items) {
        counts[item.category] = (counts[item.category] ?? 0) + 1;
      }
      final kept = items.where(row.items.contains).length;
      final moved = items.length - kept;
      final dropped = row.items.length - items.length;
      guardedByPage[row.rawPage] = _PageAnalysisRow.success(
        rawPage: row.rawPage,
        displayPage: row.displayPage,
        section: counts.isEmpty
            ? 'unknown'
            : counts.entries.reduce((a, b) => b.value > a.value ? b : a).key,
        pageKind: items.isEmpty ? 'concept_page' : row.pageKind,
        conceptDrillHeaderVisible: row.conceptDrillHeaderVisible,
        notes: _appendGuardNote(
          row.notes,
          'wonri_middle_sub_unit_corner_fixed=$moved'
          ' dropped=$dropped',
        ),
        items: items,
      );
    }
    return <_PageAnalysisRow>[
      for (final row in rows) guardedByPage[row.rawPage] ?? row,
    ];
  }

  /// 수력충전 소단원의 번호 역행 문항을 걷어낸다.
  ///
  /// 한 소단원 행 안에서 문항 번호는 01부터 끝까지 1씩 커진다(지면이 바뀌어도
  /// 이어진다). 뒷 지면에서 앞 지면 최대 번호보다 작거나 같은 번호가 나오면
  /// 그것은 문항이 아니라 개념 정리 박스의 항목 번호를 잘못 읽은 것이다.
  ///
  /// 같은 지면 안에서는 비교하지 않는다. 2단 조판이라 모델이 좌·우 단을 섞어
  /// 내보내는 일이 있는데, 그때 멀쩡한 문항이 역행으로 보여 지워지기 때문이다.
  ///
  /// 그 지면의 세트 지문("[07-09] …")이 감싸는 번호도 건드리지 않는다. 지문이
  /// 그 자리에 인쇄돼 있다는 것은 그 번호가 이 지면의 진짜 문항이라는 뜻이라,
  /// 앞 지면 최댓값보다 작아도 역행이 아니다. 공통수학1 p31 개념 박스의 공식
  /// 번호 7~12 가 문항으로 잘못 들어와 최댓값을 12 로 밀어 올리자, p32 의 진짜
  /// 문항 07~12 가 통째로 지워지고 세트 지문 두 줄만 남았다.
  List<_PageAnalysisRow> _guardSuryeokNumberRewind(
    List<_PageAnalysisRow> rows,
  ) {
    int? printedNumber(TextbookVlmItem item) {
      // 하위문항 표기("1)", "(2)")가 섞여 들어오면 그 숫자가 번호열의 최댓값을
      // 밀어 올려, 다음 지면의 진짜 문항이 역행으로 오해받아 통째로 지워진다.
      // 인쇄된 문항번호 형태만 기준선으로 센다.
      final raw = item.number.trim();
      if (!RegExp(r'^\d{1,3}$').hasMatch(raw)) return null;
      return int.tryParse(raw);
    }

    bool coveredBySetHeader(_PageAnalysisRow row, int number) {
      for (final item in row.items) {
        if (!item.isSetHeader) continue;
        final from = item.setFrom;
        final to = item.setTo;
        if (from == null || to == null) continue;
        if (number >= from && number <= to) return true;
      }
      return false;
    }

    final order = rows.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    final droppedByPage = <int, Set<int>>{};
    var maxBeforePage = 0;
    for (final row in order) {
      var maxOnPage = maxBeforePage;
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        // 세트 헤더("01~05")는 아래 개별 문항과 같은 번호를 공유한다.
        if (item.isSetHeader) continue;
        final number = printedNumber(item);
        if (number == null) continue;
        if (number <= maxBeforePage && !coveredBySetHeader(row, number)) {
          (droppedByPage[row.rawPage] ??= <int>{}).add(i);
          continue;
        }
        if (number > maxOnPage) maxOnPage = number;
      }
      maxBeforePage = maxOnPage;
    }
    if (droppedByPage.isEmpty) return rows;
    final out = <_PageAnalysisRow>[];
    for (final row in rows) {
      final dropped = row.ok ? droppedByPage[row.rawPage] : null;
      if (dropped == null || dropped.isEmpty) {
        out.add(row);
        continue;
      }
      final kept = <TextbookVlmItem>[
        for (var i = 0; i < row.items.length; i += 1)
          if (!dropped.contains(i)) row.items[i],
      ];
      out.add(_rowWithGuardedItems(
        row,
        kept,
        row.items.length,
        reason: 'suryeok_number_rewind_filtered',
      ));
    }
    return out;
  }

  /// 개념원리 소단원의 개념 구간(앞쪽 연속 "개념원리 이해" 페이지) 문항을
  /// 강제로 비운다. 게이트웨이 전용 2차 판독이 개념 페이지를 concept_page 로
  /// 확정하므로, 첫 문제 페이지("개념원리 익히기" 헤더 또는 문항이 검증된
  /// 필수유형/기타 페이지) 이전 페이지의 잔여 오인식만 여기서 정리한다.
  List<_PageAnalysisRow> _guardWonriRowsBeforeConceptDrillHeader(
    List<_PageAnalysisRow> rows,
  ) {
    final successful = rows.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    int? firstProblemPage;
    for (final row in successful) {
      final isVerifiedProblemPage = row.conceptDrillHeaderVisible ||
          (row.pageKind != 'concept_page' && row.items.isNotEmpty);
      if (isVerifiedProblemPage) {
        firstProblemPage = row.rawPage;
        break;
      }
    }
    final out = <_PageAnalysisRow>[];
    for (final row in rows) {
      final beforeHeader = row.ok &&
          (firstProblemPage == null || row.rawPage < firstProblemPage);
      if (!beforeHeader) {
        out.add(row);
        continue;
      }
      if (row.items.isEmpty && row.pageKind == 'concept_page') {
        out.add(row);
        continue;
      }
      out.add(_rowWithGuardedItems(
        row,
        const <TextbookVlmItem>[],
        row.items.length,
        reason: 'wonri_before_concept_drill_header_filtered',
      ));
    }
    return out;
  }

  /// 개념+유형 "한 번 더 연습"(F) 오인식 되돌리기.
  ///
  /// 한 번 더 연습은 상단에 초록색 코너 배지를 달고 자기 지면을 차지하며,
  /// 번호가 **1번부터** 다시 시작한다. 반면 쏙쏙 개념 익히기 문항 옆에 붙는
  /// 초록색 "한번더 +1" 배지는 같은 번호를 잇는 쌍둥이 문항 표시일 뿐이다.
  /// 코너 배지가 없는 쏙쏙 이어지는 지면(예: 6~10번)에 이 배지가 하나라도
  /// 있으면 모델이 지면 전체를 F 로 넘겨 버리는데, 그러면 정답 파일의
  /// "쏙쏙 개념 익히기" 박스와 매칭이 어긋나고 같은 문항이 C/F 양쪽에 남는다.
  ///
  /// 그래서 번호가 1이 아니라 직전 쏙쏙 번호에서 그대로 이어지면 쏙쏙으로
  /// 되돌린다. 진짜 한 번 더 연습 지면은 1번부터라 여기 걸리지 않는다.
  List<_PageAnalysisRow> _guardGaeyuExtraPracticeContinuation(
    List<_PageAnalysisRow> rows,
  ) {
    int? printedNumber(TextbookVlmItem item) {
      final digits = RegExp(r'\d+').firstMatch(item.number);
      return digits == null ? null : int.tryParse(digits[0]!);
    }

    final order = rows.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    final reclassified = <int>{};
    int? lastStepNumber;
    for (final row in order) {
      final categories = [
        for (final item in row.items) _wonriCategoryOfItem(item, row.section),
      ];
      final extraNumbers = <int>[];
      final stepNumbers = <int>[];
      for (var i = 0; i < row.items.length; i += 1) {
        final number = printedNumber(row.items[i]);
        if (number == null) continue;
        if (categories[i] == 'extra_practice') extraNumbers.add(number);
        if (categories[i] == 'step_drill') stepNumbers.add(number);
      }
      final continues = extraNumbers.isNotEmpty &&
          lastStepNumber != null &&
          extraNumbers.reduce((a, b) => a < b ? a : b) == lastStepNumber + 1;
      if (continues) {
        reclassified.add(row.rawPage);
        stepNumbers.addAll(extraNumbers);
      }
      for (final number in stepNumbers) {
        if (lastStepNumber == null || number > lastStepNumber) {
          lastStepNumber = number;
        }
      }
    }
    if (reclassified.isEmpty) return rows;

    final out = <_PageAnalysisRow>[];
    for (final row in rows) {
      if (!reclassified.contains(row.rawPage)) {
        out.add(row);
        continue;
      }
      var moved = 0;
      final items = <TextbookVlmItem>[];
      for (final item in row.items) {
        if (_wonriCategoryOfItem(item, row.section) == 'extra_practice') {
          moved += 1;
          items.add(item.withCategory('step_drill'));
        } else {
          items.add(item);
        }
      }
      out.add(_PageAnalysisRow.success(
        rawPage: row.rawPage,
        displayPage: row.displayPage,
        section: row.section == 'extra_practice' ? 'step_drill' : row.section,
        pageKind: row.pageKind,
        conceptDrillHeaderVisible: row.conceptDrillHeaderVisible,
        notes: _appendGuardNote(row.notes, 'gaeyu_extra_practice_kept=$moved'),
        items: items,
      ));
    }
    return out;
  }

  /// 개념+유형 STEP 코너는 한 중단원 안에서 STEP1 → STEP2 → STEP3 순서로만
  /// 진행한다. 중단원이 끝나기 전에 STEP2 뒤로 STEP1 이 다시 오는 일은 없다.
  ///
  /// 탄탄 단원 다지기는 세 쪽까지 이어지는데, 마지막 쪽은 코너 배지가 다시
  /// 인쇄되지 않아 모델이 쏙쏙 개념 익히기로 되돌리곤 한다. 그러면 그 쪽 문항만
  /// sub_key 가 C 로 갈려서 번호에 본문 페이지 접두어가 붙고, 정답·해설의
  /// "탄탄" 박스와 매칭이 어긋난다.
  ///
  /// 앞 지면에서 이미 확인된 STEP 단계보다 낮은 STEP 은 그 단계로 되돌린다.
  /// 다음 중단원은 분석 범위가 달라 서로 영향을 주지 않는다.
  List<_PageAnalysisRow> _guardGaeyuStepOrder(List<_PageAnalysisRow> rows) {
    const stepRanks = <String, int>{
      'step_drill': 1,
      'unit_drill': 2,
      'descriptive': 3,
    };
    final categoryByRank = <int, String>{
      for (final entry in stepRanks.entries) entry.value: entry.key,
    };

    final order = rows.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    // 지면마다 "앞 지면까지 확인된 최고 STEP 단계"를 기록한다. 같은 지면 안의
    // 순서로는 판단하지 않는다 (한 쪽에 두 코너가 걸치면 모델이 주는 순서가
    // 지면 순서와 다를 수 있다).
    final floorByPage = <int, int>{};
    var reached = 0;
    for (final row in order) {
      floorByPage[row.rawPage] = reached;
      var pageMax = stepRanks[row.section] ?? 0;
      for (final item in row.items) {
        final rank = stepRanks[_wonriCategoryOfItem(item, row.section)] ?? 0;
        if (rank > pageMax) pageMax = rank;
      }
      if (pageMax > reached) reached = pageMax;
    }

    final out = <_PageAnalysisRow>[];
    for (final row in rows) {
      final floor = row.ok ? (floorByPage[row.rawPage] ?? 0) : 0;
      if (floor <= 0) {
        out.add(row);
        continue;
      }
      final promotedTo = categoryByRank[floor]!;
      var promoted = 0;
      final items = <TextbookVlmItem>[];
      for (final item in row.items) {
        final category = _wonriCategoryOfItem(item, row.section);
        final rank = stepRanks[category] ?? 0;
        if (rank > 0 && rank < floor) {
          promoted += 1;
          items.add(item.withCategory(promotedTo));
        } else {
          items.add(item);
        }
      }
      final sectionRank = stepRanks[row.section] ?? 0;
      final section =
          sectionRank > 0 && sectionRank < floor ? promotedTo : row.section;
      if (promoted == 0 && section == row.section) {
        out.add(row);
        continue;
      }
      out.add(_PageAnalysisRow.success(
        rawPage: row.rawPage,
        displayPage: row.displayPage,
        section: section,
        pageKind: row.pageKind,
        conceptDrillHeaderVisible: row.conceptDrillHeaderVisible,
        notes: _appendGuardNote(
          row.notes,
          'gaeyu_step_order_promoted=$promoted->$promotedTo',
        ),
        items: items,
      ));
    }
    return out;
  }

  /// 개념+유형 쏙쏙 개념 익히기(STEP1)는 자기 전용 지면에 1번부터 연속으로
  /// 인쇄된다. 필수 문제·따름 문제가 있는 본문 지면에는 절대 섞이지 않는다.
  ///
  /// 그런데 개념 카드 제목 앞의 굵은 개념 번호를 모델이 앞 지면 쏙쏙의 이어지는
  /// 번호로 오해해 필수 문제 지면에 쏙쏙 한 개를 얹는 일이 있다(122쪽 "4").
  /// 필수 문제가 있는 지면에서 소수인 쏙쏙은 그런 오인식이라 걷어낸다.
  List<_PageAnalysisRow> _guardGaeyuStepOnEssentialPage(
    List<_PageAnalysisRow> rows,
  ) {
    final droppedByPage = <int, Set<int>>{};
    for (final row in rows.where((r) => r.ok)) {
      final stepIndexes = <int>[];
      var essentialCount = 0;
      for (var i = 0; i < row.items.length; i += 1) {
        switch (_wonriCategoryOfItem(row.items[i], row.section)) {
          case 'essential_problem':
            essentialCount += 1;
          case 'step_drill':
            stepIndexes.add(i);
        }
      }
      if (essentialCount == 0 || stepIndexes.isEmpty) continue;
      // 쏙쏙이 다수인 지면은 반대로 필수 문제 쪽이 오인식일 수 있으니 건드리지
      // 않는다. 번호 순서 가드가 따로 판단한다.
      if (stepIndexes.length > essentialCount) continue;
      (droppedByPage[row.rawPage] ??= <int>{}).addAll(stepIndexes);
    }
    if (droppedByPage.isEmpty) return rows;

    final out = <_PageAnalysisRow>[];
    for (final row in rows) {
      final dropped = droppedByPage[row.rawPage];
      if (dropped == null || dropped.isEmpty) {
        out.add(row);
        continue;
      }
      final kept = <TextbookVlmItem>[
        for (var i = 0; i < row.items.length; i += 1)
          if (!dropped.contains(i)) row.items[i],
      ];
      out.add(_rowWithGuardedItems(
        row,
        kept,
        dropped.length,
        reason: 'gaeyu_step_on_essential_page_filtered',
      ));
    }
    return out;
  }

  /// "2-1" 처럼 대표 번호에 가지를 붙인 따름 문제 번호인지.
  ///
  /// 따름 문제는 대표 번호를 그대로 물려받으므로 번호 비교로 진짜/가짜를 가릴 수
  /// 없다. 개념 번호에는 이 형태가 아예 없으니(사용자 확인) 번호 가드들은 이
  /// 번호를 판정에서 빼야 한다. 대표 문제가 앞 지면에 있고 따름 문제가 다음 지면
  /// 맨 위로 넘어가면(135쪽 필수 2 → 136쪽 2-1) 앞 지면 최대 번호와 같아져서
  /// 역행으로 오해받아 통째로 지워졌다.
  static final RegExp _gaeyuFollowUpNumber = RegExp(r'^\s*\d+\s*-\s*\d+\s*$');

  bool _isGaeyuFollowUpNumber(String number) =>
      _gaeyuFollowUpNumber.hasMatch(number);

  /// 개념+유형 필수 문제 번호는 한 지면에서 **위에서 아래로 커진다.**
  ///
  /// 개념 카드 제목 앞의 굵은 개념 번호는 그 지면 필수 문제보다 앞서 나오는데,
  /// 개념 번호는 중단원 전체를 통틀어 매기므로 그 지면 필수 번호보다 크다.
  /// 122쪽에서 개념 번호 "4" 가 필수 문제 3·3-1 위에 있는데 필수 문제 4번으로
  /// 잡혔고, 그 바람에 다음 지면의 진짜 필수 문제 4번이 번호 역행으로 지워졌다.
  ///
  /// 그래서 자기보다 **아래에 있는** 필수 문제 번호보다 큰 번호는 문항 번호가
  /// 아니라고 본다. 따름 문제("3-1")는 대표 번호를 물려받을 뿐이라 판정에서 뺀다.
  List<_PageAnalysisRow> _guardGaeyuEssentialNumberOrder(
    List<_PageAnalysisRow> rows,
  ) {
    int? printedNumber(TextbookVlmItem item) {
      final digits = RegExp(r'^\s*(\d+)').firstMatch(item.number);
      return digits == null ? null : int.tryParse(digits[1]!);
    }

    final droppedByPage = <int, Set<int>>{};
    for (final row in rows.where((r) => r.ok)) {
      // 지면에 인쇄된 순서(단 → 위에서 아래)로 세운다. 필수 문제 지면은 1단이
      // 기본이라 column 은 보조 기준으로만 쓴다.
      final ordered = <int>[];
      final numbers = <int, int>{};
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        if (_wonriCategoryOfItem(item, row.section) != 'essential_problem') {
          continue;
        }
        if (_isGaeyuFollowUpNumber(item.number)) continue;
        final number = printedNumber(item);
        final bbox = item.bbox;
        if (number == null || bbox == null || bbox.length != 4) continue;
        numbers[i] = number;
        ordered.add(i);
      }
      if (ordered.length < 2) continue;
      ordered.sort((a, b) {
        final columnA = row.items[a].column ?? 1;
        final columnB = row.items[b].column ?? 1;
        if (columnA != columnB) return columnA.compareTo(columnB);
        return row.items[a].bbox![0].compareTo(row.items[b].bbox![0]);
      });
      // 아래에서 위로 올라가며 "아래쪽 최소 번호" 를 들고 간다.
      var minBelow = numbers[ordered.last]!;
      for (var k = ordered.length - 2; k >= 0; k -= 1) {
        final index = ordered[k];
        final number = numbers[index]!;
        if (number > minBelow) {
          (droppedByPage[row.rawPage] ??= <int>{}).add(index);
          continue;
        }
        if (number < minBelow) minBelow = number;
      }
    }
    if (droppedByPage.isEmpty) return rows;

    final out = <_PageAnalysisRow>[];
    for (final row in rows) {
      final dropped = droppedByPage[row.rawPage];
      if (dropped == null || dropped.isEmpty) {
        out.add(row);
        continue;
      }
      final kept = <TextbookVlmItem>[
        for (var i = 0; i < row.items.length; i += 1)
          if (!dropped.contains(i)) row.items[i],
      ];
      out.add(_rowWithGuardedItems(
        row,
        kept,
        dropped.length,
        reason: 'gaeyu_essential_number_order_filtered',
      ));
    }
    return out;
  }

  /// 개념+유형 쏙쏙·탄탄의 번호가 **뒤로 돌아간** 문항을 걷어낸다.
  ///
  /// 이어지는 지면에는 코너 배지가 다시 인쇄되지 않아 모델이 앞 코너를
  /// 이어받는다. 이때 지면 상단의 크림색 개념 정리 카드(굵은 개념 번호 +
  /// 명사구 제목)를 그 코너의 문항으로 올리는 오인식이 난다. 실제로 83쪽
  /// 쏙쏙이 1~5번으로 끝난 뒤 84쪽 개념 카드의 "2" 가 쏙쏙 2번으로 붙었다.
  ///
  /// 코너가 이어지는 동안 번호는 반드시 커진다. 그래서 직전 지면까지의 최대
  /// 번호 이하로 내려가는 번호는 문항 번호가 아니다.
  ///
  /// 단, 한 소단원 범위(예: 101~110쪽) 안에 쏙쏙 블록이 여러 번 나오고 블록마다
  /// 번호가 1번부터 다시 시작한다. 그래서 1번이 보이는 지면은 **새 블록**으로
  /// 보고 기준선을 0 으로 되돌린다. 이 처리가 없으면 새 블록의 2~5번이 앞
  /// 블록의 최대 번호 이하라는 이유로 통째로 지워진다.
  List<_PageAnalysisRow> _guardGaeyuStepNumberRewind(
    List<_PageAnalysisRow> rows,
  ) {
    // 필수 문제도 한 소단원 안에서 1번부터 끝번호까지 이어진다. 105쪽 개념 카드의
    // "4" 가 필수 문제 7·8 사이에 끼어든 사고가 있어 같이 추적한다.
    const tracked = <String>{'step_drill', 'unit_drill', 'essential_problem'};

    int? printedNumber(TextbookVlmItem item) {
      final digits = RegExp(r'^\s*(\d+)').firstMatch(item.number);
      return digits == null ? null : int.tryParse(digits[1]!);
    }

    final order = rows.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    final droppedByPage = <int, Set<int>>{};
    final maxByCategory = <String, int>{};
    for (final row in order) {
      // 지면 단위로 판단한다. 한 지면 안에서 모델이 주는 순서는 지면 순서와
      // 다를 수 있으므로 항목끼리 비교하지 않고, 지면 전체의 기준선 하나와만
      // 비교한다.
      final numbersByCategory = <String, Map<int, int>>{};
      for (var i = 0; i < row.items.length; i += 1) {
        final category = _wonriCategoryOfItem(row.items[i], row.section);
        if (!tracked.contains(category)) continue;
        // 따름 문제는 대표 번호를 물려받으므로 기준선과 같거나 작을 수밖에 없다.
        // 대표 문제가 앞 지면에 있으면 전부 역행으로 잡혀 지워진다.
        if (_isGaeyuFollowUpNumber(row.items[i].number)) continue;
        final number = printedNumber(row.items[i]);
        if (number == null) continue;
        (numbersByCategory[category] ??= <int, int>{})[i] = number;
      }
      for (final entry in numbersByCategory.entries) {
        // 1번이 있으면 코너 배지가 다시 인쇄된 새 블록이다. 앞 블록의 최대
        // 번호를 기준으로 삼으면 새 블록의 2~5번이 통째로 지워진다.
        final restarted = entry.value.values.contains(1);
        final baseline = restarted ? 0 : (maxByCategory[entry.key] ?? 0);
        var pageMax = 0;
        for (final one in entry.value.entries) {
          if (one.value > baseline) {
            if (one.value > pageMax) pageMax = one.value;
          } else {
            (droppedByPage[row.rawPage] ??= <int>{}).add(one.key);
          }
        }
        if (pageMax <= 0) continue;
        final seen = maxByCategory[entry.key];
        maxByCategory[entry.key] =
            restarted || seen == null || pageMax > seen ? pageMax : seen;
      }
    }
    if (droppedByPage.isEmpty) return rows;

    final out = <_PageAnalysisRow>[];
    for (final row in rows) {
      final dropped = droppedByPage[row.rawPage];
      if (dropped == null || dropped.isEmpty) {
        out.add(row);
        continue;
      }
      final kept = <TextbookVlmItem>[
        for (var i = 0; i < row.items.length; i += 1)
          if (!dropped.contains(i)) row.items[i],
      ];
      out.add(_rowWithGuardedItems(
        row,
        kept,
        dropped.length,
        reason: 'gaeyu_step_number_rewind_filtered',
      ));
    }
    return out;
  }

  int? _rawStartPageForFocus(_SubFocus focus) {
    if (focus.bigIndex < 0 || focus.bigIndex >= _bigUnits.length) return null;
    final big = _bigUnits[focus.bigIndex];
    if (focus.midIndex < 0 || focus.midIndex >= big.middles.length) {
      return null;
    }
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final displayStart = _positiveInt(sub.startCtrl.text);
    return displayStart == null ? null : _rawPageForDisplayPage(displayStart);
  }

  List<_PageAnalysisRow> _guardBasicDrillRows(
    List<_PageAnalysisRow> rows, {
    int? startRawPage,
  }) {
    final firstPass = <_PageAnalysisRow>[];

    for (final row in rows) {
      if (!row.ok || row.section != 'basic_drill' || row.items.isEmpty) {
        firstPass.add(row);
        continue;
      }
      final kept = <TextbookVlmItem>[];
      var dropped = 0;
      final allowFlexibleGeometry =
          _seriesKey == 'rpm' || _hasStrongBasicDrillPageEvidence(row.items);
      for (final item in row.items) {
        if (_isValidBasicDrillCandidate(
          item,
          allowFlexibleGeometry: allowFlexibleGeometry,
        )) {
          kept.add(item);
        } else {
          dropped += 1;
        }
      }
      firstPass.add(_rowWithGuardedItems(
        row,
        kept,
        dropped,
        reason: 'basic_drill_candidate_filtered',
      ));
    }

    return _guardBasicDrillStartPage(firstPass, startRawPage);
  }

  List<_PageAnalysisRow> _guardBasicDrillStartPage(
    List<_PageAnalysisRow> rows,
    int? startRawPage,
  ) {
    if (startRawPage == null) return rows;
    final firstIndex = rows.indexWhere((r) =>
        r.ok &&
        r.rawPage == startRawPage &&
        r.section == 'basic_drill' &&
        r.items.isNotEmpty);
    if (firstIndex < 0) return rows;

    final first = rows[firstIndex];
    final laterRows = rows
        .where((r) =>
            r.ok &&
            r.rawPage > startRawPage &&
            r.section == 'basic_drill' &&
            r.items.isNotEmpty)
        .toList();
    if (laterRows.isEmpty) return rows;

    final firstValues = _basicDrillNumberValues(first.items);
    final laterValues = _basicDrillNumberValues(
      laterRows.expand((r) => r.items).toList(growable: false),
    );
    if (firstValues.isEmpty || laterValues.isEmpty) return rows;

    final firstHasGroup = first.items.any(_hasBasicDrillContentGroup);
    final laterHasGroup =
        laterRows.expand((r) => r.items).any(_hasBasicDrillContentGroup);
    final connected = _numberSetsAreNear(firstValues, laterValues);

    if (connected || firstHasGroup || !laterHasGroup) return rows;

    final out = List<_PageAnalysisRow>.of(rows);
    out[firstIndex] = _rowWithGuardedItems(
      first,
      const <TextbookVlmItem>[],
      first.items.length,
      reason: 'basic_drill_start_page_filtered',
    );
    return out;
  }

  _PageAnalysisRow _rowWithGuardedItems(
    _PageAnalysisRow row,
    List<TextbookVlmItem> kept,
    int dropped, {
    required String reason,
  }) {
    if (dropped <= 0) return row;
    final notes = _appendGuardNote(row.notes, '$reason=$dropped');
    if (kept.isEmpty) {
      return _PageAnalysisRow.success(
        rawPage: row.rawPage,
        displayPage: row.displayPage,
        section: row.section,
        pageKind: 'concept_page',
        conceptDrillHeaderVisible: row.conceptDrillHeaderVisible,
        notes: _appendGuardNote(notes, 'concept_page:auto_guarded'),
        items: const <TextbookVlmItem>[],
      );
    }
    return _PageAnalysisRow.success(
      rawPage: row.rawPage,
      displayPage: row.displayPage,
      section: row.section,
      pageKind: row.pageKind == 'concept_page' ? 'mixed' : row.pageKind,
      conceptDrillHeaderVisible: row.conceptDrillHeaderVisible,
      notes: notes,
      items: kept,
    );
  }

  bool _hasStrongBasicDrillPageEvidence(List<TextbookVlmItem> items) {
    final values = <int>{};
    for (final item in items) {
      if (item.isSetHeader || item.label.trim().isNotEmpty) continue;
      final number = item.number.trim();
      if (!RegExp(r'^\d{4}$').hasMatch(number)) continue;
      if (!_isValidBasicDrillCandidate(
        item,
        allowFlexibleGeometry: true,
      )) {
        continue;
      }
      final value = int.tryParse(number);
      if (value != null) values.add(value);
    }
    final sorted = values.toList()..sort();
    if (sorted.length < 3) return false;
    for (var i = 1; i < sorted.length; i += 1) {
      final gap = sorted[i] - sorted[i - 1];
      if (gap >= 1 && gap <= 3) return true;
    }
    return false;
  }

  bool _isValidBasicDrillCandidate(
    TextbookVlmItem item, {
    bool allowFlexibleGeometry = false,
  }) {
    if (!_isBasicDrillNumber(item)) return false;
    final bbox = item.bbox;
    final region = item.itemRegion;
    if (bbox == null ||
        bbox.length != 4 ||
        region == null ||
        region.length != 4) {
      return false;
    }
    final byMin = bbox[0];
    final bxMin = bbox[1];
    final byMax = bbox[2];
    final bxMax = bbox[3];
    final ryMin = region[0];
    final rxMin = region[1];
    final ryMax = region[2];
    final rxMax = region[3];
    if (byMin >= byMax || bxMin >= bxMax || ryMin >= ryMax || rxMin >= rxMax) {
      return false;
    }

    // RPM A에는 짧은 가로형 외에 세로형·독립형 세트가 섞인다. 4자리 번호와
    // 유효 좌표가 확인되면 쎈 전용 짧은 행 기하 검증으로 제거하지 않는다.
    if (_seriesKey == 'rpm' || allowFlexibleGeometry) return true;

    if (item.label.trim().isNotEmpty) return false;
    final regionHeight = ryMax - ryMin;
    final numberCenterY = (byMin + byMax) / 2;
    if (regionHeight > 380) return false;
    final regionStartsAfterNumber = bxMin < rxMin && bxMax <= rxMin + 60;
    final regionContainsNumber = rxMin <= bxMin + 8 && rxMax >= bxMax + 40;
    if (!regionStartsAfterNumber && !regionContainsNumber) return false;
    if (numberCenterY < ryMin - 80 || numberCenterY > ryMax + 80) {
      return false;
    }
    return true;
  }

  bool _isBasicDrillNumber(TextbookVlmItem item) {
    final number = item.number.trim();
    if (item.isSetHeader) {
      final pattern = _seriesKey == 'rpm'
          ? RegExp(r'^(\d{1,4})\s*[~\-\u2013\u2014\u301c]\s*(\d{1,4})$')
          : RegExp(r'^(\d{4})\s*[~\-\u2013\u2014\u301c]\s*(\d{4})$');
      final match = pattern.firstMatch(number);
      if (match == null) return false;
      final from = int.tryParse(match.group(1)!);
      final to = int.tryParse(match.group(2)!);
      return from != null && to != null && from <= to;
    }
    return RegExp(r'^\d{4}$').hasMatch(number);
  }

  int? _basicDrillIndividualNumber(TextbookVlmItem item) {
    if (item.isSetHeader) return null;
    final number = item.number.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(number)) return null;
    return int.tryParse(number);
  }

  Set<int> _basicDrillNumberValues(List<TextbookVlmItem> items) {
    final out = <int>{};
    for (final item in items) {
      if (item.isSetHeader) {
        final pattern = _seriesKey == 'rpm'
            ? RegExp(r'^(\d{1,4})\s*[~\-\u2013\u2014\u301c]\s*(\d{1,4})$')
            : RegExp(r'^(\d{4})\s*[~\-\u2013\u2014\u301c]\s*(\d{4})$');
        final match = pattern.firstMatch(item.number.trim());
        final from = match == null ? null : int.tryParse(match.group(1)!);
        final to = match == null ? null : int.tryParse(match.group(2)!);
        if (from != null && to != null && from <= to && to - from <= 30) {
          for (var n = from; n <= to; n += 1) {
            out.add(n);
          }
        }
      } else {
        final n = _basicDrillIndividualNumber(item);
        if (n != null) out.add(n);
      }
    }
    return out;
  }

  bool _hasBasicDrillContentGroup(TextbookVlmItem item) {
    if (item.contentGroupKind != 'basic_subtopic') return false;
    return item.contentGroupLabel.trim().isNotEmpty ||
        item.contentGroupTitle.trim().isNotEmpty;
  }

  bool _numberSetsAreNear(Set<int> a, Set<int> b) {
    for (final x in a) {
      for (final y in b) {
        if ((x - y).abs() <= 2) return true;
      }
    }
    return false;
  }

  String _appendGuardNote(String notes, String suffix) {
    final trimmed = notes.trim();
    if (trimmed.contains(suffix)) return trimmed;
    return trimmed.isEmpty ? suffix : '$trimmed; $suffix';
  }

  bool _samePageRows(List<_PageAnalysisRow> a, List<_PageAnalysisRow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i].rawPage != b[i].rawPage ||
          a[i].ok != b[i].ok ||
          a[i].pageKind != b[i].pageKind ||
          a[i].notes != b[i].notes ||
          a[i].items.length != b[i].items.length) {
        return false;
      }
    }
    return true;
  }

  int _totalRegionsFor(_SubRunState state, _SubFocus focus) {
    final edits = _manualEdits[_stateKeyFor(focus)];
    var total = 0;
    for (final row in state.pageResults.where((r) => r.ok)) {
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        final edited = edits?[_problemKey(row.rawPage, i)];
        final region = edited ?? item.itemRegion;
        if (region != null && region.length == 4) total += 1;
      }
    }
    return total;
  }

  /// 지금 화면의 크롭을 서버에 임시저장한다. 다시 분석한 결과도 옛 추출을 지우지 않고
  /// 덮어쓴다: 같은 번호는 갱신되고, 문제은행에 연결됐거나 사람이 고친 크롭은 남는다.
  Future<void> _uploadFocused(_SubFocus focus, {bool quiet = false}) async {
    final state = _ensureSubState(focus);
    if (state.running || state.uploading) return;
    _applyScopeGuards(focus);
    final typeGroupError = _requiredTypeGroupError(focus, state);
    if (typeGroupError != null) {
      setState(() {
        state.error = typeGroupError;
        state.phase = '저장 안 됨 · 유형명 누락';
      });
      if (!quiet) _toast(typeGroupError, error: true);
      return;
    }
    if (_isWonriRowFocus(focus)) {
      await _uploadWonriRowFocus(focus, state, quiet: quiet);
      return;
    }
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final edits = _manualEdits[_stateKeyFor(focus)];
    final items = <TextbookCropUploadItem>[];
    _ResolvedContentGroup? lastBGroup;
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in pageRows) {
      for (var i = 0; i < row.items.length; i += 1) {
        final vlm = row.items[i];
        final edited = edits?[_problemKey(row.rawPage, i)];
        final region = edited ?? vlm.itemRegion;
        if (region == null || region.length != 4) continue;
        final rawGroup =
            _rawContentGroupForItem(vlm, focus.subKey, row.section);
        final carries = _carriesTypeGroup(focus.subKey);
        final group = carries && rawGroup.kind == 'none'
            ? (lastBGroup ?? rawGroup)
            : rawGroup;
        if (carries && rawGroup.kind == 'type') {
          lastBGroup = rawGroup;
        }
        items.add(TextbookCropUploadItem(
          rawPage: row.rawPage,
          displayPage: row.displayPage,
          section: row.section,
          problemNumber: vlm.number,
          label: vlm.label,
          isSetHeader: vlm.isSetHeader,
          setFrom: vlm.setFrom,
          setTo: vlm.setTo,
          contentGroupKind: group.kind,
          contentGroupLabel: group.label,
          contentGroupTitle: group.title,
          contentGroupOrder: group.order,
          columnIndex: vlm.column,
          bbox1k: _effectiveNumberBbox(vlm, region),
          itemRegion1k: region,
          regionSource: edited != null || state.manualItems.contains(vlm)
              ? 'manual'
              : 'vlm',
        ));
      }
    }
    if (items.isEmpty) {
      if (!quiet) _toast('저장할 문항 영역이 없습니다', error: true);
      return;
    }

    final seq = state.editSeq;
    setState(() {
      state.uploading = true;
      state.phase = '임시저장 중... (${items.length}건)';
      state.error = null;
    });
    try {
      final result = await _cropUploader.uploadCropBatch(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        bigOrder: focus.bigIndex,
        midOrder: focus.midIndex,
        subKey: focus.subKey,
        bigName: big.nameCtrl.text.trim(),
        midName: mid.nameCtrl.text.trim(),
        items: items,
        regionsOnly: true,
        onProgress: (processed, total) {
          if (!mounted) return;
          setState(() {
            state.phase = '임시저장 중... $processed / $total';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.dirty = state.editSeq != seq;
        state.uploadResult = result;
        state.phase = '임시저장 · ${result.upserted}/${items.length}건';
      });
      // 다시 분석한 지면에서 이번에 안 잡힌 번호의 옛 크롭은 지운다. 문제은행에
      // 연결됐거나 사람이 고친 크롭은 서버가 남긴다.
      var deletedStale = 0;
      final protectedNumbers = <String>[];
      try {
        final sync = await _cropUploader.syncCropScope(
          academyId: widget.academyId,
          bookId: widget.bookId,
          gradeLabel: widget.gradeLabel,
          bigOrder: focus.bigIndex,
          midOrder: focus.midIndex,
          subKey: focus.subKey,
          rawPages: pageRows.map((row) => row.rawPage),
          keepProblemNumbers: items.map((item) => item.problemNumber),
        );
        deletedStale = sync.deleted;
        protectedNumbers.addAll(sync.protectedNumbers);
      } catch (e) {
        if (mounted) setState(() => state.error = '범위 정리 실패(저장은 완료): $e');
      }
      if (!mounted) return;
      if (deletedStale > 0 || protectedNumbers.isNotEmpty) {
        setState(() {
          state.phase = '${state.phase}'
              '${deletedStale > 0 ? ' · 옛 크롭 $deletedStale건 삭제' : ''}'
              '${protectedNumbers.isEmpty ? '' : ' · 연결된 옛 크롭 ${protectedNumbers.length}건 남김'}';
        });
      }
      if (!quiet) {
        _toast('${_subFocusLabel(focus)} 크롭 ${result.upserted}건 임시저장');
      }
      unawaited(_loadStageStatuses());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.error = '$e';
        state.phase = '임시저장 실패';
      });
      _toast('${_subFocusLabel(focus)} 임시저장 실패: $e', error: true);
    }
  }

  /// 소단원 안에서 번호가 두 번 이상 1로 되돌아가는 슬롯의 문항별 접두어.
  ///
  /// 개념+유형의 쏙쏙 개념 익히기와 한 번 더 연습은 소단원이 아니라 지면
  /// 블록마다 1번부터 다시 시작한다(예: 소단원 O2 안에 109쪽 1~6번, 112쪽
  /// 1~5번, 116쪽 1~4번). 이런 슬롯만 번호 앞에 본문 페이지를 붙여
  /// "109-1", "112-1" 로 저장한다.
  ///
  /// 접두어는 문항이 실제로 인쇄된 페이지가 아니라 **블록이 시작한 페이지**다.
  /// 정답·해설 파일이 블록 단위로 "P.25~26" 처럼 묶여 있어서, 두 페이지에
  /// 걸친 블록에 페이지별 접두어를 붙이면 답지 매칭이 어긋난다.
  ///
  /// 반환 키는 `'<subKey>|<rawPage>|<itemIndex>'`, 값은 접두어로 쓸 페이지.
  /// 개념+유형 중등은 블록이 하나뿐인 슬롯을 담지 않고(번호가 겹치지 않음),
  /// 고등 개념 Check 는 해설의 "개념 Check N쪽" 매칭을 위해 늘 접두어를 붙인다.
  Map<String, int> _gaeyuBlockNumberPrefixes(List<_PageAnalysisRow> pageRows) {
    final isHigh = _seriesKey == 'gaeyu_high';
    if (_seriesKey != 'gaeyu' && !isHigh) return const <String, int>{};
    final subKeyByCategory =
        isHigh ? _kGaeyuHighSubKeyByCategory : _kGaeyuSubKeyByCategory;
    final blockScopedKeys =
        isHigh ? _kGaeyuHighBlockScopedKeys : _kGaeyuBlockScopedKeys;
    final blockStartBySubKey = <String, int>{};
    final lastNumberBySubKey = <String, int>{};
    final lastPageBySubKey = <String, int>{};
    final blockCountBySubKey = <String, int>{};
    final prefixByItem = <String, int>{};
    for (final row in pageRows) {
      final printedPage = row.displayPage > 0 ? row.displayPage : row.rawPage;
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        final category = _wonriCategoryOfItem(item, row.section);
        final subKey = subKeyByCategory[category];
        if (subKey == null || !blockScopedKeys.contains(subKey)) {
          continue;
        }
        final digits = RegExp(r'\d+').firstMatch(item.number);
        if (digits == null) continue;
        final number = int.parse(digits[0]!);
        final previous = lastNumberBySubKey[subKey];
        // 개념+유형 고등의 개념 Check 블록 사이에는 필수예제 지면이 끼므로,
        // 한 쪽 넘게 떨어지면 첫 번호를 놓쳤어도 새 블록으로 본다.
        final lastPage = lastPageBySubKey[subKey];
        final skippedPage =
            isHigh && lastPage != null && printedPage - lastPage > 1;
        if (previous == null || number <= previous || skippedPage) {
          blockStartBySubKey[subKey] = printedPage;
          blockCountBySubKey[subKey] = (blockCountBySubKey[subKey] ?? 0) + 1;
        }
        lastNumberBySubKey[subKey] = number;
        lastPageBySubKey[subKey] = printedPage;
        prefixByItem['$subKey|${row.rawPage}|$i'] = blockStartBySubKey[subKey]!;
      }
    }
    if (!isHigh) {
      prefixByItem.removeWhere(
        (key, _) => (blockCountBySubKey[key.split('|').first] ?? 0) <= 1,
      );
    }
    return prefixByItem;
  }

  /// 개념+유형 고등 연습문제 라벨(`실력`, `교육청`, `실력+교육청` …).
  ///
  /// "▶ 실력" 머리말은 구간 첫 자리에만 찍혀서 모델이 머리말 아래 몇 문항에만
  /// 실력을 단다(2단 지면의 오른쪽 단, 다음 지면은 빠진다). 한 번 보이면 그
  /// 소단원 연습문제 끝까지 실력 구간이다. 키는 [_problemKey].
  Map<String, String> _gaeyuHighExerciseLabels(List<_PageAnalysisRow> rows) {
    final out = <String, String>{};
    if (_seriesKey != 'gaeyu_high') return out;
    final ordered = rows.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    var skillSeen = false;
    for (final row in ordered) {
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        if (_wonriCategoryOfItem(item, row.section) != 'high_exercise') {
          continue;
        }
        var label = item.label.trim();
        if (label.contains('실력')) {
          skillSeen = true;
        } else if (skillSeen) {
          label = label.isEmpty ? '실력' : '실력+$label';
        }
        out[_problemKey(row.rawPage, i)] = label;
      }
    }
    return out;
  }

  /// 분석 화면 뱃지 글자. 문항이름 뒤에 출처 배지(교육청·평가원·수능)를 붙인다.
  String _gaeyuHighBadgeText(String category, String label) {
    final name = _wonriItemName(category, label);
    final sources = label
        .split('+')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != '실력')
        .join('+');
    if (sources.isEmpty) return name;
    return name.isEmpty ? sources : '$name · $sources';
  }

  /// 저장·시드 양쪽에서 동일한 문항번호를 만들기 위한 단일 진입점.
  String _conceptProblemNumber(
    Map<String, int> prefixes,
    String subKey,
    int rawPage,
    int itemIndex,
    String printedNumber,
  ) {
    final prefix = prefixes['$subKey|$rawPage|$itemIndex'];
    if (prefix == null) return printedNumber;
    // 이미 같은 접두어가 붙어 있으면 그대로 둔다 (복원된 번호를 두 번 접두어
    // 붙여 "10-10-1" 로 만들지 않기 위한 방어선).
    if (printedNumber.startsWith('$prefix-')) return printedNumber;
    return '$prefix-$printedNumber';
  }

  /// 개념원리 단일 패스 저장 — 소단원 분석 결과의 문항을 category 별로
  /// sub_key(A~D)에 나눠 업로드한다. 이후 정답/해설/문제은행 흐름은
  /// 쎈과 동일하게 sub_key 단위로 동작한다.
  Future<void> _uploadWonriRowFocus(
    _SubFocus focus,
    _SubRunState state, {
    bool quiet = false,
  }) async {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final edits = _manualEdits[_stateKeyFor(focus)];
    final itemsBySubKey = <String, List<TextbookCropUploadItem>>{};
    var skippedNoCategory = 0;
    // 필수유형은 유형 헤더가 있는 페이지에서만 content_group 이 잡히므로,
    // 그룹 정보가 빠진 후속 문항은 직전 유형 그룹을 승계한다 (쎈 B 와 동일).
    _ResolvedContentGroup? lastTypeGroup;
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    // 개념+유형 쏙쏙/한 번 더 연습은 한 소단원 안에서 지면 블록마다 번호가
    // 1번부터 다시 시작할 수 있다. 그런 슬롯만 번호 앞에 본문 페이지를 붙인다.
    final numberPrefixes = _gaeyuBlockNumberPrefixes(pageRows);
    // 유형명(content_group)을 갖는 카테고리. 수력충전 개념 체크는 아래서
    // 유형 이름을 개념 체크로 따로 넣는다.
    final groupCategories = switch (_seriesKey) {
      'gaeyu' => const {'essential_problem'},
      'suryeok' => const {'type_problem'},
      // 핵심문제 익히기 대표 예제 위 색 띠의 유형명. 본문 크롭에서 뺀 대신
      // 여기에 담아 두고, 뒤따르는 확인 문항도 같은 유형을 승계한다.
      'wonri_middle' => const {'middle_core_problem'},
      // 필수예제와 그 아래 "문제"(01-1, 01-2 …)가 같은 유형명을 공유한다.
      'gaeyu_high' => const {'high_example', 'high_problem'},
      _ => const {'type_example'},
    };
    final gaeyuHighLabels = _gaeyuHighExerciseLabels(pageRows);
    for (final row in pageRows) {
      for (var i = 0; i < row.items.length; i += 1) {
        final vlm = row.items[i];
        final edited = edits?[_problemKey(row.rawPage, i)];
        final region = edited ?? vlm.itemRegion;
        if (region == null || region.length != 4) continue;
        final category = _wonriCategoryOfItem(vlm, row.section);
        if (category.isEmpty) {
          skippedNoCategory += 1;
          continue;
        }
        final itemLabel = _seriesKey == 'gaeyu_high'
            ? gaeyuHighLabels[_problemKey(row.rawPage, i)] ?? ''
            : vlm.label.trim();
        final subKey = _conceptSubKeyByCategory[category]!;
        var group = _seriesKey == 'suryeok' && category == 'concept_check'
            ? const _ResolvedContentGroup.suryeokConceptCheck()
            : const _ResolvedContentGroup.none();
        if (groupCategories.contains(category)) {
          final rawGroup = _rawContentGroupForItem(vlm, subKey, category);
          group =
              rawGroup.kind == 'type' ? rawGroup : (lastTypeGroup ?? rawGroup);
          if (rawGroup.kind == 'type') lastTypeGroup = rawGroup;
        }
        final detectedNumber = _conceptProblemNumber(
          numberPrefixes,
          subKey,
          row.rawPage,
          i,
          vlm.number,
        );
        final storedNumber = _seriesKey == 'wonri_middle'
            ? textbookWonriMiddleStoredProblemNumber(
                section: category,
                problemNumber: detectedNumber,
                itemRole: vlm.itemRole,
              )
            : detectedNumber;
        // 필수유형(B)은 소단원마다 번호(01,02...)가 새로 시작한다. 소단원별
        // 분리는 저장 시 sub_index(= 소단원 순번)로 처리하므로, 번호 자체는
        // 인쇄된 값을 그대로 쓴다. (익히기/확인체크/연습문제는 중단원 내 연속.)
        itemsBySubKey
            .putIfAbsent(subKey, () => <TextbookCropUploadItem>[])
            .add(TextbookCropUploadItem(
              rawPage: row.rawPage,
              displayPage: row.displayPage,
              section: category,
              problemNumber: storedNumber,
              // 개념원리는 난이도가 없어 label 을 비운다. 개념+유형은 탄탄의
              // 난이도(상/중/하)와 쓱쓱의 갈래(예제/유제/연습)를 label 에 담고,
              // 코너 이름은 두 시리즈 모두 전용 컬럼(itemName)에 저장한다.
              // 수력충전에 난이도는 없고, 단원 마무리·실력 향상 테스트의
              // 특수 배지만 label 에 담는다.
              label: switch (_seriesKey) {
                'gaeyu' => _gaeyuLabelForCategory(category, vlm.label),
                'suryeok' => category == 'unit_review' ? vlm.label.trim() : '',
                'wonri_middle' => category == 'middle_exam_problem' &&
                        vlm.label.trim().toUpperCase() == 'UP'
                    ? 'UP'
                    : '',
                'gaeyu_high' => itemLabel,
                _ => '',
              },
              itemName: _wonriItemName(
                category,
                itemLabel,
                itemRole: vlm.itemRole,
              ),
              isImportant: _seriesKey == 'gaeyu'
                  ? category == 'unit_drill' && vlm.isImportant
                  : vlm.isImportant,
              isSetHeader: vlm.isSetHeader,
              setFrom: vlm.setFrom,
              setTo: vlm.setTo,
              contentGroupKind: group.kind,
              contentGroupLabel: group.label,
              contentGroupTitle: group.title,
              contentGroupOrder: group.order,
              columnIndex: vlm.column,
              bbox1k: _effectiveNumberBbox(vlm, region),
              itemRegion1k: region,
              companionRegions: vlm.companionRegions,
              regionSource: edited != null || state.manualItems.contains(vlm)
                  ? 'manual'
                  : 'vlm',
            ));
      }
    }
    final totalItems =
        itemsBySubKey.values.fold<int>(0, (sum, list) => sum + list.length);
    // 서버는 한 슬롯에 같은 번호가 두 번 오면 배치를 통째로 거절하고 JSON만
    // 돌려준다. 어느 코너·지면인지 보이도록 올리기 전에 먼저 막는다.
    final duplicateError = _duplicateCropNumbersError(itemsBySubKey);
    if (duplicateError != null) {
      setState(() {
        state.error = duplicateError;
        state.phase = '저장 안 됨 · 번호 중복';
      });
      if (!quiet) _toast(duplicateError, error: true);
      return;
    }
    if (totalItems == 0) {
      if (!quiet) _toast('저장할 문항 영역이 없습니다', error: true);
      return;
    }

    final seq = state.editSeq;
    setState(() {
      state.uploading = true;
      state.phase = '임시저장 중... ($totalItems건)';
      state.error = null;
    });
    try {
      final allRows = <Map<String, dynamic>>[];
      var upserted = 0;
      var deletedStale = 0;
      // 필수유형(B)·특강(E)은 소단원별로 분리 저장한다 (번호가 소단원마다
      // 새로 시작). 익히기(A)/확인체크(C)/연습문제(D)는 중단원 내 연속 번호라
      // sub_index=0.
      final wonriIndex = _wonriRowIndex(focus) ?? 0;
      final subKeys = _conceptCategoryBySubKey.keys.toList()..sort();
      for (final subKey in subKeys) {
        final items = itemsBySubKey[subKey];
        if (items == null || items.isEmpty) continue;
        final categoryName =
            _conceptCategoryShortNames[_conceptCategoryBySubKey[subKey]] ??
                subKey;
        final result = await _cropUploader.uploadCropBatch(
          academyId: widget.academyId,
          bookId: widget.bookId,
          gradeLabel: widget.gradeLabel,
          bigOrder: focus.bigIndex,
          midOrder: focus.midIndex,
          subKey: subKey,
          subIndex: _conceptPerSubUnitKeys.contains(subKey) ? wonriIndex : 0,
          bigName: big.nameCtrl.text.trim(),
          midName: mid.nameCtrl.text.trim(),
          items: items,
          regionsOnly: true,
          onProgress: (processed, total) {
            if (!mounted) return;
            setState(() {
              state.phase = '$categoryName 임시저장 중... $processed / $total';
            });
          },
        );
        upserted += result.upserted;
        allRows.addAll(result.rows);
      }
      // 여기까지 왔으면 영역은 이미 서버에 들어갔다. 아래 범위 정리는 뒷정리라
      // 실패하더라도 저장 결과를 버리면 안 된다. 예전에는 정리 단계의 예외가
      // uploadResult 를 비워서, 다 저장해 놓고도 "영역 저장 실패" 로 보였다.
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.dirty = state.editSeq != seq;
        state.uploadResult = TextbookCropBatchResult(
          upserted: upserted,
          bucket: 'textbook-crops',
          rows: allRows,
        );
      });

      final analyzedRawPages =
          pageRows.map((row) => row.rawPage).where((page) => page > 0);
      final protectedNumbers = <String>[];
      String? syncError;
      for (final subKey in subKeys) {
        try {
          final sync = await _cropUploader.syncCropScope(
            academyId: widget.academyId,
            bookId: widget.bookId,
            gradeLabel: widget.gradeLabel,
            bigOrder: focus.bigIndex,
            midOrder: focus.midIndex,
            subKey: subKey,
            subIndex: _conceptPerSubUnitKeys.contains(subKey) ? wonriIndex : 0,
            rawPages: analyzedRawPages,
            keepProblemNumbers:
                (itemsBySubKey[subKey] ?? const <TextbookCropUploadItem>[])
                    .map((item) => item.problemNumber),
          );
          deletedStale += sync.deleted;
          protectedNumbers.addAll(sync.protectedNumbers);
        } catch (e) {
          syncError ??= '$e';
        }
      }
      if (!mounted) return;
      final skippedNote =
          skippedNoCategory > 0 ? ' · 카테고리 미상 $skippedNoCategory건 제외' : '';
      final deletedNote = deletedStale > 0 ? ' · 기존 오인식 $deletedStale건 삭제' : '';
      final protectedNote = protectedNumbers.isEmpty
          ? ''
          : ' · 문제은행 연결 ${protectedNumbers.length}건 남김';
      setState(() {
        state.error = syncError;
        state.phase = '임시저장 · $upserted/$totalItems건'
            '$skippedNote$deletedNote$protectedNote';
      });
      if (!quiet) {
        _toast(
          '${_subFocusLabel(focus)} 크롭 $upserted건 임시저장'
          '${deletedStale > 0 ? ' · 오인식 $deletedStale건 삭제' : ''}',
        );
      }
      if (protectedNumbers.isNotEmpty) {
        // 재분류로 옛 crop 이 필요 없어졌는데 이미 문제은행 문항이 붙어 있는
        // 경우다. 문항을 말없이 지울 수는 없으니 어떤 번호인지 알려준다.
        final preview = protectedNumbers.take(8).join(', ');
        final more = protectedNumbers.length > 8
            ? ' 외 ${protectedNumbers.length - 8}건'
            : '';
        _toast(
          '옛 분류로 남은 $preview$more 은(는) 이미 문제은행에 올라가 있어 지우지 '
          '않았습니다. 문제은행에서 삭제한 뒤 다시 저장하세요.',
          error: true,
        );
      }
      if (syncError != null) {
        _toast('범위 정리 실패(영역 저장은 완료): $syncError', error: true);
      }
      unawaited(_loadStageStatuses());

      // 특강(E) 크롭이 새로 저장됐으면 정규화 특강 소단원을 재동기화한다.
      // 슬롯 E 는 개념원리에서만 특강이다 — 개념+유형의 E 는 쓱쓱 서술형이라
      // 여기서 걸리면 있지도 않은 특강 소단원이 단원 트리에 생긴다.
      final hasSpecial = _seriesKey == 'wonri' &&
          allRows.any(
            (r) => '${r['sub_key'] ?? ''}'.trim().toUpperCase() == 'E',
          );
      if (hasSpecial) {
        unawaited(_rebuildSpecialUnits());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state.uploading = false;
        state.error = '$e';
        if (state.dirty) state.phase = '임시저장 실패';
      });
      if (state.dirty) {
        _toast('${_subFocusLabel(focus)} 임시저장 실패: $e', error: true);
      }
    }
  }

  String? _duplicateCropNumbersError(
    Map<String, List<TextbookCropUploadItem>> itemsBySubKey,
  ) {
    final parts = <String>[];
    final subKeys = itemsBySubKey.keys.toList()..sort();
    for (final subKey in subKeys) {
      final pagesByNumber = <String, List<int>>{};
      for (final item in itemsBySubKey[subKey]!) {
        pagesByNumber
            .putIfAbsent(item.problemNumber, () => <int>[])
            .add(item.displayPage ?? item.rawPage);
      }
      final duplicates =
          pagesByNumber.entries.where((e) => e.value.length > 1).toList();
      if (duplicates.isEmpty) continue;
      final pages = <int>{for (final e in duplicates) ...e.value}.toList()
        ..sort();
      final name =
          _conceptCategoryShortNames[_conceptCategoryBySubKey[subKey]] ??
              subKey;
      parts.add('$name ${duplicates.map((e) => e.key).join('·')}번 '
          '(${pages.join('·')}쪽)');
    }
    if (parts.isEmpty) return null;
    return '같은 번호가 두 번 잡혔습니다: ${parts.join(', ')}. '
        '코너를 잘못 읽은 지면입니다. 이 소단원을 다시 분석하세요.';
  }

  Future<void> _runSelectedBatch() async {
    if (_batchRunning) return;
    final selected = _selectedBatchFocuses();
    if (selected.isEmpty) {
      _toast('중단원 또는 소단원 체크박스를 먼저 선택하세요', error: true);
      return;
    }
    setState(() {
      _batchRunning = true;
      _batchDone = 0;
      _batchTotal = selected.length;
      _batchStatus = '일괄 실행 준비 중...';
    });
    final failed = <String>[];
    var skipped = 0;
    try {
      for (var i = 0; i < selected.length; i += 1) {
        final focus = selected[i];
        final label = _subFocusLabel(focus);
        if (!mounted) return;
        if (_cropLocked(focus)) {
          skipped += 1;
          setState(() => _batchDone = i + 1);
          continue;
        }
        setState(() {
          _focus = focus;
          _selectedProblemKey = null;
          _batchStatus = '$label · 크롭 분석 중...';
        });
        await _runFocusedAnalysis(focus);
        final state = _ensureSubState(focus);
        if (state.error != null || _totalRegionsFor(state, focus) == 0) {
          failed.add('$label: ${state.error ?? '문항 영역 없음'}');
          if (mounted) setState(() => _batchDone = i + 1);
          continue;
        }

        if (!mounted) return;
        setState(() {
          _batchDone = i + 1;
          _batchStatus = '$label · 크롭 분석 완료';
        });
      }
      if (!mounted) return;
      final failText = failed.isEmpty ? '' : ' · 실패 ${failed.length}개';
      final skipText = skipped == 0 ? '' : ' · 확정돼 건너뜀 $skipped개';
      _toast('선택 분석 완료$failText$skipText');
      setState(() {
        _batchRunning = false;
        _batchStatus = failed.isEmpty
            ? '크롭을 확인한 뒤 "크롭 확정"을 누르면 2단계(본문 추출·정답 위치·AI 검수)가 시작됩니다$skipText'
            : failed.join('\n');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _batchRunning = false;
        _batchStatus = '일괄 실행 실패: $e';
      });
      _toast('일괄 실행 실패: $e', error: true);
    }
  }

  // ------------------------------------------------------------ workflow

  Future<void> _loadWorkflows({bool resume = false}) async {
    try {
      final list = await _workflowService.fetchForBook(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
      );
      if (!mounted) return;
      setState(() {
        _workflows = {for (final w in list) w.stateKey: w};
      });
      unawaited(_refreshLiveReady(list));
      if (resume) {
        final n = TextbookWorkflowRunner.instance.resumeUnfinished(list);
        if (n > 0) _toast('멈춰 있던 2단계 작업 $n개를 이어서 진행합니다');
      }
    } catch (e) {
      debugPrint('[textbook-workflow] load failed: $e');
    }
  }

  /// 소단원별 지금 카드 기준 (준비됨, 전체). 2단계 요약 문구는 그 뒤 바뀐 카드 상태를 모르므로 이것을 먼저 쓴다.
  Map<String, (int, int)> _liveReady = {};
  DateTime? _liveReadyAt;

  Future<void> _refreshLiveReady(List<TextbookSubunitWorkflow> list) async {
    final byMid = <String, List<TextbookSubunitWorkflow>>{};
    for (final w in list) {
      final order = w.workOrder;
      if (order == null || !w.cropConfirmed || w.pipelineStatus != 'done') continue;
      byMid.putIfAbsent('${order.bigOrder}|${order.midOrder}', () => []).add(w);
    }
    if (byMid.isEmpty) return;
    final startedAt = DateTime.now();
    final review = TextbookProblemReviewService();
    final next = <String, (int, int)>{};
    for (final group in byMid.values) {
      try {
        final items = await review.fetchUnitItems(group.first.workOrder!.reviewScope);
        for (final w in group) {
          final mine = [for (final it in items) if (w.workOrder!.matches(it)) it];
          next[w.stateKey] = (mine.where((x) => x.isWorkflowReady).length, mine.length);
        }
      } catch (e) {
        debugPrint('[textbook-workflow] ready count failed: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _liveReady = {..._liveReady, ...next};
      _liveReadyAt = startedAt;
    });
  }

  TextbookSubunitWorkflow? _workflowFor(_SubFocus focus) =>
      _workflows[_stateKeyFor(focus)];

  String _workflowKeyFor(_SubFocus focus) => textbookWorkflowKey(
        widget.bookId,
        widget.gradeLabel,
        focus.bigIndex,
        focus.midIndex,
        focus.subKey,
      );

  TextbookWorkflowRunState? _runStateFor(_SubFocus focus) =>
      TextbookWorkflowRunner.instance.stateFor(_workflowKeyFor(focus));

  /// 크롭을 확정했거나 2단계가 돌고 있으면 1단계에서 고치지 않는다.
  bool _cropLocked(_SubFocus focus) =>
      (_workflowFor(focus)?.cropConfirmed ?? false) ||
      TextbookWorkflowRunner.instance.isActive(_workflowKeyFor(focus));

  TextbookSubunitStage _stageOf(_SubFocus focus) => TextbookSubunitStage.of(
        workflow: _workflowFor(focus),
        extractedBodies: _bodyCounts[_stateKeyFor(focus)]?.bodies ?? 0,
        reviewedBodies: _bodyCounts[_stateKeyFor(focus)]?.reviewed ?? 0,
      );

  /// 예전 원스톱으로 본문만 뽑아 둔 소단원(검수 여부 무관). 크롭 확정 대신 "이어서 마무리"로 2단계에 들어간다.
  bool _isLegacy(_SubFocus focus) => _stageOf(focus).isLegacy;

  void _scheduleAutoSave(
    _SubFocus focus, {
    Duration delay = const Duration(milliseconds: 900),
  }) {
    final key = _stateKeyFor(focus);
    _autoSaveTimers.remove(key)?.cancel();
    _autoSaveTimers[key] = Timer(delay, () {
      _autoSaveTimers.remove(key);
      unawaited(_autoSave(focus));
    });
  }

  Future<void> _autoSave(_SubFocus focus) async {
    if (!mounted) return;
    final key = _stateKeyFor(focus);
    final state = _ensureSubState(focus);
    if (state.running) return;
    if (state.uploading) {
      _autoSavePending.add(key);
      return;
    }
    if (!state.dirty || _cropLocked(focus)) return;
    if (_totalRegionsFor(state, focus) == 0) return;
    await _uploadFocused(focus, quiet: true);
    if (!mounted) return;
    if (!state.dirty) unawaited(_markCropDraft(focus));
    if (_autoSavePending.remove(key)) await _autoSave(focus);
  }

  /// 닫기 전에 기다리는 자동 저장을 끝낸다.
  Future<void> _flushAutoSaves() async {
    final keys = _autoSaveTimers.keys.toList();
    for (final key in keys) {
      _autoSaveTimers.remove(key)?.cancel();
      final focus = _focusFromStateKey(key);
      if (focus != null) await _autoSave(focus);
    }
    for (var i = 0;
        i < 300 && _subStates.values.any((s) => s.uploading);
        i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  bool _closing = false;

  Future<void> _close() async {
    if (_closing) return;
    final pending = _autoSaveTimers.isNotEmpty ||
        _subStates.values.any((s) => s.uploading);
    if (pending) {
      setState(() => _closing = true);
      await _flushAutoSaves();
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _markCropDraft(_SubFocus focus) async {
    final wf = _workflowFor(focus);
    if (wf != null && wf.cropStatus != 'none') return;
    try {
      await _workflowService.markCropDraft(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        bigOrder: focus.bigIndex,
        midOrder: focus.midIndex,
        scopeKey: focus.subKey,
      );
      await _loadWorkflows();
    } catch (e) {
      debugPrint('[textbook-workflow] draft mark failed: $e');
    }
  }

  /// 저장할 때 쓰는 (sub_key, 문항번호). 업로드와 삭제가 같은 키를 쓴다.
  (String, String)? _storedKeyOf(
    _SubFocus focus,
    _SubRunState state,
    _PageAnalysisRow row,
    int index,
  ) {
    final vlm = row.items[index];
    if (!_isWonriRowFocus(focus)) return (focus.subKey, vlm.number.trim());
    final category = _wonriCategoryOfItem(vlm, row.section);
    final subKey = _conceptSubKeyByCategory[category];
    if (subKey == null) return null;
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    final detected = _conceptProblemNumber(
      _gaeyuBlockNumberPrefixes(pageRows),
      subKey,
      row.rawPage,
      index,
      vlm.number,
    );
    final stored = _seriesKey == 'wonri_middle'
        ? textbookWonriMiddleStoredProblemNumber(
            section: category,
            problemNumber: detected,
            itemRole: vlm.itemRole,
          )
        : detected;
    return (subKey, stored.trim());
  }

  Future<void> _deleteItem(_SubFocus focus, int rawPage, int index) async {
    final state = _ensureSubState(focus);
    if (state.running || state.uploading || _cropLocked(focus)) return;
    final row = state.pageResults.firstWhere(
      (r) => r.rawPage == rawPage && r.ok,
      orElse: () => _PageAnalysisRow.placeholder(),
    );
    if (index < 0 || index >= row.items.length) return;
    final item = row.items[index];
    final stored = _storedKeyOf(focus, state, row, index);
    final rows = state.uploadResult?.rows ?? const <Map<String, dynamic>>[];
    final dbRow = stored == null
        ? null
        : rows
            .where((r) =>
                '${r['sub_key'] ?? ''}'.trim().toUpperCase() == stored.$1 &&
                '${r['problem_number'] ?? ''}'.trim() == stored.$2)
            .firstOrNull;
    final cropId = '${dbRow?['id'] ?? ''}'.trim();
    if (cropId.isNotEmpty) {
      try {
        final deleted = await _workflowService.deleteDraftCrop(cropId);
        if (!deleted) {
          _toast(
            '${item.number}번은 이미 본문을 추출해 지우지 않았습니다. 작업 화면에서 정리하세요',
            error: true,
          );
          return;
        }
      } catch (e) {
        _toast('${item.number}번 삭제 실패: $e', error: true);
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _bakeManualEdits(focus, state);
      final idx = state.pageResults.indexWhere(
        (r) => r.rawPage == rawPage && r.ok,
      );
      if (idx >= 0) {
        final current = state.pageResults[idx];
        if (index < current.items.length) {
          state.manualItems.remove(current.items[index]);
          state.pageResults[idx] = current.withItems([
            for (var i = 0; i < current.items.length; i += 1)
              if (i != index) current.items[i],
          ]);
        }
      }
      final result = state.uploadResult;
      if (result != null && dbRow != null) {
        state.uploadResult = TextbookCropBatchResult(
          upserted: math.max(0, result.upserted - 1),
          bucket: result.bucket,
          rows: [
            for (final r in result.rows)
              if (!identical(r, dbRow)) r,
          ],
        );
      }
      _selectedProblemKey = null;
      state.markDirty();
    });
    _toast('${item.number}번 크롭을 지웠습니다');
    _scheduleAutoSave(focus);
    unawaited(_loadStageStatuses());
  }

  // ─── 수동 크롭(번호 상자 → 본문 상자) ────────────────────────────────

  void _toggleManualDraw() {
    setState(() {
      _manualDrawMode = !_manualDrawMode;
      _manualNumberBox = null;
      _manualNumberPage = null;
      _manualDragRect = null;
      _manualDragStart = null;
      _manualDragPage = null;
      _selectedProblemKey = null;
    });
  }

  Offset _normalizedOffset(Offset local, Size pageSize) => Offset(
        (local.dx / pageSize.width).clamp(0.0, 1.0),
        (local.dy / pageSize.height).clamp(0.0, 1.0),
      );

  void _onManualDragStart(int rawPage, Offset local, Size pageSize) {
    if (pageSize.width <= 0 || pageSize.height <= 0) return;
    final start = _normalizedOffset(local, pageSize);
    setState(() {
      _manualDragPage = rawPage;
      _manualDragStart = start;
      _manualDragRect = Rect.fromPoints(start, start);
    });
  }

  void _onManualDragUpdate(int rawPage, Offset local, Size pageSize) {
    final start = _manualDragStart;
    if (start == null || _manualDragPage != rawPage) return;
    if (pageSize.width <= 0 || pageSize.height <= 0) return;
    setState(() {
      _manualDragRect =
          Rect.fromPoints(start, _normalizedOffset(local, pageSize));
    });
  }

  Future<void> _onManualDragEnd(_SubFocus focus, int rawPage) async {
    final rect = _manualDragRect;
    setState(() {
      _manualDragRect = null;
      _manualDragStart = null;
      _manualDragPage = null;
    });
    if (rect == null || rect.width < 0.004 || rect.height < 0.003) return;
    final numberBox = _manualNumberBox;
    if (numberBox == null || _manualNumberPage != rawPage) {
      setState(() {
        _manualNumberBox = rect;
        _manualNumberPage = rawPage;
      });
      return;
    }
    setState(() {
      _manualNumberBox = null;
      _manualNumberPage = null;
    });
    await _addManualItem(focus, rawPage, numberBox, rect);
  }

  List<int> _rectTo1k(Rect r) => <int>[
        (r.top * 1000).round().clamp(0, 1000),
        (r.left * 1000).round().clamp(0, 1000),
        (r.bottom * 1000).round().clamp(0, 1000),
        (r.right * 1000).round().clamp(0, 1000),
      ];

  String _suggestNextNumber(_SubRunState state, int rawPage, int ymin) {
    TextbookVlmItem? prev;
    final rows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in rows) {
      if (row.rawPage > rawPage) break;
      for (final it in row.items) {
        if (it.isSetHeader) continue;
        final box = it.itemRegion ?? it.bbox;
        if (row.rawPage == rawPage &&
            box != null &&
            box.length == 4 &&
            box[0] > ymin) {
          continue;
        }
        prev = it;
      }
    }
    final m = RegExp(r'^(\d+)$').firstMatch(prev?.number.trim() ?? '');
    if (m == null) return '';
    final digits = m.group(1)!;
    return '${int.parse(digits) + 1}'.padLeft(digits.length, '0');
  }

  Future<void> _addManualItem(
    _SubFocus focus,
    int rawPage,
    Rect numberRect,
    Rect bodyRect,
  ) async {
    final state = _ensureSubState(focus);
    if (state.running || _cropLocked(focus)) return;
    final numberBox = _rectTo1k(numberRect);
    final body = _rectTo1k(bodyRect);
    final region = <int>[
      math.min(numberBox[0], body[0]),
      math.min(numberBox[1], body[1]),
      math.max(numberBox[2], body[2]),
      math.max(numberBox[3], body[3]),
    ];
    final pageRow = state.pageResults.firstWhere(
      (r) => r.rawPage == rawPage && r.ok,
      orElse: () => _PageAnalysisRow.placeholder(),
    );
    final concept = _isWonriRowFocus(focus);
    var defaultCategory = '';
    if (concept) {
      for (final it in pageRow.items) {
        final box = it.itemRegion ?? it.bbox;
        if (box != null && box.length == 4 && box[0] > region[0]) break;
        final c = _wonriCategoryOfItem(it, pageRow.section);
        if (c.isNotEmpty) defaultCategory = c;
      }
      if (defaultCategory.isEmpty) {
        defaultCategory = _conceptSubKeyByCategory.containsKey(pageRow.section)
            ? pageRow.section
            : _conceptSubKeyByCategory.keys.first;
      }
    }
    final spec = await _promptManualItem(
      title: '${_displayPageForRawPage(rawPage)}쪽에 문항 추가',
      suggestedNumber: _suggestNextNumber(state, rawPage, region[0]),
      category: defaultCategory,
      categories: concept ? _conceptSubKeyByCategory.keys.toList() : const [],
    );
    if (spec == null || !mounted || state.running || _cropLocked(focus)) {
      return;
    }
    final candidate = TextbookVlmItem(
      number: spec.number,
      label: spec.label,
      category: spec.category,
      isSetHeader: spec.isSetHeader,
      setFrom: spec.setFrom,
      setTo: spec.setTo,
      contentGroupKind: 'none',
      contentGroupLabel: '',
      contentGroupTitle: '',
      contentGroupOrder: null,
      column: pageRow.items.any((it) => it.column != null)
          ? ((region[1] + region[3]) / 2 < 500 ? 1 : 2)
          : null,
      bbox: numberBox,
      itemRegion: region,
    );
    final duplicates = [
      for (final row in state.pageResults.where((r) => r.ok))
        for (final it in row.items)
          if (_sameProblem(it, candidate)) (row.rawPage, it),
    ];
    if (duplicates.isNotEmpty) {
      final pages = duplicates.map((d) => '${_displayPageForRawPage(d.$1)}쪽');
      final replace = await _confirmDialog(
        title: '${spec.number}번이 이미 있습니다',
        message: '${pages.toSet().join(', ')}에 같은 번호가 있습니다. '
            '지금 그린 영역으로 바꿀까요?',
        confirmLabel: '바꾸기',
      );
      if (!replace || !mounted) return;
    }
    setState(() {
      _bakeManualEdits(focus, state);
      for (var r = 0; r < state.pageResults.length; r += 1) {
        final row = state.pageResults[r];
        if (!row.ok || !row.items.any((it) => _sameProblem(it, candidate))) {
          continue;
        }
        for (final it in row.items) {
          if (_sameProblem(it, candidate)) state.manualItems.remove(it);
        }
        state.pageResults[r] = row.withItems([
          for (final it in row.items)
            if (!_sameProblem(it, candidate)) it,
        ]);
      }
      final source = pageRow.ok
          ? pageRow
          : _PageAnalysisRow.success(
              rawPage: rawPage,
              displayPage: _displayPageForRawPage(rawPage),
              section: concept
                  ? spec.category
                  : _sectionForSubKey(focus.subKey),
              pageKind: 'problem_page',
              notes: 'manual_crops',
              items: const <TextbookVlmItem>[],
            );
      _restoreManualItems(state, [(source, candidate)]);
      final row = state.pageResults.firstWhere(
        (r) => r.rawPage == rawPage && r.ok,
        orElse: () => _PageAnalysisRow.placeholder(),
      );
      final index = row.items.indexWhere((it) => identical(it, candidate));
      _selectedProblemKey = index < 0 ? null : _problemKey(rawPage, index);
      state.markDirty();
    });
    _scheduleAutoSave(focus, delay: Duration.zero);
  }

  Future<
      ({
        String number,
        String category,
        String label,
        bool isSetHeader,
        int? setFrom,
        int? setTo,
      })?> _promptManualItem({
    required String title,
    required String suggestedNumber,
    required String category,
    required List<String> categories,
  }) async {
    final numberCtrl = TextEditingController(text: suggestedNumber);
    final labelCtrl = TextEditingController();
    final fromCtrl = TextEditingController();
    final toCtrl = TextEditingController();
    var selectedCategory = category;
    var setHeader = false;
    String? error;
    final result = await showDialog<
        ({
          String number,
          String category,
          String label,
          bool isSetHeader,
          int? setFrom,
          int? setTo,
        })>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          void submit() {
            final from = int.tryParse(fromCtrl.text.trim());
            final to = int.tryParse(toCtrl.text.trim());
            final number =
                setHeader ? '${from ?? ''}~${to ?? ''}' : numberCtrl.text.trim();
            if (setHeader && (from == null || to == null || to < from)) {
              setLocal(() => error = '세트 범위(시작~끝 번호)를 입력하세요');
              return;
            }
            if (!setHeader && number.isEmpty) {
              setLocal(() => error = '문항 번호를 입력하세요');
              return;
            }
            Navigator.of(ctx).pop((
              number: number,
              category: selectedCategory,
              label: labelCtrl.text.trim(),
              isSetHeader: setHeader,
              setFrom: setHeader ? from : null,
              setTo: setHeader ? to : null,
            ));
          }

          return AlertDialog(
            backgroundColor: _kPanel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: const BorderSide(color: _kBorder),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: _kText,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (categories.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in categories)
                          _choicePill(
                            label: _conceptCategoryShortNames[c] ?? c,
                            selected: selectedCategory == c,
                            onTap: () => setLocal(() => selectedCategory = c),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      _choicePill(
                        label: '문항',
                        selected: !setHeader,
                        onTap: () => setLocal(() => setHeader = false),
                      ),
                      const SizedBox(width: 6),
                      _choicePill(
                        label: '세트 머리글(공통 지문)',
                        selected: setHeader,
                        onTap: () => setLocal(() => setHeader = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (setHeader)
                    Row(
                      children: [
                        Expanded(
                          child: _textInput(
                            fromCtrl,
                            hint: '시작 번호',
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('~', style: TextStyle(color: _kTextSub)),
                        ),
                        Expanded(
                          child: _textInput(
                            toCtrl,
                            hint: '끝 번호',
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                        ),
                      ],
                    )
                  else
                    _textInput(numberCtrl, hint: '문항 번호 (인쇄된 그대로)'),
                  const SizedBox(height: 8),
                  _textInput(labelCtrl, hint: '라벨 (선택 · 난이도·STEP 등)'),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: const TextStyle(color: _kDanger, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('취소', style: TextStyle(color: _kTextSub)),
              ),
              FilledButton(
                onPressed: submit,
                style: FilledButton.styleFrom(
                  backgroundColor: _kAccent,
                  shape: const StadiumBorder(),
                ),
                child: const Text('추가'),
              ),
            ],
          );
        },
      ),
    );
    numberCtrl.dispose();
    labelCtrl.dispose();
    fromCtrl.dispose();
    toCtrl.dispose();
    return result;
  }

  Widget _choicePill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? _kChipSelected : _kCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? _kAccent : _kBorder),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _kText : _kTextSub,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: const BorderSide(color: _kBorder),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: _kText,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            message,
            style: const TextStyle(color: _kTextSub, fontSize: 13, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소', style: TextStyle(color: _kTextSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: danger ? _kDanger : _kAccent,
              shape: const StadiumBorder(),
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ─── 크롭 확정 → 2단계 ────────────────────────────────────────────

  TextbookWorkflowStageRun _stageRunOf(TextbookAuthoringStageScope s) =>
      TextbookWorkflowStageRun(
        subKey: s.subKey,
        subIndex: textbookStageCropSubIndexForScope(_seriesKey, s),
        answerStartPage: s.answerStartPage,
        answerEndPage: s.answerEndPage,
        solutionStartPage: s.solutionStartPage,
        solutionEndPage: s.solutionEndPage,
        bodyPageFrom: s.bodyStartPage == null
            ? null
            : _rawPageForDisplayPage(s.bodyStartPage!),
        bodyPageTo: s.bodyEndPage == null
            ? null
            : _rawPageForDisplayPage(s.bodyEndPage!),
      );

  /// 크롭 확정 때 실행기에 넘길 작업 지시. 단원 트리 입력값(쪽 범위)을 그대로 담는다.
  TextbookSubunitWorkOrder? _workOrderFor(_SubFocus focus) {
    final state = _ensureSubState(focus);
    final rows = state.uploadResult?.rows ?? const <Map<String, dynamic>>[];
    if (rows.isEmpty) return null;
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final series = _currentSeries();
    if (_isWonriRowFocus(focus)) {
      final row = _wonriRowFor(focus);
      if (row == null) return null;
      final rowIndex = _wonriRowIndex(focus) ?? 0;
      final displayStart = _positiveInt(row.startCtrl.text);
      final displayEnd = _positiveInt(row.endCtrl.text);
      final rawFrom =
          displayStart == null ? null : _rawPageForDisplayPage(displayStart);
      final rawTo =
          displayEnd == null ? null : _rawPageForDisplayPage(displayEnd);
      final keys = <String>{
        for (final r in rows) '${r['sub_key'] ?? ''}'.trim().toUpperCase(),
      }.where(_conceptCategoryBySubKey.containsKey).toList()
        ..sort();
      if (keys.isEmpty) return null;
      // 개념서는 익히기·확인체크·연습문제도 소단원마다 되풀이된다. 추출 런을
      // sub_key 단위로만 잡으면 (big, mid, sub_key, 0) 런이 하나뿐이라 두 번째
      // 소단원부터 "이미 처리된 런"으로 걸러진다. 쪽 범위가 있으면 소단원별로 나눈다.
      final perSubUnitRun = rawFrom != null && rawTo != null;
      return TextbookSubunitWorkOrder(
        academyId: widget.academyId,
        bookId: widget.bookId,
        bookName: widget.bookName,
        gradeLabel: widget.gradeLabel,
        seriesKey: _seriesKey,
        bigOrder: focus.bigIndex,
        midOrder: focus.midIndex,
        bigName: big.nameCtrl.text.trim(),
        midName: mid.nameCtrl.text.trim(),
        scopeKey: focus.subKey,
        label: _subFocusLabel(focus),
        bodyLinkId: widget.linkId,
        supportsExtraction: series.supportsProblemExtraction,
        extractRuns: [
          for (final k in keys)
            TextbookWorkflowExtractRun(
              subKey: k,
              subIndex: perSubUnitRun || _conceptPerSubUnitKeys.contains(k)
                  ? rowIndex
                  : 0,
              subName:
                  _conceptCategoryShortNames[_conceptCategoryBySubKey[k]] ?? k,
              rawPageFrom: rawFrom,
              rawPageTo: rawTo,
              displayPageFrom: displayStart,
              displayPageTo: displayEnd,
            ),
        ],
        stageRuns: [
          for (final s in _wonriStageScopesFor(
            focus,
            _buildStageCropSeeds(focus, state),
          ))
            _stageRunOf(s),
        ],
        reviewSubKeys: keys,
        indexedSubKeys: _conceptPerSubUnitKeys.toList()..sort(),
        reviewSubIndex: rowIndex,
        rawPageFrom: rawFrom,
        rawPageTo: rawTo,
      );
    }
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final displayStart = _positiveInt(sub.startCtrl.text);
    final displayEnd = _positiveInt(sub.endCtrl.text);
    return TextbookSubunitWorkOrder(
      academyId: widget.academyId,
      bookId: widget.bookId,
      bookName: widget.bookName,
      gradeLabel: widget.gradeLabel,
      seriesKey: _seriesKey,
      bigOrder: focus.bigIndex,
      midOrder: focus.midIndex,
      bigName: big.nameCtrl.text.trim(),
      midName: mid.nameCtrl.text.trim(),
      scopeKey: focus.subKey,
      label: _subFocusLabel(focus),
      bodyLinkId: widget.linkId,
      supportsExtraction: series.supportsProblemExtraction,
      extractRuns: [
        TextbookWorkflowExtractRun(
          subKey: focus.subKey,
          subName: sub.preset.displayName,
          rawPageFrom:
              displayStart == null ? null : _rawPageForDisplayPage(displayStart),
          rawPageTo:
              displayEnd == null ? null : _rawPageForDisplayPage(displayEnd),
          displayPageFrom: displayStart,
          displayPageTo: displayEnd,
        ),
      ],
      stageRuns: [_stageRunOf(_stageScopeFor(focus))],
      reviewSubKeys: [focus.subKey],
    );
  }

  bool _confirming = false;

  Future<void> _confirmCrops(List<_SubFocus> targets) async {
    if (_confirming) return;
    final candidates = [
      for (final f in targets)
        if (!_cropLocked(f)) f,
    ];
    if (candidates.isEmpty) {
      _toast('확정할 소단원이 없습니다 (이미 확정됨)');
      return;
    }
    final legacy = candidates.where(_isLegacy).length;
    final allLegacy = legacy == candidates.length;
    final ok = await _confirmDialog(
      title: allLegacy
          ? '이어서 마무리 · ${candidates.length}개 소단원'
          : '크롭 확정 · ${candidates.length}개 소단원'
              '${legacy > 0 ? ' (기존 추출 $legacy개 포함)' : ''}',
      message: [
        if (!allLegacy)
          '크롭을 확정하면 2단계가 바로 시작됩니다.\n'
              '본문 추출 → 정답·해설 위치 → V2 렌더·AI 검수 순서로 돌고, '
              '이 창을 닫아도 계속 진행됩니다.',
        if (legacy > 0)
          '${allLegacy ? '' : '기존 추출 $legacy개는 '}'
              '이미 뽑아 둔 본문을 그대로 두고, 본문이 빠진 번호만 추출한 뒤 '
              '정답·해설 위치 → V2 렌더·AI 검수로 이어갑니다.'
              '${allLegacy ? ' 이 창을 닫아도 계속 진행됩니다.' : ''}',
        '확정한 뒤 크롭을 고치려면 "크롭 다시 열기"를 누르세요.',
      ].join('\n'),
      confirmLabel: allLegacy ? '이어서 마무리' : '확정하고 시작',
    );
    if (!ok || !mounted) return;
    setState(() => _confirming = true);
    final started = <String>[];
    final problems = <String>[];
    try {
      for (final focus in candidates) {
        final label = _subFocusLabel(focus);
        final state = _ensureSubState(focus);
        _autoSaveTimers.remove(_stateKeyFor(focus))?.cancel();
        if (state.running) {
          problems.add('$label: 분석 중');
          continue;
        }
        for (var i = 0; i < 300 && state.uploading; i += 1) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (state.dirty) await _uploadFocused(focus, quiet: true);
        if (!mounted) return;
        if (state.dirty || (state.uploadResult?.rows ?? const []).isEmpty) {
          problems.add('$label: ${state.error ?? '저장된 크롭이 없습니다'}');
          continue;
        }
        final order = _workOrderFor(focus);
        if (order == null) {
          problems.add('$label: 작업 범위를 만들지 못했습니다');
          continue;
        }
        try {
          await _workflowService.confirmCrop(order);
          TextbookWorkflowRunner.instance.enqueue(order);
          started.add(label);
        } catch (e) {
          problems.add('$label: $e');
        }
      }
      await _loadWorkflows();
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (!mounted) return;
    if (started.isNotEmpty) {
      _toast('${allLegacy ? '이어서 마무리' : '크롭 확정'} ${started.length}개 · 2단계를 시작했습니다');
    }
    if (problems.isNotEmpty) {
      _toast('확정하지 못함: ${problems.join(' / ')}', error: true);
    }
  }

  bool _confirmingSubunits = false;

  /// 선택한 소단원이 모두 준비됨(2단계 끝 · 모든 카드 준비됨) 또는 확정이면 아직 확정 안 한 소단원 목록, 아니면 null.
  List<_SubFocus>? _subunitsToConfirm(List<_SubFocus> selected) {
    if (selected.isEmpty) return null;
    final todo = <_SubFocus>[];
    for (final f in selected) {
      final wf = _workflowFor(f);
      if (wf?.isConfirmed ?? false) continue;
      if (wf == null || !wf.cropConfirmed || wf.pipelineStatus != 'done') return null;
      if (_runStateFor(f)?.active ?? false) return null;
      final counts = _readyCounts(f);
      if (counts == null || counts.$2 == 0 || counts.$1 != counts.$2) return null;
      todo.add(f);
    }
    return todo;
  }

  /// 3단계 일괄 확정. 저장된 요약 대신 카드 상태를 다시 읽어 모든 카드가 준비됨인 소단원만 확정한다.
  Future<void> _confirmSubunits(List<_SubFocus> targets) async {
    if (_confirmingSubunits || targets.isEmpty) return;
    final ok = await _confirmDialog(
      title: '일괄 확정 · ${targets.length}개 소단원',
      message: '모든 카드가 준비됨인 소단원을 확정합니다.\n'
          '확정 직전에 카드 상태를 다시 확인하고, 준비됨이 아닌 카드가 생긴 소단원은 건너뜁니다.',
      confirmLabel: '확정',
    );
    if (!ok || !mounted) return;
    setState(() => _confirmingSubunits = true);
    final review = TextbookProblemReviewService();
    final itemsByMid = <String, List<TextbookProblemReviewItem>>{};
    final done = <String>[];
    final problems = <String>[];
    try {
      for (final focus in targets) {
        final label = _subFocusLabel(focus);
        final wf = _workflowFor(focus);
        final order = wf?.workOrder ?? _workOrderFor(focus);
        if (wf == null || order == null) {
          problems.add('$label: 작업 범위를 찾지 못했습니다');
          continue;
        }
        try {
          final midKey = '${order.bookId}|${order.gradeLabel}|${order.bigOrder}|${order.midOrder}';
          var all = itemsByMid[midKey] ??= await review.fetchUnitItems(order.reviewScope);
          var items = [for (final it in all) if (order.matches(it)) it];
          if (await review.reconcileBeforeConfirm(items) > 0) {
            all = itemsByMid[midKey] = await review.fetchUnitItems(order.reviewScope);
            items = [for (final it in all) if (order.matches(it)) it];
          }
          final ready = items.where((x) => x.isWorkflowReady).length;
          if (items.isEmpty || ready < items.length) {
            problems.add('$label: 준비됨 $ready/${items.length}');
            continue;
          }
          await _workflowService.confirmSubunit(wf, confirmed: true);
          await _registry.setScopeConfirmed(
            academyId: wf.academyId,
            bookId: wf.bookId,
            gradeLabel: wf.gradeLabel,
            scopeKey: wf.stateKey,
            confirmed: true,
          );
          done.add(label);
        } catch (e) {
          problems.add('$label: $e');
        }
      }
      await _loadWorkflows();
    } finally {
      if (mounted) setState(() => _confirmingSubunits = false);
    }
    if (!mounted) return;
    if (done.isNotEmpty) _toast('소단원 ${done.length}개를 확정했습니다');
    if (problems.isNotEmpty) _toast('확정하지 못함: ${problems.join(' / ')}', error: true);
  }

  Future<void> _reopenCrop(_SubFocus focus) async {
    final key = _workflowKeyFor(focus);
    final active = TextbookWorkflowRunner.instance.isActive(key);
    final ok = await _confirmDialog(
      title: '크롭 다시 열기',
      message: active
          ? '2단계가 진행 중입니다. 중단하고 크롭을 다시 열까요?\n'
              '이미 추출·검수한 결과는 남고, 다시 확정하면 빠진 것만 이어서 합니다.'
          : '크롭을 다시 고칠 수 있게 엽니다.\n'
              '이미 추출·검수한 결과는 남고, 다시 확정하면 빠진 것만 이어서 합니다.',
      confirmLabel: active ? '중단하고 열기' : '다시 열기',
      danger: active,
    );
    if (!ok || !mounted) return;
    if (active) TextbookWorkflowRunner.instance.cancel(key);
    try {
      await _workflowService.reopenCrop(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        bigOrder: focus.bigIndex,
        midOrder: focus.midIndex,
        scopeKey: focus.subKey,
      );
      await _loadWorkflows();
    } catch (e) {
      _toast('다시 열기 실패: $e', error: true);
    }
  }

  void _retryPipeline(_SubFocus focus) {
    final wf = _workflowFor(focus);
    final order = wf?.workOrder ?? _workOrderFor(focus);
    if (order == null) {
      _toast('작업 범위를 만들지 못했습니다. 크롭을 다시 저장하세요', error: true);
      return;
    }
    TextbookWorkflowRunner.instance.enqueue(
      order,
      fromPhase: TextbookWorkflowPhase.resumeFrom(wf?.pipelinePhase ?? ''),
      since: wf?.pipelineStartedAt,
    );
  }

  Future<void> _openWorkScreen(int bigIndex, int midIndex, {String? scopeKey}) async {
    await _flushAutoSaves();
    if (!mounted) return;
    final big = _bigUnits[bigIndex];
    final mid = big.middles[midIndex];
    final legacy = [
      for (final f in _midBatchFocuses(bigIndex, midIndex))
        if (_isLegacy(f))
          TextbookLegacySubunit(
            scopeKey: f.subKey,
            label: _subFocusLabel(f),
            bodies: _bodyCounts[_stateKeyFor(f)]?.bodies ?? 0,
            crops: _bodyCounts[_stateKeyFor(f)]?.crops ?? 0,
            reviewed: _bodyCounts[_stateKeyFor(f)]?.reviewed ?? 0,
          ),
    ];
    final picked = await showTextbookWorkflowDialog(
      context,
      academyId: widget.academyId,
      bookId: widget.bookId,
      bookName: widget.bookName,
      gradeLabel: widget.gradeLabel,
      bigOrder: bigIndex,
      midOrder: midIndex,
      unitTitle: [
        big.nameCtrl.text.trim(),
        mid.nameCtrl.text.trim(),
      ].where((s) => s.isNotEmpty).join(' › '),
      initialScopeKey: scopeKey,
      legacySubunits: legacy,
    );
    if (!mounted) return;
    unawaited(_loadWorkflows());
    unawaited(_loadStageStatuses());
    if (picked == null) return;
    final focus = _SubFocus(bigIndex: bigIndex, midIndex: midIndex, subKey: picked);
    setState(() {
      _focus = focus;
      _selectedProblemKey = null;
    });
    _jumpViewerToFocusStart(focus);
  }

  String _subFocusLabel(_SubFocus focus) {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final bigName = big.nameCtrl.text.trim().isEmpty
        ? '대${focus.bigIndex + 1}'
        : big.nameCtrl.text.trim();
    final midName = mid.nameCtrl.text.trim().isEmpty
        ? '중${focus.midIndex + 1}'
        : mid.nameCtrl.text.trim();
    if (_isWonriRowFocus(focus)) {
      final row = _wonriRowFor(focus);
      final rowName = row?.nameCtrl.text.trim() ?? '';
      return '$bigName/$midName/${rowName.isEmpty ? '소단원' : rowName}';
    }
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    return '$bigName/$midName/${sub.preset.displayName}';
  }

  /// 개념서 소단원 포커스 → 정답·해설 단계 스코프 목록.
  ///
  /// 정답·해설 시작 페이지는 **소단원 행**에서 입력한 하나의 값을 공유한다
  /// (쎈은 소단원=A/B/C 이지만 개념서는 소단원 안에 카테고리가 섞여 있어
  /// 소단원 단위로 한 번만 입력받는다).
  ///
  /// 어떤 슬롯을 펼칠지는 [seeds] 로 정한다. 시드는 본문 '풀이' 체이닝이
  /// 담당하는 문항(개념원리 필수유형·특강, 개념+유형 쓱쓱 예제)을 이미
  /// 걸러낸 목록이라, 슬롯 이름을 고정 나열하지 않아도 된다. 개념+유형의
  /// 쓱쓱(E)처럼 한 슬롯 안에 본문 문항(예제)과 답지 문항(유제·연습해 보자)이
  /// 섞여 있는 경우까지 이 방식이라야 맞는다.
  List<TextbookAuthoringStageScope> _wonriStageScopesFor(
    _SubFocus focus,
    List<TextbookAuthoringStageCropSeed> seeds,
  ) {
    final present = <String>{
      for (final seed in seeds)
        if (_conceptSubKeyByCategory[seed.section] != null)
          _conceptSubKeyByCategory[seed.section]!,
    };
    final row = _wonriRowFor(focus);
    if (row == null) return const <TextbookAuthoringStageScope>[];
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final rowName = row.nameCtrl.text.trim().isEmpty
        ? (row.isExercise ? '연습문제' : '소단원')
        : row.nameCtrl.text.trim();
    final solutionStart = _positiveInt(row.solutionStartCtrl.text);
    final solutionEnd = _wonriNextRowStageStart(focus, answer: false);
    // 개념+유형 고등은 정답 PDF 가 없어 해설 PDF 에서 정답도 읽는다.
    // 중등 개념원리는 단계 창이 따로 해설 범위로 정답을 읽으므로 그대로 둔다.
    final answersFromSolution = _seriesKey != 'wonri_middle' &&
        textbookSeriesAnswersFromSolutionPdf(_seriesKey);
    final answerStart = answersFromSolution
        ? solutionStart
        : _positiveInt(row.answerStartCtrl.text);
    final answerEnd = answersFromSolution
        ? solutionEnd
        : _wonriNextRowStageStart(focus, answer: true);
    final rowIndex = _wonriRowIndex(focus);
    final bodyStart = _positiveInt(row.startCtrl.text);
    final bodyEnd = _positiveInt(row.endCtrl.text);
    final subKeys = _conceptCategoryBySubKey.keys.toList()..sort();
    return [
      for (final subKey in subKeys)
        if (present.contains(subKey))
          TextbookAuthoringStageScope(
            bigOrder: focus.bigIndex,
            midOrder: focus.midIndex,
            subKey: subKey,
            bigName: big.nameCtrl.text.trim(),
            midName: mid.nameCtrl.text.trim(),
            subName:
                '$rowName · ${_conceptCategoryShortNames[_conceptCategoryBySubKey[subKey]] ?? subKey}',
            unitRowIndex: rowIndex,
            bodyStartPage: bodyStart,
            bodyEndPage: bodyEnd,
            answerStartPage: answerStart,
            answerEndPage: answerEnd,
            solutionStartPage: solutionStart,
            solutionEndPage: solutionEnd,
          ),
    ];
  }

  /// 개념원리 — 이 소단원 행 다음에 정답/해설 시작 페이지가 입력된 소단원
  /// 행의 시작 페이지. 정답·해설 스캔 끝 페이지 유도에 쓴다.
  int? _wonriNextRowStageStart(_SubFocus focus, {required bool answer}) {
    final wonriIndex = _wonriRowIndex(focus);
    if (wonriIndex == null) return null;
    final curRow = _wonriRowFor(focus);
    final currentStart = curRow == null
        ? null
        : _positiveInt(
            answer ? curRow.answerStartCtrl.text : curRow.solutionStartCtrl.text,
          );
    var passed = false;
    for (var b = 0; b < _bigUnits.length; b += 1) {
      for (var m = 0; m < _bigUnits[b].middles.length; m += 1) {
        final rows = _bigUnits[b].middles[m].subUnitRows;
        for (var i = 0; i < rows.length; i += 1) {
          final isCurrent =
              b == focus.bigIndex && m == focus.midIndex && i == wonriIndex;
          if (isCurrent) {
            passed = true;
            continue;
          }
          if (!passed) continue;
          final page = _positiveInt(answer
              ? rows[i].answerStartCtrl.text
              : rows[i].solutionStartCtrl.text);
          if (page == null) continue;
          if (currentStart != null && page < currentStart) continue;
          return page;
        }
      }
    }
    return null;
  }

  int? _wonriRowIndex(_SubFocus focus) {
    if (!_isWonriRowFocus(focus)) return null;
    final idx = int.tryParse(focus.subKey.substring(1));
    return idx;
  }

  TextbookAuthoringStageScope _stageScopeFor(_SubFocus focus) {
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    return TextbookAuthoringStageScope(
      bigOrder: focus.bigIndex,
      midOrder: focus.midIndex,
      subKey: focus.subKey,
      bigName: big.nameCtrl.text.trim(),
      midName: mid.nameCtrl.text.trim(),
      subName: sub.preset.displayName,
      answerStartPage: _positiveInt(sub.answerStartCtrl.text),
      answerEndPage: _stageEndPageFor(focus, answer: true),
      solutionStartPage: _positiveInt(sub.solutionStartCtrl.text),
      solutionEndPage: _stageEndPageFor(focus, answer: false),
    );
  }

  int? _stageEndPageFor(_SubFocus focus, {required bool answer}) {
    final nextStart = _nextStageStartPageAfter(focus, answer: answer);
    if (nextStart == null || nextStart <= 1) return null;
    // 마지막 문제가 다음 단원 시작 페이지와 섞여 있는 교재가 있어
    // 다음 단원 첫 페이지까지 포함해 스캔한다.
    return nextStart;
  }

  int? _nextStageStartPageAfter(_SubFocus focus, {required bool answer}) {
    var passed = false;
    int? currentStart;
    final currentPageFamily = textbookStagePageFamily(_seriesKey, focus.subKey);
    for (var b = 0; b < _bigUnits.length; b += 1) {
      final big = _bigUnits[b];
      for (var m = 0; m < big.middles.length; m += 1) {
        final mid = big.middles[m];
        for (final sub in mid.subs) {
          final isCurrent = b == focus.bigIndex &&
              m == focus.midIndex &&
              sub.preset.key == focus.subKey;
          final page = _positiveInt(
            answer ? sub.answerStartCtrl.text : sub.solutionStartCtrl.text,
          );
          if (isCurrent) {
            passed = true;
            currentStart = page;
            continue;
          }
          if (!passed) continue;
          if (page == null) continue;
          // 고쟁이는 본교재 해설(A~D)과 워크북 해설(E/F)이 PDF 안에서
          // 서로 멀리 떨어진 별도 묶음이다. D 다음에 트리상 E가 온다는 이유로
          // E 시작 쪽(실사례 140)을 D의 끝으로 쓰면 D가 45~140을 통째로
          // 훑으면서 다른 중단원 풀이를 자기 것으로 집어 온다.
          //
          // 같은 출처 묶음 안의 다음 시작 쪽만 끝 경계 후보로 사용한다.
          if (currentPageFamily.isNotEmpty &&
              textbookStagePageFamily(_seriesKey, sub.preset.key) !=
                  currentPageFamily) {
            continue;
          }
          // 답지 안의 차례가 단원트리 차례와 어긋나는 교재가 있다. 고쟁이는
          // 워크북 빠른 정답이 본문 빠른 정답 **뒤에** 몰려 있어서, 중단원 1의
          // 워크북 슬롯 다음에 오는 중단원 2의 본문 슬롯이 더 앞쪽 지면을
          // 가리킨다. 그걸 끝 경계로 삼으면 범위가 한 지면으로 접혀 그 묶음의
          // 정답을 하나도 못 찾는다. 뒤로 가는 후보는 건너뛰고 계속 찾는다.
          if (currentStart != null && page <= currentStart) continue;
          return page;
        }
      }
    }
    return null;
  }

  List<TextbookAuthoringStageCropSeed> _buildStageCropSeeds(
    _SubFocus focus,
    _SubRunState state,
  ) {
    final uploadRows =
        state.uploadResult?.rows ?? const <Map<String, dynamic>>[];
    if (uploadRows.isEmpty) return const <TextbookAuthoringStageCropSeed>[];
    if (_isWonriRowFocus(focus)) {
      return _buildWonriStageCropSeeds(focus, state, uploadRows);
    }
    final scope = _stageScopeFor(focus);
    final seedScopeLabel =
        '${scope.midName.trim().isEmpty ? '중${scope.midOrder + 1}' : scope.midName}/${scope.subName.trim().isEmpty ? scope.subKey : scope.subName}';
    final idByNumber = <String, String>{};
    for (final row in uploadRows) {
      final id = '${row['id'] ?? ''}'.trim();
      final number = '${row['problem_number'] ?? ''}'.trim();
      if (id.isNotEmpty && number.isNotEmpty) {
        idByNumber[number] = id;
      }
    }
    if (idByNumber.isEmpty) return const <TextbookAuthoringStageCropSeed>[];

    final seeds = <TextbookAuthoringStageCropSeed>[];
    _ResolvedContentGroup? lastBGroup;
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    for (final row in pageRows) {
      for (final item in row.items) {
        final id = idByNumber[item.number];
        if (id == null) continue;
        final rawGroup =
            _rawContentGroupForItem(item, focus.subKey, row.section);
        final carries = _carriesTypeGroup(focus.subKey);
        final group = carries && rawGroup.kind == 'none'
            ? (lastBGroup ?? rawGroup)
            : rawGroup;
        if (carries && rawGroup.kind == 'type') {
          lastBGroup = rawGroup;
        }
        seeds.add(TextbookAuthoringStageCropSeed(
          id: id,
          problemNumber: item.number,
          rawPage: row.rawPage,
          displayPage: row.displayPage,
          section: row.section,
          isSetHeader: item.isSetHeader,
          contentGroupKind: group.kind,
          contentGroupLabel: group.label,
          contentGroupTitle: group.title,
          contentGroupOrder: group.order,
          scopeLabel: seedScopeLabel,
          scopeKey: textbookStageScopeKey(scope),
        ));
      }
    }
    return seeds;
  }

  /// 개념원리 소단원 포커스용 시드 — 문항 번호가 카테고리마다 1부터 다시
  /// 시작하므로 `sub_key|번호` 복합 키로 업로드 행과 매칭한다.
  /// 필수유형(B)은 본문 체이닝으로 정답·풀이가 끝나 시드에서 제외한다.
  List<TextbookAuthoringStageCropSeed> _buildWonriStageCropSeeds(
    _SubFocus focus,
    _SubRunState state,
    List<Map<String, dynamic>> uploadRows,
  ) {
    final mid = _bigUnits[focus.bigIndex].middles[focus.midIndex];
    final midName = mid.nameCtrl.text.trim().isEmpty
        ? '중${focus.midIndex + 1}'
        : mid.nameCtrl.text.trim();
    final idByKey = <String, String>{};
    for (final row in uploadRows) {
      final id = '${row['id'] ?? ''}'.trim();
      final number = '${row['problem_number'] ?? ''}'.trim();
      final subKey = '${row['sub_key'] ?? ''}'.trim().toUpperCase();
      if (id.isNotEmpty && number.isNotEmpty && subKey.isNotEmpty) {
        idByKey['$subKey|$number'] = id;
      }
    }
    if (idByKey.isEmpty) return const <TextbookAuthoringStageCropSeed>[];

    final seeds = <TextbookAuthoringStageCropSeed>[];
    final pageRows = state.pageResults.where((r) => r.ok).toList()
      ..sort((a, b) => a.rawPage.compareTo(b.rawPage));
    final numberPrefixes = _gaeyuBlockNumberPrefixes(pageRows);
    final gaeyuHighLabels = _gaeyuHighExerciseLabels(pageRows);
    for (final row in pageRows) {
      for (var i = 0; i < row.items.length; i += 1) {
        final item = row.items[i];
        final category = _wonriCategoryOfItem(item, row.section);
        if (category.isEmpty) continue;
        final subKey = _conceptSubKeyByCategory[category]!;
        final detectedNumber = _conceptProblemNumber(
          numberPrefixes,
          subKey,
          row.rawPage,
          i,
          item.number,
        );
        final number = _seriesKey == 'wonri_middle'
            ? textbookWonriMiddleStoredProblemNumber(
                section: category,
                problemNumber: detectedNumber,
                itemRole: item.itemRole,
              )
            : detectedNumber;
        // 본문 "풀이" 단락이 딸린 문항(개념원리 필수유형·특강, 개념+유형 쓱쓱
        // 예제)은 본문 체인이 정답·풀이를 처리하므로 답지 PDF 기반
        // Stage 2/3 시드에서 제외한다.
        if (_isConceptBodySolutionItem(category, number)) continue;
        final id = idByKey['$subKey|$number'];
        if (id == null) continue;
        seeds.add(TextbookAuthoringStageCropSeed(
          id: id,
          problemNumber: number,
          rawPage: row.rawPage,
          displayPage: row.displayPage,
          section: category,
          isSetHeader: item.isSetHeader,
          itemName: _wonriItemName(
            category,
            _seriesKey == 'gaeyu_high'
                ? gaeyuHighLabels[_problemKey(row.rawPage, i)] ?? ''
                : item.label,
            itemRole: item.itemRole,
          ),
          scopeLabel:
              '$midName/${_conceptCategoryShortNames[category] ?? category}',
          scopeKey: textbookStageScopeKey(TextbookAuthoringStageScope(
            bigOrder: focus.bigIndex,
            midOrder: focus.midIndex,
            subKey: subKey,
            unitRowIndex: _wonriRowIndex(focus),
          )),
        ));
      }
    }
    return seeds;
  }

  /// 정답·풀이가 정답 파일이 아니라 **본문 지면**에 인쇄된 문항인지.
  ///
  /// 개념원리는 필수유형·특강 전체가 그렇고, 개념+유형은 쓱쓱 서술형
  /// 완성하기 중 "예제"만 그렇다 (유제·연습해 보자는 정답 파일에 있다).
  bool _isConceptBodySolutionItem(String category, String problemNumber) =>
      textbookConceptBodySolutionItem(_seriesKey, category, problemNumber);

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_manualDrawMode) {
          _toggleManualDraw();
          return;
        }
        unawaited(_close());
      },
      child: Dialog(
        backgroundColor: _kBg,
        insetPadding: const EdgeInsets.all(16),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: const BorderSide(color: _kBorder),
        ),
        child: SizedBox(
          width: size.width * 0.94,
          height: size.height * 0.94,
          child: _buildStage1Shell(),
        ),
      ),
    );
  }

  Widget _buildStage1Shell() {
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: _loadingPayload
              ? const Center(
                  child: CircularProgressIndicator(color: _kAccent),
                )
              : _payloadError != null
                  ? Center(
                      child: Text(
                        '단원 정보를 불러오지 못했습니다\n${_payloadError!}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: _kDanger,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : _buildMain(),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final running = _activeRunKeys.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
      decoration: const BoxDecoration(
        color: _kPanel,
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _kChipSelected,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.crop_rounded, color: _kText, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '단원·크롭',
                  style: TextStyle(
                    color: _kText,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.bookName} · ${widget.gradeLabel}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _kTextSub, fontSize: 12),
                ),
              ],
            ),
          ),
          _stepPill('1', '크롭 확인', active: true),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.chevron_right_rounded, size: 16, color: _kMuted),
          ),
          _stepPill('2', '추출·검수', active: false),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.chevron_right_rounded, size: 16, color: _kMuted),
          ),
          _stepPill('3', '확정', active: false),
          const SizedBox(width: 16),
          if (_loadingPdf)
            _statusPill(label: 'PDF 불러오는 중', color: _kInfo, busy: true),
          if (_pdfLoadError != null)
            Tooltip(
              message: _pdfLoadError!,
              child: _statusPill(
                label: 'PDF 오류',
                color: _kDanger,
                icon: Icons.warning_amber_rounded,
              ),
            ),
          if (running > 0)
            _statusPill(
              label: '2단계 진행 $running개',
              color: _kInfo,
              busy: true,
            ),
          if (_closing)
            _statusPill(label: '임시저장 마무리 중', color: _kWarn, busy: true),
          const SizedBox(width: 8),
          Tooltip(
            message: '대·중·소단원 이름과 쪽 범위를 저장합니다. '
                '크롭은 분석·수정할 때마다 자동으로 임시저장됩니다.',
            child: _pillButton(
              label: '단원 구조 저장',
              icon: Icons.save_outlined,
              onTap: _saveTree,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '닫기',
            onPressed: _closing ? null : () => unawaited(_close()),
            icon: const Icon(Icons.close_rounded, color: _kTextSub),
          ),
        ],
      ),
    );
  }

  Widget _stepPill(String number, String label, {required bool active}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      decoration: BoxDecoration(
        color: active ? _kChipSelected : _kCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: active ? _kAccent : _kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? _kAccent : _kPanel,
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: TextStyle(
                color: active ? _kText : _kMuted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: active ? _kText : _kMuted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill({
    required String label,
    required Color color,
    IconData? icon,
    bool busy = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
            )
          else if (icon != null)
            Icon(icon, size: 12, color: color),
          if (busy || icon != null) const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  /// 캡슐 버튼. [filled] 면 [color](기본 강조색) 바탕, 아니면 테두리만.
  /// 테두리 버튼에 [color] 를 주지 않으면 중립색.
  Widget _pillButton({
    required String label,
    IconData? icon,
    VoidCallback? onTap,
    bool filled = false,
    Color? color,
    bool busy = false,
  }) {
    final enabled = onTap != null && !busy;
    final tone = color ?? (filled ? _kAccent : _kTextSub);
    final Color fg;
    final Color bg;
    final Color border;
    if (!enabled) {
      fg = _kMuted;
      bg = filled ? _kCard : Colors.transparent;
      border = _kBorder;
    } else if (filled) {
      fg = _kText;
      bg = tone;
      border = Colors.transparent;
    } else {
      fg = tone;
      bg = Colors.transparent;
      border = color == null ? _kBorder : tone.withValues(alpha: 0.55);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8, color: fg),
                )
              else if (icon != null)
                Icon(icon, size: 16, color: fg),
              if (busy || icon != null) const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMain() {
    return Row(
      children: [
        SizedBox(width: 540, child: _buildLeftPane()),
        const VerticalDivider(width: 1, color: _kBorder),
        Expanded(child: _buildRightPane()),
      ],
    );
  }

  Widget _buildLeftPane() {
    final selectedCount = _batchSelection.length;
    return Container(
      color: _kPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '단원',
                    style: TextStyle(
                      color: _kText,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _pillButton(
                  label: '대단원',
                  icon: Icons.add_rounded,
                  onTap: () {
                    setState(() {
                      final newBig = _BigUnitEdit();
                      newBig.middles.add(
                        _MidUnitEdit(series: _currentSeries()),
                      );
                      _bigUnits.add(newBig);
                    });
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
            child: Row(
              children: [
                Expanded(child: _buildSeriesDropdown()),
                const SizedBox(width: 8),
                Tooltip(
                  message: '본문 PDF의 목차(차례) 페이지를 VLM 으로 읽어 단원 이름과 '
                      '페이지 범위를 자동으로 채웁니다.\n적용 후 "단원 구조 저장"을 '
                      '눌러야 반영됩니다.',
                  child: _pillButton(
                    label: '목차 자동 인식',
                    icon: Icons.auto_awesome_outlined,
                    busy: _tocParsing,
                    onTap: _runTocAutoParse,
                  ),
                ),
              ],
            ),
          ),
          if (_tocStatus?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
              child: Text(
                _tocStatus!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _tocStatus!.startsWith('실패') ? _kDanger : _kTextSub,
                  fontSize: 11,
                ),
              ),
            ),
          if (selectedCount > 0)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                color: _kChipSelected.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _kAccent.withValues(alpha: 0.45)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '선택 $selectedCount개',
                          style: const TextStyle(
                            color: _kText,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _batchRunning
                            ? null
                            : () => setState(_batchSelection.clear),
                        child: const Text(
                          '선택 해제',
                          style: TextStyle(color: _kTextSub, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  _buildBatchActions(_selectedBatchFocuses()),
                ],
              ),
            ),
          if (_batchRunning || _batchStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_batchTotal > 0)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _batchRunning ? _batchDone / _batchTotal : 1,
                        minHeight: 4,
                        backgroundColor: _kCard,
                        color: _kAccent,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    _batchStatus,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _kTextSub, fontSize: 11),
                  ),
                ],
              ),
            ),
          const Divider(height: 1, color: _kBorder),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              itemCount: _bigUnits.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) => _buildBigUnit(i),
            ),
          ),
        ],
      ),
    );
  }

  TextbookSeriesCatalogEntry _currentSeries() =>
      textbookSeriesByKey(_seriesKey) ?? kTextbookSeriesCatalog.first;

  /// 교재 시리즈 선택. 위저드를 거치지 않고(신규행 추가 등) 만들어진 책은
  /// payload 에 series 가 없어 기본값(쎈)으로 열리므로, 여기서 바꿔서
  /// "단원 구조 저장"으로 함께 저장할 수 있게 한다.
  Widget _buildSeriesDropdown() {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: textbookSeriesByKey(_seriesKey) == null
              ? kTextbookSeriesCatalog.first.key
              : _seriesKey,
          dropdownColor: _kCard,
          isExpanded: true,
          isDense: true,
          style: const TextStyle(color: _kText, fontSize: 12),
          items: [
            for (final entry in kTextbookSeriesCatalog)
              DropdownMenuItem<String>(
                value: entry.key,
                child: Text('시리즈: ${entry.displayName}'),
              ),
          ],
          onChanged: _tocParsing
              ? null
              : (value) {
                  if (value == null || value == _seriesKey) return;
                  setState(() {
                    _seriesKey = value;
                    final entry = _currentSeries();
                    // 새 시리즈의 A~D 슬롯 프리셋으로 재구성한다.
                    // (같은 키의 슬롯에 입력된 페이지는 유지)
                    for (final big in _bigUnits) {
                      for (final mid in big.middles) {
                        mid.applyPreset(entry);
                      }
                    }
                    _focus = null;
                    _selectedProblemKey = null;
                  });
                },
        ),
      ),
    );
  }

  Widget _buildBigUnit(int i) {
    final big = _bigUnits[i];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _pill(text: '대 ${i + 1}', color: _kChipSelected, fg: _kText),
              const SizedBox(width: 8),
              Expanded(
                child: _textInput(big.nameCtrl, hint: '대단원 이름'),
              ),
              IconButton(
                tooltip: '중단원 추가',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  setState(() {
                    big.middles.add(
                      _MidUnitEdit(series: _currentSeries()),
                    );
                  });
                },
                icon: const Icon(Icons.add, size: 14, color: _kTextSub),
              ),
              IconButton(
                tooltip: '대단원 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: _bigUnits.length == 1
                    ? null
                    : () {
                        setState(() {
                          _bigUnits[i].dispose();
                          _bigUnits.removeAt(i);
                          if (_focus != null &&
                              _focus!.bigIndex >= _bigUnits.length) {
                            _focus = null;
                          }
                        });
                      },
                icon: const Icon(Icons.close, size: 13, color: _kTextSub),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var m = 0; m < big.middles.length; m += 1) ...[
            _buildMidUnit(i, m),
            if (m < big.middles.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildMidUnit(int bigIndex, int midIndex) {
    final mid = _bigUnits[bigIndex].middles[midIndex];
    final focuses = _midBatchFocuses(bigIndex, midIndex).where((f) {
      final (start, end) = _focusRange(f);
      return start != null && end != null;
    }).toList();
    final cropConfirmed =
        focuses.where((f) => _workflowFor(f)?.cropConfirmed ?? false).length;
    final stages = [for (final f in focuses) _stageOf(f)];
    int countOf(TextbookSubunitStage s) => stages.where((x) => x == s).length;
    final confirmed = countOf(TextbookSubunitStage.confirmed);
    final inProgress = countOf(TextbookSubunitStage.inProgress);
    final reviewed = countOf(TextbookSubunitStage.reviewed);
    final legacy = countOf(TextbookSubunitStage.legacy);
    final stageText = [
      '확정 $confirmed',
      if (inProgress > 0) '진행 $inProgress',
      if (reviewed > 0) '검수 완료 $reviewed',
      if (legacy > 0) '기존 추출 $legacy',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _kPanel,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Checkbox(
                value: _midBatchValue(bigIndex, midIndex),
                tristate: true,
                onChanged: _batchRunning
                    ? null
                    : (value) => _toggleBatchMid(
                          bigIndex,
                          midIndex,
                          value != false,
                        ),
                visualDensity: VisualDensity.compact,
                side: const BorderSide(color: _kTextSub),
                activeColor: _kAccent,
              ),
              _pill(
                text: '중 ${midIndex + 1}',
                color: _kInfo.withValues(alpha: 0.16),
                fg: _kInfo,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _textInput(
                  mid.nameCtrl,
                  hint: '중단원 이름',
                  // 고쟁이는 "대단원 TEST" 로 이름을 고쳐 쓰면 그 행이 F 슬롯만
                  // 갖는 대단원 끝 행으로 바뀐다.
                  onChanged: _syncTrailingMidSlots,
                ),
              ),
              IconButton(
                tooltip: '중단원 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: _bigUnits[bigIndex].middles.length == 1
                    ? null
                    : () {
                        setState(() {
                          _bigUnits[bigIndex].middles[midIndex].dispose();
                          _bigUnits[bigIndex].middles.removeAt(midIndex);
                          if (_focus != null &&
                              _focus!.bigIndex == bigIndex &&
                              _focus!.midIndex >=
                                  _bigUnits[bigIndex].middles.length) {
                            _focus = null;
                          }
                        });
                      },
                icon: const Icon(Icons.close, size: 12, color: _kTextSub),
              ),
            ],
          ),
          if (focuses.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$stageText / ${focuses.length}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: confirmed == focuses.length
                            ? _kAccent
                            : _kTextSub,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (cropConfirmed > 0)
                    TextButton.icon(
                      onPressed: () => _openWorkScreen(bigIndex, midIndex),
                      icon: const Icon(
                        Icons.view_agenda_outlined,
                        size: 14,
                        color: _kAccent,
                      ),
                      label: const Text(
                        '작업 화면',
                        style: TextStyle(
                          color: _kAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          if (_currentSeries().hasSubUnitRows) ...[
            // 특강(E)은 편집 payload 밖의 정규화 유닛이지만, 학습/학생앱과
            // 동일한 물리 페이지 순서로 읽기 전용 표시한다.
            if (_specialUnitByMid['$bigIndex|$midIndex'] case final special?)
              _buildSpecialUnitRow(special),
            // 개념서: 트리에는 책의 실제 소단원 행을 이어서 보여준다.
            // 분석 단위도 소단원 행이다 — 행을 누르면 그 페이지 범위를
            // 단일 패스로 분석하고, 문항은 카테고리별로 자동 분류된다.
            for (var s = 0; s < mid.subUnitRows.length; s += 1)
              _buildSubUnitRow(bigIndex, midIndex, mid, s),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () =>
                      setState(() => mid.subUnitRows.add(_SubUnitRowEdit())),
                  icon: const Icon(Icons.add, size: 13, color: _kTextSub),
                  label: const Text('소단원 추가',
                      style: TextStyle(color: _kTextSub, fontSize: 10)),
                ),
                if (_currentSeries().unitEndRowName.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => setState(() => mid.subUnitRows.add(
                          _SubUnitRowEdit(
                            name: _currentSeries().unitEndRowName,
                            isExercise: true,
                          ),
                        )),
                    icon:
                        const Icon(Icons.add_task, size: 13, color: _kTextSub),
                    label: Text('${_currentSeries().unitEndRowName} 추가',
                        style: const TextStyle(color: _kTextSub, fontSize: 10)),
                  ),
              ],
            ),
          ] else ...[
            for (final sub in mid.subs) _buildSubRow(bigIndex, midIndex, sub),
          ],
        ],
      ),
    );
  }

  Widget _buildSpecialUnitRow(_SpecialUnitView special) {
    final pageText = special.startPage == special.endPage
        ? '${special.startPage}쪽'
        : '${special.startPage}-${special.endPage}쪽';
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: _kWarn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kWarn.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: _kWarn.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Text(
              '특강',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _kWarn,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              special.name,
              style: const TextStyle(
                color: _kText,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            pageText,
            style: const TextStyle(
              color: _kTextSub,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 개념원리 전용 — 책의 실제 소단원 한 행 (이름 + 시작/끝 페이지 + 삭제).
  /// 행을 누르면 이 소단원 페이지 범위가 분석 패널의 작업 단위가 된다.
  /// 페이지를 고치면 A~D 카테고리 슬롯 범위가 자동으로 다시 계산된다.
  Widget _buildSubUnitRow(
    int bigIndex,
    int midIndex,
    _MidUnitEdit mid,
    int index,
  ) {
    final row = mid.subUnitRows[index];
    final focus = _SubFocus(
      bigIndex: bigIndex,
      midIndex: midIndex,
      subKey: 'W$index',
    );
    final key = _stateKeyFor(focus);
    final selected = _focus != null && _stateKeyFor(_focus!) == key;
    final batchSelected = _batchSelection.contains(key);
    final state = _subStates[key];
    final analyzed = state == null
        ? 0
        : state.pageResults.where((r) => r.ok).fold<int>(
              0,
              (sum, r) =>
                  sum +
                  r.items
                      .where((it) => (it.itemRegion?.length ?? 0) == 4)
                      .length,
            );
    final uploaded = state?.uploadResult?.upserted ?? 0;
    final isRunning = state?.running == true || state?.uploading == true;
    // 정답·해설 진행 배지는 중단원의 카테고리(A/C/D/B) 상태를 합쳐 보여준다
    // (개념원리는 카테고리 단위로 저장되므로 소단원 행은 그 합계를 반영).
    final stageStatus = _wonriRowStageStatus(focus);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        color: selected
            ? _kChipSelected.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? _kAccent.withValues(alpha: 0.45) : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          setState(() {
            _focus = focus;
            _selectedProblemKey = null;
          });
          _jumpViewerToFocusStart(focus);
        },
        child: Column(
          children: [
            Row(
              children: [
                Checkbox(
                  value: batchSelected,
                  onChanged: _batchRunning
                      ? null
                      : (value) => _toggleBatchSub(focus, value == true),
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(color: _kTextSub),
                  activeColor: _kAccent,
                ),
                Container(
                  width: 44,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  decoration: BoxDecoration(
                    color: (row.isExercise ? _kWarn : _kAccent)
                        .withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    row.isExercise ? '연습' : '소단원',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: row.isExercise ? _kWarn : _kAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  flex: 3,
                  child: _textInput(
                    row.nameCtrl,
                    hint: row.isExercise ? '연습문제' : '소단원 이름',
                    dense: true,
                  ),
                ),
                const SizedBox(width: 4),
                _buildWorkflowChip(focus),
                const SizedBox(width: 4),
                Expanded(
                  flex: 2,
                  child: _StageProgressChip(
                    status: stageStatus,
                    loading: _loadingStageStatuses,
                    onTap: () => _showStageStatusDialog(focus),
                  ),
                ),
                IconButton(
                  tooltip: '소단원 삭제',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    // 행을 지우면 뒤 소단원의 W 번호가 당겨져 확정 기록과 어긋난다.
                    final locked = _midBatchFocuses(bigIndex, midIndex)
                        .skip(index)
                        .any(_cropLocked);
                    if (locked) {
                      _toast(
                        '이 행이나 아래 행에 크롭을 확정한 소단원이 있어 지울 수 없습니다. '
                        '먼저 "크롭 다시 열기"를 하세요',
                        error: true,
                      );
                      return;
                    }
                    _removeSubUnitRow(bigIndex, midIndex, mid, index);
                  },
                  icon: const Icon(Icons.close, size: 12, color: _kTextSub),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 38),
                Expanded(
                  child: _textInput(
                    row.startCtrl,
                    hint: '시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: () => _recalcSubUnitSlotPages(mid),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _textInput(
                    row.endCtrl,
                    hint: '끝',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: () => _recalcSubUnitSlotPages(mid),
                  ),
                ),
                const SizedBox(width: 6),
                _SubRowStats(
                  analyzed: analyzed,
                  uploaded: uploaded,
                  running: isRunning,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 38),
                if (!textbookSeriesAnswersFromSolutionPdf(_seriesKey)) ...[
                  Expanded(
                    child: _textInput(
                      row.answerStartCtrl,
                      hint: '정답 시작',
                      dense: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: _textInput(
                    row.solutionStartCtrl,
                    hint: textbookSeriesAnswersFromSolutionPdf(_seriesKey)
                        ? '해설(정답 포함) 시작'
                        : '해설 시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 58),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _removeSubUnitRow(
    int bigIndex,
    int midIndex,
    _MidUnitEdit mid,
    int index,
  ) {
    setState(() {
      mid.subUnitRows.removeAt(index).dispose();
      _recalcSubUnitSlotPages(mid);
      // 행 삭제로 W 인덱스가 밀리므로 이 중단원의 소단원 상태는
      // 통째로 버린다 (저장된 영역은 DB에 남아 재복원 가능).
      final prefix = '$bigIndex/$midIndex/W';
      _subStates.removeWhere((k, _) => k.startsWith(prefix));
      _manualEdits.removeWhere((k, _) => k.startsWith(prefix));
      _batchSelection.removeWhere((k) => k.startsWith(prefix));
      for (final k in _autoSaveTimers.keys.toList()) {
        if (k.startsWith(prefix)) _autoSaveTimers.remove(k)?.cancel();
      }
      if (_focus != null &&
          _focus!.bigIndex == bigIndex &&
          _focus!.midIndex == midIndex &&
          _focus!.subKey.startsWith('W')) {
        _focus = null;
      }
    });
  }

  /// (준비됨, 전체) — 방금 끝난 실행 결과 → 지금 카드 상태 → DB 에 남은 요약 문구 순으로 읽는다.
  (int, int)? _readyCounts(_SubFocus focus) {
    final run = _runStateFor(focus);
    final live = _liveReady[_stateKeyFor(focus)];
    final runFresh = run != null &&
        run.total > 0 &&
        (live == null ||
            _liveReadyAt == null ||
            (run.finishedAt?.isAfter(_liveReadyAt!) ?? true));
    if (runFresh) return (run.ready, run.total);
    if (live != null) return live;
    final m = RegExp(r'준비됨 (\d+)/(\d+)')
        .firstMatch(_workflowFor(focus)?.pipelineDetail ?? '');
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  /// 소단원 행의 1·2단계 상태 배지.
  Widget _buildWorkflowChip(_SubFocus focus) {
    final wf = _workflowFor(focus);
    final run = _runStateFor(focus);
    final state = _subStates[_stateKeyFor(focus)];
    String? label;
    var color = _kMuted;
    var busy = false;
    var tip = '';
    if (wf?.isConfirmed ?? false) {
      label = '확정';
      color = _kAccent;
      tip = '모든 문항이 준비됨이라 확정했습니다';
    } else if (run != null && run.active) {
      label = TextbookWorkflowPhase.label(run.phase);
      color = _kInfo;
      busy = true;
      tip = run.detail;
    } else if (wf != null && wf.cropConfirmed) {
      switch (wf.pipelineStatus) {
        case 'done':
          final counts = _readyCounts(focus);
          final allReady = counts != null && counts.$2 > 0 && counts.$1 == counts.$2;
          label = counts == null
              ? '2단계 완료'
              : allReady
                  ? '준비됨 ${counts.$2}'
                  : '준비 ${counts.$1}/${counts.$2}';
          color = allReady ? _kAccent : _kWarn;
          tip = run?.summaryText ?? wf.pipelineDetail;
        case 'failed':
          label = '2단계 실패';
          color = _kDanger;
          tip = wf.pipelineError.isEmpty ? wf.pipelineDetail : wf.pipelineError;
        case 'queued':
        case 'running':
          label = '2단계 대기';
          color = _kInfo;
          tip = '이 앱에서 이어서 돌릴 차례를 기다립니다';
        default:
          label = '2단계 중단';
          color = _kWarn;
          tip = wf.pipelineDetail;
      }
    } else if (state != null && state.dirty) {
      label = '저장 전';
      color = _kWarn;
      tip = '분석·수정한 크롭이 아직 임시저장되지 않았습니다';
    } else if (_isLegacy(focus)) {
      final counts = _bodyCounts[_stateKeyFor(focus)];
      final allReviewed = _stageOf(focus) == TextbookSubunitStage.reviewed;
      final reviewedText = counts == null || counts.reviewed == 0
          ? ''
          : ' · 검수 ${counts.reviewed}/${counts.bodies}';
      label = allReviewed ? '검수 완료' : '기존 추출$reviewedText';
      color = allReviewed ? _kAccent : _kTextSub;
      tip = allReviewed
          ? '예전 흐름에서 본문이 붙은 문항을 모두 검수(정답·품질 승인)했습니다'
              '${counts == null ? '' : ' · 본문 ${counts.bodies}/${counts.crops}'}. '
              '"이어서 마무리"를 누르면 검수 결과는 그대로 두고 빈 단계만 채운 뒤 확정할 수 있습니다'
          : '예전에 본문(+정답)만 뽑아 둔 소단원입니다'
              '${counts == null ? '' : ' · 본문 ${counts.bodies}/${counts.crops}$reviewedText'}. '
              '"이어서 마무리"를 누르면 본문과 검수 결과는 그대로 두고 다음 단계부터 진행합니다';
    } else if ((wf?.cropStatus ?? 'none') == 'draft' ||
        (state?.uploadResult?.rows.isNotEmpty ?? false)) {
      label = '임시저장';
      tip = '크롭이 임시저장돼 있습니다. 확인한 뒤 "크롭 확정"을 누르세요';
    }
    if (label == null) return const SizedBox.shrink();
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.4, color: color),
            ),
            const SizedBox(width: 4),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 148),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    // 행마다 다시 그려지는 칩이라 Tooltip 오버레이 대신 접근성 라벨만 단다
    // (단원 트리 갱신 프레임에 Tooltip 이 MouseTracker assertion 을 일으킨 적이 있다).
    return Semantics(
      label: tip.isEmpty ? label : '$label. $tip',
      child: (wf?.cropConfirmed ?? false)
          ? InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _openWorkScreen(
                focus.bigIndex,
                focus.midIndex,
                scopeKey: focus.subKey,
              ),
              child: chip,
            )
          : chip,
    );
  }

  /// 개념원리 소단원 행의 정답·해설 진행 배지용 합계 상태.
  /// 카테고리(A/B/C/D)별 스테이지 상태를 합쳐 하나로 만든다. 없으면 null.
  TextbookStageScopeStatus? _wonriRowStageStatus(_SubFocus focus) {
    final direct = _stageStatusBySub[_stateKeyFor(focus)];
    if (direct != null) return direct;

    // 이전 버전에서 불러온 상태가 카테고리 키(A~E)에만 남아 있을 수 있어
    // 다이얼로그를 닫지 않은 세션에서는 한 번 더 기존 방식으로 보완한다.
    var found = false;
    var bd = 0, bt = 0, ad = 0, at = 0, sd = 0, st = 0;
    for (final k in _conceptCategoryBySubKey.keys) {
      final s = _stageStatusBySub[_stateKeyFor(_SubFocus(
        bigIndex: focus.bigIndex,
        midIndex: focus.midIndex,
        subKey: k,
      ))];
      if (s == null) continue;
      found = true;
      bd += s.bodyDone;
      bt += s.bodyTotal;
      ad += s.answerDone;
      at += s.answerTotal;
      sd += s.solutionDone;
      st += s.solutionTotal;
    }
    if (!found) return null;
    return TextbookStageScopeStatus(
      bigOrder: focus.bigIndex,
      midOrder: focus.midIndex,
      subKey: 'W',
      bodyDone: bd,
      bodyTotal: bt,
      answerDone: ad,
      answerTotal: at,
      solutionDone: sd,
      solutionTotal: st,
    );
  }

  // 쎈/RPM 전용 — 개념원리(wonri)는 트리에 카테고리 행을 그리지 않는다
  // (분석 패널의 카테고리 칩으로 대체).
  Widget _buildSubRow(int bigIndex, int midIndex, _SubSectionEdit sub) {
    final focus = _SubFocus(
      bigIndex: bigIndex,
      midIndex: midIndex,
      subKey: sub.preset.key,
    );
    final selected = _focus != null &&
        _focus!.bigIndex == focus.bigIndex &&
        _focus!.midIndex == focus.midIndex &&
        _focus!.subKey == focus.subKey;
    final batchSelected = _batchSelection.contains(_stateKeyFor(focus));
    final state = _subStates[_stateKeyFor(focus)];
    final analyzed = state == null
        ? 0
        : state.pageResults.where((r) => r.ok).fold<int>(
              0,
              (sum, row) =>
                  sum +
                  row.items
                      .where((it) => (it.itemRegion?.length ?? 0) == 4)
                      .length,
            );
    final uploaded = state?.uploadResult?.upserted ?? 0;
    final isRunning = state?.running == true || state?.uploading == true;
    final key = _stateKeyFor(focus);
    final pbStatus = _pbExtractStatusBySub[key] ?? '';
    final stageStatus = _stageStatusBySub[key];
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        color: selected
            ? _kChipSelected.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? _kAccent.withValues(alpha: 0.45) : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          setState(() {
            _focus = focus;
            _selectedProblemKey = null;
          });
          _jumpViewerToFocusStart(focus);
        },
        child: Column(
          children: [
            Row(
              children: [
                Checkbox(
                  value: batchSelected,
                  onChanged: _batchRunning
                      ? null
                      : (value) => _toggleBatchSub(focus, value == true),
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(color: _kTextSub),
                  activeColor: _kAccent,
                ),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 72, maxWidth: 168),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _kWarn.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        sub.preset.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _kWarn,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _buildWorkflowChip(focus),
                const SizedBox(width: 4),
                Expanded(
                  child: _StageProgressChip(
                    status: stageStatus,
                    loading: _loadingStageStatuses,
                    onTap: () => _showStageStatusDialog(focus),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 38),
                Expanded(
                  child: _textInput(
                    sub.startCtrl,
                    hint: '시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _textInput(
                    sub.endCtrl,
                    hint: '끝',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 6),
                _SubRowStats(
                  analyzed: analyzed,
                  uploaded: uploaded,
                  running: isRunning,
                ),
                if (pbStatus.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  _PbExtractStatusChip(status: pbStatus),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 38),
                Expanded(
                  child: _textInput(
                    sub.answerStartCtrl,
                    hint: '정답 시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _textInput(
                    sub.solutionStartCtrl,
                    hint: '해설 시작',
                    dense: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 82),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showStageStatusDialog(_SubFocus focus) async {
    await _loadStageStatuses();
    if (!mounted) return;
    final status = _isWonriRowFocus(focus)
        ? _wonriRowStageStatus(focus)
        : _stageStatusBySub[_stateKeyFor(focus)];
    final title = _subFocusLabel(focus);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: _kPanel,
          title: Text(
            '$title 추출 상태',
            style: const TextStyle(color: _kText, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StageStatusDialogRow(
                  label: '본문',
                  description: '문항 영역 좌표',
                  done: status?.bodyDone ?? 0,
                  total: status?.bodyTotal ?? 0,
                  dangerHint: '본문 삭제 시 정답·해설·문제은행 문서도 함께 삭제',
                  onDelete: () {
                    Navigator.of(ctx).pop();
                    _confirmDeleteStage(focus, 'body');
                  },
                ),
                const SizedBox(height: 8),
                _StageStatusDialogRow(
                  label: '정답',
                  description: '정답 VLM 및 이미지 크롭',
                  done: status?.answerDone ?? 0,
                  total: status?.answerTotal ?? 0,
                  dangerHint: '정답 삭제 시 해설도 함께 삭제',
                  onDelete: (status?.bodyDone ?? 0) == 0
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          _confirmDeleteStage(focus, 'answer');
                        },
                ),
                const SizedBox(height: 8),
                _StageStatusDialogRow(
                  label: '해설',
                  description: '해설 번호/본문 좌표',
                  done: status?.solutionDone ?? 0,
                  total: status?.solutionTotal ?? 0,
                  dangerHint: '해설 좌표만 삭제',
                  onDelete: (status?.bodyDone ?? 0) == 0
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          _confirmDeleteStage(focus, 'solution');
                        },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('닫기'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDeleteStage(_SubFocus focus, String stage) async {
    if (TextbookWorkflowRunner.instance.isActive(_workflowKeyFor(focus))) {
      _toast('2단계가 진행 중이라 지울 수 없습니다. 먼저 "크롭 다시 열기"로 중단하세요',
          error: true);
      return;
    }
    final label = switch (stage) {
      'body' => '본문',
      'answer' => '정답',
      'solution' => '해설',
      _ => stage,
    };
    final detail = switch (stage) {
      'body' => '본문 영역, 정답, 해설, 연결된 문제은행 문서를 모두 서버에서 영구 삭제합니다.',
      'answer' => '정답과 해설 좌표를 서버에서 영구 삭제합니다.',
      'solution' => '해설 좌표만 서버에서 영구 삭제합니다.',
      _ => '선택한 데이터를 서버에서 영구 삭제합니다.',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        title: Text(
          '$label 삭제',
          style: const TextStyle(color: _kText, fontWeight: FontWeight.w800),
        ),
        content: Text(
          '$detail\n대상 소단원: ${focus.subKey}\n되돌릴 수 없습니다.',
          style: const TextStyle(color: _kTextSub, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: _kDanger),
            child: const Text('영구 삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final scope = _stageScopePayload(focus);
      final result = await _pdfService.deleteStageData(
        academyId: widget.academyId,
        bookId: widget.bookId,
        gradeLabel: widget.gradeLabel,
        bigOrder: focus.bigIndex,
        midOrder: focus.midIndex,
        subKey: focus.subKey,
        subIndex: (scope['sub_index'] as num?)?.toInt() ?? 0,
        stage: stage,
        scopeKind: scope['scope_kind']?.toString(),
        unitRowIndex: (scope['unit_row_index'] as num?)?.toInt(),
        bodyStartPage: (scope['body_start_page'] as num?)?.toInt(),
        bodyEndPage: (scope['body_end_page'] as num?)?.toInt(),
      );
      if (!mounted) return;
      if (stage == 'body') {
        _subStates.remove(_stateKeyFor(focus));
        _manualEdits.remove(_stateKeyFor(focus));
        // 개념서: 카테고리 크롭 삭제는 소단원(W) 작업 상태에도 반영돼야
        // 하므로 이 중단원의 W 상태를 모두 비운다.
        if (_currentSeries().hasSubUnitRows) {
          final prefix = '${focus.bigIndex}/${focus.midIndex}/W';
          _subStates.removeWhere((k, _) => k.startsWith(prefix));
          _manualEdits.removeWhere((k, _) => k.startsWith(prefix));
        }
      }
      final affected = result.affectedSubKeys.isEmpty
          ? focus.subKey
          : result.affectedSubKeys.join(', ');
      _toast('$label 삭제 완료 · 대상 $affected');
      if (result.warnings.isNotEmpty) {
        debugPrint('[textbook-stage-delete] warnings: ${result.warnings}');
      }
      if (stage == 'body' && (_workflowFor(focus)?.cropConfirmed ?? false)) {
        await _workflowService.reopenCrop(
          academyId: widget.academyId,
          bookId: widget.bookId,
          gradeLabel: widget.gradeLabel,
          bigOrder: focus.bigIndex,
          midOrder: focus.midIndex,
          scopeKey: focus.subKey,
        );
        await _loadWorkflows();
      }
      await _loadExistingCrops();
      await _loadStageStatuses();
    } catch (e) {
      if (!mounted) return;
      _toast('$label 삭제 실패: $e', error: true);
    }
  }

  void _jumpViewerToFocusStart(_SubFocus focus) {
    final (start, _) = _focusRange(focus);
    if (start == null) return;
    if (!_viewerController.isReady) return;
    final pageCount = _bodyDocument?.pages.length ?? 0;
    if (pageCount <= 0) return;
    final targetPage = _rawPageForDisplayPage(start).clamp(1, pageCount);
    try {
      _viewerController.goToPage(pageNumber: targetPage);
    } catch (_) {
      // Best-effort; pdfrx throws if the page number is out of range.
    }
  }

  Widget _buildRightPane() {
    final focus = _focus;
    if (focus == null) {
      final selected = _selectedBatchFocuses();
      if (selected.isNotEmpty) {
        return _buildBatchSelectionPane(selected);
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _currentSeries().hasSubUnitRows
                ? '왼쪽에서 소단원 행을 선택하면 분석 패널이 열립니다.\n'
                    '분석 한 번으로 '
                    '${_currentSeries().subPreset.map((p) => p.displayName).join('·')}'
                    '가 자동 분류됩니다.'
                : '왼쪽에서 소단원(A/B/C)을 선택하면 분석 패널이 열립니다.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kTextSub, fontSize: 13),
          ),
        ),
      );
    }
    final state = _ensureSubState(focus);
    final big = _bigUnits[focus.bigIndex];
    final mid = big.middles[focus.midIndex];
    final sub = mid.subs.firstWhere(
      (s) => s.preset.key == focus.subKey,
      orElse: () => mid.subs.first,
    );
    final wonriRow = _wonriRowFor(focus);
    final focusName = wonriRow != null
        ? (wonriRow.nameCtrl.text.trim().isEmpty
            ? (wonriRow.isExercise ? '연습문제' : '소단원')
            : wonriRow.nameCtrl.text.trim())
        : sub.preset.displayName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  '${big.nameCtrl.text.trim().isEmpty ? "대${focus.bigIndex + 1}" : big.nameCtrl.text.trim()} '
                  '› ${mid.nameCtrl.text.trim().isEmpty ? "중${focus.midIndex + 1}" : mid.nameCtrl.text.trim()} '
                  '› $focusName',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kText,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildWorkflowChip(focus),
            ],
          ),
        ),
        // 개념원리: 소단원 페이지를 한 번만 분석하면 문항이 개념원리 익히기 /
        // 필수유형 / 확인 체크 / 연습문제로 자동 분류돼 문항이름으로 저장된다.
        // 정답·해설 시작 페이지는 왼쪽 소단원 행에서 입력한다 (쎈과 동일).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: _buildSubControls(focus, state, sub),
        ),
        if (state.progress != null) _buildProgressRow(state),
        Expanded(child: _buildViewerArea(focus, state)),
      ],
    );
  }

  Widget _buildBatchSelectionPane(List<_SubFocus> selected) {
    final totalReady = selected.fold<int>(
      0,
      (sum, focus) => sum + _totalRegionsFor(_ensureSubState(focus), focus),
    );
    final lockedCount = selected.where(_cropLocked).length;
    final legacyCount =
        selected.where((f) => !_cropLocked(f) && _isLegacy(f)).length;
    return Center(
      child: Container(
        width: 560,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _kPanel,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '선택한 소단원 ${selected.length}개',
              style: const TextStyle(
                color: _kText,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _batchStatus.isNotEmpty
                  ? _batchStatus
                  : '선택 분석으로 크롭을 만들고, 소단원을 하나씩 눌러 크롭을 확인·수정한 뒤 '
                      '"선택 크롭 확정"을 누르면 소단원마다 2단계가 이어서 돕니다. '
                      '기존 추출 소단원은 본문을 그대로 두고 다음 단계부터 이어갑니다.',
              style: const TextStyle(
                color: _kTextSub,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            if (_batchTotal > 0) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _batchRunning
                      ? (_batchDone / _batchTotal).clamp(0.0, 1.0)
                      : 1,
                  minHeight: 4,
                  backgroundColor: _kCard,
                  color: _kAccent,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _tag('크롭 $totalReady개', _kCard),
                if (lockedCount > 0)
                  _tag('크롭 확정 $lockedCount개', _kChipSelected),
                if (legacyCount > 0) _tag('기존 추출 $legacyCount개', _kCard),
              ],
            ),
            const SizedBox(height: 16),
            _buildBatchActions(selected),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchActions(List<_SubFocus> selected) {
    final confirmable = selected
        .where((f) =>
            !_cropLocked(f) && _totalRegionsFor(_ensureSubState(f), f) > 0)
        .toList();
    final legacy = confirmable.where(_isLegacy).length;
    final confirmLabel = legacy == 0
        ? '선택 크롭 확정 (${confirmable.length})'
        : legacy == confirmable.length
            ? '선택 이어서 마무리 ($legacy)'
            : '선택 크롭 확정 (${confirmable.length} · 기존 추출 $legacy)';
    final toConfirm = _subunitsToConfirm(selected);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pillButton(
                label: _batchRunning ? '분석 중' : '선택 분석',
                icon: Icons.play_arrow_rounded,
                busy: _batchRunning,
                onTap: _runSelectedBatch,
              ),
              _pillButton(
                label: confirmLabel,
                icon: Icons.task_alt_rounded,
                filled: true,
                busy: _confirming,
                onTap: confirmable.isEmpty || _batchRunning
                    ? null
                    : () => _confirmCrops(selected),
              ),
            ],
          ),
        ),
        if (toConfirm != null && toConfirm.isNotEmpty) ...[
          const SizedBox(width: 8),
          _pillButton(
            label: '일괄 확정 (${toConfirm.length})',
            icon: Icons.verified_rounded,
            filled: true,
            busy: _confirmingSubunits,
            onTap: _batchRunning || _confirming
                ? null
                : () => _confirmSubunits(toConfirm),
          ),
        ],
      ],
    );
  }

  Widget _buildSubControls(
    _SubFocus focus,
    _SubRunState state,
    _SubSectionEdit sub,
  ) {
    final (start, end) = _focusRange(focus);
    final readyRange = start != null && end != null && end >= start;
    final failedPages = state.progress?.failedPages ?? const <int>{};
    final totalRegions = _totalRegionsFor(state, focus);
    final manualCount = state.manualItems.length +
        (_manualEdits[_stateKeyFor(focus)]?.length ?? 0);
    final locked = _cropLocked(focus);
    final wf = _workflowFor(focus);
    final run = _runStateFor(focus);
    final busy = state.running || state.uploading;
    final pipelineStopped = wf != null &&
        wf.cropConfirmed &&
        !(run?.active ?? false) &&
        wf.pipelineStatus != 'done';
    final legacy = !locked && _isLegacy(focus);
    final legacyCounts = legacy ? _bodyCounts[_stateKeyFor(focus)] : null;

    final tags = <Widget>[
      if (readyRange)
        _tag('본문 $start–$end쪽 (${end - start + 1}쪽)', _kChipSelected)
      else
        const _InfoTag(text: '시작/끝 쪽을 입력하세요', danger: true),
      if (totalRegions > 0) _tag('크롭 $totalRegions개', _kCard),
      if (manualCount > 0)
        _tag('수동 $manualCount', _kWarn.withValues(alpha: 0.22)),
      if (legacyCounts != null)
        _tag(
          '기존 추출 · 본문 ${legacyCounts.bodies}/${legacyCounts.crops}'
          ' · 검수 ${legacyCounts.reviewed}/${legacyCounts.bodies}',
          _kCard,
        ),
    ];

    final actions = <Widget>[
      if (!locked) ...[
        if (state.running)
          _pillButton(
            label: '분석 취소',
            icon: Icons.stop_circle_outlined,
            color: _kDanger,
            onTap: () => _cancelFocused(focus),
          )
        else ...[
          if (failedPages.isNotEmpty)
            _pillButton(
              label: '실패 ${failedPages.length}쪽 다시 분석',
              icon: Icons.refresh_rounded,
              color: _kInfo,
              onTap: state.uploading ? null : () => _retryFailedForFocus(focus),
            ),
          _pillButton(
            label: totalRegions > 0 ? '다시 분석' : '분석 시작',
            icon: Icons.play_arrow_rounded,
            onTap: !readyRange || state.uploading || _batchRunning
                ? null
                : () => _runFocusedAnalysis(focus),
          ),
        ],
        _pillButton(
          label: _manualDrawMode ? '수동 추가 끝내기' : '수동 추가',
          icon: _manualDrawMode ? Icons.close_rounded : Icons.add_box_outlined,
          color: _manualDrawMode ? _kWarn : null,
          onTap: busy || !readyRange || _bodyLocalPath == null
              ? null
              : _toggleManualDraw,
        ),
        _pillButton(
          label: legacy ? '이어서 마무리' : '크롭 확정',
          icon: legacy ? Icons.fast_forward_rounded : Icons.task_alt_rounded,
          filled: true,
          busy: _confirming,
          onTap: busy || totalRegions == 0 || _batchRunning
              ? null
              : () => _confirmCrops([focus]),
        ),
      ] else ...[
        if (pipelineStopped)
          _pillButton(
            label: '2단계 다시 시도',
            icon: Icons.replay_rounded,
            color: _kInfo,
            onTap: () => _retryPipeline(focus),
          ),
        _pillButton(
          label: '크롭 다시 열기',
          icon: Icons.lock_open_rounded,
          onTap: () => _reopenCrop(focus),
        ),
        _pillButton(
          label: '작업 화면',
          icon: Icons.view_agenda_outlined,
          filled: true,
          onTap: () => _openWorkScreen(
            focus.bigIndex,
            focus.midIndex,
            scopeKey: focus.subKey,
          ),
        ),
      ],
    ];

    final String status;
    var statusColor = _kTextSub;
    if (locked) {
      final phase = run != null && run.active
          ? '${TextbookWorkflowPhase.label(run.phase)}'
              '${run.detail.isEmpty ? '' : ' · ${run.detail}'}'
          : (wf?.pipelineDetail.isNotEmpty ?? false)
              ? wf!.pipelineDetail
              : TextbookWorkflowPhase.label(wf?.pipelinePhase ?? '');
      status = '크롭 확정됨 · 2단계: $phase\n'
          '크롭을 고치려면 "크롭 다시 열기"를 누르세요. 다시 확정하면 빠진 것만 이어서 합니다.';
      if (wf?.pipelineStatus == 'failed') statusColor = _kDanger;
    } else if (_manualDrawMode) {
      status = _manualNumberBox == null
          ? '① 문항 번호(+유형명) 부분을 드래그하세요. 그다음 ② 문항 본문 전체를 드래그합니다. '
              'Esc 또는 "수동 추가 끝내기"로 나갑니다.'
          : '② 같은 쪽에서 문항 본문 전체를 드래그하세요. 다른 쪽을 드래그하면 ①부터 다시 합니다.';
      statusColor = _kWarn;
    } else if (state.error != null) {
      status = state.error!;
      statusColor = _kDanger;
    } else if (legacy) {
      status = '예전에 본문(+정답)을 뽑아 둔 소단원입니다. 크롭을 확인한 뒤 "이어서 마무리"를 누르면 '
          '본문과 검수 결과는 그대로 두고, 본문이 빠진 번호만 추출한 다음 정답·해설 위치 → V2 렌더·AI 검수로 이어갑니다. '
          '이미 승인된 문항은 AI 풀이·검수를 다시 하지 않습니다.';
    } else {
      status = '${state.phase} · 분석·수정한 크롭은 자동으로 임시저장됩니다. '
          '문항을 누르면 모서리로 영역을 고치거나 지울 수 있습니다.';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kPanel,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Wrap(spacing: 8, runSpacing: 8, children: tags),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            status,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: statusColor, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressRow(_SubRunState state) {
    final progress = state.progress;
    if (progress == null) return const SizedBox.shrink();
    final total = progress.total == 0 ? 1 : progress.total;
    final ratio = ((progress.done + progress.failed) / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                state.phase,
                style: const TextStyle(color: _kText, fontSize: 11),
              ),
              const Spacer(),
              Text(
                '${progress.done}/${progress.total} 완료'
                '${progress.failed > 0 ? " · 실패 ${progress.failed}" : ""}'
                ' · 현재 PDF ${progress.cursor}p',
                style: const TextStyle(color: _kTextSub, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.running ? ratio : 1.0,
              minHeight: 4,
              backgroundColor: _kCard,
              valueColor: AlwaysStoppedAnimation<Color>(
                progress.failed > 0 ? _kDanger : _kAccent,
              ),
            ),
          ),
          if (progress.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                progress.lastError!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _kDanger, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  // ─── PDF viewer + overlays ──────────────────────────────────────────

  Widget _buildViewerArea(_SubFocus focus, _SubRunState state) {
    if (_bodyLocalPath == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.picture_as_pdf_outlined,
                  size: 32, color: _kTextSub),
              const SizedBox(height: 8),
              Text(
                _pdfLoadError != null
                    ? 'PDF 로드 실패\n$_pdfLoadError'
                    : 'PDF가 아직 로드되지 않았어요.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _kTextSub, fontSize: 12),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _loadingPdf ? null : _ensurePdf,
                icon: const Icon(Icons.file_download_outlined, size: 14),
                label: const Text('PDF 로드'),
                style: FilledButton.styleFrom(backgroundColor: _kInfo),
              ),
              if (state.pageResults.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    '"분석 시작" 을 누르면 PDF를 로드하고 문항 영역을 감지합니다.',
                    style: TextStyle(color: _kTextSub, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Container(
      color: _kBg,
      child: Stack(
        children: [
          Positioned.fill(
            child: PdfViewer.file(
              _bodyLocalPath!,
              controller: _viewerController,
              params: PdfViewerParams(
                backgroundColor: _kBg,
                margin: 8,
                layoutPages: _layoutTwoPageSpread,
                pageAnchor: PdfPageAnchor.center,
                viewerOverlayBuilder: (context, size, handleLinkTap) => [
                  PdfViewerScrollThumb(
                    controller: _viewerController,
                    orientation: ScrollbarOrientation.right,
                  ),
                  PdfViewerScrollThumb(
                    controller: _viewerController,
                    orientation: ScrollbarOrientation.bottom,
                  ),
                ],
                onViewerReady: (document, controller) {
                  if (!mounted) return;
                  _jumpViewerToFocusStart(focus);
                },
                pageOverlaysBuilder: (context, pageRect, page) {
                  return _buildPageOverlays(
                    focus: focus,
                    state: state,
                    pageNumber: page.pageNumber,
                    pageRect: pageRect,
                  );
                },
              ),
            ),
          ),
          if (state.pageResults.any((r) => !r.ok))
            Positioned(
              left: 12,
              top: 12,
              child: _FailureChip(
                count: state.pageResults.where((r) => !r.ok).length,
              ),
            ),
          if (_manualDrawMode)
            Positioned(
              left: 12,
              bottom: 12,
              child: _statusPill(
                label: _manualNumberBox == null
                    ? '수동 추가 · ① 번호 부분 드래그'
                    : '수동 추가 · ② 본문 전체 드래그',
                color: _kWarn,
                icon: Icons.add_box_outlined,
              ),
            ),
          if (_selectedProblemKey != null && !_manualDrawMode)
            Positioned(
              right: 12,
              bottom: 12,
              child: _buildSelectionBar(focus, state),
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionBar(_SubFocus focus, _SubRunState state) {
    final parts = _selectedProblemKey!.split(':');
    final rawPage = int.tryParse(parts.first) ?? 0;
    final index = parts.length == 2 ? (int.tryParse(parts[1]) ?? -1) : -1;
    final row = state.pageResults.firstWhere(
      (r) => r.rawPage == rawPage && r.ok,
      orElse: () => _PageAnalysisRow.placeholder(),
    );
    final item =
        index >= 0 && index < row.items.length ? row.items[index] : null;
    final locked = _cropLocked(focus);
    final manual = item != null && state.manualItems.contains(item);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: _kPanel,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: _kBorder),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item == null ? '선택한 문항' : '${item.number}번${manual ? ' · 수동' : ''}',
            style: const TextStyle(
              color: _kText,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            locked ? '크롭 확정됨 · 보기만 가능' : '모서리를 끌어 영역을 고칩니다',
            style: const TextStyle(color: _kTextSub, fontSize: 12),
          ),
          const SizedBox(width: 12),
          if (!locked && item != null) ...[
            _pillButton(
              label: '지우기',
              icon: Icons.delete_outline_rounded,
              color: _kDanger,
              onTap: state.running || state.uploading
                  ? null
                  : () => _deleteItem(focus, rawPage, index),
            ),
            const SizedBox(width: 8),
          ],
          _pillButton(
            label: '선택 해제',
            onTap: () => setState(() => _selectedProblemKey = null),
          ),
        ],
      ),
    );
  }

  PdfPageLayout _layoutTwoPageSpread(
      List<PdfPage> pages, PdfViewerParams params) {
    if (pages.isEmpty) {
      return PdfPageLayout(
        pageLayouts: const <Rect>[],
        documentSize: Size.zero,
      );
    }
    const colGap = 20.0;
    const rowGap = 24.0;
    final rowWidths = <double>[];
    for (var i = 0; i < pages.length; i += 2) {
      final left = pages[i];
      final right = (i + 1) < pages.length ? pages[i + 1] : null;
      final width =
          right == null ? left.width : left.width + colGap + right.width;
      rowWidths.add(width);
    }
    final maxRowWidth = rowWidths.fold<double>(0, (acc, w) => math.max(acc, w));
    final totalWidth = maxRowWidth + params.margin * 2;
    final layouts = <Rect>[];
    var y = params.margin;
    for (var i = 0; i < pages.length; i += 2) {
      final left = pages[i];
      final right = (i + 1) < pages.length ? pages[i + 1] : null;
      final rowWidth =
          right == null ? left.width : left.width + colGap + right.width;
      final startX = (totalWidth - rowWidth) / 2;
      layouts.add(Rect.fromLTWH(startX, y, left.width, left.height));
      if (right != null) {
        layouts.add(Rect.fromLTWH(
            startX + left.width + colGap, y, right.width, right.height));
      }
      final rowHeight = math.max(left.height, right?.height ?? 0);
      y += rowHeight + rowGap;
    }
    return PdfPageLayout(
      pageLayouts: layouts,
      documentSize: Size(totalWidth, y + params.margin),
    );
  }

  List<Widget> _buildPageOverlays({
    required _SubFocus focus,
    required _SubRunState state,
    required int pageNumber,
    required Rect pageRect,
  }) {
    final regions = _buildRegionOverlays(
      focus: focus,
      state: state,
      pageNumber: pageNumber,
      pageRect: pageRect,
    );
    if (!_manualDrawMode) return regions;
    final (start, end) = _focusRange(focus);
    if (start == null || end == null) return regions;
    if (pageNumber < _rawPageForDisplayPage(start) ||
        pageNumber > _rawPageForDisplayPage(end)) {
      return regions;
    }
    return [
      ...regions,
      ..._buildManualDrawLayer(focus, pageNumber, pageRect.size),
    ];
  }

  List<Widget> _buildManualDrawLayer(
    _SubFocus focus,
    int rawPage,
    Size pageSize,
  ) {
    Rect toPx(Rect n) => Rect.fromLTRB(
          n.left * pageSize.width,
          n.top * pageSize.height,
          n.right * pageSize.width,
          n.bottom * pageSize.height,
        );
    Widget box(Rect normalized, Color color, String label) {
      return Positioned.fromRect(
        rect: toPx(normalized),
        child: IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    border: Border.all(color: color, width: 2),
                  ),
                ),
              ),
              Positioned(
                left: -2,
                top: -18,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  color: color,
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final out = <Widget>[
      Positioned.fill(
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) =>
                _onManualDragStart(rawPage, d.localPosition, pageSize),
            onPanUpdate: (d) =>
                _onManualDragUpdate(rawPage, d.localPosition, pageSize),
            onPanEnd: (_) => unawaited(_onManualDragEnd(focus, rawPage)),
            onPanCancel: () => setState(() {
              _manualDragRect = null;
              _manualDragStart = null;
              _manualDragPage = null;
            }),
            child: ColoredBox(color: _kWarn.withValues(alpha: 0.04)),
          ),
        ),
      ),
    ];
    final numberBox = _manualNumberBox;
    final numberOnThisPage = numberBox != null && _manualNumberPage == rawPage;
    if (numberOnThisPage) out.add(box(numberBox, _kDanger, '① 번호'));
    final drag = _manualDragRect;
    if (drag != null && _manualDragPage == rawPage) {
      out.add(numberOnThisPage
          ? box(drag, _kAccent, '② 본문')
          : box(drag, _kDanger, '① 번호'));
    }
    return out;
  }

  List<Widget> _buildRegionOverlays({
    required _SubFocus focus,
    required _SubRunState state,
    required int pageNumber,
    required Rect pageRect,
  }) {
    final row = state.pageResults.firstWhere(
      (r) => r.rawPage == pageNumber && r.ok,
      orElse: () => _PageAnalysisRow.placeholder(),
    );
    if (row.items.isEmpty) {
      if (row.isConceptPage) {
        return <Widget>[
          Positioned(
            left: 12,
            top: 12,
            child: _ConceptPageMarker(
              text: row.wasAutoGuarded ? '자동 제외 · 개념 페이지' : '개념 페이지',
            ),
          ),
        ];
      }
      return const <Widget>[];
    }
    final pageSize = pageRect.size;
    final widgets = <Widget>[];
    if (row.wasAutoGuarded) {
      widgets.add(const Positioned(
        left: 12,
        top: 12,
        child: _AutoGuardMarker(),
      ));
    }
    for (var i = 0; i < row.items.length; i += 1) {
      final item = row.items[i];
      final region = _effectiveItemRegion(
        focus: focus,
        rawPage: pageNumber,
        orderIndex: i,
        item: item,
      );
      if (region == null || region.length != 4) continue;
      final rect = _bboxToRect(region, pageSize);
      if (rect == null) continue;
      final key = _problemKey(pageNumber, i);
      final isSelected = _selectedProblemKey == key;
      final isEdited =
          _manualEdits[_stateKeyFor(focus)]?.containsKey(key) == true ||
              state.manualItems.contains(item);
      widgets.add(_RegionBox(
        rect: rect,
        item: item,
        selected: isSelected,
        edited: isEdited,
        onTap: () {
          setState(() {
            _selectedProblemKey = isSelected ? null : key;
          });
        },
      ));
    }
    // Bottom pass: number bboxes (for context)
    final gaeyuHighLabels = _gaeyuHighExerciseLabels(state.pageResults);
    for (var i = 0; i < row.items.length; i += 1) {
      final item = row.items[i];
      final region = _effectiveItemRegion(
        focus: focus,
        rawPage: pageNumber,
        orderIndex: i,
        item: item,
      );
      final bbox = _effectiveNumberBbox(item, region);
      if (bbox == null || bbox.length != 4) continue;
      final rect = _bboxToRect(bbox, pageSize);
      if (rect == null) continue;
      final effectiveGroup = _effectiveContentGroupForItem(
        focus: focus,
        state: state,
        rawPage: pageNumber,
        itemIndex: i,
      );
      widgets.add(_NumberBadge(
        rect: rect,
        item: item,
        groupLabelOverride:
            effectiveGroup.kind == 'type' ? effectiveGroup.label : null,
        groupTitleOverride:
            effectiveGroup.kind == 'type' ? effectiveGroup.title : null,
        // 개념서는 난이도가 없으므로 뱃지에 문항이름을 표시한다.
        labelOverride: _seriesKey == 'gaeyu_high'
            ? _gaeyuHighBadgeText(
                _wonriCategoryOfItem(item, row.section),
                gaeyuHighLabels[_problemKey(pageNumber, i)] ?? '',
              )
            : const {'wonri', 'wonri_middle'}.contains(_seriesKey)
                ? _wonriItemName(
                    _wonriCategoryOfItem(item, ''),
                    item.label,
                    itemRole: item.itemRole,
                  )
                : null,
      ));
    }
    // Top pass: drag handles for the selected region. Drawn last so they
    // stay clickable.
    if (_selectedProblemKey != null && !_cropLocked(focus)) {
      final parts = _selectedProblemKey!.split(':');
      if (parts.length == 2) {
        final selRawPage = int.tryParse(parts[0]);
        final selIndex = int.tryParse(parts[1]);
        if (selRawPage == pageNumber && selIndex != null) {
          if (selIndex >= 0 && selIndex < row.items.length) {
            final item = row.items[selIndex];
            final region = _effectiveItemRegion(
              focus: focus,
              rawPage: pageNumber,
              orderIndex: selIndex,
              item: item,
            );
            if (region != null && region.length == 4) {
              final rect = _bboxToRect(region, pageSize);
              if (rect != null) {
                widgets.addAll(_buildDragHandles(
                  rect: rect,
                  pageSize: pageSize,
                  focus: focus,
                  rawPage: pageNumber,
                  orderIndex: selIndex,
                  currentRegion: region,
                ));
              }
            }
          }
        }
      }
    }
    return widgets;
  }

  List<Widget> _buildDragHandles({
    required Rect rect,
    required Size pageSize,
    required _SubFocus focus,
    required int rawPage,
    required int orderIndex,
    required List<int> currentRegion,
  }) {
    const handleSize = 14.0;
    Widget makeHandle(Offset center, _HandleKind kind) {
      return Positioned(
        left: center.dx - handleSize / 2,
        top: center.dy - handleSize / 2,
        width: handleSize,
        height: handleSize,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) {
            _onHandleDrag(
              kind: kind,
              delta: details.delta,
              pageSize: pageSize,
              focus: focus,
              rawPage: rawPage,
              orderIndex: orderIndex,
            );
          },
          onPanEnd: (_) {
            if (_ensureSubState(focus).dirty) _scheduleAutoSave(focus);
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _kAccent, width: 2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      );
    }

    return [
      makeHandle(Offset(rect.left, rect.top), _HandleKind.topLeft),
      makeHandle(Offset(rect.right, rect.top), _HandleKind.topRight),
      makeHandle(Offset(rect.left, rect.bottom), _HandleKind.bottomLeft),
      makeHandle(Offset(rect.right, rect.bottom), _HandleKind.bottomRight),
    ];
  }

  void _onHandleDrag({
    required _HandleKind kind,
    required Offset delta,
    required Size pageSize,
    required _SubFocus focus,
    required int rawPage,
    required int orderIndex,
  }) {
    if (pageSize.width <= 0 || pageSize.height <= 0) return;
    final runState = _ensureSubState(focus);
    if (runState.running || _cropLocked(focus)) return;
    // The overlay is drawn on top of the already-zoomed page rect, so the
    // delta is already in viewer-space pixels relative to the current
    // zoom. Converting to normalised 0..1000 by the current pageSize gives
    // the same effective step regardless of zoom.
    final dxNorm = (delta.dx / pageSize.width * 1000).round();
    final dyNorm = (delta.dy / pageSize.height * 1000).round();

    final edits = _ensureManualEdits(focus);
    final key = _problemKey(rawPage, orderIndex);
    final state = _ensureSubState(focus);
    final row = state.pageResults.firstWhere(
      (r) => r.rawPage == rawPage && r.ok,
      orElse: () => _PageAnalysisRow.placeholder(),
    );
    if (orderIndex < 0 || orderIndex >= row.items.length) return;
    final item = row.items[orderIndex];
    final current = edits[key] ?? List<int>.from(item.itemRegion ?? const []);
    if (current.length != 4) return;
    // item_region format = [ymin, xmin, ymax, xmax] in 0..1000.
    var ymin = current[0];
    var xmin = current[1];
    var ymax = current[2];
    var xmax = current[3];
    switch (kind) {
      case _HandleKind.topLeft:
        ymin = (ymin + dyNorm).clamp(0, ymax - 10);
        xmin = (xmin + dxNorm).clamp(0, xmax - 10);
        break;
      case _HandleKind.topRight:
        ymin = (ymin + dyNorm).clamp(0, ymax - 10);
        xmax = (xmax + dxNorm).clamp(xmin + 10, 1000);
        break;
      case _HandleKind.bottomLeft:
        ymax = (ymax + dyNorm).clamp(ymin + 10, 1000);
        xmin = (xmin + dxNorm).clamp(0, xmax - 10);
        break;
      case _HandleKind.bottomRight:
        ymax = (ymax + dyNorm).clamp(ymin + 10, 1000);
        xmax = (xmax + dxNorm).clamp(xmin + 10, 1000);
        break;
    }
    edits[key] = <int>[ymin, xmin, ymax, xmax];
    state.markDirty();
    if (mounted) setState(() {});
  }

  Rect? _bboxToRect(List<int> bbox, Size pageSize) {
    final ymin = bbox[0] / 1000.0;
    final xmin = bbox[1] / 1000.0;
    final ymax = bbox[2] / 1000.0;
    final xmax = bbox[3] / 1000.0;
    final left = xmin * pageSize.width;
    final top = ymin * pageSize.height;
    final width = (xmax - xmin) * pageSize.width;
    final height = (ymax - ymin) * pageSize.height;
    if (width <= 0 || height <= 0) return null;
    return Rect.fromLTWH(left, top, width, height);
  }

  // ─── widgets ────────────────────────────────────────────────────────

  Widget _pill(
      {required String text, required Color color, required Color fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _textInput(
    TextEditingController controller, {
    required String hint,
    bool dense = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    VoidCallback? onChanged,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: (_) => setState(() {
        onChanged?.call();
      }),
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      style: const TextStyle(color: _kText, fontSize: 12),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _kMuted, fontSize: 11),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 10,
          vertical: dense ? 8 : 10,
        ),
        filled: true,
        fillColor: _kCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _kAccent),
        ),
      ),
    );
  }

  Widget _tag(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kBorder),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: _kText,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: _kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: error ? _kDanger : _kAccent),
        ),
        content: Text(
          msg,
          style: TextStyle(color: error ? _kDanger : _kText, fontSize: 13),
        ),
      ),
    );
  }
}

// ────────────────────────────── overlays ──────────────────────────────

class _ConceptPageMarker extends StatelessWidget {
  const _ConceptPageMarker({this.text = '개념 페이지'});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A1E).withValues(alpha: 0.92),
          border: Border.all(color: Color(0xFFE6C07A)),
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 6,
              offset: Offset(1, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lightbulb_outline,
              size: 13,
              color: Color(0xFFE6C07A),
            ),
            const SizedBox(width: 5),
            Text(
              text,
              style: const TextStyle(
                color: Color(0xFFE6C07A),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AutoGuardMarker extends StatelessWidget {
  const _AutoGuardMarker();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF3A2F18).withValues(alpha: 0.92),
          border: Border.all(color: const Color(0xFFEAB968)),
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 6,
              offset: Offset(1, 2),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rule, size: 13, color: Color(0xFFEAB968)),
            SizedBox(width: 5),
            Text(
              'A 오인식 후보 자동 제외',
              style: TextStyle(
                color: Color(0xFFEAB968),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RegionBox extends StatelessWidget {
  const _RegionBox({
    required this.rect,
    required this.item,
    required this.selected,
    required this.edited,
    required this.onTap,
  });

  final Rect rect;
  final TextbookVlmItem item;
  final bool selected;
  final bool edited;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final baseColor =
        item.isSetHeader ? const Color(0xFFFFB44A) : const Color(0xFF5AA6FF);
    final borderColor = selected
        ? const Color(0xFF33A373)
        : edited
            ? const Color(0xFFEAB968)
            : baseColor;
    final fillColor = selected
        ? const Color(0xFF33A373).withValues(alpha: 0.12)
        : edited
            ? const Color(0xFFEAB968).withValues(alpha: 0.08)
            : baseColor.withValues(alpha: 0.05);
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: fillColor,
            border: Border.all(
              color: borderColor,
              width: selected ? 2.5 : 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberBadge extends StatelessWidget {
  const _NumberBadge(
      {required this.rect,
      required this.item,
      this.labelOverride,
      this.groupLabelOverride,
      this.groupTitleOverride});
  final Rect rect;
  final TextbookVlmItem item;

  /// 개념서 문항이름처럼 난이도(label) 대신 표시할 라벨. null 이면 item.label 사용.
  final String? labelOverride;
  final String? groupLabelOverride;
  final String? groupTitleOverride;

  @override
  Widget build(BuildContext context) {
    final color =
        item.isSetHeader ? const Color(0xFFFFB44A) : const Color(0xFFFF4D4F);
    final groupLabel = (groupLabelOverride ?? item.contentGroupLabel).trim();
    // 필수유형 유형명(content_group_title). 확인용으로 뱃지에 함께 표시한다.
    final groupTitle = (groupTitleOverride ?? item.contentGroupTitle).trim();
    final badgeLabel = labelOverride ?? item.label;
    final numberLabel =
        badgeLabel.isEmpty ? item.number : '${item.number} · $badgeLabel';
    final groupText = groupLabel.isEmpty
        ? groupTitle
        : (groupTitle.isEmpty ? groupLabel : '$groupLabel $groupTitle');
    final text = groupText.isEmpty ? numberLabel : '$groupText · $numberLabel';
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 2),
                color: color.withValues(alpha: 0.08),
              ),
            ),
            Positioned(
              left: -2,
              top: -18,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                color: color,
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureChip extends StatelessWidget {
  const _FailureChip({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE57373)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 12, color: Color(0xFFE57373)),
          const SizedBox(width: 4),
          Text(
            '$count쪽 분석 실패',
            style: const TextStyle(
              color: Color(0xFFE57373),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────── helpers ──────────────────────────────

class _InfoTag extends StatelessWidget {
  const _InfoTag({required this.text, this.danger = false});
  final String text;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    const dangerColor = Color(0xFFE57373);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: danger
            ? dangerColor.withValues(alpha: 0.14)
            : const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: danger
              ? dangerColor.withValues(alpha: 0.45)
              : const Color(0x22FFFFFF),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: danger ? dangerColor : const Color(0xFFEAF2F2),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SubRowStats extends StatelessWidget {
  const _SubRowStats({
    required this.analyzed,
    required this.uploaded,
    required this.running,
  });

  final int analyzed;
  final int uploaded;
  final bool running;

  @override
  Widget build(BuildContext context) {
    if (!running && analyzed == 0 && uploaded == 0) {
      return const SizedBox(width: 72);
    }

    final fullyUploaded = uploaded > 0 && uploaded >= analyzed;
    final partiallyUploaded = uploaded > 0 && uploaded < analyzed;
    final label = '$uploaded/$analyzed';
    final Color bg;
    final Color fg;
    if (fullyUploaded) {
      bg = const Color(0xFF1B3A2A);
      fg = const Color(0xFF9FD49F);
    } else if (partiallyUploaded) {
      bg = const Color(0xFF3A2F18);
      fg = const Color(0xFFEAB968);
    } else if (analyzed > 0) {
      bg = const Color(0xFF1B2A3A);
      fg = const Color(0xFF7AA9E6);
    } else {
      bg = const Color(0xFF242424);
      fg = const Color(0xFFB3B3B3);
    }
    return Tooltip(
      message: fullyUploaded
          ? '분석 $analyzed건 · 전부 서버 저장 완료 ($uploaded건)'
              : partiallyUploaded
                  ? '분석 $analyzed건 · 임시저장 $uploaded건 (일부)'
                  : analyzed > 0
                      ? '분석 $analyzed건 · 아직 임시저장 전 (자동 저장 대기)'
                      : '분석 진행 중',
      child: SizedBox(
        width: 72,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      fullyUploaded
                          ? Icons.cloud_done_outlined
                          : analyzed > 0 && uploaded == 0
                              ? Icons.cloud_upload_outlined
                              : Icons.inventory_2_outlined,
                      size: 11,
                      color: fg,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      label,
                      style: TextStyle(
                        color: fg,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (running)
              const Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: SizedBox(
                  width: 10,
                  height: 10,
                  child: Center(
                    child: SizedBox(
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.2,
                        color: Color(0xFFEAB968),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StageProgressChip extends StatelessWidget {
  const _StageProgressChip({
    required this.status,
    required this.loading,
    required this.onTap,
  });

  final TextbookStageScopeStatus? status;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final completed = status?.completedStages ?? 0;
    final ready = completed == 3;
    final label = loading ? '확인 중...' : '$completed/3 완료';
    final color = ready
        ? const Color(0xFF9FD49F)
        : completed > 0
            ? const Color(0xFFEAB968)
            : const Color(0xFF9FB3B3);
    // Windows에서 단원 트리가 갱신되는 프레임에 Tooltip의 OverlayPortal이
    // 제거되면 MouseTracker가 아직 layout되지 않은 오버레이를 hit-test하며
    // assertion 폭주를 일으킬 수 있다. 이 칩은 행마다 동적으로 생성되므로
    // 오버레이 대신 접근성 라벨만 제공한다.
    return Semantics(
      label: '본문, 정답, 해설 추출 상태 $label. 눌러서 상세 상태 확인',
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Row(
            children: [
              if (loading)
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.3,
                    color: Color(0xFF9FB3B3),
                  ),
                )
              else
                Icon(
                  ready ? Icons.task_alt : Icons.fact_check_outlined,
                  size: 11,
                  color: color,
                ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StageStatusDialogRow extends StatelessWidget {
  const _StageStatusDialogRow({
    required this.label,
    required this.description,
    required this.done,
    required this.total,
    required this.dangerHint,
    required this.onDelete,
  });

  final String label;
  final String description;
  final int done;
  final int total;
  final String dangerHint;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final exists = total > 0 || done > 0;
    final complete = total > 0 && done >= total;
    final color = complete
        ? const Color(0xFF9FD49F)
        : exists
            ? const Color(0xFFEAB968)
            : const Color(0xFF8A8A8A);
    final countText = total > 0 ? '$done/$total' : '$done';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Row(
        children: [
          Icon(
            complete
                ? Icons.check_circle_outline
                : Icons.radio_button_unchecked,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$label · $countText',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$description · $dangerHint',
                  style: const TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: exists ? onDelete : null,
            icon: const Icon(Icons.delete_outline, size: 14),
            label: const Text('삭제'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE68A8A),
              disabledForegroundColor: const Color(0xFF4A4A4A),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _PbExtractStatusChip extends StatelessWidget {
  const _PbExtractStatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.trim().toLowerCase();
    final success = normalized == 'completed';
    final failed = normalized == 'failed' || normalized == 'cancelled';
    final running = normalized == 'queued' || normalized == 'extracting';
    final Color color = success
        ? const Color(0xFF9FD49F)
        : failed
            ? const Color(0xFFE68A8A)
            : running
                ? const Color(0xFF7AA9E6)
                : const Color(0xFFB3B3B3);
    final text = success
        ? '본문 성공'
        : failed
            ? '본문 실패'
            : running
                ? '본문 진행'
                : '본문 대기';
    return Tooltip(
      message: '문제은행 PDF-only 본문 추출: $status',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

// ─────────── data classes ───────────

enum _HandleKind { topLeft, topRight, bottomLeft, bottomRight }

class _SubFocus {
  const _SubFocus({
    required this.bigIndex,
    required this.midIndex,
    required this.subKey,
  });
  final int bigIndex;
  final int midIndex;
  final String subKey;
}

class _SubRunState {
  bool running = false;
  bool uploading = false;
  bool cancelled = false;
  String phase = '대기';
  String? error;
  RangeProgress? progress;
  final List<_PageAnalysisRow> pageResults = <_PageAnalysisRow>[];
  TextbookCropBatchResult? uploadResult;

  /// 지금 화면에 있는 분석 결과가 아직 서버에 안 올라갔는지.
  ///
  /// [uploadResult] 는 다이얼로그를 열 때 **서버에 저장돼 있던 크롭**으로도
  /// 채워진다. 그래서 "결과가 있으니 저장은 끝났다" 로 판단하면, 다시 분석한
  /// 내용을 올리지 않고 옛 데이터로 다음 단계에 넘어가면서 저장했다고 말하게
  /// 된다. 분석·수정이 있었는지는 이 플래그로만 판단한다.
  bool dirty = false;

  /// 사람이 그리거나 핸들로 고친 문항. 저장 때 region_source='manual' 로 올리고,
  /// 다시 분석해도 AI 결과로 덮지 않는다.
  final Set<TextbookVlmItem> manualItems = Set<TextbookVlmItem>.identity();

  /// 바뀔 때마다 오른다. 저장 중에 또 고쳤으면 저장이 끝나도 [dirty] 를 풀지 않는다.
  int editSeq = 0;

  void markDirty() {
    dirty = true;
    editSeq += 1;
  }
}

class _ResolvedContentGroup {
  const _ResolvedContentGroup({
    required this.kind,
    required this.label,
    required this.title,
    required this.order,
  });

  const _ResolvedContentGroup.none()
      : kind = 'none',
        label = '',
        title = '',
        order = null;

  const _ResolvedContentGroup.suryeokConceptCheck()
      : kind = 'type',
        label = '개념 체크',
        title = '',
        order = null;

  final String kind;
  final String label;
  final String title;
  final int? order;
}

class _PageAnalysisRow {
  _PageAnalysisRow({
    required this.rawPage,
    required this.ok,
    this.error,
    this.displayPage = 0,
    this.section = 'unknown',
    this.pageKind = 'unknown',
    this.conceptDrillHeaderVisible = false,
    this.notes = '',
    List<TextbookVlmItem>? items,
  }) : items = items ?? const <TextbookVlmItem>[];

  factory _PageAnalysisRow.success({
    required int rawPage,
    required int displayPage,
    required String section,
    required String pageKind,
    bool conceptDrillHeaderVisible = false,
    required String notes,
    required List<TextbookVlmItem> items,
  }) {
    return _PageAnalysisRow(
      rawPage: rawPage,
      ok: true,
      displayPage: displayPage,
      section: section,
      pageKind: pageKind,
      conceptDrillHeaderVisible: conceptDrillHeaderVisible,
      notes: notes,
      items: items,
    );
  }

  factory _PageAnalysisRow.failure({
    required int rawPage,
    required String error,
  }) {
    return _PageAnalysisRow(rawPage: rawPage, ok: false, error: error);
  }

  /// Sentinel used by the overlay builder when the requested page has no
  /// analysis yet. Every property is safe to read but `items` is empty so
  /// the overlay list comes back empty.
  factory _PageAnalysisRow.placeholder() {
    return _PageAnalysisRow(rawPage: 0, ok: false);
  }

  final int rawPage;
  final bool ok;
  final String? error;
  final int displayPage;
  final String section;
  final String pageKind;
  final bool conceptDrillHeaderVisible;
  final String notes;
  final List<TextbookVlmItem> items;

  _PageAnalysisRow withItems(List<TextbookVlmItem> next) => _PageAnalysisRow(
        rawPage: rawPage,
        ok: ok,
        error: error,
        displayPage: displayPage,
        section: section,
        pageKind: pageKind,
        conceptDrillHeaderVisible: conceptDrillHeaderVisible,
        notes: notes,
        items: next,
      );

  bool get isConceptPage =>
      ok &&
      items.isEmpty &&
      (pageKind == 'concept_page' ||
          notes.toLowerCase().contains('concept_page'));

  bool get wasAutoGuarded {
    final lower = notes.toLowerCase();
    return lower.contains('auto_guarded') ||
        lower.contains('basic_drill_candidate_filtered') ||
        lower.contains('basic_drill_sequence_filtered') ||
        lower.contains('basic_drill_start_page_filtered') ||
        lower.contains('wonri_before_concept_drill_header_filtered') ||
        lower.contains('basic_drill_expected_start_missing') ||
        lower.contains('basic_drill_expected_start_mismatch');
  }
}

// ─────────── reused unit-edit models (tree editor) ───────────

class _SpecialUnitView {
  const _SpecialUnitView({
    required this.name,
    required this.startPage,
    required this.endPage,
  });

  final String name;
  final int startPage;
  final int endPage;
}

class _BigUnitEdit {
  _BigUnitEdit({String? bigName}) {
    if (bigName != null) nameCtrl.text = bigName;
  }
  final TextEditingController nameCtrl = TextEditingController();
  final List<_MidUnitEdit> middles = <_MidUnitEdit>[];
  void dispose() {
    nameCtrl.dispose();
    for (final m in middles) {
      m.dispose();
    }
  }
}

class _MidUnitEdit {
  _MidUnitEdit({
    required TextbookSeriesCatalogEntry series,
    String? midName,
  }) {
    if (midName != null) nameCtrl.text = midName;
    for (final preset in series.slotsForMid(nameCtrl.text)) {
      subs.add(_SubSectionEdit(preset: preset));
    }
  }
  final TextEditingController nameCtrl = TextEditingController();
  final List<_SubSectionEdit> subs = <_SubSectionEdit>[];

  /// 개념서(개념원리)의 실제 소단원 행들 — 책의 소단원/연습문제 이름과
  /// 페이지 범위를 이 단위로 편집하고, A~D 문제 카테고리 슬롯의 페이지는
  /// 여기서 자동 유도된다 (A/B/C = 일반 소단원 전체 범위, D = 연습문제 범위).
  final List<_SubUnitRowEdit> subUnitRows = <_SubUnitRowEdit>[];

  /// 시리즈 변경 시 A~D 슬롯을 새 프리셋으로 재구성한다.
  /// 같은 키의 슬롯에 이미 입력된 페이지 텍스트는 유지한다.
  ///
  /// 슬롯 구성은 중단원 이름을 본다 — 고쟁이 "대단원 TEST" 행은 F 슬롯만,
  /// 나머지 중단원은 F 를 뺀 A~E 를 갖는다.
  void applyPreset(TextbookSeriesCatalogEntry series) {
    final keyed = <String, _SubSectionEdit>{
      for (final s in subs) s.preset.key: s,
    };
    final rebuilt = <_SubSectionEdit>[];
    for (final preset in series.slotsForMid(nameCtrl.text)) {
      final existing = keyed.remove(preset.key);
      if (existing == null) {
        rebuilt.add(_SubSectionEdit(preset: preset));
        continue;
      }
      final next = _SubSectionEdit(preset: preset);
      next.startCtrl.text = existing.startCtrl.text;
      next.endCtrl.text = existing.endCtrl.text;
      next.answerStartCtrl.text = existing.answerStartCtrl.text;
      next.solutionStartCtrl.text = existing.solutionStartCtrl.text;
      existing.dispose();
      rebuilt.add(next);
    }
    for (final leftover in keyed.values) {
      leftover.dispose();
    }
    subs
      ..clear()
      ..addAll(rebuilt);
  }

  void dispose() {
    nameCtrl.dispose();
    for (final s in subs) {
      s.dispose();
    }
    for (final s in subUnitRows) {
      s.dispose();
    }
  }
}

/// 개념서(개념원리)의 소단원 한 행 — 이름 + 시작/끝 페이지.
/// "연습문제" 행은 STEP1/STEP2/실력UP이 있는 연습문제 페이지 범위다.
class _SubUnitRowEdit {
  _SubUnitRowEdit({String? name, this.isExercise = false}) {
    if (name != null) nameCtrl.text = name;
  }

  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController startCtrl = TextEditingController();
  final TextEditingController endCtrl = TextEditingController();
  // 정답/해설 시작 페이지는 소단원 단위로 사용자가 직접 입력한다 (쎈과 동일).
  // 소단원 안의 익히기·확인체크·연습문제 카테고리는 이 값을 공유한다.
  final TextEditingController answerStartCtrl = TextEditingController();
  final TextEditingController solutionStartCtrl = TextEditingController();
  final bool isExercise;

  void dispose() {
    nameCtrl.dispose();
    startCtrl.dispose();
    endCtrl.dispose();
    answerStartCtrl.dispose();
    solutionStartCtrl.dispose();
  }
}

class _SubSectionEdit {
  _SubSectionEdit({required this.preset});
  final TextbookSubSectionPreset preset;
  final TextEditingController startCtrl = TextEditingController();
  final TextEditingController endCtrl = TextEditingController();
  final TextEditingController answerStartCtrl = TextEditingController();
  final TextEditingController solutionStartCtrl = TextEditingController();
  void dispose() {
    startCtrl.dispose();
    endCtrl.dispose();
    answerStartCtrl.dispose();
    solutionStartCtrl.dispose();
  }
}

int? _positiveInt(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final n = int.tryParse(t);
  if (n == null || n <= 0) return null;
  return n;
}
