import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

import '../../services/print_routing_service.dart';
import '../../services/textbook_explorer_service.dart';
import '../../widgets/app_dialog_action_button.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/dialog_tokens.dart';
import '../../widgets/utility_glass_dialog_shell.dart';
import 'resource_print_side_choice.dart';
import 'textbook_explorer_view.dart';

/// 자료 메뉴 교재 원본 인쇄에서 고른 범위.
class TextbookOriginalPrintRequest {
  const TextbookOriginalPrintRequest({
    required this.bodyRawPages,
    required this.includeAnswer,
    required this.includeSolution,
    required this.duplexMode,
  });

  /// 본문 PDF의 1-based 페이지. 개념 페이지도 포함한다.
  final List<int> bodyRawPages;
  final bool includeAnswer;
  final bool includeSolution;
  final PrintDuplexMode duplexMode;
}

/// 교재를 열었을 때와 같은 단원 트리에서 원본 인쇄 범위를 고른다.
class TextbookOriginalPrintDialog extends StatefulWidget {
  const TextbookOriginalPrintDialog({
    super.key,
    required this.academyId,
    required this.bookId,
    required this.gradeLabel,
    required this.bookTitle,
  });

  final String academyId;
  final String bookId;
  final String gradeLabel;
  final String bookTitle;

  @override
  State<TextbookOriginalPrintDialog> createState() =>
      _TextbookOriginalPrintDialogState();
}

