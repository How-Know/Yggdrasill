import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/student_flow.dart';
import '../../screens/learning/models/problem_bank_export_models.dart';
import '../../screens/learning/widgets/problem_bank_export_server_preview_dialog.dart';
import '../../services/data_manager.dart';
import '../../services/homework_store.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../services/tenant_service.dart';
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
  _TemplateLibraryMode _mode = _TemplateLibraryMode.assignments;
  List<HomeworkRecentTemplate> _templates = const [];
  List<HomeworkRecentTemplate> _assignmentTemplates = const [];
  Map<String, LearningProblemDocumentExportPreset> _assignmentPresetById =
      const <String, LearningProblemDocumentExportPreset>{};
  Map<String, String> _bookNameById = const <String, String>{};
  final LearningProblemBankService _problemBankService =
      LearningProblemBankService();
  StreamSubscription<void>? _assignmentPresetSubscription;
  String _printingPresetId = '';
  String _previewingPresetId = '';
  bool _assignmentOrderMode = false;
  bool _savingAssignmentOrder = false;
  bool _pendingAssignmentOrderSave = false;

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
      final sortedAssignmentPresets =
          _sortGeneratedAssignmentPresets(assignmentPresets);
      final assignmentTemplates = sortedAssignmentPresets
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
        ...assignmentTemplates
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
      setState(() {
        _templates = templates;
        _assignmentTemplates = assignmentTemplates;
        _assignmentPresetById = <String, LearningProblemDocumentExportPreset>{
          for (final preset in assignmentPresets) preset.id: preset,
        };
        _bookNameById = bookNameById;
        if (_bookFilter.isNotEmpty &&
            !_activeTemplates()
                .any((t) => _templateBookKey(t) == _bookFilter)) {
          _bookFilter = '';
        }
        if (_gradeFilter.isNotEmpty &&
            !_activeTemplates()
                .any((t) => t.primaryGradeLabel == _gradeFilter)) {
          _gradeFilter = '';
        }
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
    final course = _assignmentCourseLabel(template);
    final bookId = template.primaryBookId.trim();
    String stripCourseAndUnit(String raw) {
      var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || course.isEmpty) return text;
      final normalizedCourse = course.replaceAll(RegExp(r'\s+'), ' ').trim();
      final idx = text.indexOf(normalizedCourse);
      if (idx > 0) {
        text = text.substring(0, idx).trim();
      }
      return text.replaceAll(RegExp(r'[\s·>\-/,:]+$'), '').trim();
    }

    if (bookId.isNotEmpty) {
      final named = (_bookNameById[bookId] ?? '').trim();
      if (named.isNotEmpty) return stripCourseAndUnit(named);
    }
    for (final part in template.parts) {
      final value = (part.sourceUnitPath ?? '').trim();
      if (value.isNotEmpty) return stripCourseAndUnit(value);
    }
    return '';
  }

  String _assignmentCourseLabel(HomeworkRecentTemplate template) {
    String normalizeCourse(String raw) {
      final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return '';
      final compact = text.replaceAll(' ', '');
      final numeric = RegExp(r'([1-6])[-\s]?([1-2])').firstMatch(text);
      if (numeric != null) {
        return '${numeric.group(1)}-${numeric.group(2)}';
      }
      for (final keyword in <String>[
        '공통수학1',
        '공통수학2',
        '수학상',
        '수학하',
        '수학I',
        '수학II',
        '미적분1',
        '미적분2',
        '확률과통계',
        '대수',
      ]) {
        if (compact.contains(keyword)) return keyword;
      }
      return text.split(RegExp(r'[·>/,]|\s{2,}')).first.trim();
    }

    final preset = _presetForTemplate(template);
    final fromPreset = normalizeCourse(preset?.assignmentCourseLabel ?? '');
    if (fromPreset.isNotEmpty) return fromPreset;
    final rawBook = preset?.assignmentBookLabel.trim() ?? '';
    final fromBook = normalizeCourse(rawBook);
    if (fromBook.isNotEmpty && fromBook != rawBook) return fromBook;
    for (final part in template.parts) {
      final grade = (part.gradeLabel ?? '').trim();
      final normalized = normalizeCourse(grade);
      if (normalized.isNotEmpty) return normalized;
      final source = normalizeCourse(part.sourceUnitPath ?? '');
      if (source.isNotEmpty && source != (part.sourceUnitPath ?? '').trim()) {
        return source;
      }
    }
    return '';
  }

  String _assignmentBookCourseKey(HomeworkRecentTemplate template) {
    final book = _assignmentBookLabel(template);
    final course = _assignmentCourseLabel(template);
    if (book.isEmpty && course.isEmpty) return '';
    return '$book\t$course';
  }

  String _assignmentBookCourseLabel(HomeworkRecentTemplate template) {
    final book = _assignmentBookLabel(template);
    final course = _assignmentCourseLabel(template);
    if (book.isEmpty && course.isEmpty) return '교재 없음';
    if (book.isEmpty) return course;
    if (course.isEmpty) return book;
    return '$book $course';
  }

  String _templateBookKey(HomeworkRecentTemplate template) {
    if (_isGeneratedAssignmentTemplate(template)) {
      return _assignmentBookCourseKey(template);
    }
    return template.primaryBookId.trim();
  }

  String _templateBookLabel(HomeworkRecentTemplate template) {
    if (_isGeneratedAssignmentTemplate(template)) {
      return _assignmentBookCourseLabel(template);
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
    final isAssignmentMode = _mode == _TemplateLibraryMode.assignments;
    for (final template in _activeTemplates()) {
      if (_bookFilter.isNotEmpty && _templateBookKey(template) != _bookFilter) {
        continue;
      }
      if (!isAssignmentMode &&
          _gradeFilter.isNotEmpty &&
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

  int? _assignmentLibraryOrder(LearningProblemDocumentExportPreset preset) {
    if (preset.assignmentLibraryOrder != null) {
      return preset.assignmentLibraryOrder;
    }
    final raw = preset.renderConfig['assignmentLibraryOrder'] ??
        preset.renderConfig['assignmentSortOrder'] ??
        preset.renderConfig['sortOrder'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw');
  }

  List<LearningProblemDocumentExportPreset> _sortGeneratedAssignmentPresets(
    List<LearningProblemDocumentExportPreset> presets,
  ) {
    final out = presets.toList(growable: true);
    out.sort((a, b) {
      final aOrder = _assignmentLibraryOrder(a);
      final bOrder = _assignmentLibraryOrder(b);
      if (aOrder != null && bOrder != null && aOrder != bOrder) {
        return aOrder.compareTo(bOrder);
      }
      if (aOrder != null && bOrder == null) return -1;
      if (aOrder == null && bOrder != null) return 1;
      final aDate = a.updatedAt ?? a.createdAt ?? DateTime(1970);
      final bDate = b.updatedAt ?? b.createdAt ?? DateTime(1970);
      final dateCmp = bDate.compareTo(aDate);
      if (dateCmp != 0) return dateCmp;
      return a.id.compareTo(b.id);
    });
    return out;
  }

  String _presetIdForTemplate(HomeworkRecentTemplate template) {
    if (template.parts.isEmpty) return '';
    return (template.parts.first.pbPresetId ?? '').trim();
  }

  Future<void> _saveAssignmentTemplateOrder(
    List<HomeworkRecentTemplate> orderedTemplates,
  ) async {
    if (_savingAssignmentOrder) {
      _pendingAssignmentOrderSave = true;
      return;
    }
    final presetIds = orderedTemplates
        .map(_presetIdForTemplate)
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (presetIds.isEmpty) return;
    setState(() => _savingAssignmentOrder = true);
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      final safeAcademyId = (academyId ?? '').trim();
      if (safeAcademyId.isEmpty) {
        throw Exception('학원 정보를 찾지 못했습니다.');
      }
      await _problemBankService.saveGeneratedAssignmentPresetOrder(
        academyId: safeAcademyId,
        orderedPresetIds: presetIds,
      );
      LearningProblemBankService.generatedAssignmentChanged.add(null);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('과제 순서 저장 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingAssignmentOrder = false);
      if (_pendingAssignmentOrderSave && mounted) {
        _pendingAssignmentOrderSave = false;
        unawaited(_saveAssignmentTemplateOrder(_assignmentTemplates));
      }
    }
  }

  void _reorderAssignmentTemplates({
    required int oldIndex,
    required int newIndex,
    required List<HomeworkRecentTemplate> visibleTemplates,
  }) {
    if (oldIndex < 0 || oldIndex >= visibleTemplates.length) return;
    var targetIndex = newIndex;
    if (targetIndex > oldIndex) targetIndex -= 1;
    if (targetIndex < 0) targetIndex = 0;
    if (targetIndex >= visibleTemplates.length) {
      targetIndex = visibleTemplates.length - 1;
    }
    if (oldIndex == targetIndex) return;

    final reorderedVisible = visibleTemplates.toList(growable: true);
    final moved = reorderedVisible.removeAt(oldIndex);
    reorderedVisible.insert(targetIndex, moved);
    final visibleIds = visibleTemplates.map((e) => e.templateId).toSet();
    final visibleQueue = reorderedVisible.toList(growable: true);
    final merged = _assignmentTemplates.map((template) {
      if (!visibleIds.contains(template.templateId)) return template;
      return visibleQueue.removeAt(0);
    }).toList(growable: false);
    setState(() => _assignmentTemplates = merged);
    unawaited(_saveAssignmentTemplateOrder(merged));
  }

  void _selectMode(_TemplateLibraryMode mode) {
    if (_mode == mode) return;
    final nextTemplates = mode == _TemplateLibraryMode.assignments
        ? _assignmentTemplates
        : _templates;
    setState(() {
      _mode = mode;
      _assignmentOrderMode = false;
      if (mode == _TemplateLibraryMode.assignments) {
        _gradeFilter = '';
      }
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
    VoidCallback? onTitleTap,
    VoidCallback? onFlowTap,
  }) {
    final title =
        template.title.trim().isEmpty ? '(제목 없음)' : template.title.trim();
    final grade = template.primaryGradeLabel.trim();
    final bookText = _templateBookLabel(template);
    final gradeText = grade.isEmpty ? '학년 미지정' : grade;
    final preferredFlowName = template.primaryPreferredFlowName.trim();
    final kindLabel = template.isGroup
        ? '그룹 과제 · 하위 ${template.partCount}개'
        : '단일 과제';
    final flowLabel = preferredFlowName.isNotEmpty
        ? '$preferredFlowName 플로우'
        : '플로우 미지정';
    final subtitleMetaStyle = TextStyle(
      color: const Color(0xFF8FA3A3),
      fontSize: 14.5 * sheetScale,
      fontWeight: FontWeight.w700,
    );
    final subtitleFlowStyle = TextStyle(
      color: const Color(0xFF9FE3C6),
      fontSize: 14.5 * sheetScale,
      fontWeight: FontWeight.w800,
      decoration: onFlowTap == null ? TextDecoration.none : TextDecoration.underline,
      decorationColor: const Color(0xFF617777),
    );
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
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTitleTap,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: onTitleTap == null ? 0 : 2 * sheetScale,
                  vertical: onTitleTap == null ? 0 : 1 * sheetScale,
                ),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: kDlgText,
                    fontSize: titleFontSize,
                    fontWeight: FontWeight.w600,
                    decoration: onTitleTap == null
                        ? TextDecoration.none
                        : TextDecoration.underline,
                    decorationColor: const Color(0xFF617777),
                  ),
                ),
              ),
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
          Row(
            children: [
              Flexible(
                child: Text(
                  onFlowTap == null && preferredFlowName.isNotEmpty
                      ? '$kindLabel · $flowLabel'
                      : kindLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: subtitleMetaStyle,
                ),
              ),
              if (onFlowTap != null) ...[
                Text(' · ', style: subtitleMetaStyle),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onFlowTap,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 2 * sheetScale,
                        vertical: 1 * sheetScale,
                      ),
                      child: Text(
                        flowLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: subtitleFlowStyle,
                      ),
                    ),
                  ),
                ),
              ],
            ],
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
    VoidCallback? onTitleTap,
    VoidCallback? onFlowTap,
    bool draggable = true,
  }) {
    final card = _buildTemplateCardSurface(
      template,
      width: width,
      sheetScale: sheetScale,
      onTitleTap: onTitleTap,
      onFlowTap: onFlowTap,
    );
    if (!draggable) return card;
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
            onTitleTap: onTitleTap,
            onFlowTap: onFlowTap,
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

  List<String> _selectedQuestionUidsForPreset(
    LearningProblemDocumentExportPreset preset,
  ) {
    return preset.selectedQuestionUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  String _sourceDocumentIdForPreset(
      LearningProblemDocumentExportPreset preset) {
    final sourceDocumentId = preset.sourceDocumentId.trim();
    if (sourceDocumentId.isNotEmpty) return sourceDocumentId;
    return preset.sourceDocumentIds.isEmpty
        ? ''
        : preset.sourceDocumentIds.first.trim();
  }

  Map<String, dynamic> _assignmentRenderConfigForPreset(
    LearningProblemDocumentExportPreset preset, {
    ProblemBankPreviewRefreshRequest? request,
  }) {
    final selectedUids = _selectedQuestionUidsForPreset(preset);
    final patch = request == null
        ? const <String, dynamic>{}
        : _renderPatchForAssignmentPreview(
            preset,
            request,
          );
    return <String, dynamic>{
      ...preset.renderConfig,
      ...patch,
      'selectedQuestionUidsOrdered': selectedUids,
      'selectedQuestionIdsOrdered': selectedUids,
      'questionModeByQuestionUid': preset.questionModeByQuestionUid,
      'questionModeByQuestionId': preset.questionModeByQuestionUid,
      'presetKind': 'assignment',
      'assignmentLibraryKind': 'generated_assignment',
      'disableAutoLabels': true,
    };
  }

  Map<String, dynamic> _renderPatchForAssignmentPreview(
    LearningProblemDocumentExportPreset preset,
    ProblemBankPreviewRefreshRequest request,
  ) {
    final settings = LearningProblemExportSettings.fromPresetRenderConfig(
      base: LearningProblemExportSettings.initial(),
      renderConfig: preset.renderConfig,
    );
    final topText = request.titlePageTopText.trim();
    final goalText = request.titlePageGoalText.trim();
    final timeLimitText = request.timeLimitText.trim();
    final patch = <String, dynamic>{
      'subjectTitleText': request.subjectTitleText.trim().isEmpty
          ? '수학 영역'
          : request.subjectTitleText.trim(),
      'titlePageTopText':
          topText.isEmpty ? kLearningDefaultTitlePageTopText : topText,
      'titlePageGoalText':
          goalText.isEmpty ? kLearningDefaultTitlePageGoalText : goalText,
      'timeLimitText': timeLimitText,
      'includeAcademyLogo': request.includeAcademyLogo,
      'includeCoverPage': request.includeCoverPage,
      'coverPageTexts': request.coverPageTexts,
      'includeAnswerSheet': request.includeAnswerSheet,
      'includeExplanation': request.includeExplanation,
      'includeQuestionScore': request.includeQuestionScore,
      'questionScoreByQuestionUid': request.questionScoreByQuestionId,
      'questionScoreByQuestionId': request.questionScoreByQuestionId,
      'mathEngine': request.mathEngine,
      'disableAutoLabels': request.disableAutoLabels,
    };
    if (request.pageColumnQuestionCounts.isNotEmpty) {
      patch['pageColumnQuestionCounts'] = request.pageColumnQuestionCounts;
    }
    if (settings.layoutColumnCount == 2) {
      patch['layoutMode'] = 'custom_columns';
      patch['columnLabelAnchors'] = request.columnLabelAnchors;
      patch['titlePageIndices'] = request.titlePageIndices;
      patch['titlePageHeaders'] = request.titlePageHeaders;
    }
    if (request.assignmentFlowName.trim().isNotEmpty) {
      patch['assignmentFlowName'] = StudentFlow.normalizeName(
        request.assignmentFlowName.trim(),
      );
    }
    return patch;
  }

  List<Map<String, dynamic>> _readMapRows(dynamic primary, dynamic fallback) {
    final source = primary is List ? primary : fallback;
    if (source is! List) return const <Map<String, dynamic>>[];
    return source
        .whereType<Map>()
        .map((e) => e.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
  }

  Map<String, dynamic> _readCoverPageTexts(
    dynamic primary,
    dynamic fallback,
  ) {
    final source = primary is Map
        ? primary
        : (fallback is Map ? fallback : const <String, dynamic>{});
    return source.map((key, value) => MapEntry('$key', value));
  }

  Map<String, double> _readScoreMap(dynamic primary, dynamic fallback) {
    final source = primary is Map
        ? primary
        : (fallback is Map ? fallback : const <String, dynamic>{});
    final out = <String, double>{};
    for (final entry in source.entries) {
      final id = '${entry.key}'.trim();
      if (id.isEmpty) continue;
      final raw = entry.value;
      final score = raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (score == null || !score.isFinite || score < 0) continue;
      out[id] = score;
    }
    return out;
  }

  List<int> _readPositiveIntList(
    dynamic primary,
    dynamic fallback, {
    List<int> defaults = const <int>[1],
  }) {
    final source = primary is List ? primary : fallback;
    if (source is! List) return defaults;
    final out = source
        .map((e) => int.tryParse('$e'))
        .whereType<int>()
        .where((e) => e > 0)
        .toList(growable: false);
    return out.isEmpty ? defaults : out;
  }

  bool _readBoolFlag(dynamic primary, dynamic fallback, bool defaultValue) {
    var value = primary;
    value ??= fallback;
    if (value is bool) return value;
    final text = '$value'.trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes' || text == 'y') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'n') {
      return false;
    }
    return defaultValue;
  }

  String _normalizeMathEngineValue(dynamic raw) {
    final value = '$raw'.trim().toLowerCase();
    if (value == 'mathjax-svg') return 'mathjax-svg';
    if (value == 'xelatex-v2') return 'xelatex-v2';
    return 'xelatex';
  }

  List<ProblemBankPreviewQuestionScoreEntry> _scoreEntriesForPreset(
    LearningProblemDocumentExportPreset preset,
  ) {
    final scores = _readScoreMap(
      preset.renderConfig['questionScoreByQuestionUid'],
      preset.renderConfig['questionScoreByQuestionId'],
    );
    return _selectedQuestionUidsForPreset(preset).asMap().entries.map((entry) {
      final uid = entry.value;
      return ProblemBankPreviewQuestionScoreEntry(
        questionId: uid,
        questionNumber: '${entry.key + 1}',
        defaultScore: scores[uid] ?? 3,
      );
    }).toList(growable: false);
  }

  ProblemBankPreviewRefreshResult _previewResultFromJob(
    LearningProblemExportJob job,
    ProblemBankPreviewRefreshRequest request,
  ) {
    final result = job.resultSummary;
    final options = job.options;
    final mathEngine = _normalizeMathEngineValue(
      result['mathEngine'] ?? options['mathEngine'] ?? request.mathEngine,
    );
    final titlePageTopText =
        '${result['titlePageTopText'] ?? options['titlePageTopText'] ?? request.titlePageTopText}'
            .trim();
    final titlePageGoalText =
        '${result['titlePageGoalText'] ?? options['titlePageGoalText'] ?? request.titlePageGoalText}'
            .trim();
    final timeLimitText =
        '${result['timeLimitText'] ?? options['timeLimitText'] ?? request.timeLimitText}'
            .trim();
    final questionScoreByUid = _readScoreMap(
      result['questionScoreByQuestionUid'],
      options['questionScoreByQuestionUid'],
    );
    final questionScoreById = _readScoreMap(
      result['questionScoreByQuestionId'],
      options['questionScoreByQuestionId'],
    );
    return ProblemBankPreviewRefreshResult(
      pdfUrl: job.outputUrl,
      mathEngine: mathEngine,
      titlePageTopText: titlePageTopText.isEmpty
          ? kLearningDefaultTitlePageTopText
          : titlePageTopText,
      titlePageGoalText: titlePageGoalText.isEmpty
          ? kLearningDefaultTitlePageGoalText
          : titlePageGoalText,
      timeLimitText: timeLimitText,
      pageColumnQuestionCounts: _readMapRows(
        result['pageColumnQuestionCounts'],
        options['pageColumnQuestionCounts'],
      ),
      columnLabelAnchors: _readMapRows(
        result['columnLabelAnchors'],
        options['columnLabelAnchors'],
      ),
      titlePageIndices: _readPositiveIntList(
        result['titlePageIndices'],
        options['titlePageIndices'],
      ),
      titlePageHeaders: _readMapRows(
        result['titlePageHeaders'],
        options['titlePageHeaders'],
      ),
      coverPageTexts: _readCoverPageTexts(
        result['coverPageTexts'],
        options['coverPageTexts'],
      ),
      includeAcademyLogo: _readBoolFlag(
        result['includeAcademyLogo'],
        options['includeAcademyLogo'],
        request.includeAcademyLogo,
      ),
      includeCoverPage: _readBoolFlag(
        result['includeCoverPage'],
        options['includeCoverPage'],
        request.includeCoverPage,
      ),
      includeAnswerSheet: _readBoolFlag(
        result['includeAnswerSheet'],
        options['includeAnswerSheet'],
        request.includeAnswerSheet,
      ),
      includeExplanation: _readBoolFlag(
        result['includeExplanation'],
        options['includeExplanation'],
        request.includeExplanation,
      ),
      includeQuestionScore: _readBoolFlag(
        result['includeQuestionScore'],
        options['includeQuestionScore'],
        request.includeQuestionScore,
      ),
      questionScoreByQuestionId: questionScoreByUid.isNotEmpty
          ? questionScoreByUid
          : questionScoreById,
    );
  }

  Future<LearningProblemExportJob> _createAssignmentExportJob({
    required String academyId,
    required LearningProblemDocumentExportPreset preset,
    required bool previewOnly,
    ProblemBankPreviewRefreshRequest? request,
  }) {
    final sourceDocumentId = _sourceDocumentIdForPreset(preset);
    final selectedUids = _selectedQuestionUidsForPreset(preset);
    final renderConfig = _assignmentRenderConfigForPreset(
      preset,
      request: request,
    );
    return _problemBankService.createExportJob(
      academyId: academyId,
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
      previewOnly: previewOnly,
      options: renderConfig,
    );
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

  Future<void> _previewGeneratedAssignmentPreset(
    LearningProblemDocumentExportPreset preset,
  ) async {
    final academyId = await TenantService.instance.getActiveAcademyId();
    final safeAcademyId = (academyId ?? '').trim();
    if (safeAcademyId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('학원 정보가 없어 과제를 볼 수 없습니다.')),
      );
      return;
    }
    final selectedUids = _selectedQuestionUidsForPreset(preset);
    if (_sourceDocumentIdForPreset(preset).isEmpty || selectedUids.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('과제의 원본 문항 정보를 찾지 못했습니다.')),
      );
      return;
    }

    if (mounted) setState(() => _previewingPresetId = preset.id);
    try {
      final initialJob = await _createAssignmentExportJob(
        academyId: safeAcademyId,
        preset: preset,
        previewOnly: true,
      );
      final completed =
          await _waitForAssignmentPrintJob(safeAcademyId, initialJob);
      if (!mounted) return;
      if (completed == null ||
          completed.status != 'completed' ||
          completed.outputUrl.trim().isEmpty) {
        final err = completed?.errorMessage.isNotEmpty == true
            ? completed!.errorMessage
            : (completed?.errorCode ?? completed?.status ?? 'unknown');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('과제 미리보기 생성 실패: $err')),
        );
        return;
      }

      final renderConfig = _assignmentRenderConfigForPreset(preset);
      final settings = LearningProblemExportSettings.fromPresetRenderConfig(
        base: LearningProblemExportSettings.initial(),
        renderConfig: renderConfig,
      );
      final subjectTitle = '${renderConfig['subjectTitleText'] ?? ''}'.trim();
      final titlePageTopText =
          '${renderConfig['titlePageTopText'] ?? ''}'.trim();
      final titlePageGoalText =
          '${renderConfig['titlePageGoalText'] ?? ''}'.trim();
      final timeLimitText = '${renderConfig['timeLimitText'] ?? ''}'.trim();
      final initialMathEngine = _normalizeMathEngineValue(
        renderConfig['mathEngine'] ?? completed.resultSummary['mathEngine'],
      );
      await ProblemBankExportServerPreviewDialog.open(
        context,
        pdfUrl: completed.outputUrl.trim(),
        titleText: '과제보기 (${selectedUids.length}문항)',
        initialSubjectTitle: subjectTitle.isEmpty ? '수학 영역' : subjectTitle,
        initialTitlePageTopText: titlePageTopText.isEmpty
            ? kLearningDefaultTitlePageTopText
            : titlePageTopText,
        initialTitlePageGoalText: titlePageGoalText.isEmpty
            ? kLearningDefaultTitlePageGoalText
            : titlePageGoalText,
        isAssignmentTemplate: settings.templateProfile == 'assignment',
        initialTimeLimitText: timeLimitText,
        layoutColumns: settings.layoutColumnCount,
        maxQuestionsPerPage: settings.maxQuestionsPerPageCount,
        totalQuestionCount: selectedUids.length,
        initialPageColumnQuestionCounts: _readMapRows(
          renderConfig['pageColumnQuestionCounts'],
          completed.resultSummary['pageColumnQuestionCounts'],
        ),
        initialColumnLabelAnchors: _readMapRows(
          renderConfig['columnLabelAnchors'],
          completed.resultSummary['columnLabelAnchors'],
        ),
        initialTitlePageIndices: _readPositiveIntList(
          renderConfig['titlePageIndices'],
          completed.resultSummary['titlePageIndices'],
        ),
        initialTitlePageHeaders: _readMapRows(
          renderConfig['titlePageHeaders'],
          completed.resultSummary['titlePageHeaders'],
        ),
        initialCoverPageTexts: _readCoverPageTexts(
          renderConfig['coverPageTexts'],
          completed.resultSummary['coverPageTexts'],
        ),
        initialIncludeAcademyLogo: _readBoolFlag(
          renderConfig['includeAcademyLogo'],
          completed.resultSummary['includeAcademyLogo'],
          settings.includeAcademyLogo,
        ),
        initialIncludeCoverPage: _readBoolFlag(
          renderConfig['includeCoverPage'],
          completed.resultSummary['includeCoverPage'],
          false,
        ),
        initialIncludeAnswerSheet: _readBoolFlag(
          renderConfig['includeAnswerSheet'],
          completed.resultSummary['includeAnswerSheet'],
          settings.includeAnswerSheet,
        ),
        initialIncludeExplanation: _readBoolFlag(
          renderConfig['includeExplanation'],
          completed.resultSummary['includeExplanation'],
          settings.includeExplanation,
        ),
        initialIncludeQuestionScore: _readBoolFlag(
          renderConfig['includeQuestionScore'],
          completed.resultSummary['includeQuestionScore'],
          settings.includeQuestionScore,
        ),
        initialMathEngine: initialMathEngine,
        initialQuestionScoreByQuestionId: _readScoreMap(
          renderConfig['questionScoreByQuestionUid'],
          renderConfig['questionScoreByQuestionId'],
        ),
        questionScoreEntries: _scoreEntriesForPreset(preset),
        initialEditingPresetId: preset.id,
        initialEditingPresetName: preset.displayName,
        assignmentFlowNames: StudentFlow.defaultNames,
        onRefreshRequested: (request) async {
          final job = await _createAssignmentExportJob(
            academyId: safeAcademyId,
            preset: preset,
            previewOnly: true,
            request: request,
          );
          final refreshed =
              await _waitForAssignmentPrintJob(safeAcademyId, job);
          if (!mounted || refreshed == null) return null;
          if (refreshed.status != 'completed' ||
              refreshed.outputUrl.trim().isEmpty) {
            final err = refreshed.errorMessage.isNotEmpty
                ? refreshed.errorMessage
                : refreshed.errorCode;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '미리보기 생성 실패: ${err.isEmpty ? refreshed.status : err}',
                ),
              ),
            );
            return null;
          }
          return _previewResultFromJob(refreshed, request);
        },
        onGeneratePdfRequested: (request) async {
          final job = await _createAssignmentExportJob(
            academyId: safeAcademyId,
            preset: preset,
            previewOnly: false,
            request: request,
          );
          final generated =
              await _waitForAssignmentPrintJob(safeAcademyId, job);
          if (!mounted || generated == null) return;
          if (generated.status != 'completed' ||
              generated.outputUrl.trim().isEmpty) {
            final err = generated.errorMessage.isNotEmpty
                ? generated.errorMessage
                : generated.errorCode;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'PDF 생성 실패: ${err.isEmpty ? generated.status : err}',
                ),
              ),
            );
            return;
          }
          await _openPdfForPrint(generated.outputUrl.trim(), preset.id);
        },
        onSaveSettingsRequested: (request) async {
          final renderConfig = _assignmentRenderConfigForPreset(
            preset,
            request: request,
          );
          final presetIdToUpdate = request.presetIdToUpdate.trim();
          final displayName = request.presetDisplayName.trim().isEmpty
              ? preset.displayName
              : request.presetDisplayName.trim();
          final result = await _problemBankService.saveExportSettingsAsDocument(
            academyId: safeAcademyId,
            sourceDocumentId: _sourceDocumentIdForPreset(preset),
            selectedQuestionUidsOrdered: selectedUids,
            questionModeByQuestionUid: preset.questionModeByQuestionUid,
            renderConfig: renderConfig,
            templateProfile: preset.templateProfile.isEmpty
                ? 'assignment'
                : preset.templateProfile,
            paperSize: preset.paperSize.isEmpty ? 'A4' : preset.paperSize,
            includeAnswerSheet:
                _boolFromConfig(renderConfig, 'includeAnswerSheet', true),
            includeExplanation:
                _boolFromConfig(renderConfig, 'includeExplanation', false),
            displayName: displayName,
            presetId: presetIdToUpdate,
            presetKind: 'assignment',
          );
          final savedPresetId = (result.preset?.id ?? presetIdToUpdate).trim();
          if (savedPresetId.isNotEmpty) {
            await _problemBankService.overwriteExportPresetRenderConfig(
              academyId: safeAcademyId,
              presetId: savedPresetId,
              renderConfig: renderConfig,
            );
          }
          LearningProblemBankService.generatedAssignmentChanged.add(null);
          await _refreshTemplates();
          if (!mounted) return false;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                presetIdToUpdate.isNotEmpty
                    ? '미리 만든 과제를 저장했습니다.'
                    : '새 미리 만든 과제를 저장했습니다.',
              ),
            ),
          );
          return true;
        },
        onCreateAssignmentRequested: (request) async {
          final renderConfig = _assignmentRenderConfigForPreset(
            preset,
            request: request,
          );
          final displayName = request.presetDisplayName.trim().isEmpty
              ? preset.displayName
              : request.presetDisplayName.trim();
          await _problemBankService.createGeneratedAssignmentPreset(
            academyId: safeAcademyId,
            sourceDocumentId: _sourceDocumentIdForPreset(preset),
            selectedQuestionUidsOrdered: selectedUids,
            questionModeByQuestionUid: preset.questionModeByQuestionUid,
            renderConfig: renderConfig,
            templateProfile: preset.templateProfile.isEmpty
                ? 'assignment'
                : preset.templateProfile,
            paperSize: preset.paperSize.isEmpty ? 'A4' : preset.paperSize,
            includeAnswerSheet:
                _boolFromConfig(renderConfig, 'includeAnswerSheet', true),
            includeExplanation:
                _boolFromConfig(renderConfig, 'includeExplanation', false),
            displayName: displayName,
          );
          if (!mounted) return false;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('미리 만든 과제를 추가로 생성했습니다.')),
          );
          return true;
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('과제보기 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _previewingPresetId = '');
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

  Future<String?> _pickAssignmentFlowName({
    required String currentFlowName,
  }) async {
    final flowNames = StudentFlow.defaultNames
        .map(
          (e) => StudentFlow.normalizeName(
            e.replaceAll(RegExp(r'\s+'), ' ').trim(),
          ),
        )
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    var selectedFlowName = StudentFlow.normalizeName(
      currentFlowName.replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setPromptState) {
            void submit() => Navigator.of(ctx).pop(selectedFlowName);
            return AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: kDlgBorder),
              ),
              title: const Text(
                '플로우 선택',
                style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '학생에게 드롭할 때 사용할 플로우를 선택하세요.',
                      style: TextStyle(color: kDlgTextSub, height: 1.35),
                    ),
                    if (flowNames.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('지정 안 함'),
                            selected: selectedFlowName.isEmpty,
                            onSelected: (_) {
                              setPromptState(() => selectedFlowName = '');
                            },
                          ),
                          for (final flowName in flowNames)
                            ChoiceChip(
                              label: Text(flowName),
                              selected: selectedFlowName == flowName,
                              onSelected: (_) {
                                setPromptState(
                                  () => selectedFlowName = flowName,
                                );
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: submit,
                  style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                  child: const Text('저장'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == null) return null;
    return StudentFlow.normalizeName(
      result.replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
  }

  Future<void> _updateAssignmentPresetFlow(
    LearningProblemDocumentExportPreset preset,
    String flowName,
  ) async {
    final presetId = preset.id.trim();
    if (presetId.isEmpty) return;
    final normalized =
        StudentFlow.normalizeName(flowName.replaceAll(RegExp(r'\s+'), ' ').trim());
    final current = StudentFlow.normalizeName(
      '${preset.renderConfig['assignmentFlowName'] ?? preset.renderConfig['preferredFlowName'] ?? preset.renderConfig['assignmentFlow'] ?? ''}'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
    );
    if (normalized == current) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      final safeAcademyId = (academyId ?? '').trim();
      if (safeAcademyId.isEmpty) {
        throw Exception('학원 정보를 찾지 못했습니다.');
      }
      final nextRenderConfig = <String, dynamic>{...preset.renderConfig};
      if (normalized.isEmpty) {
        nextRenderConfig
          ..remove('assignmentFlowName')
          ..remove('assignmentFlow')
          ..remove('preferredFlowName')
          ..remove('assignmentFlowId')
          ..remove('flowName')
          ..remove('flowId');
      } else {
        nextRenderConfig['assignmentFlowName'] = normalized;
        nextRenderConfig
          ..remove('assignmentFlowId')
          ..remove('flowId');
      }
      await _problemBankService.overwriteExportPresetRenderConfig(
        academyId: safeAcademyId,
        presetId: presetId,
        renderConfig: nextRenderConfig,
      );
      LearningProblemBankService.generatedAssignmentChanged.add(null);
      await _refreshTemplates();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            normalized.isEmpty
                ? '플로우 지정을 해제했습니다.'
                : '플로우를 "$normalized"(으)로 변경했습니다.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('플로우 변경 실패: $e')),
      );
    }
  }

  Future<void> _editGeneratedAssignmentPresetFlow(
    LearningProblemDocumentExportPreset preset,
  ) async {
    final current =
        '${preset.renderConfig['assignmentFlowName'] ?? preset.renderConfig['preferredFlowName'] ?? preset.renderConfig['assignmentFlow'] ?? ''}'
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    final nextFlowName =
        await _pickAssignmentFlowName(currentFlowName: current);
    if (nextFlowName == null) return;
    await _updateAssignmentPresetFlow(preset, nextFlowName);
  }

  Future<void> _renameGeneratedAssignmentPreset(
    LearningProblemDocumentExportPreset preset,
  ) async {
    final presetId = preset.id.trim();
    if (presetId.isEmpty) return;
    final controller = TextEditingController(text: preset.displayName.trim());
    final nextName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kDlgBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: kDlgBorder),
          ),
          title: const Text(
            '미리 만든 과제 이름 수정',
            style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w700,
            ),
            decoration: const InputDecoration(
              hintText: '과제 이름',
              hintStyle: TextStyle(color: kDlgTextSub),
            ),
            onSubmitted: (value) => Navigator.of(ctx).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    final normalized = (nextName ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty || normalized == preset.displayName.trim()) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      final safeAcademyId = (academyId ?? '').trim();
      if (safeAcademyId.isEmpty) {
        throw Exception('학원 정보를 찾지 못했습니다.');
      }
      await _problemBankService.renameExportPreset(
        academyId: safeAcademyId,
        presetId: presetId,
        displayName: normalized,
      );
      LearningProblemBankService.generatedAssignmentChanged.add(null);
      await _refreshTemplates();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('과제 이름을 수정했습니다.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('과제 이름 수정 실패: $e')),
      );
    }
  }

  Widget _buildAssignmentCard(
    HomeworkRecentTemplate template, {
    required double width,
    required double sheetScale,
    bool orderMode = false,
    int? reorderIndex,
  }) {
    final preset = _presetForTemplate(template);
    final presetId = preset?.id ?? '';
    final isPrinting = presetId.isNotEmpty && _printingPresetId == presetId;
    final isPreviewing = presetId.isNotEmpty && _previewingPresetId == presetId;
    final isBusy = isPrinting || isPreviewing;
    final cardBody = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTemplateCard(
          template,
          width: width,
          sheetScale: sheetScale,
          draggable: !orderMode,
          onTitleTap: preset == null || isBusy
              ? null
              : () => unawaited(_renameGeneratedAssignmentPreset(preset)),
          onFlowTap: preset == null || isBusy
              ? null
              : () => unawaited(_editGeneratedAssignmentPresetFlow(preset)),
        ),
        SizedBox(height: 6 * sheetScale),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: preset == null || isBusy
                  ? null
                  : () => unawaited(_previewGeneratedAssignmentPreset(preset)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFE5F5FF),
                disabledForegroundColor: const Color(0xFF7F9AA3),
                side: const BorderSide(color: Color(0xFF2E5368), width: 1.1),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.symmetric(
                  horizontal: 10 * sheetScale,
                  vertical: 7 * sheetScale,
                ),
              ),
              icon: isPreviewing
                  ? SizedBox(
                      width: 14 * sheetScale,
                      height: 14 * sheetScale,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.article_outlined, size: 16 * sheetScale),
              label: Text(
                isPreviewing ? '여는 중' : '과제보기',
                style: TextStyle(
                  fontSize: 13 * sheetScale,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: preset == null || isBusy
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
                onPressed: preset == null || isBusy
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
    if (!orderMode || reorderIndex == null) return cardBody;
    final handleWidth = 34 * sheetScale;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ReorderableDragStartListener(
          index: reorderIndex,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Container(
              width: handleWidth,
              margin: EdgeInsets.only(top: 8 * sheetScale),
              alignment: Alignment.topCenter,
              child: Icon(
                Icons.drag_indicator_rounded,
                color: const Color(0xFF8FA3A3),
                size: 22 * sheetScale,
              ),
            ),
          ),
        ),
        SizedBox(width: 4 * sheetScale),
        Expanded(child: cardBody),
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
    final bookFilterLabelByKey = <String, String>{};
    for (final template in activeTemplates) {
      final key = _templateBookKey(template);
      if (key.trim().isEmpty || bookFilterLabelByKey.containsKey(key)) {
        continue;
      }
      bookFilterLabelByKey[key] = _templateBookLabel(template);
    }
    final bookIds = activeTemplates
        .map(_templateBookKey)
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => (isAssignmentMode ? a : _bookName(a))
          .compareTo(isAssignmentMode ? b : _bookName(b)));
    final gradeLabels = isAssignmentMode
        ? <String>[]
        : (activeTemplates
            .map((e) => e.primaryGradeLabel)
            .where((e) => e.trim().isNotEmpty)
            .toSet()
            .toList()
          ..sort());
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
              if (isAssignmentMode) ...[
                Tooltip(
                  message: _assignmentOrderMode ? '순서 편집 종료' : '순서 편집',
                  child: SizedBox(
                    width: 34 * sheetScale,
                    height: 34 * sheetScale,
                    child: IconButton(
                      onPressed: _loading
                          ? null
                          : () {
                              setState(() {
                                _assignmentOrderMode =
                                    !_assignmentOrderMode;
                              });
                            },
                      icon: Icon(
                        _assignmentOrderMode
                            ? Icons.check_rounded
                            : Icons.swap_vert_rounded,
                        size: headerIconSize,
                        color: _assignmentOrderMode
                            ? const Color(0xFF9FE3C6)
                            : kDlgTextSub,
                      ),
                      padding: EdgeInsets.zero,
                      splashRadius: 18 * sheetScale,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                if (_savingAssignmentOrder)
                  SizedBox(
                    width: 24 * sheetScale,
                    height: 24 * sheetScale,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
              SizedBox(
                width: 34 * sheetScale,
                height: 34 * sheetScale,
                child: IconButton(
                  onPressed: _loading || _savingAssignmentOrder
                      ? null
                      : () => unawaited(_refreshTemplates()),
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
                label: '과제',
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
                      label: isAssignmentMode ? '전체 교재/과정' : '전체 교재',
                      selected: _bookFilter.isEmpty,
                      onTap: () => setState(() => _bookFilter = ''),
                      sheetScale: sheetScale,
                    ),
                    for (final bookId in bookIds)
                      _buildFilterChip(
                        label: isAssignmentMode
                            ? (bookFilterLabelByKey[bookId] ?? bookId)
                            : _bookName(bookId),
                        selected: _bookFilter == bookId,
                        onTap: () => setState(() => _bookFilter = bookId),
                        sheetScale: sheetScale,
                      ),
                  ],
                ),
                if (!isAssignmentMode)
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
                if (isAssignmentMode && _assignmentOrderMode) {
                  return ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: filteredTemplates.length,
                    onReorder: (oldIndex, newIndex) =>
                        _reorderAssignmentTemplates(
                      oldIndex: oldIndex,
                      newIndex: newIndex,
                      visibleTemplates: filteredTemplates,
                    ),
                    proxyDecorator: (child, index, animation) {
                      return Material(
                        color: Colors.transparent,
                        child: FadeTransition(
                          opacity: Tween<double>(
                            begin: 0.92,
                            end: 1,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    itemBuilder: (context, index) {
                      final template = filteredTemplates[index];
                      return Padding(
                        key: ValueKey('assignment-order-${template.templateId}'),
                        padding: EdgeInsets.only(
                          bottom: index == filteredTemplates.length - 1
                              ? 0
                              : 8 * sheetScale,
                        ),
                        child: _buildAssignmentCard(
                          template,
                          width: cardWidth - (38 * sheetScale),
                          sheetScale: sheetScale,
                          orderMode: true,
                          reorderIndex: index,
                        ),
                      );
                    },
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
