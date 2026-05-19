import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/data_manager.dart';
import '../../services/homework_store.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../services/tenant_service.dart';
import '../../screens/learning/models/problem_bank_export_models.dart';
import '../dialog_tokens.dart';

enum _TemplateLibraryMode { favorites, assignments }

class FavoriteTemplatesPanel extends StatefulWidget {
  const FavoriteTemplatesPanel({
    super.key,
    required this.containerWidth,
  });

  final double containerWidth;

  @override
  State<FavoriteTemplatesPanel> createState() => _FavoriteTemplatesPanelState();
}

class _FavoriteTemplatesPanelState extends State<FavoriteTemplatesPanel> {
  bool _loading = false;
  String _bookFilter = '';
  String _gradeFilter = '';
  _TemplateLibraryMode _mode = _TemplateLibraryMode.favorites;
  List<HomeworkRecentTemplate> _templates = const [];
  List<HomeworkRecentTemplate> _assignmentTemplates = const [];
  Map<String, LearningProblemDocumentExportPreset> _assignmentPresetById =
      const <String, LearningProblemDocumentExportPreset>{};
  Map<String, String> _bookNameById = const <String, String>{};
  final LearningProblemBankService _problemBankService =
      LearningProblemBankService();
  StreamSubscription<void>? _assignmentPresetSubscription;
  String _printingPresetId = '';

  @override
  void initState() {
    super.initState();
    _assignmentPresetSubscription = LearningProblemBankService
        .generatedAssignmentChanged.stream
        .listen((_) {
      if (mounted) unawaited(_refreshTemplates());
    });
    unawaited(_refreshTemplates());
  }

  @override
  void dispose() {
    _assignmentPresetSubscription?.cancel();
    super.dispose();
  }

