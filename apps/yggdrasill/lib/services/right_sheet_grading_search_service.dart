import 'dart:io';

import 'package:flutter/material.dart';

import '../app_overlays.dart';
import '../screens/learning/models/problem_bank_export_models.dart';
import '../widgets/pdf/homework_answer_viewer_dialog.dart';
import 'data_manager.dart';
import 'homework_assignment_store.dart';
import 'homework_batch_confirm_service.dart';
import 'homework_test_grading_result_service.dart';
import 'homework_store.dart';
import 'learning_problem_bank_service.dart';
import 'tenant_service.dart';

class RightSheetGradingSearchService {
  RightSheetGradingSearchService._();

  static final RightSheetGradingSearchService instance =
      RightSheetGradingSearchService._();

  final LearningProblemBankService _problemBankService =
      LearningProblemBankService();
  final HomeworkBatchConfirmService _batchConfirmService =
      HomeworkBatchConfirmService.instance;
  final HomeworkTestGradingResultService _gradingResultService =
      HomeworkTestGradingResultService.instance;
  final Map<String, Map<String, HomeworkAnswerCellState>>
      _testGradingDraftStatesByHomeworkId =
      <String, Map<String, HomeworkAnswerCellState>>{};
  final Map<String, List<Map<String, dynamic>>>
      _testGradingSerializedDraftByHomeworkId =
      <String, List<Map<String, dynamic>>>{};
  final Set<String> _testGradingSavedHomeworkIds = <String>{};

  Future<List<RightSheetGradingSearchResult>> search(String query) async {
    final rawQuery = query.trim();
    if (rawQuery.isEmpty) return const <RightSheetGradingSearchResult>[];
    final normalizedQuery = _normalizeAssignmentSearchToken(rawQuery);
    final lowerQuery = rawQuery.toLowerCase();
    final ranked = <({
      RightSheetGradingSearchResult result,
      int score,
      DateTime updatedAt
    })>[];
    final seen = <String>{};
    final homeworkStore = HomeworkStore.instance;

    for (final row in DataManager.instance.students) {
      final studentId = row.student.id.trim();
      if (studentId.isEmpty) continue;
      final studentName =
          row.student.name.trim().isEmpty ? '학생' : row.student.name.trim();
      final items = homeworkStore.items(studentId);
      for (final hw in items) {
        if (hw.status == HomeworkStatus.completed) continue;
        final uniqueKey = '$studentId:${hw.id}';
        if (!seen.add(uniqueKey)) continue;

        final assignmentCode = _formatHomeworkAssignmentCode(
          hw.assignmentCode,
          fallback: '',
        );
        final normalizedCode = _normalizeAssignmentSearchToken(assignmentCode);
        final resolvedGroupTitle = _resolveGroupHomeworkTitle(
          studentId: studentId,
          hw: hw,
        );
        final homeworkTitle = hw.title.trim().isEmpty ? '과제' : hw.title.trim();

        var score = _assignmentCodeMatchPriority(
          normalizedCode: normalizedCode,
          normalizedQuery: normalizedQuery,
        );
        if (score == null) {
          final searchableText =
              '$studentName $resolvedGroupTitle $homeworkTitle'.toLowerCase();
          if (!searchableText.contains(lowerQuery)) continue;
          score = 50;
        }

        ranked.add(
          (
            result: RightSheetGradingSearchResult(
              studentId: studentId,
              homeworkItemId: hw.id,
              assignmentCode: assignmentCode,
              studentName: studentName,
              groupHomeworkTitle: resolvedGroupTitle,
              homeworkTitle: homeworkTitle,
              hasTextbookLink: _hasDirectHomeworkTextbookLink(hw),
              isTestHomework: _hasProblemBankPreset(hw),
              isSubmitted: _isSubmittedHomeworkForGradingSearch(hw),
            ),
            score: score,
            updatedAt: hw.updatedAt ?? hw.createdAt ?? DateTime(1970),
          ),
        );
      }
    }

    ranked.sort((a, b) {
      final scoreCmp = a.score.compareTo(b.score);
      if (scoreCmp != 0) return scoreCmp;
      final updatedCmp = b.updatedAt.compareTo(a.updatedAt);
      if (updatedCmp != 0) return updatedCmp;
      return a.result.assignmentCode.compareTo(b.result.assignmentCode);
    });

    const maxResults = 50;
    return ranked
        .take(maxResults)
        .map((entry) => entry.result)
        .toList(growable: false);
  }

