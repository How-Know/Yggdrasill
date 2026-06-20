import 'package:flutter/material.dart';

import '../../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../models/problem_bank_curriculum_filter.dart';
import 'problem_bank_curriculum_controls.dart';
import 'problem_bank_range_controls.dart';

/// 문제은행 좌측 패널 상단 — 추출 문서 트리와 동일한 그룹 카드 스타일 범위 선택.
class ProblemBankSidebarRangeSection extends StatefulWidget {
  const ProblemBankSidebarRangeSection({
    super.key,
    required this.selectedLevel,
    required this.levelOptions,
    required this.onLevelChanged,
    required this.selectedSourceTypeCode,
    required this.sourceTypeLabels,
    required this.onSourceTypeChanged,
    required this.curriculumFilter,
    required this.onCurriculumFilterChanged,
    required this.selectedCourse,
    required this.courseOptions,
    required this.onCourseChanged,
    required this.isBusy,
  });

  final String selectedLevel;
  final List<String> levelOptions;
  final ValueChanged<String> onLevelChanged;
  final String selectedSourceTypeCode;
  final Map<String, String> sourceTypeLabels;
  final ValueChanged<String?> onSourceTypeChanged;
  final ProblemBankCurriculumFilter curriculumFilter;
  final ValueChanged<ProblemBankCurriculumFilter> onCurriculumFilterChanged;
  final String selectedCourse;
  final List<String> courseOptions;
  final ValueChanged<String?> onCourseChanged;
  final bool isBusy;

  @override
  State<ProblemBankSidebarRangeSection> createState() =>
      _ProblemBankSidebarRangeSectionState();
}

class _ProblemBankSidebarRangeSectionState
    extends State<ProblemBankSidebarRangeSection> {
  bool _settingsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);

    return DecoratedBox(
      decoration: PreviewAcademyGroupedFieldsCard.cardDecoration(
        panelStyle,
        brightness: brightness,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          FabTabBarTokens.previewAcademyGroupedCardRadius,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal - 6,
            20,
            FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '범위 선택',
                      style: TextStyle(
                        color: panelStyle.title,
                        fontWeight: FontWeight.w600,
                        fontSize: FabTabBarTokens.fabBarLabelFontSize,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.isBusy
                        ? null
                        : () => setState(
                              () => _settingsExpanded = !_settingsExpanded,
                            ),
                    tooltip: '교육과정·세부 과정 설정',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: Icon(
                      _settingsExpanded
                          ? Icons.settings
                          : Icons.settings_outlined,
                      size: 20,
                      color: _settingsExpanded
                          ? panelStyle.title
                          : panelStyle.icon,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ProblemBankLevelSegmentBar(
                selectedLevel: widget.selectedLevel,
                levelOptions: widget.levelOptions,
                onLevelChanged: widget.onLevelChanged,
                isBusy: widget.isBusy,
              ),
              const SizedBox(height: 10),
              ProblemBankFilterDropdown<String>(
                value: widget.selectedSourceTypeCode,
                isBusy: widget.isBusy,
                items: widget.sourceTypeLabels.entries
                    .map(
                      (e) => DropdownMenuItem<String>(
                        value: e.key,
                        child: Text(
                          e.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: widget.onSourceTypeChanged,
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                crossFadeState: _settingsExpanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox.shrink(),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: ProblemBankCurriculumControls(
                    curriculumFilter: widget.curriculumFilter,
                    onCurriculumFilterChanged: widget.onCurriculumFilterChanged,
                    selectedCourse: widget.selectedCourse,
                    courseOptions: widget.courseOptions,
                    onCourseChanged: widget.onCourseChanged,
                    isBusy: widget.isBusy,
                  ),
                ),
                sizeCurve: Curves.easeOutCubic,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