  Future<void> _refreshTemplates() async {
    if (_loading) return;
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final templates =
          await HomeworkStore.instance.loadRecentTemplates(limit: 120);
      List<LearningProblemDocumentExportPreset> assignmentPresets =
          const <LearningProblemDocumentExportPreset>[];
      final academyId = await TenantService.instance.getActiveAcademyId();
      if (academyId != null && academyId.trim().isNotEmpty) {
        try {
          assignmentPresets =
              await _problemBankService.listGeneratedAssignmentPresets(
            academyId: academyId.trim(),
            limit: 120,
          );
        } catch (_) {
          assignmentPresets = const <LearningProblemDocumentExportPreset>[];
        }
      }
      final assignmentTemplates = assignmentPresets
          .map(
            HomeworkStore.instance.templateFromGeneratedAssignmentPreset,
          )
          .toList(growable: false);
      Map<String, String> bookNameById = _bookNameById;
      final requiredBookIds = <String>{
        ...templates
            .map((e) => e.primaryBookId)
            .where((id) => id.trim().isNotEmpty)
            .toSet(),
      };
      final missingBookIds = requiredBookIds
          .where((id) => !bookNameById.containsKey(id))
          .toList(growable: false);
      if (bookNameById.isEmpty || missingBookIds.isNotEmpty) {
        final rows = await DataManager.instance.loadTextbooksWithMetadata();
        final merged = <String, String>{...bookNameById};
        for (final row in rows) {
          final id = '${row['book_id'] ?? ''}'.trim();
          if (id.isEmpty) continue;
          final name = '${row['book_name'] ?? ''}'.trim();
          if (name.isEmpty) continue;
          merged[id] = name;
        }
        bookNameById = merged;
      }
      if (!mounted) return;
      final activeTemplates = _mode == _TemplateLibraryMode.assignments
          ? assignmentTemplates
          : templates;
      final hasBookFilter = _bookFilter.isNotEmpty &&
          activeTemplates.any((t) => _templateBookKey(t) == _bookFilter);
      final hasGradeFilter = _gradeFilter.isNotEmpty &&
          activeTemplates.any((t) => t.primaryGradeLabel == _gradeFilter);
      setState(() {
        _templates = templates;
        _assignmentTemplates = assignmentTemplates;
        _assignmentPresetById = <String, LearningProblemDocumentExportPreset>{
          for (final preset in assignmentPresets) preset.id: preset,
        };
        _bookNameById = bookNameById;
        if (!hasBookFilter) _bookFilter = '';
        if (!hasGradeFilter) _gradeFilter = '';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _bookName(String bookId) {
    final key = bookId.trim();
    if (key.isEmpty) return '교재 없음';
    final named = (_bookNameById[key] ?? '').trim();
    if (named.isNotEmpty) return named;
    return key;
  }

  bool _isGeneratedAssignmentTemplate(HomeworkRecentTemplate template) {
    if (template.templateId.startsWith('pb-preset:')) return true;
    return template.parts.any(
      (part) =>
          (part.pbPresetId ?? '').trim().isNotEmpty &&
          (part.sourceUnitLevel ?? '').trim() == 'problem_bank_assignment',
    );
  }

  String _assignmentBookLabel(HomeworkRecentTemplate template) {
    for (final part in template.parts) {
      final value = (part.sourceUnitPath ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _templateBookKey(HomeworkRecentTemplate template) {
    if (_isGeneratedAssignmentTemplate(template)) {
      return _assignmentBookLabel(template);
    }
    return template.primaryBookId.trim();
  }

  String _templateBookLabel(HomeworkRecentTemplate template) {
    if (_isGeneratedAssignmentTemplate(template)) {
      final label = _assignmentBookLabel(template);
      return label.isEmpty ? '교재 없음' : label;
    }
    final bookId = template.primaryBookId.trim();
    return bookId.isEmpty ? '교재 없음' : _bookName(bookId);
  }

  List<HomeworkRecentTemplate> _activeTemplates() {
    return _mode == _TemplateLibraryMode.assignments
        ? _assignmentTemplates
        : _templates;
  }

  List<HomeworkRecentTemplate> _filteredTemplates() {
    final out = <HomeworkRecentTemplate>[];
    for (final template in _activeTemplates()) {
      if (_bookFilter.isNotEmpty && _templateBookKey(template) != _bookFilter) {
        continue;
      }
      if (_gradeFilter.isNotEmpty &&
          template.primaryGradeLabel != _gradeFilter) {
        continue;
      }
      out.add(template);
    }
    return out;
  }

  String _partTitle(HomeworkRecentTemplatePart part) {
    final title = part.title.trim().isEmpty ? '(제목 없음)' : part.title.trim();
    return title;
  }

  String _partRightMeta(HomeworkRecentTemplatePart part) {
    final rawPage = (part.page ?? '').trim();
    final pageText = rawPage.isEmpty ? 'p.-' : 'p.$rawPage';
    final countText =
        (part.count == null || part.count! <= 0) ? '문항 미지정' : '${part.count}문항';
    return '$pageText · $countText';
  }

  void _selectMode(_TemplateLibraryMode mode) {
    if (_mode == mode) return;
    final nextTemplates = mode == _TemplateLibraryMode.assignments
        ? _assignmentTemplates
        : _templates;
    setState(() {
      _mode = mode;
      if (_bookFilter.isNotEmpty &&
          !nextTemplates.any((t) => _templateBookKey(t) == _bookFilter)) {
        _bookFilter = '';
      }
      if (_gradeFilter.isNotEmpty &&
          !nextTemplates.any((t) => t.primaryGradeLabel == _gradeFilter)) {
        _gradeFilter = '';
      }
    });
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required double sheetScale,
  }) {
    return Padding(
      padding: EdgeInsets.only(
        right: 8 * sheetScale,
        bottom: 8 * sheetScale,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: 12 * sheetScale,
              vertical: 7 * sheetScale,
            ),
            decoration: BoxDecoration(
              color:
                  selected ? const Color(0x1F33A373) : const Color(0xFF151C1F),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? const Color(0xFF33A373)
                    : const Color(0xFF2F4343),
                width: selected ? 1.2 : 1.0,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFF9FE3C6)
                    : const Color(0xFF9FB3B3),
                fontSize: 14.5 * sheetScale,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTemplateCardSurface(
    HomeworkRecentTemplate template, {
    required double width,
    required double sheetScale,
  }) {
    final title =
        template.title.trim().isEmpty ? '(제목 없음)' : template.title.trim();
    final grade = template.primaryGradeLabel.trim();
    final bookText = _templateBookLabel(template);
    final gradeText = grade.isEmpty ? '학년 미지정' : grade;
    final preferredFlowName = template.primaryPreferredFlowName.trim();
    final subtitleParts = <String>[
      template.isGroup ? '그룹 과제 · 하위 ${template.partCount}개' : '단일 과제',
      if (preferredFlowName.isNotEmpty) '$preferredFlowName 플로우',
    ];
    final subtitle = subtitleParts.join(' · ');
    final titleFontSize = (template.isGroup ? 20.0 : 16.0) * sheetScale;
    final titleToMetaGap = (template.isGroup ? 7.5 : 5.0) * sheetScale;
    final previewParts = template.parts.take(3).toList(growable: false);
    final moreCount = template.parts.length - previewParts.length;
    return Container(
      width: width,
      decoration: BoxDecoration(
        // 홈메뉴 그룹과제 카드 배경 톤과 통일
        color: const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A3A3A)),
      ),
      padding: EdgeInsets.fromLTRB(
        18 * sheetScale,
        14 * sheetScale,
        18 * sheetScale,
        14 * sheetScale,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: kDlgText,
              fontSize: titleFontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: titleToMetaGap),
          Text(
            '$bookText · $gradeText',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: kDlgTextSub,
              fontSize: 14.5 * sheetScale,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 5 * sheetScale),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: const Color(0xFF8FA3A3),
              fontSize: 14.5 * sheetScale,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 8 * sheetScale),
          for (int i = 0; i < previewParts.length; i++) ...[
            if (i > 0) SizedBox(height: 4 * sheetScale),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${i + 1}. ${_partTitle(previewParts[i])}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xFFCAD2C5),
                      fontSize: 14 * sheetScale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(width: 8 * sheetScale),
                Text(
                  _partRightMeta(previewParts[i]),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: const Color(0xFF9FB3B3),
                    fontSize: 13.5 * sheetScale,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
          if (moreCount > 0) ...[
            SizedBox(height: 4 * sheetScale),
            Text(
              '+ $moreCount개 더',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFF7F8C8C),
                fontSize: 13.5 * sheetScale,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTemplateCard(
    HomeworkRecentTemplate template, {
    required double width,
    required double sheetScale,
  }) {
    final card = _buildTemplateCardSurface(
      template,
      width: width,
      sheetScale: sheetScale,
    );
    return Draggable<HomeworkRecentTemplate>(
      data: template,
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.94,
          child: _buildTemplateCardSurface(
            template,
            width: width,
            sheetScale: sheetScale,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.34, child: card),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: card,
      ),
    );
  }

  LearningProblemDocumentExportPreset? _presetForTemplate(
    HomeworkRecentTemplate template,
  ) {
    final presetId = template.parts.isEmpty
        ? ''
        : (template.parts.first.pbPresetId ?? '').trim();
    if (presetId.isEmpty) return null;
    return _assignmentPresetById[presetId];
  }

  bool _boolFromConfig(
    Map<String, dynamic> config,
    String key,
    bool fallback,
  ) {
    final value = config[key];
    if (value is bool) return value;
    final text = '$value'.trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'false' || text == '0' || text == 'no') return false;
    return fallback;
  }

  Future<LearningProblemExportJob?> _waitForAssignmentPrintJob(
    String academyId,
    LearningProblemExportJob initialJob,
  ) async {
    var current = initialJob;
    for (var attempt = 0; attempt < 120; attempt += 1) {
      if (current.isTerminal) return current;
      await Future<void>.delayed(const Duration(seconds: 2));
      final latest = await _problemBankService.getExportJob(
        academyId: academyId,
        jobId: current.id,
      );
      if (latest != null) current = latest;
    }
    return current;
  }

  Future<void> _openPdfForPrint(String url, String presetId) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw Exception('PDF URL이 올바르지 않습니다.');
    }
    try {
      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('PDF 다운로드 실패(${response.statusCode})');
      }
      final dir = await getTemporaryDirectory();
      final safeId = presetId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final file = File(p.join(dir.path, 'generated_assignment_$safeId.pdf'));
      await file.writeAsBytes(response.bodyBytes, flush: true);
      final result = await OpenFilex.open(file.path);
      if (result.type == ResultType.done) return;
    } catch (_) {
      // 다운로드/open 실패 시에도 브라우저에서 PDF를 열 수 있게 fallback 한다.
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw Exception('PDF를 열 수 없습니다.');
    }
  }

  Future<void> _printGeneratedAssignmentPreset(
    LearningProblemDocumentExportPreset preset,
  ) async {
    final academyId = await TenantService.instance.getActiveAcademyId();
    if (academyId == null || academyId.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('학원 정보가 없어 인쇄할 수 없습니다.')),
      );
      return;
    }
    final sourceDocumentId = preset.sourceDocumentId.trim().isNotEmpty
        ? preset.sourceDocumentId.trim()
        : (preset.sourceDocumentIds.isEmpty
            ? ''
            : preset.sourceDocumentIds.first);
    final selectedUids = preset.selectedQuestionUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (sourceDocumentId.isEmpty || selectedUids.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('과제의 원본 문항 정보를 찾지 못했습니다.')),
      );
      return;
    }
    if (mounted) setState(() => _printingPresetId = preset.id);
    try {
      final renderConfig = <String, dynamic>{
        ...preset.renderConfig,
        'selectedQuestionUidsOrdered': selectedUids,
        'selectedQuestionIdsOrdered': selectedUids,
        'questionModeByQuestionUid': preset.questionModeByQuestionUid,
        'questionModeByQuestionId': preset.questionModeByQuestionUid,
        'presetKind': 'assignment',
        'assignmentLibraryKind': 'generated_assignment',
      };
      final job = await _problemBankService.createExportJob(
        academyId: academyId.trim(),
        documentId: sourceDocumentId,
        templateProfile: preset.templateProfile.isEmpty
            ? 'assignment'
            : preset.templateProfile,
        paperSize: preset.paperSize.isEmpty ? 'A4' : preset.paperSize,
        includeAnswerSheet:
            _boolFromConfig(renderConfig, 'includeAnswerSheet', true),
        includeExplanation:
            _boolFromConfig(renderConfig, 'includeExplanation', false),
        selectedQuestionUids: selectedUids,
        renderHash: buildLearningRenderHashFromConfig(renderConfig),
        previewOnly: false,
        options: renderConfig,
      );
      final completed = await _waitForAssignmentPrintJob(academyId.trim(), job);
      if (!mounted) return;
      if (completed == null ||
          completed.status != 'completed' ||
          completed.outputUrl.trim().isEmpty) {
        final err = completed?.errorMessage.isNotEmpty == true
            ? completed!.errorMessage
            : (completed?.errorCode ?? completed?.status ?? 'unknown');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('과제 PDF 생성 실패: $err')),
        );
        return;
      }
      await _openPdfForPrint(completed.outputUrl.trim(), preset.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('과제 인쇄 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _printingPresetId = '');
    }
  }

  Future<void> _deleteGeneratedAssignmentPreset(
    LearningProblemDocumentExportPreset preset,
  ) async {
    final presetId = preset.id.trim();
    if (presetId.isEmpty) return;
    final title = preset.displayName.trim().isEmpty
        ? '문제은행 과제'
        : preset.displayName.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kDlgBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: kDlgBorder),
          ),
          title: const Text(
            '미리 만든 과제 삭제',
            style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
          ),
          content: Text(
            '"$title" 과제를 목록에서 삭제할까요?',
            style: const TextStyle(color: kDlgTextSub, height: 1.35),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB74C4C),
                foregroundColor: Colors.white,
              ),
              child: const Text('삭제'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      final safeAcademyId = (academyId ?? '').trim();
      if (safeAcademyId.isEmpty) {
        throw Exception('학원 정보를 찾지 못했습니다.');
      }
      await _problemBankService.deleteExportPreset(
        academyId: safeAcademyId,
        presetId: presetId,
      );
      LearningProblemBankService.generatedAssignmentChanged.add(null);
      await _refreshTemplates();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('미리 만든 과제를 삭제했습니다.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('과제 삭제 실패: $e')),
      );
    }
  }

  Widget _buildAssignmentCard(
    HomeworkRecentTemplate template, {
    required double width,
    required double sheetScale,
  }) {
    final preset = _presetForTemplate(template);
    final presetId = preset?.id ?? '';
    final isPrinting = presetId.isNotEmpty && _printingPresetId == presetId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTemplateCard(template, width: width, sheetScale: sheetScale),
        SizedBox(height: 6 * sheetScale),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: preset == null || isPrinting
                  ? null
                  : () => unawaited(_printGeneratedAssignmentPreset(preset)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFC7F2D8),
                disabledForegroundColor: const Color(0xFF7CA39A),
                side: const BorderSide(color: Color(0xFF285C46), width: 1.1),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.symmetric(
                  horizontal: 10 * sheetScale,
                  vertical: 7 * sheetScale,
                ),
              ),
              icon: isPrinting
                  ? SizedBox(
                      width: 14 * sheetScale,
                      height: 14 * sheetScale,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.print_rounded, size: 16 * sheetScale),
              label: Text(
                isPrinting ? '생성 중' : '바로 인쇄',
                style: TextStyle(
                  fontSize: 13 * sheetScale,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SizedBox(width: 6 * sheetScale),
            Tooltip(
              message: '삭제',
              child: IconButton(
                onPressed: preset == null || isPrinting
                    ? null
                    : () => unawaited(_deleteGeneratedAssignmentPreset(preset)),
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 20 * sheetScale,
                  color: const Color(0xFFE57373),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sheetScale =
        ((widget.containerWidth / 420.0).clamp(0.78, 1.0)).toDouble();
    final headerTitleFont = 16.0 * sheetScale;
    final headerHintFont = 14.5 * sheetScale;
    final headerIconSize = 18.0 * sheetScale;
    final activeTemplates = _activeTemplates();
    final filteredTemplates = _filteredTemplates();
    final isAssignmentMode = _mode == _TemplateLibraryMode.assignments;
    final bookIds = activeTemplates
        .map(_templateBookKey)
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => (isAssignmentMode ? a : _bookName(a))
          .compareTo(isAssignmentMode ? b : _bookName(b)));
    final gradeLabels = activeTemplates
        .map((e) => e.primaryGradeLabel)
        .where((e) => e.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12 * sheetScale,
        12 * sheetScale,
        12 * sheetScale,
        10 * sheetScale,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.star_rounded, size: headerIconSize, color: kDlgAccent),
              SizedBox(width: 8 * sheetScale),
              Expanded(
                child: Text(
                  isAssignmentMode ? '미리 만든 과제' : '최근 과제 즐겨찾기',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: kDlgText,
                    fontWeight: FontWeight.w900,
                    fontSize: headerTitleFont,
                  ),
                ),
              ),
              SizedBox(
                width: 34 * sheetScale,
                height: 34 * sheetScale,
                child: IconButton(
                  onPressed:
                      _loading ? null : () => unawaited(_refreshTemplates()),
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: headerIconSize,
                    color: kDlgTextSub,
                  ),
                  tooltip: '새로고침',
                  padding: EdgeInsets.zero,
                  splashRadius: 18 * sheetScale,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          SizedBox(height: 4 * sheetScale),
          Text(
            isAssignmentMode
                ? '생성한 과제를 드래그해 배정하거나 설정한 레이아웃 그대로 인쇄하세요.'
                : '카드를 드래그해 오른쪽 학생 카드에 드롭하세요.',
            style: TextStyle(
              color: const Color(0xFF7F8C8C),
              fontSize: headerHintFont,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 10 * sheetScale),
          Wrap(
            children: [
              _buildFilterChip(
                label: '즐겨찾기',
                selected: _mode == _TemplateLibraryMode.favorites,
                onTap: () => _selectMode(_TemplateLibraryMode.favorites),
                sheetScale: sheetScale,
              ),
              _buildFilterChip(
                label: '미리 만든 과제',
                selected: _mode == _TemplateLibraryMode.assignments,
                onTap: () => _selectMode(_TemplateLibraryMode.assignments),
                sheetScale: sheetScale,
              ),
            ],
          ),
          SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  children: [
                    _buildFilterChip(
                      label: '전체 교재',
                      selected: _bookFilter.isEmpty,
                      onTap: () => setState(() => _bookFilter = ''),
                      sheetScale: sheetScale,
                    ),
                    for (final bookId in bookIds)
                      _buildFilterChip(
                        label: isAssignmentMode ? bookId : _bookName(bookId),
                        selected: _bookFilter == bookId,
                        onTap: () => setState(() => _bookFilter = bookId),
                        sheetScale: sheetScale,
                      ),
                  ],
                ),
                Wrap(
                  children: [
                    _buildFilterChip(
                      label: '전체 학년',
                      selected: _gradeFilter.isEmpty,
                      onTap: () => setState(() => _gradeFilter = ''),
                      sheetScale: sheetScale,
                    ),
                    for (final grade in gradeLabels)
                      _buildFilterChip(
                        label: grade,
                        selected: _gradeFilter == grade,
                        onTap: () => setState(() => _gradeFilter = grade),
                        sheetScale: sheetScale,
                      ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: 8 * sheetScale),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth;
                if (_loading) {
                  return const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
                      ),
                    ),
                  );
                }
                if (filteredTemplates.isEmpty) {
                  return Center(
                    child: Text(
                      isAssignmentMode
                          ? '아직 미리 만든 과제가 없습니다.'
                          : '표시할 최근 과제가 없습니다.',
                      style: const TextStyle(
                        color: kDlgTextSub,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: filteredTemplates.length,
                  separatorBuilder: (_, __) => SizedBox(height: 8 * sheetScale),
                  itemBuilder: (context, index) {
                    final template = filteredTemplates[index];
                    if (isAssignmentMode) {
                      return _buildAssignmentCard(
                        template,
                        width: cardWidth,
                        sheetScale: sheetScale,
                      );
                    }
                    return _buildTemplateCard(
                      template,
                      width: cardWidth,
                      sheetScale: sheetScale,
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
