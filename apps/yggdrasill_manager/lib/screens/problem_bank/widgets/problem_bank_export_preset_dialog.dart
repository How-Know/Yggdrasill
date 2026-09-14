import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../services/problem_bank_service.dart';
import '../naesin_link_school_name.dart';
import '../problem_bank_models.dart';

ProblemBankExportPreset? latestExportPresetForDocument(
  Iterable<ProblemBankExportPreset> presets,
  String documentId,
) {
  ProblemBankExportPreset? latest;
  for (final preset in presets) {
    final linked = preset.sourceDocumentId == documentId ||
        preset.documentId == documentId ||
        preset.sourceDocumentIds.contains(documentId);
    if (!linked) continue;
    final candidateAt = preset.updatedAt ?? preset.createdAt;
    final latestAt = latest?.updatedAt ?? latest?.createdAt;
    if (latest == null ||
        (candidateAt != null &&
            (latestAt == null || candidateAt.isAfter(latestAt)))) {
      latest = preset;
    }
  }
  return latest;
}

const List<String> _naesinExamTerms = <String>['중간고사', '기말고사'];
const List<int> _naesinLinkYears = <int>[
  2021,
  2022,
  2023,
  2024,
  2025,
  2026,
  2027,
  2028,
];
const List<String> _naesinMiddleSchools = <String>[
  '경신중',
  '능인중',
  '대륜중',
  '동도중',
  '소선여중',
  '오성중',
  '정화중',
  '황금중',
];
const List<String> _naesinHighSchools = <String>[
  '경북고',
  '경신고',
  '능인고',
  '대구여고',
  '대륜고',
  '오성고',
  '정화여고',
  '혜화여고',
];

class _NaesinLinkSelection {
  const _NaesinLinkSelection({
    required this.gradeKey,
    required this.courseKey,
    required this.examTerm,
    required this.school,
    required this.year,
    required this.cellLabel,
  });

  final String gradeKey;
  final String courseKey;
  final String examTerm;
  final String school;
  final int year;
  final String cellLabel;
}

class _NaesinOption {
  const _NaesinOption(this.key, this.label);
  final String key;
  final String label;
}

