import 'package:flutter/material.dart';

import '../models/student_flow.dart';
import '../screens/resources/exam_preset_support.dart';
import '../services/homework_store.dart';
import '../services/learning_problem_bank_service.dart';
import '../services/student_flow_store.dart';
import '../utils/naesin_exam_context.dart';
import 'app_snackbar.dart';
import 'dialog_tokens.dart';
import 'flow_setup_dialog.dart';

bool isTestHomeworkEntry(Map<String, dynamic> entry) {
  final typeLabel = (entry['type'] as String?)?.trim();
  final sourceUnitLevel = (entry['sourceUnitLevel'] as String?)?.trim();
  final testOriginFlowId = (entry['testOriginFlowId'] as String?)?.trim();
  return typeLabel == '테스트' ||
      entry['testMode'] == true ||
      sourceUnitLevel == 'naesin' ||
      (testOriginFlowId != null && testOriginFlowId.isNotEmpty);
}

String _naesinGradeYearLabel(String gradeKey) {
  final matched = RegExp(r'(\d)').firstMatch(gradeKey.trim());
  final year = int.tryParse(matched?.group(1) ?? '');
  if (year == null || year <= 0) return '1학년';
  return '${year}학년';
}

String _composeBodyValues({
  required String page,
  required String count,
  required String content,
  int? timeLimitMinutes,
}) {
  final parts = <String>[];
  if (page.isNotEmpty) parts.add('p.$page');
  if (count.isNotEmpty) parts.add('${count}문항');
  if (timeLimitMinutes != null && timeLimitMinutes > 0) {
    parts.add('제한시간 ${timeLimitMinutes}분');
  }
  if (parts.isEmpty) return content;
  if (content.isEmpty) return parts.join(' / ');
  return '${parts.join(' / ')}\n$content';
}

String _formatPageRangeFromCount(int pageCount) {
  if (pageCount <= 0) return '';
  if (pageCount == 1) return '1';
  return '1-$pageCount';
}

int _safeIntFromDynamic(dynamic raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw') ?? 0;
}

int? _parseTimeLimitMinutesFromPresetRenderConfig(
  Map<String, dynamic> renderConfig,
) {
  final raw = '${renderConfig['timeLimitText'] ?? ''}'.trim();
  if (raw.isEmpty) return null;
  final matched = RegExp(r'(\d{1,4})').firstMatch(raw);
  final parsed = int.tryParse(matched?.group(1) ?? '');
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

int? _estimateQuestionPageCountFromPreset({
  required Map<String, dynamic> renderConfig,
  required int questionCount,
}) {
  final rawPageRows = renderConfig['pageColumnQuestionCounts'];
  if (rawPageRows is List) {
    var maxPageIndex = 0;
    for (final row in rawPageRows) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final pageIndex = _safeIntFromDynamic(
        map['pageIndex'] ?? map['page'] ?? map['pageNo'],
      );
      final left = _safeIntFromDynamic(
        map['left'] ?? map['leftCount'] ?? map['col1'],
      );
      final right = _safeIntFromDynamic(
        map['right'] ?? map['rightCount'] ?? map['col2'],
      );
      if (pageIndex <= 0 || left + right <= 0) continue;
      if (pageIndex > maxPageIndex) {
        maxPageIndex = pageIndex;
      }
    }
    if (maxPageIndex > 0) return maxPageIndex;
  }
  if (questionCount <= 0) return null;
  final layoutColumns = _safeIntFromDynamic(renderConfig['layoutColumns']);
  final defaultPerPage = layoutColumns == 2 ? 8 : 4;
  final maxQuestionsPerPage = _safeIntFromDynamic(
    renderConfig['maxQuestionsPerPage'],
  );
  final perPage =
      maxQuestionsPerPage > 0 ? maxQuestionsPerPage : defaultPerPage;
  if (perPage <= 0) return null;
  return ((questionCount + perPage - 1) / perPage).floor();
}

Map<String, dynamic>? buildNaesinHomeworkItemFromPreset({
  required LearningProblemDocumentExportPreset preset,
  required String testOriginFlowId,
}) {
  final normalizedLinkKey = naesinLinkKeyOfPreset(preset);
  if (normalizedLinkKey.isEmpty) return null;
  final parsedLink = NaesinExamContext.parseNaesinLinkKey(normalizedLinkKey);
  if (parsedLink == null) return null;

  final questionCount = preset.selectedQuestionCount > 0
      ? preset.selectedQuestionCount
      : preset.selectedQuestionUids.length;
  final questionPageCount = _estimateQuestionPageCountFromPreset(
    renderConfig: preset.renderConfig,
    questionCount: questionCount,
  );
  final timeLimitMinutes = _parseTimeLimitMinutesFromPresetRenderConfig(
    preset.renderConfig,
  );
  final resolvedPage = _formatPageRangeFromCount(questionPageCount ?? 0);
  if (resolvedPage.isEmpty || questionCount <= 0) return null;

  final school = parsedLink.school.trim();
  final year = parsedLink.year;
  final title = examPresetCardLine2(parsedLink);
  final groupTitle =
      '$year $school ${_naesinGradeYearLabel(parsedLink.gradeKey)} 내신 기출';
  final countText = '$questionCount';
  final autoContent = <String>[
    '내신 기출',
    '학교: $school',
    '연도: $year',
    '학년: ${_naesinGradeYearLabel(parsedLink.gradeKey)}',
    '과정: ${NaesinExamContext.courseLabel(parsedLink.courseKey)}',
    '시험: ${parsedLink.examTerm}',
    if (parsedLink.cellLabel.isNotEmpty) '셀: ${parsedLink.cellLabel}',
  ].join('\n');
  final body = _composeBodyValues(
    page: resolvedPage,
    count: countText,
    content: autoContent,
    timeLimitMinutes: timeLimitMinutes,
  );
  final presetId = preset.id.trim();

  return {
    'type': '프린트',
    'title': title,
    'page': resolvedPage,
    'count': countText,
    'memo': '',
    'content': autoContent,
    'body': body,
    'color': Colors.blue,
    'splitParts': 1,
    if (timeLimitMinutes != null && timeLimitMinutes > 0)
      'timeLimitMinutes': timeLimitMinutes,
    'testMode': true,
    if (testOriginFlowId.trim().isNotEmpty)
      'testOriginFlowId': testOriginFlowId.trim(),
    if (presetId.isNotEmpty) 'pbPresetId': presetId,
    'sourceUnitLevel': 'naesin',
    'sourceUnitPath': normalizedLinkKey,
    'unitMappings': const <Map<String, dynamic>>[],
    'naesinLinkKey': normalizedLinkKey,
    'naesinGroupTitle': groupTitle,
  };
}