class _TextbookOriginalPrintDialogState
    extends State<TextbookOriginalPrintDialog> {
  late final TextbookExplorerController _explorer;
  late final TextEditingController _rangeController;
  bool _includeAnswer = false;
  bool _includeSolution = false;
  PrintDuplexMode _duplexMode = PrintDuplexMode.twoSidedLongEdge;
  bool _suppressTreeSync = false;

  @override
  void initState() {
    super.initState();
    _explorer = TextbookExplorerController(
      academyId: widget.academyId,
      bookId: widget.bookId,
      gradeLabel: widget.gradeLabel,
      bookTitle: widget.bookTitle,
      homeworkSelectionMode: true,
    );
    _rangeController = ImeAwareTextEditingController();
    _explorer.addListener(_syncRangeFromTree);
    _explorer.load();
  }

  @override
  void dispose() {
    _explorer.removeListener(_syncRangeFromTree);
    _explorer.dispose();
    _rangeController.dispose();
    super.dispose();
  }

  void _syncRangeFromTree() {
    if (_suppressTreeSync) return;
    final text = _shownRangeFromChecked();
    if (_rangeController.text == text) return;
    _rangeController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _onRangeEdited(String _) {
    if (_explorer.checkedPageKeys.isEmpty) return;
    _suppressTreeSync = true;
    _explorer.togglePageKeys(
      List<String>.from(_explorer.checkedPageKeys),
      false,
    );
    _suppressTreeSync = false;
  }

  String _shownRangeFromChecked() {
    final shownToRaw = _shownToRawPages(_explorer.data);
    final rawToShown = <int, int>{};
    for (final entry in shownToRaw.entries) {
      for (final raw in entry.value) {
        rawToShown[raw] = entry.key;
      }
    }
    final shown = <int>{};
    for (final key in _explorer.checkedPageKeys) {
      final raw = int.tryParse(key.split('#').last);
      if (raw == null || raw <= 0) continue;
      shown.add(rawToShown[raw] ?? raw);
    }
    return _pagesToRangeText(shown);
  }

  void _submit() {
    final request = _buildRequest();
    if (request == null) return;
    Navigator.of(context).pop(request);
  }

  TextbookOriginalPrintRequest? _buildRequest() {
    final checkedRaw = _checkedRawPages();
    late final Set<int> rawPages;
    if (checkedRaw.isNotEmpty) {
      rawPages = checkedRaw;
    } else {
      final parsed = _parsePageNumbers(_rangeController.text);
      if (parsed == null) {
        showAppSnackBar(context, '페이지 형식을 확인하세요. (예: 10-15, 20)');
        return null;
      }
      if (parsed.isEmpty) {
        showAppSnackBar(context, '페이지를 선택하거나 입력하세요.');
        return null;
      }
      final shownToRaw = _shownToRawPages(_explorer.data);
      if (shownToRaw.isEmpty) {
        rawPages = parsed;
      } else {
        final missing = <int>[];
        rawPages = <int>{};
        for (final page in parsed) {
          final mapped = shownToRaw[page];
          if (mapped == null || mapped.isEmpty) {
            missing.add(page);
          } else {
            rawPages.addAll(mapped);
          }
        }
        if (missing.isNotEmpty) {
          showAppSnackBar(
            context,
            '교재에 없는 페이지: ${missing.join(', ')}',
          );
          return null;
        }
      }
    }
    final pages = rawPages.toList()..sort();
    return TextbookOriginalPrintRequest(
      bodyRawPages: pages,
      includeAnswer: _includeAnswer,
      includeSolution: _includeSolution,
      duplexMode: _duplexMode,
    );
  }

  Set<int> _checkedRawPages() {
    final out = <int>{};
    for (final key in _explorer.checkedPageKeys) {
      final raw = int.tryParse(key.split('#').last);
      if (raw != null && raw > 0) out.add(raw);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = math.min(MediaQuery.sizeOf(context).height - 48, 760.0);
    final bookTitle = widget.bookTitle.trim();
    return ListenableBuilder(
      listenable: _explorer,
      builder: (context, _) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(24),
          child: UtilityGlassDialogShell(
            title: '원본 인쇄',
            icon: Icons.print_rounded,
            preferredWidth: 680,
            maxWidth: 680,
            maxHeight: maxHeight,
            onClose: () => Navigator.of(context).pop(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (bookTitle.isNotEmpty)
                    Text(
                      bookTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kDlgText,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  if (bookTitle.isNotEmpty) const SizedBox(height: 8),
                  const Text(
                    '단원에서 페이지를 고르거나 아래에 입력하세요. 개념 페이지도 함께 인쇄됩니다.',
                    style: const TextStyle(
                      color: kDlgTextSub,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: TextbookExplorerTreePanel(controller: _explorer),
                    ),
                  ),
                  if ((_explorer.error ?? '').trim().isNotEmpty &&
                      _explorer.data.units.isEmpty &&
                      !_explorer.loading) ...[
                    const SizedBox(height: 8),
                    const Text(
                      '단원 정보가 없으면 입력한 숫자는 PDF 페이지로 인쇄합니다.',
                      style: const TextStyle(
                        color: kDlgTextSub,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _rangeController,
                    style: const TextStyle(
                      color: kDlgText,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                    decoration: InputDecoration(
                      hintText: '예: 10-15, 20',
                      hintStyle: const TextStyle(
                        color: kDlgTextSub,
                        fontWeight: FontWeight.w600,
                      ),
                      filled: true,
                      fillColor: kDlgFieldBg,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      enabledBorder: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(10)),
                        borderSide: BorderSide(color: kDlgBorder),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(10)),
                        borderSide: BorderSide(color: kDlgAccent, width: 2),
                      ),
                    ),
                    onChanged: _onRangeEdited,
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _optionCheck(
                        label: '정답',
                        value: _includeAnswer,
                        textColor: kDlgText,
                        onChanged: (value) =>
                            setState(() => _includeAnswer = value),
                      ),
                      const SizedBox(width: 16),
                      _optionCheck(
                        label: '해설',
                        value: _includeSolution,
                        textColor: kDlgText,
                        onChanged: (value) =>
                            setState(() => _includeSolution = value),
                      ),
                    ],
                  ),
                  const Text(
                    '체크하면 고른 페이지의 문항이 들어 있는 정답·해설 원본을 본문 다음에 각각 인쇄합니다.',
                    style: const TextStyle(
                      color: kDlgTextSub,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      decoration: TextDecoration.none,
                    ),
                  ),
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
                        onPressed: _explorer.loading ? null : _submit,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _optionCheck({
    required String label,
    required bool value,
    required Color textColor,
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
            style: TextStyle(
              color: textColor,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}

Map<int, Set<int>> _shownToRawPages(TbExData data) {
  final out = <int, Set<int>>{};
  for (final big in data.units) {
    for (final mid in big.mids) {
      for (final small in mid.smalls) {
        for (final page in small.pages) {
          if (page.rawPage <= 0) continue;
          final shown = page.displayPage ?? page.rawPage;
          if (shown <= 0) continue;
          out.putIfAbsent(shown, () => <int>{}).add(page.rawPage);
        }
      }
    }
  }
  return out;
}

Set<int>? _parsePageNumbers(String input) {
  final cleaned = input.trim();
  if (cleaned.isEmpty) return <int>{};
  final normalized = cleaned
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('~', '-')
      .replaceAll('–', '-')
      .replaceAll('—', '-');
  final out = <int>{};
  for (final raw in normalized.split(',')) {
    if (raw.isEmpty) continue;
    if (raw.contains('-')) {
      final parts = raw.split('-');
      if (parts.length != 2) return null;
      final start = int.tryParse(parts[0]);
      final end = int.tryParse(parts[1]);
      if (start == null || end == null || start <= 0 || end <= 0) {
        return null;
      }
      var a = start;
      var b = end;
      if (a > b) {
        final tmp = a;
        a = b;
        b = tmp;
      }
      for (var page = a; page <= b; page++) {
        out.add(page);
      }
    } else {
      final page = int.tryParse(raw);
      if (page == null || page <= 0) return null;
      out.add(page);
    }
  }
  return out;
}

String _pagesToRangeText(Set<int> pages) {
  if (pages.isEmpty) return '';
  final sorted = pages.toList()..sort();
  final chunks = <String>[];
  var start = sorted.first;
  var prev = sorted.first;
  for (var i = 1; i < sorted.length; i++) {
    final cur = sorted[i];
    if (cur == prev + 1) {
      prev = cur;
      continue;
    }
    chunks.add(start == prev ? '$start' : '$start-$prev');
    start = cur;
    prev = cur;
  }
  chunks.add(start == prev ? '$start' : '$start-$prev');
  return chunks.join(',');
}