Future<void> showProblemBankExportPresetDialog({
  required BuildContext context,
  required ProblemBankService service,
  required String academyId,
  required void Function(String message, {bool error}) showSnack,
  Future<void> Function(
    ProblemBankDocument document,
    ProblemBankExportPreset? latestPreset,
  )? onOpenDocumentPreset,
}) async {
  List<ProblemBankExportPreset> presets;
  List<ProblemBankDocument> naesinDocuments;
  Map<String, int> questionCounts;
  try {
    presets = await service.listExportPresets(
      academyId: academyId,
      limit: 300,
    );
    naesinDocuments = (await service.listAllSchoolPastDocuments(
      academyId: academyId,
    ))
        .where((document) => document.status.trim().toLowerCase() == 'ready')
        .toList(growable: false);
    questionCounts = await service.countQuestionsByDocumentIds(
      academyId: academyId,
      documentIds: naesinDocuments.map((document) => document.id),
    );
  } catch (e) {
    showSnack('프리셋/내신 문서 목록 조회 실패: $e', error: true);
    return;
  }
  if (!context.mounted) return;

  final size = MediaQuery.sizeOf(context);
  final dialogWidth = (size.width * 0.82).clamp(760.0, 1180.0);
  final dialogHeight = (size.height * 0.78).clamp(520.0, 860.0);
  final gridColumns = dialogWidth >= 1080
      ? 4
      : dialogWidth >= 900
          ? 3
          : 2;

  var workingPresets = presets;
  var workingDocuments = naesinDocuments;
  var workingQuestionCounts = questionCounts;
  var showNaesinDocuments = false;
  var isWorking = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      Future<void> reloadPresets(StateSetter setModalState) async {
        setModalState(() => isWorking = true);
        try {
          final refreshed = await service.listExportPresets(
            academyId: academyId,
            limit: 300,
          );
          final refreshedDocuments =
              (await service.listAllSchoolPastDocuments(academyId: academyId))
                  .where(
                    (document) =>
                        document.status.trim().toLowerCase() == 'ready',
                  )
                  .toList(growable: false);
          final refreshedCounts = await service.countQuestionsByDocumentIds(
            academyId: academyId,
            documentIds: refreshedDocuments.map((document) => document.id),
          );
          setModalState(() {
            workingPresets = refreshed;
            workingDocuments = refreshedDocuments;
            workingQuestionCounts = refreshedCounts;
          });
        } catch (e) {
          showSnack('프리셋 새로고침 실패: $e', error: true);
        } finally {
          setModalState(() => isWorking = false);
        }
      }

      int readInt(dynamic value) {
        if (value is int) return value;
        if (value is num) return value.toInt();
        return int.tryParse('${value ?? ''}') ?? 0;
      }

      Future<void> runLegacyCloneCleanup(StateSetter setModalState) async {
        setModalState(() => isWorking = true);
        Map<String, dynamic> dryRunResult;
        try {
          dryRunResult = await service.cleanupLegacySavedSettingsClones(
            academyId: academyId,
            dryRun: true,
            limit: 2000,
          );
        } catch (e) {
          showSnack('레거시 정리(미리보기) 실패: $e', error: true);
          setModalState(() => isWorking = false);
          return;
        }

        final legacyCount = readInt(dryRunResult['legacyDocumentCount']);
        if (legacyCount <= 0) {
          showSnack('정리할 레거시 저장 문서가 없습니다.');
          setModalState(() => isWorking = false);
          return;
        }

        if (!dialogContext.mounted) {
          setModalState(() => isWorking = false);
          return;
        }
        final confirmed = await showDialog<bool>(
          context: dialogContext,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF10171A),
            title: const Text(
              '레거시 저장 문서 정리',
              style: TextStyle(color: Color(0xFFEAF2F2)),
            ),
            content: Text(
              '레거시 저장 문서 $legacyCount건을 삭제합니다.\n원본 문서와 프리셋은 유지됩니다.',
              style: const TextStyle(color: Color(0xFF9FB3B3), height: 1.45),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('정리'),
              ),
            ],
          ),
        );
        if (confirmed != true) {
          setModalState(() => isWorking = false);
          return;
        }

        try {
          final result = await service.cleanupLegacySavedSettingsClones(
            academyId: academyId,
            dryRun: false,
            limit: 2000,
          );
          final deletedDocs = readInt(result['deletedDocumentCount']);
          final deletedPresets = readInt(result['deletedPresetCount']);
          showSnack(
            '레거시 정리 완료: 문서 $deletedDocs개 · 프리셋 $deletedPresets개',
          );
          await reloadPresets(setModalState);
        } catch (e) {
          showSnack('레거시 정리 실패: $e', error: true);
          setModalState(() => isWorking = false);
        }
      }

      Future<void> renamePreset(
        ProblemBankExportPreset preset,
        StateSetter setModalState,
      ) async {
        final controller = TextEditingController(text: preset.displayName);
        final nextName = await showDialog<String>(
          context: dialogContext,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF10171A),
            title: const Text(
              '프리셋 이름 수정',
              style: TextStyle(color: Color(0xFFEAF2F2)),
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Color(0xFFEAF2F2)),
              decoration: const InputDecoration(
                hintText: '프리셋 이름을 입력하세요',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('저장'),
              ),
            ],
          ),
        );
        controller.dispose();
        final normalized =
            (nextName ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (normalized.isEmpty) return;

        setModalState(() => isWorking = true);
        try {
          final renamed = await service.renameExportPreset(
            academyId: academyId,
            presetId: preset.id,
            displayName: normalized,
          );
          if (renamed != null) {
            setModalState(() {
              workingPresets = workingPresets
                  .map((item) => item.id == preset.id ? renamed : item)
                  .toList(growable: false);
            });
            showSnack('프리셋 이름을 수정했습니다.');
          }
        } catch (e) {
          showSnack('프리셋 이름 수정 실패: $e', error: true);
        } finally {
          setModalState(() => isWorking = false);
        }
      }

      Future<void> deletePreset(
        ProblemBankExportPreset preset,
        StateSetter setModalState,
      ) async {
        final confirmed = await showDialog<bool>(
          context: dialogContext,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF10171A),
            title: const Text(
              '프리셋 삭제',
              style: TextStyle(color: Color(0xFFEAF2F2)),
            ),
            content: Text(
              '`${preset.displayName}` 프리셋을 삭제할까요?\n(원본/저장 문서는 유지됩니다.)',
              style: const TextStyle(color: Color(0xFF9FB3B3), height: 1.45),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDE6A73),
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('삭제'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;

        setModalState(() => isWorking = true);
        try {
          await service.deleteExportPreset(
            academyId: academyId,
            presetId: preset.id,
          );
          setModalState(() {
            workingPresets = workingPresets
                .where((item) => item.id != preset.id)
                .toList(growable: false);
          });
          showSnack('프리셋 삭제 완료');
        } catch (e) {
          showSnack('프리셋 삭제 실패: $e', error: true);
        } finally {
          setModalState(() => isWorking = false);
        }
      }

      Future<void> linkPresetToNaesinCell(
        ProblemBankExportPreset preset,
        StateSetter setModalState,
      ) async {
        final now = DateTime.now();
        final currentLinkKey = preset.naesinLinkKey.trim();
        final existing = _parseNaesinLinkKey(currentLinkKey);
        final sourceDocument = _sourceDocumentForPreset(
          preset,
          workingDocuments,
        );
        final sourceGradeKey = sourceDocument == null
            ? ''
            : _naesinGradeKeyFromDocument(sourceDocument);
        final sourceCourseKey = sourceDocument == null
            ? ''
            : _naesinCourseKeyFromDocument(
                sourceDocument,
                sourceGradeKey,
              );
        var selectedCurriculumCode = _normalizeNaesinCurriculumCode(
          existing != null
              ? preset.naesinCurriculumCode
              : (sourceDocument?.curriculumCode ??
                  preset.naesinCurriculumCode),
        );
        var selectedGradeKey = existing?.gradeKey ??
            (sourceGradeKey.isNotEmpty ? sourceGradeKey : 'M1');
        var selectedCourseKey = existing?.courseKey ??
            (sourceCourseKey.isNotEmpty ? sourceCourseKey : 'M1-1');
        selectedCourseKey = _reconcileNaesinCourseKeyForCurriculum(
          gradeKey: selectedGradeKey,
          curriculumCode: selectedCurriculumCode,
          currentCourseKey: selectedCourseKey,
        );
        var selectedExamTerm = existing?.examTerm ??
            _normalizeNaesinExamTerm(sourceDocument?.examTermLabel) ??
            _defaultNaesinExamTermByDate(now);
        if (!_naesinExamTerms.contains(selectedExamTerm)) {
          selectedExamTerm = _naesinExamTerms.first;
        }
        var selectedSchool = _canonicalSchoolForGrade(
          existing?.school ??
              (sourceDocument?.schoolName.trim().isNotEmpty == true
                  ? sourceDocument!.schoolName.trim()
                  : ''),
          selectedGradeKey,
        );
        var selectedYear = existing?.year ??
            sourceDocument?.examYear ??
            _defaultNaesinYearByDate(now);
        var selectedCellLabel = _normalizeCellLabel(
          existing?.cellLabel ?? preset.naesinCellLabel,
        );

        final nextLink =
            await showDialog<({String linkKey, String curriculumCode})>(
          context: dialogContext,
          builder: (ctx) {
            final cellNameController = TextEditingController(
              text: selectedCellLabel,
            );
            return StatefulBuilder(
              builder: (context, setLinkState) {
                const fieldTextStyle = TextStyle(
                  color: Color(0xFFEAF2F2),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                );
                InputDecoration fieldDecoration(String label) {
                  return InputDecoration(
                    labelText: label,
                    labelStyle: const TextStyle(
                      color: Color(0xFF9FB3B3),
                      fontSize: 12.4,
                      fontWeight: FontWeight.w700,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF141D22),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF223131)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                        color: Color(0xFF3E8A7A),
                        width: 1.2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 10,
                    ),
                  );
                }

                final gradeOptions = _naesinGradeOptions();
                if (!gradeOptions.any((e) => e.key == selectedGradeKey)) {
                  selectedGradeKey = gradeOptions.first.key;
                }
                final courseOptions = _naesinCourseOptionsForGrade(
                  selectedGradeKey,
                  selectedCurriculumCode,
                );
                selectedCourseKey = _reconcileNaesinCourseKeyForCurriculum(
                  gradeKey: selectedGradeKey,
                  curriculumCode: selectedCurriculumCode,
                  currentCourseKey: selectedCourseKey,
                );
                final schoolOptions = _schoolsForGradeKey(selectedGradeKey);
                if (!schoolOptions.contains(selectedSchool)) {
                  selectedSchool = schoolOptions.first;
                }
                if (!_naesinLinkYears.contains(selectedYear)) {
                  selectedYear = _naesinLinkYears.last;
                }

                return AlertDialog(
                  backgroundColor: const Color(0xFF10171A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: Color(0xFF223131)),
                  ),
                  title: const Text(
                    '내신 셀 연결',
                    style: TextStyle(
                      color: Color(0xFFEAF2F2),
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                  content: SizedBox(
                    width: 430,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            sourceDocument == null
                                ? '프리셋과 연결할 내신 셀을 선택하세요.'
                                : '원본 문서에 저장된 정보를 불러왔습니다. 내용을 확인하고 필요한 항목만 수정하세요.',
                            style: const TextStyle(
                              color: Color(0xFF9FB3B3),
                              fontSize: 12.2,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (sourceDocument != null) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0D1518),
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: const Color(0xFF223131),
                                ),
                              ),
                              child: Text(
                                _naesinSourceDocumentSummary(sourceDocument),
                                style: const TextStyle(
                                  color: Color(0xFFAFC2D6),
                                  fontSize: 11.7,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'manager-naesin-curriculum-$selectedCurriculumCode',
                            ),
                            initialValue: selectedCurriculumCode,
                            decoration: fieldDecoration('교육과정'),
                            dropdownColor: const Color(0xFF141D22),
                            style: fieldTextStyle,
                            iconEnabledColor: const Color(0xFF9FB3B3),
                            items: const [
                              DropdownMenuItem<String>(
                                value: 'rev_2022',
                                child: Text('2022 개정', style: fieldTextStyle),
                              ),
                              DropdownMenuItem<String>(
                                value: 'rev_2015',
                                child: Text('2015 개정', style: fieldTextStyle),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == null || value.isEmpty) return;
                              setLinkState(() {
                                selectedCurriculumCode =
                                    _normalizeNaesinCurriculumCode(value);
                                selectedCourseKey =
                                    _reconcileNaesinCourseKeyForCurriculum(
                                  gradeKey: selectedGradeKey,
                                  curriculumCode: selectedCurriculumCode,
                                  currentCourseKey: selectedCourseKey,
                                );
                              });
                            },
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  key: ValueKey(
                                    'manager-naesin-grade-$selectedCurriculumCode-$selectedGradeKey',
                                  ),
                                  initialValue: selectedGradeKey,
                                  decoration: fieldDecoration('학년'),
                                  dropdownColor: const Color(0xFF141D22),
                                  style: fieldTextStyle,
                                  iconEnabledColor: const Color(0xFF9FB3B3),
                                  items: [
                                    for (final option in gradeOptions)
                                      DropdownMenuItem<String>(
                                        value: option.key,
                                        child: Text(
                                          option.label,
                                          style: fieldTextStyle,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null || value.isEmpty) return;
                                    setLinkState(() {
                                      selectedGradeKey = value;
                                      selectedCourseKey =
                                          _reconcileNaesinCourseKeyForCurriculum(
                                        gradeKey: selectedGradeKey,
                                        curriculumCode: selectedCurriculumCode,
                                        currentCourseKey: selectedCourseKey,
                                      );
                                      final nextSchools =
                                          _schoolsForGradeKey(value);
                                      if (!nextSchools
                                          .contains(selectedSchool)) {
                                        selectedSchool = nextSchools.first;
                                      }
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  key: ValueKey(
                                    'manager-naesin-course-$selectedCurriculumCode-$selectedGradeKey-$selectedCourseKey',
                                  ),
                                  initialValue: selectedCourseKey,
                                  decoration: fieldDecoration('과정'),
                                  dropdownColor: const Color(0xFF141D22),
                                  style: fieldTextStyle,
                                  iconEnabledColor: const Color(0xFF9FB3B3),
                                  items: [
                                    for (final option in courseOptions)
                                      DropdownMenuItem<String>(
                                        value: option.key,
                                        child: Text(
                                          option.label,
                                          style: fieldTextStyle,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null || value.isEmpty) return;
                                    setLinkState(() {
                                      selectedCourseKey = value;
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: selectedExamTerm,
                                  decoration: fieldDecoration('시험 구분'),
                                  dropdownColor: const Color(0xFF141D22),
                                  style: fieldTextStyle,
                                  iconEnabledColor: const Color(0xFF9FB3B3),
                                  items: [
                                    for (final option in _naesinExamTerms)
                                      DropdownMenuItem<String>(
                                        value: option,
                                        child: Text(
                                          option,
                                          style: fieldTextStyle,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null || value.isEmpty) return;
                                    setLinkState(() {
                                      selectedExamTerm = value;
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: DropdownButtonFormField<int>(
                                  initialValue: selectedYear,
                                  decoration: fieldDecoration('연도'),
                                  dropdownColor: const Color(0xFF141D22),
                                  style: fieldTextStyle,
                                  iconEnabledColor: const Color(0xFF9FB3B3),
                                  items: [
                                    for (final option in _naesinLinkYears)
                                      DropdownMenuItem<int>(
                                        value: option,
                                        child: Text(
                                          '$option',
                                          style: fieldTextStyle,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setLinkState(() {
                                      selectedYear = value;
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: selectedSchool,
                            decoration: fieldDecoration('학교'),
                            dropdownColor: const Color(0xFF141D22),
                            style: fieldTextStyle,
                            iconEnabledColor: const Color(0xFF9FB3B3),
                            items: [
                              for (final option in schoolOptions)
                                DropdownMenuItem<String>(
                                  value: option,
                                  child: Text(option, style: fieldTextStyle),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null || value.isEmpty) return;
                              setLinkState(() {
                                selectedSchool = value;
                              });
                            },
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: cellNameController,
                            style: fieldTextStyle,
                            decoration: fieldDecoration(
                              selectedGradeKey.startsWith('H')
                                  ? '셀 이름 (예: 수학1, 수학2)'
                                  : '셀 이름 (선택)',
                            ).copyWith(
                              hintText: selectedGradeKey.startsWith('H')
                                  ? '같은 시험에 여러 수학 시험이 있으면 입력'
                                  : '비워두면 기존 단일 셀로 저장',
                              hintStyle: const TextStyle(
                                color: Color(0xFF9FB3B3),
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    if (currentLinkKey.isNotEmpty)
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop((
                          linkKey: '',
                          curriculumCode: selectedCurriculumCode,
                        )),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFD38E8E),
                        ),
                        child: const Text('연결 해제'),
                      ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF9FB3B3),
                      ),
                      child: const Text('취소'),
                    ),
                    FilledButton(
                      onPressed: () {
                        final cellLabel = _normalizeCellLabel(
                          cellNameController.text,
                        );
                        Navigator.of(ctx).pop(
                          (
                            linkKey: _buildNaesinLinkKey(
                              gradeKey: selectedGradeKey,
                              courseKey: selectedCourseKey,
                              examTerm: selectedExamTerm,
                              school: _canonicalSchoolForGrade(
                                selectedSchool,
                                selectedGradeKey,
                              ),
                              year: selectedYear,
                              cellLabel: cellLabel,
                            ),
                            curriculumCode: selectedCurriculumCode,
                          ),
                        );
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7366),
                        foregroundColor: const Color(0xFFEAF2F2),
                      ),
                      child: const Text('확인 및 연결'),
                    ),
                  ],
                );
              },
            );
          },
        );
        if (nextLink == null) return;

        setModalState(() => isWorking = true);
        try {
          final parsedNext = nextLink.linkKey.isEmpty
              ? null
              : _parseNaesinLinkKey(nextLink.linkKey);
          final updated = await service.updateExportPresetNaesinLink(
            academyId: academyId,
            presetId: preset.id,
            naesinLinkKey: nextLink.linkKey.isEmpty ? null : nextLink.linkKey,
            naesinCellLabel: parsedNext?.cellLabel,
            naesinCurriculumCode: nextLink.curriculumCode,
          );
          if (updated != null) {
            setModalState(() {
              workingPresets = workingPresets
                  .map((item) => item.id == preset.id ? updated : item)
                  .toList(growable: false);
            });
          } else {
            await reloadPresets(setModalState);
          }
          showSnack(
            nextLink.linkKey.isEmpty ? '내신 연결 해제 완료' : '내신 연결 저장 완료',
          );
        } catch (e) {
          showSnack('내신 연결 저장 실패: $e', error: true);
        } finally {
          setModalState(() => isWorking = false);
        }
      }

      String createdAtLabel(ProblemBankExportPreset preset) {
        final createdAt = preset.createdAt;
        if (createdAt == null) return '';
        return DateFormat('yyyy.MM.dd').format(createdAt);
      }

      String naesinLinkLabel(ProblemBankExportPreset preset) {
        final cell = preset.naesinCellLabel.trim();
        if (cell.isNotEmpty) return cell;
        return _naesinLinkSummaryLabel(preset.naesinLinkKey);
      }

      ProblemBankExportPreset? latestPresetForDocument(String documentId) {
        return latestExportPresetForDocument(workingPresets, documentId);
      }

      Future<void> openDocument(
        ProblemBankDocument document,
        StateSetter setModalState,
      ) async {
        final callback = onOpenDocumentPreset;
        if (callback == null || isWorking) return;
        setModalState(() => isWorking = true);
        try {
          await callback(document, latestPresetForDocument(document.id));
          await reloadPresets(setModalState);
        } catch (e) {
          showSnack('프리셋 편집기 열기 실패: $e', error: true);
        } finally {
          if (dialogContext.mounted) {
            setModalState(() => isWorking = false);
          }
        }
      }

      return StatefulBuilder(
        builder: (context, setModalState) {
          return Dialog(
            backgroundColor: const Color(0xFF10171A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0xFF223131)),
            ),
            child: SizedBox(
              width: dialogWidth,
              height: dialogHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          showNaesinDocuments ? '내신 추출본' : '저장된 프리셋',
                          style: TextStyle(
                            color: Color(0xFFEAF2F2),
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${showNaesinDocuments ? workingDocuments.length : workingPresets.length}개',
                          style: const TextStyle(
                            color: Color(0xFF9FB3B3),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        if (isWorking)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF9FB3B3),
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: '레거시 정리',
                          onPressed: isWorking
                              ? null
                              : () => runLegacyCloneCleanup(setModalState),
                          icon: const Icon(
                            Icons.cleaning_services_outlined,
                            color: Color(0xFF9FB3B3),
                          ),
                        ),
                        IconButton(
                          tooltip: '새로고침',
                          onPressed: isWorking
                              ? null
                              : () => reloadPresets(setModalState),
                          icon: const Icon(
                            Icons.refresh,
                            color: Color(0xFF9FB3B3),
                          ),
                        ),
                        IconButton(
                          tooltip: '닫기',
                          onPressed: isWorking
                              ? null
                              : () => Navigator.of(dialogContext).pop(),
                          icon: const Icon(
                            Icons.close,
                            color: Color(0xFF9FB3B3),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text(
                        showNaesinDocuments
                            ? '업로드가 완료된 내신 문서를 선택해 프리셋을 만들거나 최신 프리셋을 편집합니다.'
                            : '학습앱 문제은행에서 저장한 양식·문항 프리셋을 관리합니다.',
                        style: TextStyle(
                          color: Color(0xFF9FB3B3),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('저장된 프리셋'),
                          selected: !showNaesinDocuments,
                          onSelected: isWorking
                              ? null
                              : (_) => setModalState(
                                    () => showNaesinDocuments = false,
                                  ),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('내신 추출본'),
                          selected: showNaesinDocuments,
                          onSelected: isWorking
                              ? null
                              : (_) => setModalState(
                                    () => showNaesinDocuments = true,
                                  ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: (showNaesinDocuments
                              ? workingDocuments.isEmpty
                              : workingPresets.isEmpty)
                          ? Center(
                              child: Text(
                                showNaesinDocuments
                                    ? '업로드 완료된 내신 추출본이 없습니다.'
                                    : '저장된 프리셋이 없습니다.',
                                style: const TextStyle(
                                  color: Color(0xFF9FB3B3),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: GridView.builder(
                                padding: const EdgeInsets.only(
                                  top: 2,
                                  bottom: 6,
                                ),
                                itemCount: showNaesinDocuments
                                    ? workingDocuments.length
                                    : workingPresets.length,
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: gridColumns,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  mainAxisExtent: 132,
                                ),
                                itemBuilder: (context, index) {
                                  if (showNaesinDocuments) {
                                    final document = workingDocuments[index];
                                    final latest =
                                        latestPresetForDocument(document.id);
                                    return _NaesinDocumentCard(
                                      document: document,
                                      questionCount:
                                          workingQuestionCounts[document.id] ??
                                              0,
                                      latestPreset: latest,
                                      disabled:
                                          isWorking || onOpenDocumentPreset == null,
                                      onTap: () => openDocument(
                                        document,
                                        setModalState,
                                      ),
                                    );
                                  }
                                  final preset = workingPresets[index];
                                  return _ExportPresetCard(
                                    preset: preset,
                                    disabled: isWorking,
                                    naesinLinkLabel: naesinLinkLabel(preset),
                                    createdAtLabel: createdAtLabel(preset),
                                    onLink: () => linkPresetToNaesinCell(
                                      preset,
                                      setModalState,
                                    ),
                                    onRename: () =>
                                        renamePreset(preset, setModalState),
                                    onDelete: () =>
                                        deletePreset(preset, setModalState),
                                  );
                                },
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class _NaesinDocumentCard extends StatelessWidget {
  const _NaesinDocumentCard({
    required this.document,
    required this.questionCount,
    required this.latestPreset,
    required this.disabled,
    required this.onTap,
  });

  final ProblemBankDocument document;
  final int questionCount;
  final ProblemBankExportPreset? latestPreset;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = document.sourceFilename.trim().isNotEmpty
        ? document.sourceFilename.trim()
        : document.materialName.trim();
    final meta = <String>[
      if (document.schoolName.trim().isNotEmpty) document.schoolName.trim(),
      if (document.examYear != null) '${document.examYear}년',
      if (document.gradeLabel.trim().isNotEmpty) document.gradeLabel.trim(),
      if (document.semesterLabel.trim().isNotEmpty)
        document.semesterLabel.trim(),
      if (document.examTermLabel.trim().isNotEmpty)
        document.examTermLabel.trim(),
      '$questionCount문항',
    ].join(' · ');
    final hasPreset = latestPreset != null;
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
        color: const Color(0xFF0F171B),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: disabled ? null : onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasPreset
                    ? const Color(0xFF3E8A7A)
                    : const Color(0xFF223131),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: title,
                          child: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFEAF2F2),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        color: Color(0xFF9FB3B3),
                        size: 20,
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    meta,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF9FB3B3),
                      fontSize: 11.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    hasPreset ? '프리셋 있음 · 최신 프리셋 편집' : '프리셋 없음 · 새로 만들기',
                    style: TextStyle(
                      color: hasPreset
                          ? const Color(0xFF74C7B6)
                          : const Color(0xFFAFC2D6),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExportPresetCard extends StatelessWidget {
  const _ExportPresetCard({
    required this.preset,
    required this.disabled,
    required this.naesinLinkLabel,
    required this.createdAtLabel,
    required this.onLink,
    required this.onRename,
    required this.onDelete,
  });

  final ProblemBankExportPreset preset;
  final bool disabled;
  final String naesinLinkLabel;
  final String createdAtLabel;
  final VoidCallback? onLink;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final profile = preset.templateProfile.toUpperCase();
    final paper = preset.paperSize.trim();
    final metaLine = [
      if (profile.isNotEmpty) profile,
      if (paper.isNotEmpty) paper,
      '${preset.selectedQuestionCount}문항',
      if (createdAtLabel.isNotEmpty) createdAtLabel,
    ].join(' · ');

    return Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: Material(
        color: const Color(0xFF0F171B),
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF223131)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        preset.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFEAF2F2),
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '내신 연결',
                      onPressed: disabled ? null : onLink,
                      icon: const Icon(Icons.link_outlined, size: 16),
                      color: const Color(0xFF9FB3B3),
                      splashRadius: 16,
                      constraints:
                          const BoxConstraints.tightFor(width: 28, height: 28),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: '이름 수정',
                      onPressed: disabled ? null : onRename,
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      color: const Color(0xFF9FB3B3),
                      splashRadius: 16,
                      constraints:
                          const BoxConstraints.tightFor(width: 28, height: 28),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: '삭제',
                      onPressed: disabled ? null : onDelete,
                      icon: const Icon(Icons.delete_outline, size: 16),
                      color: const Color(0xFFD38E8E),
                      splashRadius: 16,
                      constraints:
                          const BoxConstraints.tightFor(width: 28, height: 28),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  metaLine,
                  style: const TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 11.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (naesinLinkLabel.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.link,
                          size: 12, color: Color(0xFFAFC2D6)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          naesinLinkLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFAFC2D6),
                            fontSize: 11.4,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

ProblemBankDocument? _sourceDocumentForPreset(
  ProblemBankExportPreset preset,
  Iterable<ProblemBankDocument> documents,
) {
  final candidateIds = <String>{
    preset.sourceDocumentId.trim(),
    ...preset.sourceDocumentIds.map((id) => id.trim()),
    preset.documentId.trim(),
  }..remove('');
  for (final document in documents) {
    if (candidateIds.contains(document.id.trim())) return document;
  }
  return null;
}

String _naesinGradeKeyFromDocument(ProblemBankDocument document) {
  final direct = document.gradeKey.trim().toUpperCase();
  if (RegExp(r'^[MH][1-3]$').hasMatch(direct)) return direct;
  final grade =
      RegExp(r'[1-3]').firstMatch(document.gradeLabel)?.group(0) ?? '';
  if (grade.isEmpty) return '';
  final schoolLevel = document.schoolLevel.trim().toLowerCase();
  final isHigh = schoolLevel == 'high' ||
      document.schoolName.contains('고') ||
      document.courseKey.toUpperCase().startsWith('H');
  return '${isHigh ? 'H' : 'M'}$grade';
}

String _naesinCourseKeyFromDocument(
  ProblemBankDocument document,
  String gradeKey,
) {
  final direct = document.courseKey.trim();
  if (direct.isNotEmpty) return direct;
  if (gradeKey.startsWith('M')) {
    final semester = document.semesterLabel.contains('2') ? '2' : '1';
    return '$gradeKey-$semester';
  }
  if (gradeKey == 'H1') {
    return document.semesterLabel.contains('2') ? 'H1-c2' : 'H1-c1';
  }
  return '';
}

String? _normalizeNaesinExamTerm(String? raw) {
  final value = (raw ?? '').replaceAll(RegExp(r'\s+'), '').trim();
  if (value.contains('중간')) return '중간고사';
  if (value.contains('기말')) return '기말고사';
  return null;
}

String _naesinSourceDocumentSummary(ProblemBankDocument document) {
  return <String>[
    '원본: ${document.sourceFilename.trim().isEmpty ? document.materialName : document.sourceFilename}',
    if (document.schoolName.trim().isNotEmpty) document.schoolName.trim(),
    if (document.examYear != null) '${document.examYear}년',
    if (document.gradeLabel.trim().isNotEmpty) document.gradeLabel.trim(),
    if (document.courseLabel.trim().isNotEmpty) document.courseLabel.trim(),
    if (document.semesterLabel.trim().isNotEmpty)
      document.semesterLabel.trim(),
    if (document.examTermLabel.trim().isNotEmpty)
      document.examTermLabel.trim(),
  ].join(' · ');
}

int _defaultNaesinYearByDate(DateTime now) {
  if (_naesinLinkYears.contains(now.year)) return now.year;
  if (now.year < _naesinLinkYears.first) return _naesinLinkYears.first;
  return _naesinLinkYears.last;
}

String _defaultNaesinExamTermByDate(DateTime now) {
  final month = now.month;
  final day = now.day;
  if (month <= 4) return '중간고사';
  if (month == 5) return day <= 15 ? '중간고사' : '기말고사';
  if (month <= 7) return '기말고사';
  if (month <= 9) return '중간고사';
  if (month == 10) return day <= 15 ? '중간고사' : '기말고사';
  return '기말고사';
}

String _normalizeNaesinCurriculumCode(String raw) {
  return raw.trim() == 'rev_2015' ? 'rev_2015' : 'rev_2022';
}

String _normalizeCellLabel(String raw) {
  return raw.replaceAll('|', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<_NaesinOption> _naesinGradeOptions() {
  return const <_NaesinOption>[
    _NaesinOption('M1', '중1'),
    _NaesinOption('M2', '중2'),
    _NaesinOption('M3', '중3'),
    _NaesinOption('H1', '고1'),
    _NaesinOption('H2', '고2'),
    _NaesinOption('H3', '고3'),
  ];
}

List<_NaesinOption> _naesinCourseOptionsForGrade(
  String gradeKey,
  String curriculumCode,
) {
  switch (gradeKey) {
    case 'M1':
      return const <_NaesinOption>[
        _NaesinOption('M1-1', '1-1'),
        _NaesinOption('M1-2', '1-2'),
      ];
    case 'M2':
      return const <_NaesinOption>[
        _NaesinOption('M2-1', '2-1'),
        _NaesinOption('M2-2', '2-2'),
      ];
    case 'M3':
      return const <_NaesinOption>[
        _NaesinOption('M3-1', '3-1'),
        _NaesinOption('M3-2', '3-2'),
      ];
    case 'H1':
      if (curriculumCode == 'rev_2015') {
        return const <_NaesinOption>[
          _NaesinOption('H1-math-upper', '수학(상)'),
          _NaesinOption('H1-math-lower', '수학(하)'),
        ];
      }
      return const <_NaesinOption>[
        _NaesinOption('H1-c1', '공통수학1'),
        _NaesinOption('H1-c2', '공통수학2'),
      ];
    case 'H2':
      if (curriculumCode == 'rev_2015') {
        return const <_NaesinOption>[
          _NaesinOption('H-math1', '수학1'),
          _NaesinOption('H-math2', '수학2'),
          _NaesinOption('H-calculus', '미적분'),
          _NaesinOption('H-probstats', '확률과 통계'),
          _NaesinOption('H-geometry', '기하'),
        ];
      }
      return const <_NaesinOption>[
        _NaesinOption('H-algebra', '대수'),
        _NaesinOption('H-calc1', '미적분1'),
        _NaesinOption('H-calc2', '미적분2'),
        _NaesinOption('H-probstats', '확률과 통계'),
      ];
    case 'H3':
      if (curriculumCode == 'rev_2015') {
        return const <_NaesinOption>[
          _NaesinOption('H-math1', '수학1'),
          _NaesinOption('H-math2', '수학2'),
          _NaesinOption('H-calculus', '미적분'),
          _NaesinOption('H-probstats', '확률과 통계'),
          _NaesinOption('H-geometry', '기하'),
        ];
      }
      return const <_NaesinOption>[
        _NaesinOption('H-algebra', '대수'),
      ];
    default:
      return const <_NaesinOption>[_NaesinOption('M1-1', '1-1')];
  }
}

String _reconcileNaesinCourseKeyForCurriculum({
  required String gradeKey,
  required String curriculumCode,
  required String currentCourseKey,
}) {
  final options = _naesinCourseOptionsForGrade(gradeKey, curriculumCode);
  if (options.isEmpty) return currentCourseKey.trim();
  final current = currentCourseKey.trim();
  if (options.any((option) => option.key == current)) return current;
  final mapped = _mapNaesinCourseKeyAcrossCurriculum(
    currentCourseKey: current,
    targetCurriculumCode: curriculumCode,
  );
  if (options.any((option) => option.key == mapped)) return mapped;
  return options.first.key;
}

String _mapNaesinCourseKeyAcrossCurriculum({
  required String currentCourseKey,
  required String targetCurriculumCode,
}) {
  final key = currentCourseKey.trim();
  if (targetCurriculumCode.trim() == 'rev_2015') {
    switch (key) {
      case 'H1-c1':
        return 'H1-math-upper';
      case 'H1-c2':
        return 'H1-math-lower';
      case 'H-algebra':
        return 'H-math1';
      case 'H-calc1':
        return 'H-math2';
      case 'H-calc2':
        return 'H-calculus';
      default:
        return key;
    }
  }
  switch (key) {
    case 'H1-math-upper':
      return 'H1-c1';
    case 'H1-math-lower':
      return 'H1-c2';
    case 'H-math1':
      return 'H-algebra';
    case 'H-math2':
      return 'H-calc1';
    case 'H-calculus':
      return 'H-calc2';
    default:
      return key;
  }
}

List<String> _schoolsForGradeKey(String gradeKey) {
  if (gradeKey.startsWith('H')) {
    return _naesinHighSchools;
  }
  return _naesinMiddleSchools;
}

String _canonicalSchoolForGrade(String raw, String gradeKey) {
  final canonical = canonicalNaesinSchoolName(
    raw,
    canonicalSchools: _schoolsForGradeKey(gradeKey),
  );
  return canonical.isEmpty ? raw.trim() : canonical;
}

String _courseDisplayLabel(String courseKey) {
  for (final curriculumCode in const <String>['rev_2022', 'rev_2015']) {
    for (final grade in _naesinGradeOptions()) {
      for (final course in _naesinCourseOptionsForGrade(
        grade.key,
        curriculumCode,
      )) {
        if (course.key == courseKey) return course.label;
      }
    }
  }
  final middle = RegExp(r'^M([1-3])-([12])$').firstMatch(courseKey);
  if (middle != null) {
    return '${middle.group(1)}-${middle.group(2)}';
  }
  return courseKey;
}

String _gradeDisplayLabel(String gradeKey) {
  for (final option in _naesinGradeOptions()) {
    if (option.key == gradeKey) return option.label;
  }
  return gradeKey;
}

String _buildNaesinLinkKey({
  required String gradeKey,
  required String courseKey,
  required String examTerm,
  required String school,
  required int year,
  String cellLabel = '',
}) {
  return [
    gradeKey.trim(),
    courseKey.trim(),
    examTerm.trim(),
    _canonicalSchoolForGrade(school, gradeKey),
    '$year',
    _normalizeCellLabel(cellLabel),
  ].join('|');
}

_NaesinLinkSelection? _parseNaesinLinkKey(String raw) {
  final parts = raw.split('|');
  if (parts.length < 5) return null;
  final year = int.tryParse(parts[4].trim());
  if (year == null) return null;
  final gradeKey = parts[0].trim();
  return _NaesinLinkSelection(
    gradeKey: gradeKey,
    courseKey: parts[1].trim(),
    examTerm: parts[2].trim(),
    school: _canonicalSchoolForGrade(parts[3].trim(), gradeKey),
    year: year,
    cellLabel: parts.length >= 6 ? _normalizeCellLabel(parts[5]) : '',
  );
}

String _naesinLinkSummaryLabel(String rawKey) {
  final parsed = _parseNaesinLinkKey(rawKey.trim());
  if (parsed == null) return rawKey.trim();
  final pieces = <String>[
    _gradeDisplayLabel(parsed.gradeKey),
    _courseDisplayLabel(parsed.courseKey),
    '${parsed.year}',
    parsed.examTerm,
  ];
  if (parsed.school.trim().isNotEmpty && parsed.school.trim() != '학교 미지정') {
    pieces.add(parsed.school.trim());
  }
  if (parsed.cellLabel.trim().isNotEmpty) {
    pieces.add(parsed.cellLabel.trim());
  }
  return pieces.join(' · ');
}