  Future<List<RightSheetGradingSearchResult>> suggest(String query) async {
    final token = _normalizeAssignmentSearchToken(query.trim());
    final fourDigits = RegExp(r'^[0-9]{4}$');
    if (!fourDigits.hasMatch(token)) {
      return const <RightSheetGradingSearchResult>[];
    }

    final candidates =
        <({RightSheetGradingSearchResult result, DateTime at})>[];
    final seen = <String>{};
    final homeworkStore = HomeworkStore.instance;
    for (final row in DataManager.instance.students) {
      final studentId = row.student.id.trim();
      if (studentId.isEmpty) continue;
      final studentName =
          row.student.name.trim().isEmpty ? '학생' : row.student.name.trim();
      final items = homeworkStore.items(studentId);
      for (final hw in items) {
        if (hw.status == HomeworkStatus.completed) continue;
        final uniqueKey = '$studentId:${hw.id}';
        if (!seen.add(uniqueKey)) continue;
        final assignmentCode = _formatHomeworkAssignmentCode(
          hw.assignmentCode,
          fallback: '',
        );
        if (assignmentCode.isEmpty) continue;
        final normalizedCode = _normalizeAssignmentSearchToken(assignmentCode);
        if (!normalizedCode.endsWith(token)) continue;
        final resolvedGroupTitle = _resolveGroupHomeworkTitle(
          studentId: studentId,
          hw: hw,
        );
        final homeworkTitle = hw.title.trim().isEmpty ? '과제' : hw.title.trim();
        candidates.add(
          (
            result: RightSheetGradingSearchResult(
              studentId: studentId,
              homeworkItemId: hw.id,
              assignmentCode: assignmentCode,
              studentName: studentName,
              groupHomeworkTitle: resolvedGroupTitle,
              homeworkTitle: homeworkTitle,
              hasTextbookLink: _hasDirectHomeworkTextbookLink(hw),
              isTestHomework: _hasProblemBankPreset(hw),
              isSubmitted: _isSubmittedHomeworkForGradingSearch(hw),
            ),
            at: hw.updatedAt ?? hw.createdAt ?? DateTime(1970),
          ),
        );
      }
    }

    candidates.sort((a, b) {
      final updatedCmp = b.at.compareTo(a.at);
      if (updatedCmp != 0) return updatedCmp;
      return a.result.assignmentCode.compareTo(b.result.assignmentCode);
    });
    const maxSuggestions = 10;
    return candidates
        .take(maxSuggestions)
        .map((entry) => entry.result)
        .toList(growable: false);
  }

  Future<void> openResult({
    required BuildContext context,
    required RightSheetGradingSearchResult result,
  }) async {
    final studentId = result.studentId.trim();
    final itemId = result.homeworkItemId.trim();
    if (studentId.isEmpty || itemId.isEmpty) return;

    final homeworkStore = HomeworkStore.instance;
    var hw = homeworkStore.getById(studentId, itemId);
    if (hw == null) {
      await homeworkStore.reloadStudentHomework(studentId);
      if (!context.mounted) return;
      hw = homeworkStore.getById(studentId, itemId);
    }
    if (hw == null) {
      _showSnackBar(context, '해당 과제를 찾지 못했습니다.');
      return;
    }

    if (_hasProblemBankPreset(hw)) {
      if (!_isSubmittedHomeworkForGradingSearch(hw)) {
        await homeworkStore.submit(studentId, hw.id);
        await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
          studentId,
          [hw.id],
        );
        if (!context.mounted) return;
        final refreshed = homeworkStore.getById(studentId, hw.id);
        if (refreshed != null) {
          hw = refreshed;
        }
      }
      final opened = await _openTestHomeworkInGradingSheet(
        context: context,
        studentId: studentId,
        hw: hw,
      );
      if (opened) return;
    }
    if (!context.mounted) return;

