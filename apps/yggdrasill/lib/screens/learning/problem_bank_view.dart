import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../services/data_manager.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../services/tenant_service.dart';
import 'widgets/problem_bank_bottom_fab_bar.dart';
import 'widgets/problem_bank_filter_bar.dart';
import 'widgets/problem_bank_question_card.dart';
import 'widgets/problem_bank_school_sheet.dart';

class ProblemBankView extends StatefulWidget {
  const ProblemBankView({super.key});

  @override
  State<ProblemBankView> createState() => _ProblemBankViewState();
}

class _ProblemBankViewState extends State<ProblemBankView> {
  static const _rsBg = Color(0xFFF3EEE6);
  static const _rsPanelBg = Color(0xFFFBF7EE);
  static const _rsBorder = Color(0xFFE2D8C7);

  static const Map<String, String> _curriculumLabels = <String, String>{
    'legacy_1_6': '1차-6차 포괄',
    'curr_7th_1997': '7차 (1997)',
    'rev_2007': '2007 개정',
    'rev_2009': '2009 개정',
    'rev_2015': '2015 개정',
    'rev_2022': '2022 개정',
  };

  static const Map<String, String> _sourceTypeLabels = <String, String>{
    'private_material': '사설 교재',
    'school_past': '내신 기출',
    'mock_past': '모의고사 기출',
    'self_made': '자작문항',
  };

  static const List<String> _levelOptions = <String>['초', '중', '고'];

  final LearningProblemBankService _service = LearningProblemBankService();

  String? _academyId;
  bool _isInitializing = true;
  bool _isLoadingSchools = false;
  bool _isLoadingQuestions = false;
  bool _isBuildingPdf = false;

  String _selectedCurriculumCode = 'rev_2022';
  String _selectedSchoolLevel = '중';
  String _selectedDetailedCourse = '전체';
  String _selectedSourceTypeCode = 'school_past';

  List<String> _courseOptions = const <String>['전체'];
  List<String> _schoolNames = const <String>[];
  String? _selectedSchoolName;