Future<StudentFlow?> _pickFlowForHomeworkAssign(
  BuildContext context,
  List<StudentFlow> enabledFlows,
) async {
  if (enabledFlows.isEmpty) return null;
  if (enabledFlows.length == 1) return enabledFlows.first;

  StudentFlow selected = enabledFlows.first;
  return showDialog<StudentFlow>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              '플로우 선택',
              style: TextStyle(
                color: kDlgText,
                fontWeight: FontWeight.w900,
              ),
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '과제를 내줄 플로우를 선택하세요.',
                      style: TextStyle(color: kDlgTextSub),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: enabledFlows.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: kDlgBorder, height: 1),
                      itemBuilder: (ctx, i) {
                        final flow = enabledFlows[i];
                        return RadioListTile<String>(
                          value: flow.id,
                          groupValue: selected.id,
                          onChanged: (v) {
                            if (v == null) return;
                            setLocal(() => selected = flow);
                          },
                          activeColor: kDlgAccent,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 4),
                          title: Text(
                            flow.name,
                            style: const TextStyle(
                              color: kDlgText,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
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
                onPressed: () => Navigator.of(ctx).pop(selected),
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('선택'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> assignDraggedExamPresetHomeworkToStudent({
  required BuildContext context,
  required String studentId,
  required LearningProblemDocumentExportPreset preset,
}) async {
  final enabledFlows =
      await ensureEnabledFlowsForHomework(context, studentId);
  if (!context.mounted) return;
  if (enabledFlows.isEmpty) {
    showAppSnackBar(context, '플로우가 설정되지 않아 과제를 내줄 수 없습니다.');
    return;
  }

  final selectedFlow = await _pickFlowForHomeworkAssign(context, enabledFlows);
  if (!context.mounted || selectedFlow == null) return;

  final selectedFlowId = selectedFlow.id.trim();
  final item = buildNaesinHomeworkItemFromPreset(
    preset: preset,
    testOriginFlowId: selectedFlowId,
  );
  if (item == null) {
    showAppSnackBar(context, '프리셋에서 내신 과제 정보를 만들지 못했습니다.');
    return;
  }

  final entries = <Map<String, dynamic>>[Map<String, dynamic>.from(item)];
  if (entries.any(isTestHomeworkEntry)) {
    String? testFlowId;
    try {
      final ensured =
          await StudentFlowStore.instance.ensureTestFlowForStudent(studentId);
      testFlowId = (ensured?.id ?? '').trim();
    } catch (_) {
      testFlowId = null;
    }
    if (!context.mounted) return;
    if (testFlowId == null || testFlowId.isEmpty) {
      showAppSnackBar(context, '테스트 플로우를 준비하지 못했습니다.');
      return;
    }
    for (final entry in entries) {
      if (!isTestHomeworkEntry(entry)) continue;
      entry['flowId'] = testFlowId;
      entry['type'] = '프린트';
      final existingOrigin =
          (entry['testOriginFlowId'] as String?)?.trim() ?? '';
      if (existingOrigin.isEmpty && selectedFlowId.isNotEmpty) {
        entry['testOriginFlowId'] = selectedFlowId;
      }
    }
  }

  final groupTitle =
      (item['naesinGroupTitle'] as String?)?.trim() ?? '내신 기출';
  try {
    final createdItems =
        await HomeworkStore.instance.createGroupWithWaitingItems(
      studentId: studentId,
      groupTitle: groupTitle,
      flowId: selectedFlowId,
      items: entries,
    );
    if (!context.mounted) return;
    if (createdItems.isEmpty) {
      showAppSnackBar(context, '과제 생성에 실패했어요.');
      return;
    }
    showAppSnackBar(
        context, '그룹 과제(하위 ${createdItems.length}개)를 추가했어요.');
  } catch (e) {
    if (!context.mounted) return;
    showAppSnackBar(context, '과제 생성 중 오류가 발생했습니다: $e');
  }
}
