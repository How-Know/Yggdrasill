import 'package:flutter/material.dart';

import '../../services/print_routing_service.dart';
import '../../widgets/app_dialog_action_button.dart';
import '../../widgets/dialog_tokens.dart';
import '../../widgets/utility_glass_dialog_shell.dart';
import 'resource_print_side_choice.dart';

/// 시험 인쇄에서 고를 수 있는 용지.
enum ExamPrintPaper {
  b4('B4', '내신'),
  k8('8K', '모의고사'),
  a4('A4', '정답 및 해설');

  const ExamPrintPaper(this.label, this.usage);

  final String label;
  final String usage;
}

ExamPrintPaper examPrintPaperDefault({required bool mockExam}) {
  return mockExam ? ExamPrintPaper.k8 : ExamPrintPaper.b4;
}

/// 시험 인쇄 다이얼로그에서 고른 용지와, 모의고사 정답·해설 포함 여부.
class ExamPrintSelection {
  const ExamPrintSelection({
    required this.paper,
    required this.includeAnswer,
    required this.includeSolution,
    required this.duplexMode,
  });

  final ExamPrintPaper paper;
  final bool includeAnswer;
  final bool includeSolution;
  final PrintDuplexMode duplexMode;
}

/// 시험 카드를 인쇄할 때 B4 · 8K · A4 중 하나를 고른다.
class ExamPrintPaperDialog extends StatefulWidget {
  const ExamPrintPaperDialog({
    super.key,
    required this.documentTitle,
    required this.initial,
    this.showAnswerOptions = false,
  });

  final String documentTitle;
  final ExamPrintPaper initial;

  /// 모의고사만 정답·해설 원본을 같이 인쇄할 수 있다.
  final bool showAnswerOptions;

  @override
  State<ExamPrintPaperDialog> createState() => _ExamPrintPaperDialogState();
}

class _ExamPrintPaperDialogState extends State<ExamPrintPaperDialog> {
  late ExamPrintPaper _paper = widget.initial;
  bool _includeAnswer = false;
  bool _includeSolution = false;
  PrintDuplexMode _duplexMode = PrintDuplexMode.twoSidedLongEdge;

  @override
  Widget build(BuildContext context) {
    final title = widget.documentTitle.trim();
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: UtilityGlassDialogShell(
        title: '용지 선택',
        icon: Icons.print_rounded,
        preferredWidth: 440,
        maxWidth: 440,
        maxHeight: 680,
        fitContent: true,
        onClose: () => Navigator.of(context).pop(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title.isNotEmpty)
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgText,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    decoration: TextDecoration.none,
                  ),
                ),
              if (title.isNotEmpty) const SizedBox(height: 8),
              const Text(
                '인쇄에 쓸 용지를 고르세요.',
                style: TextStyle(
                  color: kDlgTextSub,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 12),
              for (final paper in ExamPrintPaper.values) ...[
                _paperRow(paper),
                if (paper != ExamPrintPaper.a4) const SizedBox(height: 8),
              ],
              if (widget.showAnswerOptions) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    _optionCheck(
                      label: '정답',
                      value: _includeAnswer,
                      onChanged: (value) =>
                          setState(() => _includeAnswer = value),
                    ),
                    const SizedBox(width: 16),
                    _optionCheck(
                      label: '해설',
                      value: _includeSolution,
                      onChanged: (value) =>
                          setState(() => _includeSolution = value),
                    ),
                  ],
                ),
                const Text(
                  '체크하면 문제지 다음에 정답·해설 원본을 A4로 인쇄합니다. 모의고사는 정답과 해설이 한 파일입니다.',
                  style: TextStyle(
                    color: kDlgTextSub,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              ResourcePrintSideChoice(
                mode: _duplexMode,
                onChanged: (mode) => setState(() => _duplexMode = mode),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppDialogCloseButton(
                    label: '취소',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  AppDialogConfirmButton(
                    label: '인쇄',
                    onPressed: () => Navigator.of(context).pop(
                      ExamPrintSelection(
                        paper: _paper,
                        includeAnswer: _includeAnswer,
                        includeSolution: _includeSolution,
                        duplexMode: _duplexMode,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _optionCheck({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            activeColor: kDlgAccent,
            checkColor: Colors.white,
            side: const BorderSide(color: kDlgBorder),
            onChanged: (next) => onChanged(next == true),
          ),
          Text(
            label,
            style: const TextStyle(
              color: kDlgText,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  Widget _paperRow(ExamPrintPaper paper) {
    final selected = _paper == paper;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _paper = paper),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? const Color(0x2233A373) : kDlgPanelBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? kDlgAccent : kDlgBorder,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? kDlgAccent : kDlgTextSub,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Text(
                  paper.label,
                  style: const TextStyle(
                    color: kDlgText,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    decoration: TextDecoration.none,
                  ),
                ),
                const Spacer(),
                Text(
                  paper.usage,
                  style: const TextStyle(
                    color: kDlgTextSub,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