  List<LearningProblemQuestion> _questions = const <LearningProblemQuestion>[];
  final Set<String> _selectedQuestionIds = <String>{};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      if (!mounted) return;
      _academyId = academyId;
      await _loadDetailedCourseOptions(forceResetSelection: true);
      await _reloadSchoolsAndQuestions(resetSelection: true);
    } catch (e) {
      _showSnack('문제은행 초기화 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _loadDetailedCourseOptions({
    bool forceResetSelection = false,
  }) async {
    final labels = <String>[];
    try {
      final rows = await DataManager.instance.loadAnswerKeyGrades();
      for (final row in rows) {
        final raw = '${row['label'] ?? ''}'.trim();
        if (raw.isNotEmpty) labels.add(raw);
      }
    } catch (_) {}

    final resolvedOptions = _resolveCourseOptions(_selectedSchoolLevel, labels);
    if (!mounted) return;
    setState(() {
      _courseOptions = resolvedOptions;
      if (forceResetSelection ||
          !_courseOptions.contains(_selectedDetailedCourse)) {
        _selectedDetailedCourse = _courseOptions.first;
      }
    });
  }

  List<String> _resolveCourseOptions(String level, List<String> labels) {
    final filtered = labels
        .where((label) => _matchesLevelWithText(level, label))
        .toList(growable: false);
    final source =
        filtered.isNotEmpty ? filtered : _fallbackCourseByLevel(level);
    final set = <String>{};
    set.add('전체');
    for (final item in source) {
      final safe = item.trim();
      if (safe.isNotEmpty) set.add(safe);
    }
    return set.toList(growable: false);
  }

  List<String> _fallbackCourseByLevel(String level) {
    if (level == '초') {
      return const <String>[
        '초1-1',
        '초1-2',
        '초2-1',
        '초2-2',
        '초3-1',
        '초3-2',
        '초4-1',
        '초4-2',
        '초5-1',
        '초5-2',
        '초6-1',
        '초6-2',
      ];
    }
    if (level == '고') {
      return const <String>[
        '고1',
        '고2',
        '고3',
        '공통수학1',
        '공통수학2',
        '대수',
        '미적분1',
        '확률과 통계',
        '미적분2',
        '기하',
      ];
    }
    return const <String>[
      '중1-1',
      '중1-2',
      '중2-1',
      '중2-2',
      '중3-1',
      '중3-2',
    ];
  }

  bool _matchesLevelWithText(String level, String text) {
    final merged = text.replaceAll(' ', '');
    if (merged.isEmpty) return true;
    if (level == '초') {
      return merged.contains('초') || RegExp(r'^초?[1-6]-[12]$').hasMatch(merged);
    }
    if (level == '중') {
      return merged.contains('중') || RegExp(r'^중?[1-3]-[12]$').hasMatch(merged);
    }
    if (level == '고') {
      return merged.contains('고') ||
          merged.contains('공통수학') ||
          merged.contains('대수') ||
          merged.contains('미적분') ||
          merged.contains('확률') ||
          merged.contains('기하');
    }
    return true;
  }

  Future<void> _reloadSchoolsAndQuestions({
    required bool resetSelection,
  }) async {
    if (_academyId == null) return;
    if (_selectedSourceTypeCode == 'school_past') {
      await _reloadSchools();
    } else {
      if (mounted) {
        setState(() {
          _schoolNames = const <String>[];
          _selectedSchoolName = null;
        });
      }
    }
    await _reloadQuestions(resetSelection: resetSelection);
  }

  Future<void> _reloadSchools() async {
    if (_academyId == null) return;
    setState(() {
      _isLoadingSchools = true;
    });
    try {
      final schools = await _service.listSchoolsForSchoolPast(
        academyId: _academyId!,
        curriculumCode: _selectedCurriculumCode,
        schoolLevel: _selectedSchoolLevel,
        detailedCourse: _selectedDetailedCourse,
      );
      if (!mounted) return;
      setState(() {
        _schoolNames = schools;
        if (_selectedSchoolName == null ||
            !schools.contains(_selectedSchoolName)) {
          _selectedSchoolName = schools.isNotEmpty ? schools.first : null;
        }
      });
    } catch (e) {
      _showSnack('학교 목록 조회 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingSchools = false;
        });
      }
    }
  }

  Future<void> _reloadQuestions({
    required bool resetSelection,
  }) async {
    if (_academyId == null) return;
    setState(() {
      _isLoadingQuestions = true;
    });
    try {
      final questions = await _service.searchQuestions(
        academyId: _academyId!,
        curriculumCode: _selectedCurriculumCode,
        schoolLevel: _selectedSchoolLevel,
        detailedCourse: _selectedDetailedCourse,
        sourceTypeCode: _selectedSourceTypeCode,
        schoolName: _selectedSourceTypeCode == 'school_past'
            ? _selectedSchoolName
            : null,
      );
      if (!mounted) return;
      final aliveIds = questions.map((e) => e.id).toSet();
      setState(() {
        _questions = questions;
        if (resetSelection) {
          _selectedQuestionIds.clear();
        } else {
          _selectedQuestionIds.removeWhere((id) => !aliveIds.contains(id));
        }
      });
    } catch (e) {
      _showSnack('문항 조회 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingQuestions = false;
        });
      }
    }
  }

  Future<void> _onCurriculumChanged(String? value) async {
    if (value == null || value == _selectedCurriculumCode) return;
    setState(() {
      _selectedCurriculumCode = value;
    });
    await _reloadSchoolsAndQuestions(resetSelection: true);
  }

  Future<void> _onSchoolLevelChanged(String value) async {
    if (value == _selectedSchoolLevel) return;
    setState(() {
      _selectedSchoolLevel = value;
    });
    await _loadDetailedCourseOptions(forceResetSelection: true);
    await _reloadSchoolsAndQuestions(resetSelection: true);
  }

  Future<void> _onDetailedCourseChanged(String? value) async {
    if (value == null || value == _selectedDetailedCourse) return;
    setState(() {
      _selectedDetailedCourse = value;
    });
    await _reloadSchoolsAndQuestions(resetSelection: true);
  }

  Future<void> _onSourceTypeChanged(String? value) async {
    if (value == null || value == _selectedSourceTypeCode) return;
    setState(() {
      _selectedSourceTypeCode = value;
    });
    await _reloadSchoolsAndQuestions(resetSelection: true);
  }

  Future<void> _onSchoolSelected(String school) async {
    if (school == _selectedSchoolName) return;
    setState(() {
      _selectedSchoolName = school;
    });
    await _reloadQuestions(resetSelection: true);
  }

  void _toggleQuestionSelection(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedQuestionIds.add(id);
      } else {
        _selectedQuestionIds.remove(id);
      }
    });
  }

  void _selectAllQuestions() {
    setState(() {
      _selectedQuestionIds
        ..clear()
        ..addAll(_questions.map((e) => e.id));
    });
  }

  void _clearQuestionSelection() {
    setState(() {
      _selectedQuestionIds.clear();
    });
  }

  List<LearningProblemQuestion> get _selectedQuestions {
    if (_selectedQuestionIds.isEmpty || _questions.isEmpty) {
      return const <LearningProblemQuestion>[];
    }
    return _questions
        .where((q) => _selectedQuestionIds.contains(q.id))
        .toList(growable: false);
  }

  Future<void> _openPreviewDialog() async {
    final selected = _selectedQuestions;
    if (selected.isEmpty) {
      _showSnack('미리보기할 문항을 먼저 선택해주세요.');
      return;
    }
    final size = MediaQuery.sizeOf(context);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFFF6F1E7),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text('선택 문항 미리보기 (${selected.length}개)'),
          content: SizedBox(
            width: size.width * 0.82,
            height: size.height * 0.72,
            child: ListView.separated(
              itemCount: selected.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final q = selected[index];
                return SizedBox(
                  height: 290,
                  child: ProblemBankQuestionCard(
                    question: q,
                    selected: true,
                    showSelectionControl: false,
                    onSelectedChanged: (_) {},
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _generatePdfToLocal() async {
    final selected = _selectedQuestions;
    if (selected.isEmpty) {
      _showSnack('PDF로 저장할 문항을 먼저 선택해주세요.');
      return;
    }
    setState(() {
      _isBuildingPdf = true;
    });
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '문제은행 PDF 저장 위치 선택',
        fileName: 'problem_bank_${_todayStamp()}.pdf',
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (savePath == null || savePath.trim().isEmpty) {
        return;
      }
      var outputPath = savePath.trim();
      if (!outputPath.toLowerCase().endsWith('.pdf')) {
        outputPath = '$outputPath.pdf';
      }

      final bytes = await _buildPdfBytes(selected);
      await File(outputPath).writeAsBytes(bytes, flush: true);
      await OpenFilex.open(outputPath);
      _showSnack('PDF 저장 완료: $outputPath');
    } catch (e) {
      _showSnack('PDF 생성 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isBuildingPdf = false;
        });
      }
    }
  }

  Future<Uint8List> _buildPdfBytes(List<LearningProblemQuestion> items) async {
    final regularFont = await _loadPdfFont(
      assetPath: 'assets/fonts/kakao/카카오작은글씨/TTF/KakaoSmallSans-Regular.ttf',
      size: 11,
      bold: false,
    );
    final boldFont = await _loadPdfFont(
      assetPath: 'assets/fonts/kakao/카카오작은글씨/TTF/KakaoSmallSans-Bold.ttf',
      size: 12,
      bold: true,
    );

    final document = sf.PdfDocument();
    const margin = 34.0;
    for (var i = 0; i < items.length; i += 1) {
      final question = items[i];
      final page = document.pages.add();
      final size = page.getClientSize();

      final headerElement = sf.PdfTextElement(
        text:
            '${i + 1}. ${question.displayQuestionNumber}번 [${_questionTypeLabel(question.questionType)}]',
        font: boldFont,
      );
      final headerResult = headerElement.draw(
        page: page,
        bounds: Rect.fromLTWH(margin, margin, size.width - margin * 2, 28),
      );

      final bodyY = (headerResult?.bounds.bottom ?? margin + 18) + 8;
      final bodyText = _buildPrintableText(question);
      final bodyElement = sf.PdfTextElement(
        text: bodyText,
        font: regularFont,
        format: sf.PdfStringFormat(
          lineSpacing: 6,
        ),
      );
      bodyElement.draw(
        page: page,
        bounds: Rect.fromLTWH(
          margin,
          bodyY,
          size.width - margin * 2,
          size.height - bodyY - margin,
        ),
      );
    }

    final bytes = await document.save();
    document.dispose();
    return Uint8List.fromList(bytes);
  }

  String _buildPrintableText(LearningProblemQuestion question) {
    final sb = StringBuffer();
    sb.writeln(_sanitizePdfText(question.renderedStem));
    if (question.effectiveChoices.isNotEmpty) {
      sb.writeln();
      for (final choice in question.effectiveChoices) {
        final label = choice.label.trim().isEmpty ? '-' : choice.label.trim();
        final text = _sanitizePdfText(question.renderChoiceText(choice));
        sb.writeln('$label. $text');
      }
    }
    sb.writeln();

    final meta = <String>[
      if (question.schoolName.isNotEmpty) '학교 ${question.schoolName}',
      if (question.examYear != null) '년도 ${question.examYear}',
      if (question.gradeLabel.isNotEmpty) '학년 ${question.gradeLabel}',
      if (question.semesterLabel.isNotEmpty) '학기 ${question.semesterLabel}',
      if (question.examTermLabel.isNotEmpty) '시험 ${question.examTermLabel}',
      if (question.documentSourceName.isNotEmpty)
        '문서 ${question.documentSourceName}',
      if (question.sourcePage > 0) '페이지 ${question.sourcePage}',
    ];
    if (meta.isNotEmpty) {
      sb.writeln('[출처] ${meta.join(' | ')}');
    }
    return sb.toString().trim();
  }

  Future<sf.PdfFont> _loadPdfFont({
    required String assetPath,
    required double size,
    required bool bold,
  }) async {
    try {
      final data = await rootBundle.load(assetPath);
      return sf.PdfTrueTypeFont(
        data.buffer.asUint8List(),
        size,
        style: bold ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
      );
    } catch (_) {
      return sf.PdfStandardFont(
        sf.PdfFontFamily.helvetica,
        size,
        style: bold ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
      );
    }
  }

  String _sanitizePdfText(String input) {
    var out = input;
    out = out.replaceAllMapped(
      RegExp(r'\$\$([\s\S]*?)\$\$', dotAll: true),
      (m) => m.group(1) ?? '',
    );
    out = out.replaceAllMapped(
      RegExp(r'\\\(([\s\S]*?)\\\)', dotAll: true),
      (m) => m.group(1) ?? '',
    );
    out = out.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return out.trim();
  }

  String _questionTypeLabel(String value) {
    if (value == 'objective') return '객관식';
    if (value == 'subjective') return '주관식';
    if (value == 'essay') return '서술형';
    if (value.trim().isEmpty) return '유형 미정';
    return value;
  }

  String _todayStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
  }

  void _showCreatePlaceholder() {
    _showSnack('만들기 기능은 다음 단계에서 구현 예정입니다.');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isInitializing || _isLoadingQuestions || _isLoadingSchools;
    return Container(
      color: _rsBg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: ProblemBankFilterBar(
              selectedCurriculumCode: _selectedCurriculumCode,
              curriculumLabels: _curriculumLabels,
              onCurriculumChanged: _onCurriculumChanged,
              selectedLevel: _selectedSchoolLevel,
              levelOptions: _levelOptions,
              onLevelChanged: _onSchoolLevelChanged,
              selectedCourse: _selectedDetailedCourse,
              courseOptions: _courseOptions,
              onCourseChanged: _onDetailedCourseChanged,
              selectedSourceTypeCode: _selectedSourceTypeCode,
              sourceTypeLabels: _sourceTypeLabels,
              onSourceTypeChanged: _onSourceTypeChanged,
              isBusy: busy || _isBuildingPdf,
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                  child: SizedBox(
                    width: 260,
                    child: ProblemBankSchoolSheet(
                      selectedSourceTypeCode: _selectedSourceTypeCode,
                      schoolNames: _schoolNames,
                      selectedSchoolName: _selectedSchoolName,
                      onSchoolSelected: _onSchoolSelected,
                      isLoading: _isLoadingSchools,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
                    child: _buildQuestionPanel(),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: ProblemBankBottomFabBar(
              selectedCount: _selectedQuestionIds.length,
              isBusy: _isBuildingPdf,
              onSelectAll: _selectAllQuestions,
              onClearSelection: _clearQuestionSelection,
              onPreview: _openPreviewDialog,
              onGeneratePdf: _generatePdfToLocal,
              onCreatePlaceholder: _showCreatePlaceholder,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionPanel() {
    return Container(
      decoration: BoxDecoration(
        color: _rsPanelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _rsBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '문항 ${_questions.length}개 · 선택 ${_selectedQuestionIds.length}개',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF6D6458),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (_isLoadingQuestions || _isInitializing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: _rsBorder),
          Expanded(
            child: _buildQuestionBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionBody() {
    if (_isInitializing || _isLoadingQuestions) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_questions.isEmpty) {
      return const Center(
        child: Text(
          '조건에 맞는 문항이 없습니다.\n필터나 학교를 변경해 주세요.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xFF8A8074),
            fontWeight: FontWeight.w700,
            height: 1.5,
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 640,
        mainAxisExtent: 300,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: _questions.length,
      itemBuilder: (context, index) {
        final question = _questions[index];
        final selected = _selectedQuestionIds.contains(question.id);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleQuestionSelection(question.id, !selected),
          child: ProblemBankQuestionCard(
            question: question,
            selected: selected,
            onSelectedChanged: (next) {
              _toggleQuestionSelection(question.id, next);
            },
          ),
        );
      },
    );
  }
}
