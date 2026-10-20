import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_book_order.dart';
import '../../../services/concept_book_service.dart';
import '../../think/think_style.dart';
import 'concept_workspace.dart';

typedef ConceptBookOrderLoader = Future<ConceptBookOrder> Function(ConceptBookEntry book);

/// 이 교재에 나온 순서로 개념을 다시 나열한다. 라이브러리 폴더는 바꾸지 않는다.
Future<void> showConceptBookOrderDialog(BuildContext context,
    {required ConceptBookEntry book, ConceptBookOrderLoader? load}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ConceptBookOrderDialog(book: book, load: load),
  );
}

class ConceptBookOrderDialog extends StatefulWidget {
  const ConceptBookOrderDialog({super.key, required this.book, this.load});

  final ConceptBookEntry book;
  final ConceptBookOrderLoader? load;

  @override
  State<ConceptBookOrderDialog> createState() => _ConceptBookOrderDialogState();
}

class _ConceptBookOrderDialogState extends State<ConceptBookOrderDialog> {
  final _scroll = ScrollController();
  ConceptBookOrder? _order;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _order = null;
      _error = null;
    });
    try {
      final order = await (widget.load ?? ConceptBookOrderService().load)(widget.book);
      if (mounted) setState(() => _order = order);
    } catch (e) {
      if (mounted) setState(() => _error = '교재 순서를 읽지 못했습니다: $e');
    }
  }

  String _pageLabel(ConceptBookOrderEntry e) {
    final more = e.pages.length > 1 ? ' 외 ${e.pages.length - 1}쪽' : '';
    final printed = e.displayPage == null ? '' : ' (책 ${e.displayPage}쪽)';
    return 'PDF ${e.rawPage}쪽$printed$more';
  }

  Widget _row(int n, ConceptBookOrderEntry e) {
    return Container(
      key: ValueKey('book-order-${e.conceptId}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text('$n', style: const TextStyle(color: kThinkHint, fontSize: 13, fontWeight: FontWeight.w800)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(e.name.isEmpty ? '(이름 없음)' : e.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                    if (e.versionLabel.isNotEmpty && e.versionLabel != '기본') ...[
                      const SizedBox(width: 6),
                      ThinkBadge(e.versionLabel, color: kThinkHint),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 14, color: kThinkSub),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(e.folderPath.isEmpty ? '(폴더를 읽지 못함)' : e.folderPath.join(' > '),
                          overflow: TextOverflow.ellipsis, style: const TextStyle(color: kThinkSub, fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_pageLabel(e), style: const TextStyle(color: kThinkSub, fontSize: 12)),
              if (e.orderFrom == ConceptPageOrderFrom.unknown) ...[
                const SizedBox(height: 4),
                const Tooltip(
                  message: '쪽 안 어디에 나오는지 기록이 없어 같은 쪽 개념 뒤에 둡니다(직접 이은 출처 등).',
                  child: ThinkBadge('쪽 안 순서 모름', color: kThinkHint),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => unawaited(_load()), child: const Text('다시 읽기')),
          ),
        ],
      );
    }
    final order = _order;
    if (order == null) {
      return const Center(child: CircularProgressIndicator(color: kThinkAccent));
    }
    if (order.entries.isEmpty) {
      return const Center(child: ConceptHint('이 교재를 출처로 이은 개념이 없습니다. 초안을 확정하거나 개념에 출처를 이으면 여기에 나옵니다.'));
    }
    final groups = order.byUnit;
    final notes = [
      if (order.computedFromDrafts > 0) '${order.computedFromDrafts}개는 쪽 안 순서를 저장하기 전에 확정해 초안 기록으로 순서를 계산했습니다.',
      if (order.unknownOrder > 0) '${order.unknownOrder}개는 쪽 안 순서를 몰라 같은 쪽 개념 뒤에 두었습니다.',
    ];
    var n = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConceptHint('개념 ${order.entries.length}개 · 교재에 처음 나온 자리(쪽 → 쪽 안 순서)로 놓았습니다. 라이브러리 폴더는 그대로입니다.'),
        for (final t in notes) ConceptHint(t),
        const SizedBox(height: 10),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            child: ListView(
              controller: _scroll,
              children: [
                for (final g in groups) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 6),
                    child: Text(g.unit.isEmpty ? '(단원 기록 없음)' : g.unit.join(' > '),
                        style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800)),
                  ),
                  for (final e in g.entries) _row(++n, e),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: math.min(760, size.width - 48),
        height: math.min(720, size.height - 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.format_list_numbered, color: kThinkAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('교재 순서로 보기',
                        style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                    color: kThinkSub,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('${widget.book.bookName ?? '(책 이름을 볼 수 없음)'} · ${widget.book.gradeLabel}',
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }
}