    if (_hasDirectHomeworkTextbookLink(hw)) {
      await _openHomeworkAnswerShortcut(
          context: context, studentId: studentId, hw: hw);
      return;
    }
    if (!context.mounted) return;

    _showSnackBar(context, '교재가 등록되지 않은 과제라 바로가기를 제공하지 않습니다.');
  }

  Future<bool> _openTestHomeworkInGradingSheet({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
  }) async {
    final keys = <({String studentId, String itemId})>[
      (studentId: studentId, itemId: hw.id),
    ];
    final payload = await _resolveTestPbGradingViewerPayload(
      seedHomework: hw,
      keys: keys,
    );
    if (!context.mounted) return false;
    if (payload == null) {
      _showSnackBar(context, '테스트 답안 매핑에 실패해 답지 바로가기로 전환합니다.');
      return false;
    }

    final cachedStates =
        _testGradingDraftStatesByHomeworkId[payload.homeworkId] ??
            const <String, HomeworkAnswerCellState>{};
    final savedSession =
        await _gradingResultService.loadLatestSavedSessionForHomework(
      homeworkItemId: payload.homeworkId,
    );
    if (!context.mounted) return false;
    final initialStates = savedSession?.states.isNotEmpty == true
        ? savedSession!.states
        : cachedStates;
    final hasSavedGrading = savedSession != null ||
        _testGradingSavedHomeworkIds.contains(payload.homeworkId);
    final studentName = _resolveHomeworkPrintStudentName(studentId);
    final groupHomeworkTitle = _resolveGroupHomeworkTitle(
      studentId: studentId,
      hw: hw,
      fallbackTitle: payload.title,
    );
    final assignmentCode = _formatHomeworkAssignmentCode(
      hw.assignmentCode,
      fallback: '',
    );
    final overlayEntries = _buildOverlayEntriesForHomework(hw);

    rightSideSheetTestGradingSession.value = RightSideSheetTestGradingSession(
      sessionId: 'student:$studentId|test_pb_grade:${payload.homeworkId}',
      title: payload.title,
      studentName: studentName,
      groupHomeworkTitle: groupHomeworkTitle,
      assignmentCode: assignmentCode,
      gradingPages: _toRightSheetGradingPages(payload.gradingPages),
      scoreByQuestionKey: payload.scoreByQuestionKey,
      overlayEntries: overlayEntries,
      initialStates: _toRightSheetStateMap(initialStates),
      gradingLocked: hasSavedGrading,
      onRequestEditReset: () async {
        final reset = await _gradingResultService.resetAttemptsForHomework(
          homeworkItemId: payload.homeworkId,
        );
        if (!context.mounted) return false;
        if (!reset) {
          _showSnackBar(context, '기존 채점 결과 리셋에 실패했습니다.');
          return false;
        }
        _testGradingDraftStatesByHomeworkId.remove(payload.homeworkId);
        _testGradingSerializedDraftByHomeworkId.remove(payload.homeworkId);
        _testGradingSavedHomeworkIds.remove(payload.homeworkId);
        _showSnackBar(context, '기존 채점 결과를 리셋했습니다. 다시 확인하면 새 결과로 저장됩니다.');
        return true;
      },
      closeSheetOnAction: false,
      onStatesChanged: (states) {
        final decoded = _fromRightSheetStateMap(states);
        _testGradingDraftStatesByHomeworkId[payload.homeworkId] =
            Map<String, HomeworkAnswerCellState>.from(decoded);
        _testGradingSerializedDraftByHomeworkId[payload.homeworkId] =
            _serializeTestGradingDraftRows(
          homeworkId: payload.homeworkId,
          gradingPages: payload.gradingPages,
          states: decoded,
        );
      },
      onAction: (action, states) async {
        final decoded = _fromRightSheetStateMap(states);
        _testGradingDraftStatesByHomeworkId[payload.homeworkId] =
            Map<String, HomeworkAnswerCellState>.from(decoded);
        _testGradingSerializedDraftByHomeworkId[payload.homeworkId] =
            _serializeTestGradingDraftRows(
          homeworkId: payload.homeworkId,
          gradingPages: payload.gradingPages,
          states: decoded,
        );
        if (action == 'complete' || action == 'confirm') {
          final targetItem = HomeworkStore.instance.getById(
                studentId,
                payload.homeworkId,
              ) ??
              hw;
          final saved = await _gradingResultService.saveAttemptFromSession(
            studentId: studentId,
            homeworkItem: targetItem,
            action: action,
            states: decoded,
            gradingPages: payload.gradingPages,
            scoreByQuestionKey: payload.scoreByQuestionKey,
            groupHomeworkTitleSnapshot: groupHomeworkTitle,
          );
          if (!saved) {
            if (context.mounted) {
              _showSnackBar(context, '채점 결과 저장에 실패했습니다.');
            }
            return;
          }
          _testGradingSavedHomeworkIds.add(payload.homeworkId);
          final pending = <HomeworkBatchConfirmKey, bool>{
            for (final key in keys) key: action == 'complete',
          };
          await _batchConfirmService.executeBatchConfirmNow(
            context: context,
            pending: pending,
          );
          for (final key in keys) {
            _batchConfirmService.pending.remove(key);
          }
          _batchConfirmService.syncPendingCount();
        }
      },
    );
    blockRightSideSheetOpen.value = false;
    if (!rightSideSheetOpen.value) {
      final toggleAction = toggleRightSideSheetAction;
      if (toggleAction != null) {
        await toggleAction();
      }
    }
    return true;
  }

  Future<void> _openHomeworkAnswerShortcut({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
  }) async {
    final resolved = await _resolveHomeworkPdfLinks(
      hw,
      allowFlowFallback: true,
    );
    if (!context.mounted) return;

    final answerRaw = resolved.answerPathRaw.trim();
    if (answerRaw.isEmpty) {
      _showSnackBar(context, '연결된 답지 파일을 찾을 수 없습니다.');
      return;
    }
    final answerIsUrl = _isWebUrl(answerRaw);
    final answerPath =
        answerIsUrl ? answerRaw : _toLocalFilePath(answerRaw).trim();
    if (answerPath.isEmpty) {
      _showSnackBar(context, '연결된 답지 파일을 찾을 수 없습니다.');
      return;
    }
    if (!answerIsUrl) {
      if (!answerPath.toLowerCase().endsWith('.pdf') ||
          !await File(answerPath).exists()) {
        if (!context.mounted) return;
        _showSnackBar(context, '답지 PDF 파일이 존재하지 않습니다.');
        return;
      }
    }

    String? solutionPath;
    final solutionRaw = resolved.solutionPathRaw.trim();
    if (_isWebUrl(solutionRaw)) {
      solutionPath = solutionRaw;
    } else if (solutionRaw.isNotEmpty) {
      final candidate = _toLocalFilePath(solutionRaw).trim();
      if (candidate.isNotEmpty &&
          candidate.toLowerCase().endsWith('.pdf') &&
          await File(candidate).exists()) {
        solutionPath = candidate;
      }
    }

    final closeAction = closeRightSideSheetAction;
    if (closeAction != null) {
      await closeAction();
    }
    if (!context.mounted) return;
    await openHomeworkAnswerViewerPage(
      context,
      filePath: answerPath,
      title: hw.title.trim().isEmpty ? '답지 확인' : hw.title.trim(),
      solutionFilePath: solutionPath,
      cacheKey: 'student:$studentId|grading_search_answer:$answerPath',
      enableConfirm: false,
    );
  }

  Future<
      ({
        String homeworkId,
        String title,
        List<HomeworkAnswerGradingPage> gradingPages,
        Map<String, double> scoreByQuestionKey,
      })?> _resolveTestPbGradingViewerPayload({
    required HomeworkItem seedHomework,
    required List<({String studentId, String itemId})> keys,
  }) async {
    final seenItemIds = <String>{};
    final allItems = <HomeworkItem>[];
    for (final key in keys) {
      final item = HomeworkStore.instance.getById(key.studentId, key.itemId);
      if (item == null) continue;
      if (!seenItemIds.add(item.id)) continue;
      allItems.add(item);
    }
    if (allItems.isEmpty) {
      allItems.add(seedHomework);
    }

    final testPbItems = allItems
        .where(
          (item) => _hasProblemBankPreset(item),
        )
        .toList(growable: false);
    if (testPbItems.isEmpty) return null;

    final baseItem = testPbItems.firstWhere(
      (item) => item.id == seedHomework.id,
      orElse: () => testPbItems.first,
    );
    final presetId = (baseItem.pbPresetId ?? '').trim();
    if (presetId.isEmpty) return null;

    final academyId = await _resolveAcademyIdForPrint();
    if (academyId.isEmpty) return null;

    final preset = await _problemBankService.getExportPresetById(
      academyId: academyId,
      presetId: presetId,
    );
    if (preset == null) return null;
    final selectedUids = preset.selectedQuestionUids
        .map((uid) => uid.trim())
        .where((uid) => uid.isNotEmpty)
        .toList(growable: false);
    if (selectedUids.isEmpty) return null;

    final questions = await _problemBankService.loadQuestionsByQuestionUids(
      academyId: academyId,
      questionUids: selectedUids,
    );
    if (questions.isEmpty) return null;
    final questionByKey = <String, LearningProblemQuestion>{};
    for (final question in questions) {
      final stableKey = question.stableQuestionKey.trim();
      if (stableKey.isNotEmpty) {
        questionByKey.putIfAbsent(stableKey, () => question);
      }
      final uid = question.questionUid.trim();
      if (uid.isNotEmpty) {
        questionByKey.putIfAbsent(uid, () => question);
      }
      final id = question.id.trim();
      if (id.isNotEmpty) {
        questionByKey.putIfAbsent(id, () => question);
      }
    }

    final modeByUid = preset.questionModeByQuestionUid;
    final presetScoreByUid = preset.questionScoreByQuestionUid;

    // 홈 채점모드와 동일하게 프리셋(renderConfig)의 실제 출력 레이아웃을 우선한다.
    // sourcePage는 원본 문제은행 페이지라, 내보낸 PDF의 페이지별 문항 수와 다를 수 있다.
    final pageCapacityByPage = <int, int>{};
    final rawPageRows = preset.renderConfig['pageColumnQuestionCounts'];
    if (rawPageRows is List) {
      for (final row in rawPageRows) {
        if (row is! Map) continue;
        final map = Map<String, dynamic>.from(row);
        final pageIdx = int.tryParse(
              '${map['pageIndex'] ?? map['page'] ?? map['pageNo'] ?? ''}',
            ) ??
            0;
        final left = int.tryParse(
              '${map['left'] ?? map['leftCount'] ?? map['col1'] ?? 0}',
            ) ??
            0;
        final right = int.tryParse(
              '${map['right'] ?? map['rightCount'] ?? map['col2'] ?? 0}',
            ) ??
            0;
        if (pageIdx <= 0) continue;
        final int capacity = (left < 0 ? 0 : left) + (right < 0 ? 0 : right);
        if (capacity <= 0) continue;
        pageCapacityByPage[pageIdx] = capacity;
      }
    }
    final orderedPageNumbers = pageCapacityByPage.keys.toList()..sort();

    final cellsByPage = <int, List<HomeworkAnswerGradingCell>>{};
    final scoreByQuestionKey = <String, double>{};
    var fallbackIndex = 0;
    var layoutCursor = 0;
    var layoutRemaining = orderedPageNumbers.isEmpty
        ? 0
        : pageCapacityByPage[orderedPageNumbers.first]!;
    for (final uid in selectedUids) {
      final question = questionByKey[uid];
      if (question == null) continue;
      fallbackIndex += 1;
      final rawIndex = int.tryParse(question.displayQuestionNumber.trim());
      final questionIndex = rawIndex != null && rawIndex > 0
          ? rawIndex
          : (question.sourceOrder > 0 ? question.sourceOrder : fallbackIndex);
      final answerMode = (modeByUid[uid] ?? '').trim().toLowerCase();
      final answer = previewAnswerForMode(question, answerMode).trim();
      int pageNumber;
      if (orderedPageNumbers.isNotEmpty) {
        while (
            layoutCursor < orderedPageNumbers.length && layoutRemaining <= 0) {
          layoutCursor += 1;
          if (layoutCursor < orderedPageNumbers.length) {
            layoutRemaining =
                pageCapacityByPage[orderedPageNumbers[layoutCursor]] ?? 0;
          }
        }
        if (layoutCursor < orderedPageNumbers.length) {
          pageNumber = orderedPageNumbers[layoutCursor];
          layoutRemaining -= 1;
        } else {
          pageNumber = orderedPageNumbers.last;
        }
      } else {
        pageNumber = question.sourcePage > 0 ? question.sourcePage : 1;
      }
      final key = '${baseItem.id}|$pageNumber|$questionIndex|$uid';
      final uidScore = presetScoreByUid[uid];
      if (uidScore != null && uidScore.isFinite && uidScore > 0) {
        scoreByQuestionKey[key] = uidScore;
      }
      cellsByPage
          .putIfAbsent(pageNumber, () => <HomeworkAnswerGradingCell>[])
          .add(
            HomeworkAnswerGradingCell(
              key: key,
              questionIndex: questionIndex,
              answer: answer.isEmpty ? '-' : answer,
              answerMode: answerMode,
            ),
          );
    }
    if (cellsByPage.isEmpty) return null;
    final gradingPages = cellsByPage.entries
        .map(
          (entry) => HomeworkAnswerGradingPage(
            pageNumber: entry.key,
            cells: entry.value
              ..sort((a, b) => a.questionIndex.compareTo(b.questionIndex)),
          ),
        )
        .toList(growable: false)
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));

    final title =
        baseItem.title.trim().isEmpty ? '답지 확인' : baseItem.title.trim();
    return (
      homeworkId: baseItem.id,
      title: title,
      gradingPages: gradingPages,
      scoreByQuestionKey: scoreByQuestionKey,
    );
  }

  Future<_ResolvedHomeworkPdfLinks> _resolveHomeworkPdfLinks(
    HomeworkItem hw, {
    bool allowFlowFallback = false,
  }) async {
    String bookId = (hw.bookId ?? '').trim();
    String gradeLabel = (hw.gradeLabel ?? '').trim();
    final flowId = (hw.flowId ?? '').trim();

    if (allowFlowFallback &&
        (bookId.isEmpty || gradeLabel.isEmpty) &&
        flowId.isNotEmpty) {
      try {
        final rows = await DataManager.instance.loadFlowTextbookLinks(flowId);
        if (rows.isNotEmpty) {
          Map<String, dynamic>? matched;
          for (final row in rows) {
            final rowBookId = '${row['book_id'] ?? ''}'.trim();
            final rowGrade = '${row['grade_label'] ?? ''}'.trim();
            final bool bookMatches = bookId.isNotEmpty && rowBookId == bookId;
            final bool gradeMatches =
                gradeLabel.isNotEmpty && rowGrade == gradeLabel;
            if (bookMatches || gradeMatches) {
              matched = row;
              break;
            }
          }
          final selected = matched ?? rows.first;
          if (bookId.isEmpty) {
            bookId = '${selected['book_id'] ?? ''}'.trim();
          }
          if (gradeLabel.isEmpty) {
            gradeLabel = '${selected['grade_label'] ?? ''}'.trim();
          }
        }
      } catch (_) {}
    }

    if (bookId.isEmpty || gradeLabel.isEmpty) {
      return const _ResolvedHomeworkPdfLinks(
        bookId: '',
        gradeLabel: '',
        bodyPathRaw: '',
        answerPathRaw: '',
        solutionPathRaw: '',
      );
    }

    try {
      final links = await DataManager.instance.loadResourceFileLinks(bookId);
      return _ResolvedHomeworkPdfLinks(
        bookId: bookId,
        gradeLabel: gradeLabel,
        bodyPathRaw: (links['$gradeLabel#body'] ?? '').trim(),
        answerPathRaw: (links['$gradeLabel#ans'] ?? '').trim(),
        solutionPathRaw: (links['$gradeLabel#sol'] ?? '').trim(),
      );
    } catch (_) {
      return _ResolvedHomeworkPdfLinks(
        bookId: bookId,
        gradeLabel: gradeLabel,
        bodyPathRaw: '',
        answerPathRaw: '',
        solutionPathRaw: '',
      );
    }
  }

  String _normalizeAssignmentSearchToken(String raw) {
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  }

  int? _assignmentCodeMatchPriority({
    required String normalizedCode,
    required String normalizedQuery,
  }) {
    if (normalizedCode.isEmpty || normalizedQuery.isEmpty) return null;
    if (normalizedCode == normalizedQuery) return 0;
    final numeric4 = RegExp(r'^[0-9]{1,4}$');
    if (numeric4.hasMatch(normalizedQuery) &&
        normalizedCode.endsWith(normalizedQuery)) {
      return 1;
    }
    if (normalizedCode.startsWith(normalizedQuery)) return 2;
    if (normalizedCode.contains(normalizedQuery)) return 3;
    return null;
  }

  bool _isSubmittedHomeworkForGradingSearch(HomeworkItem hw) {
    return hw.status != HomeworkStatus.completed &&
        hw.phase == 3 &&
        hw.completedAt == null;
  }

  bool _hasProblemBankPreset(HomeworkItem hw) {
    return (hw.pbPresetId ?? '').trim().isNotEmpty;
  }

  bool _hasDirectHomeworkTextbookLink(HomeworkItem hw) {
    final bookId = (hw.bookId ?? '').trim();
    final gradeLabel = (hw.gradeLabel ?? '').trim();
    return bookId.isNotEmpty && gradeLabel.isNotEmpty;
  }

  String _formatHomeworkAssignmentCode(String? raw, {String fallback = '-'}) {
    final compact =
        (raw ?? '').trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return compact.isEmpty ? fallback : compact;
  }

  String _resolveHomeworkPrintStudentName(String studentId) {
    final sid = studentId.trim();
    if (sid.isEmpty) return '학생';
    for (final row in DataManager.instance.students) {
      if (row.student.id != sid) continue;
      final name = row.student.name.trim();
      return name.isEmpty ? '학생' : name;
    }
    return '학생';
  }

  String _resolveGroupHomeworkTitle({
    required String studentId,
    required HomeworkItem hw,
    String fallbackTitle = '',
  }) {
    final homeworkStore = HomeworkStore.instance;
    final groupId = (homeworkStore.groupIdOfItem(hw.id) ?? '').trim();
    if (groupId.isNotEmpty) {
      final groupTitle =
          (homeworkStore.groupById(studentId, groupId)?.title ?? '').trim();
      if (groupTitle.isNotEmpty) return groupTitle;
    }
    final hwTitle = hw.title.trim();
    if (hwTitle.isNotEmpty) return hwTitle;
    final fallback = fallbackTitle.trim();
    if (fallback.isNotEmpty) return fallback;
    return '그룹 과제';
  }

  bool _isWebUrl(String raw) {
    final lower = raw.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  String _toLocalFilePath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || _isWebUrl(trimmed)) return '';
    if (trimmed.toLowerCase().startsWith('file://')) {
      try {
        return Uri.parse(trimmed).toFilePath(windows: Platform.isWindows);
      } catch (_) {
        return '';
      }
    }
    return trimmed;
  }

  Future<String> _resolveAcademyIdForPrint() async {
    var academyId =
        (await TenantService.instance.getActiveAcademyId() ?? '').trim();
    if (academyId.isEmpty) {
      academyId = (await TenantService.instance.ensureActiveAcademy()).trim();
    }
    return academyId;
  }

  String _encodeTestGradingState(HomeworkAnswerCellState state) {
    switch (state) {
      case HomeworkAnswerCellState.correct:
        return 'correct';
      case HomeworkAnswerCellState.wrong:
        return 'wrong';
      case HomeworkAnswerCellState.unsolved:
        return 'unsolved';
    }
  }

  HomeworkAnswerCellState _decodeTestGradingState(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'wrong':
        return HomeworkAnswerCellState.wrong;
      case 'unsolved':
        return HomeworkAnswerCellState.unsolved;
      case 'correct':
      default:
        return HomeworkAnswerCellState.correct;
    }
  }

  Map<String, String> _toRightSheetStateMap(
    Map<String, HomeworkAnswerCellState> states,
  ) {
    final out = <String, String>{};
    states.forEach((key, value) {
      out[key] = _encodeTestGradingState(value);
    });
    return out;
  }

  Map<String, HomeworkAnswerCellState> _fromRightSheetStateMap(
    Map<String, String> states,
  ) {
    final out = <String, HomeworkAnswerCellState>{};
    states.forEach((key, value) {
      out[key] = _decodeTestGradingState(value);
    });
    return out;
  }

  List<Map<String, dynamic>> _toRightSheetGradingPages(
    List<HomeworkAnswerGradingPage> pages,
  ) {
    return pages
        .map(
          (page) => <String, dynamic>{
            'pageNumber': page.pageNumber,
            'cells': page.cells
                .map(
                  (cell) => <String, dynamic>{
                    'key': cell.key,
                    'questionIndex': cell.questionIndex,
                    'answer': cell.answer,
                    'answerMode': cell.answerMode,
                  },
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _serializeTestGradingDraftRows({
    required String homeworkId,
    required List<HomeworkAnswerGradingPage> gradingPages,
    required Map<String, HomeworkAnswerCellState> states,
  }) {
    final rows = <Map<String, dynamic>>[];
    for (final page in gradingPages) {
      for (final cell in page.cells) {
        rows.add(<String, dynamic>{
          'homeworkId': homeworkId,
          'page': page.pageNumber,
          'questionIndex': cell.questionIndex,
          'state': _encodeTestGradingState(
            states[cell.key] ?? HomeworkAnswerCellState.correct,
          ),
        });
      }
    }
    return rows;
  }

  List<Map<String, String>> _buildOverlayEntriesForHomework(HomeworkItem hw) {
    final title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
    final pageRaw = (hw.page ?? '').trim();
    final memoRaw = (hw.memo ?? '').trim();
    return <Map<String, String>>[
      <String, String>{
        'title': title,
        'page': pageRaw.isEmpty ? '-' : 'p.$pageRaw',
        'memo': memoRaw.isEmpty ? '-' : memoRaw,
      }
    ];
  }

  void _showSnackBar(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ResolvedHomeworkPdfLinks {
  final String bookId;
  final String gradeLabel;
  final String bodyPathRaw;
  final String answerPathRaw;
  final String solutionPathRaw;

  const _ResolvedHomeworkPdfLinks({
    required this.bookId,
    required this.gradeLabel,
    required this.bodyPathRaw,
    required this.answerPathRaw,
    required this.solutionPathRaw,
  });
}
