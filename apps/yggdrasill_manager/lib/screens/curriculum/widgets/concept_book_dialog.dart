import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_book_service.dart';
import '../../../services/concept_draft_models.dart';
import '../../../services/concept_draft_service.dart';
import '../../../services/concept_library_controller.dart';
import '../../../services/think/think_concept_chat_controller.dart';
import '../../think/think_style.dart';
import 'concept_book_order_dialog.dart';
import 'concept_draft_batch_dialog.dart';
import 'concept_draft_build_dialog.dart';
import 'concept_library_pane.dart';
import 'concept_workspace.dart';

/// 대화에 붙인 결과. problems는 첨부하지 못한 파일 안내.
typedef ConceptBookAttached = void Function(int pages, List<String> problems);

Future<void> showConceptBookDialog(
  BuildContext context, {
  required ConceptLibraryController library,
  ConceptBookAttached? onAttached,
  ValueChanged<String>? onDraftReady,
  VoidCallback? onDraftsConfirmed,
  ConceptBookService? service,
  ConceptDraftService? draftService,
  ConceptBookOrderLoader? orderLoader,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ConceptBookDialog(
      library: library,
      onAttached: onAttached,
      onDraftReady: onDraftReady,
      onDraftsConfirmed: onDraftsConfirmed,
      service: service,
      draftService: draftService,
      orderLoader: orderLoader,
    ),
  );
}

/// 확정·검토 중·아직 안 함 비율 막대.
class _DraftProgressBar extends StatelessWidget {
  const _DraftProgressBar(this.p, {required this.height});

  final ConceptDraftProgressCount p;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            if (p.confirmed > 0) Expanded(flex: p.confirmed, child: const ColoredBox(color: kThinkSuccess)),
            if (p.open > 0) Expanded(flex: p.open, child: const ColoredBox(color: kThinkAccent)),
            if (p.remaining > 0) Expanded(flex: p.remaining, child: const ColoredBox(color: kThinkField)),
          ],
        ),
      ),
    );
  }
}

class _PickedPage {
  const _PickedPage({required this.rawPage, required this.path, this.displayPage});

  final int rawPage;
  final List<String> path;
  final int? displayPage;

  String get label => displayPage != null ? '본문 $displayPage쪽(PDF $rawPage쪽)' : 'PDF $rawPage쪽';
}

/// 개념책 불러오기. 저장된 교재 구조와 문항 기록으로 쪽을 표시하고(새로 추출하지 않는다),
/// 고른 쪽을 Think 대화에 이미지로 붙이거나 열어 둔 개념의 출처로 잇는다. 둘 다 사용자가 누를 때만 한다.
class ConceptBookDialog extends StatefulWidget {
  const ConceptBookDialog({
    super.key,
    required this.library,
    this.onAttached,
    this.onDraftReady,
    this.onDraftsConfirmed,
    this.service,
    this.draftService,
    this.orderLoader,
  });

  final ConceptLibraryController library;
  final ConceptBookAttached? onAttached;

  /// 소단원으로 개념 초안을 만들었을 때(이 창은 닫힌 뒤). 검토 화면을 연다.
  final ValueChanged<String>? onDraftReady;

  /// "차례로 만들기" 창에서 초안을 한 번에 확정했을 때. 라이브러리를 다시 읽는다.
  final VoidCallback? onDraftsConfirmed;
  final ConceptBookService? service;
  final ConceptDraftService? draftService;

  /// 시험용. 없으면 "교재 순서로 보기"가 DB에서 읽는다.
  final ConceptBookOrderLoader? orderLoader;

  static const int maxPages = 6;

  @override
  State<ConceptBookDialog> createState() => _ConceptBookDialogState();
}

class _ConceptBookDialogState extends State<ConceptBookDialog> {
  late final ConceptBookService _svc = widget.service ?? ConceptBookService();
  final ScrollController _bookScroll = ScrollController();
  final ScrollController _pageScroll = ScrollController();

  List<ConceptBookEntry>? _books;
  String? _booksError;
  bool _conceptOnly = true;
  bool _showSuperseded = false;

  /// 교재 항목별 문항 기록 수. -1은 세지 못함.
  final Map<String, int> _counts = {};
  final Set<String> _counting = {};

  ConceptBookEntry? _book;
  Map<int, ConceptBookCropPage>? _crops;
  String? _cropsError;
  int _cropsRequest = 0;

  final Map<int, _PickedPage> _picked = {};
  bool _busy = false;
  String? _progress;
  String? _notice;
  bool _noticeError = false;

  late final ConceptDraftService _draftSvc = widget.draftService ?? ConceptDraftService();
  ConceptDraftCoverage? _coverage;
  String? _coverageError;
  bool _undraftedOnly = false;

  /// 차례로 만들 중단원(단원 경로의 앞부분).
  final Set<String> _batchGroups = {};

  ConceptLibraryController get _lib => widget.library;
  ConceptChatController get _chat => _lib.chat;

  /// 초안을 만들 수 있는 창(검토 화면을 열 곳이 있음)에서만 초안 기록을 읽는다.
  bool get _tracksDrafts => widget.onDraftReady != null;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBooks());
    if (_tracksDrafts) unawaited(_loadCoverage());
  }

  Future<void> _loadCoverage() async {
    setState(() {
      _coverage = null;
      _coverageError = null;
    });
    try {
      final c = await _draftSvc.coverage();
      if (mounted) setState(() => _coverage = c);
    } catch (e) {
      if (mounted) setState(() => _coverageError = '개념 초안 기록을 읽지 못했습니다: $e');
    }
  }

  static bool _draftable(ConceptBookUnitPages u) => u.hasRange && !u.slot && !u.isExercise;

  static bool _tooLong(ConceptBookUnitPages u) => u.pages.length > kConceptDraftMaxPages || u.capped;

  /// 중단원에서 차례로 만들 소단원(아직 초안이 없고 한 번에 정리할 수 있는 것)과 쪽이 많아 빼는 소단원.
  ({List<ConceptBookUnitPages> run, List<ConceptBookUnitPages> tooLong}) _batchUnits(
      ConceptBookEntry book, Iterable<String> groups) {
    final cov = _coverage;
    final crops = _crops;
    if (cov == null || crops == null) return (run: const [], tooLong: const []);
    final wanted = groups.toSet();
    final run = <ConceptBookUnitPages>[];
    final tooLong = <ConceptBookUnitPages>[];
    for (final u in conceptBookUnitPages(book.units, crops)) {
      if (!wanted.contains(_groupOf(u.path)) || !_draftable(u) || u.pages.isEmpty) continue;
      if (cov.unit(book, u.path).state != ConceptUnitDraftState.none) continue;
      (_tooLong(u) ? tooLong : run).add(u);
    }
    return (run: run, tooLong: tooLong);
  }

  Future<void> _runBatch(ConceptBookEntry book) async {
    final units = _batchUnits(book, _batchGroups).run;
    if (units.isEmpty) return;
    final made = await showConceptDraftBatchDialog(
      context,
      book: book,
      units: units,
      criteria: _lib.criteria,
      service: widget.draftService,
      onConfirmed: widget.onDraftsConfirmed,
    );
    if (!mounted) return;
    setState(() => _batchGroups.clear());
    if (made) unawaited(_loadCoverage());
  }

  static String _groupOf(List<String> path) => path.length >= 2 ? path.sublist(0, path.length - 1).join(' > ') : '';

  @override
  void dispose() {
    _bookScroll.dispose();
    _pageScroll.dispose();
    super.dispose();
  }

  Future<void> _loadBooks() async {
    setState(() {
      _books = null;
      _booksError = null;
      _counts.clear();
    });
    try {
      final list = await _svc.listBooks();
      if (!mounted) return;
      setState(() => _books = list);
      _loadCounts(_withSameBooks(_filteredBooks));
    } catch (e) {
      if (!mounted) return;
      setState(() => _booksError = '교재 목록을 읽지 못했습니다: $e');
    }
  }

  List<ConceptBookEntry> get _filteredBooks =>
      (_books ?? const <ConceptBookEntry>[]).where((b) => !_conceptOnly || b.isConceptBook).toList();

  List<ConceptBookEntry> get _shownBooks {
    final filtered = _filteredBooks;
    if (_showSuperseded) return filtered;
    return filtered.where((b) => !_superseded(b, filtered)).toList();
  }

  /// 문항 기록이 없고, 목록에 함께 보이는 이름·학년이 같은 항목에는 문항 기록이 있는 예전 등록.
  /// 지우지 않고 목록에서만 숨긴다.
  bool _superseded(ConceptBookEntry b, List<ConceptBookEntry> filtered) {
    if (_counts[b.key] != 0) return false;
    final keys = {for (final x in filtered) x.key};
    return _sameBook(b).any((o) => keys.contains(o.key) && (_counts[o.key] ?? 0) > 0);
  }

  int get _supersededCount {
    final filtered = _filteredBooks;
    return filtered.where((b) => _superseded(b, filtered)).length;
  }

  /// 예전 등록인지 가리려면 같은 이름 항목의 문항 기록 수도 알아야 한다.
  List<ConceptBookEntry> _withSameBooks(List<ConceptBookEntry> books) {
    final seen = <String>{};
    return [
      for (final b in books)
        for (final x in [b, ..._sameBook(b)])
          if (seen.add(x.key)) x,
    ];
  }

  /// 목록에 문항 기록 수를 붙인다. 한 번에 4개까지만 센다.
  void _loadCounts(Iterable<ConceptBookEntry> books) {
    final todo = [
      for (final b in books)
        if (!_counts.containsKey(b.key) && _counting.add(b.key)) b
    ];
    var next = 0;
    Future<void> worker() async {
      while (next < todo.length) {
        final b = todo[next++];
        int n;
        try {
          n = await _svc.problemCount(b);
        } catch (_) {
          n = -1;
        }
        _counting.remove(b.key);
        if (!mounted) return;
        setState(() => _counts[b.key] = n);
      }
    }

    for (var i = 0; i < math.min(4, todo.length); i += 1) {
      unawaited(worker());
    }
  }

  /// 이름·학년이 같은 다른 교재 항목. 이름을 볼 수 없으면 찾지 않는다.
  List<ConceptBookEntry> _sameBook(ConceptBookEntry book) {
    final name = book.bookName;
    if (name == null) return const [];
    return [
      for (final b in _books ?? const <ConceptBookEntry>[])
        if (b.key != book.key && b.bookName == name && b.gradeLabel == book.gradeLabel) b,
    ];
  }

  Future<void> _selectBook(ConceptBookEntry b) async {
    final request = ++_cropsRequest;
    setState(() {
      _book = b;
      _crops = null;
      _cropsError = null;
      _picked.clear();
      _batchGroups.clear();
      _notice = null;
    });
    try {
      final crops = await _svc.problemPages(b);
      if (!mounted || request != _cropsRequest) return;
      setState(() {
        _crops = crops;
        _counts[b.key] = crops.values.fold(0, (sum, p) => sum + p.problems);
      });
      if (crops.isEmpty || b.units.isEmpty) _loadCounts(_sameBook(b));
    } catch (e) {
      if (!mounted || request != _cropsRequest) return;
      setState(() => _cropsError = '문항 기록을 읽지 못했습니다: $e');
    }
  }

  void _toggle(ConceptBookUnitPages unit, ConceptBookPage page) {
    setState(() {
      _notice = null;
      if (_picked.remove(page.rawPage) != null) return;
      if (_picked.length >= ConceptBookDialog.maxPages) {
        _notice = '한 번에 ${ConceptBookDialog.maxPages}쪽까지 고를 수 있습니다.';
        _noticeError = true;
        return;
      }
      _picked[page.rawPage] = _PickedPage(rawPage: page.rawPage, path: unit.path, displayPage: page.displayPage);
    });
  }

  List<_PickedPage> get _pickedSorted => _picked.values.toList()..sort((a, b) => a.rawPage.compareTo(b.rawPage));

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: math.min(1080, size.width - 48),
        height: math.min(740, size.height - 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.menu_book_outlined, color: kThinkAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('개념책 불러오기',
                        style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                    color: kThinkSub,
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: ConceptHint(
                '저장된 교재 구조(단원·쪽 범위)와 문항 기록으로 쪽을 표시합니다. 문항 기록이 있는 소단원에서 문항이 없는 쪽을 "개념 페이지"로 표시합니다. '
                '"개념 초안 만들기"를 누를 때만 그 소단원 쪽을 옮겨 적어 초안과 함께 저장합니다(라이브러리에는 검토 후 확정할 때만 들어감).',
              ),
            ),
            const Divider(color: kThinkBorder, height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 300, child: _bookList()),
                  const VerticalDivider(color: kThinkBorder, width: 1),
                  Expanded(child: _pages()),
                ],
              ),
            ),
            const Divider(color: kThinkBorder, height: 1),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _bookList() {
    final books = _books;
    final shown = _shownBooks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('교재', style: TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w800)),
              ),
              ThinkToggleChip(
                label: '개념서만',
                icon: Icons.filter_alt_outlined,
                selected: _conceptOnly,
                tooltip: '종류가 개념서로 저장됐거나 개념서 시리즈(개념원리·개념+유형 등)로 등록된 교재만 보입니다. 끄면 모든 교재가 보입니다.',
                onChanged: (v) {
                  setState(() => _conceptOnly = v);
                  _loadCounts(_withSameBooks(_filteredBooks));
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: () {
            if (_booksError != null) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ThinkNotice(text: _booksError!, color: kThinkError, icon: Icons.error_outline),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(onPressed: _loadBooks, child: const Text('다시 읽기')),
                    ),
                  ],
                ),
              );
            }
            if (books == null) return const Center(child: CircularProgressIndicator(color: kThinkAccent));
            if (shown.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: ConceptHint(_conceptOnly && books.isNotEmpty
                    ? '단원 구조가 저장된 개념서가 없습니다. "개념서만"을 끄면 다른 교재도 보입니다.'
                    : '단원 구조가 저장된 교재가 없습니다. 교재 탭에서 단원 구조를 먼저 저장해야 합니다.'),
              );
            }
            final hidden = _supersededCount;
            return Scrollbar(
              controller: _bookScroll,
              child: ListView.builder(
                controller: _bookScroll,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                itemCount: shown.length + (hidden > 0 ? 1 : 0),
                itemBuilder: (context, i) => i < shown.length ? _bookRow(shown[i]) : _supersededToggle(hidden),
              ),
            );
          }(),
        ),
      ],
    );
  }

  Widget _supersededToggle(int hidden) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _showSuperseded ? '문항 기록 없는 예전 항목 $hidden개도 보이는 중' : '같은 교재의 문항 기록 없는 예전 항목 $hidden개 숨김',
              style: const TextStyle(color: kThinkHint, fontSize: 12),
            ),
          ),
          TextButton(
            key: const ValueKey('concept-book-superseded-toggle'),
            onPressed: () => setState(() => _showSuperseded = !_showSuperseded),
            child: Text(_showSuperseded ? '숨기기' : '보이기'),
          ),
        ],
      ),
    );
  }

  Widget _bookRow(ConceptBookEntry b) {
    final selected = _book?.key == b.key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy ? null : () => unawaited(_selectBook(b)),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? kThinkAccent.withValues(alpha: 0.6) : kThinkBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.bookName ?? '(책 이름을 볼 수 없음)',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ThinkBadge(b.gradeLabel.isEmpty ? '(학년 없음)' : b.gradeLabel),
                    if (b.seriesName != null)
                      ThinkBadge('${b.seriesName} 시리즈',
                          color: b.series?.defaultTextbookType == '개념서' ? kThinkLink : kThinkHint),
                    ThinkBadge(b.textbookType ?? '종류 미지정', color: b.textbookType == '개념서' ? kThinkLink : kThinkHint),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_bookMeta(b), style: const TextStyle(color: kThinkSub, fontSize: 12)),
                if (_bookProgress(b) case final w?) w,
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _bookMeta(ConceptBookEntry b) {
    final structure =
        b.subUnitCount > 0 ? '소단원 ${b.subUnitCount}개' : (b.slotCount > 0 ? '문항 묶음 ${b.slotCount}개' : '단원 구조 없음');
    final n = _counts[b.key];
    final records = n == null ? '문항 기록 세는 중' : (n < 0 ? '문항 기록 수를 읽지 못함' : (n == 0 ? '문항 기록 없음' : '문항 기록 $n개'));
    return '$structure · $records';
  }

  Widget? _bookProgress(ConceptBookEntry b) {
    final p = _coverage?.progress(b);
    if (p == null || p.total == 0) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(child: _DraftProgressBar(p, height: 4)),
          const SizedBox(width: 8),
          Text('초안 ${p.percent}% · ${p.drafted}/${p.total}',
              style: TextStyle(
                color: p.remaining == 0 ? kThinkSuccess : kThinkSub,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              )),
        ],
      ),
    );
  }

  /// 교재 하나의 초안 진행. 분모는 "개념 초안 만들기"를 누를 수 있는 소단원.
  Widget _progressPanel(ConceptBookEntry book) {
    if (_coverageError != null) {
      return Row(
        children: [
          Expanded(child: ThinkNotice(text: _coverageError!, color: kThinkError, icon: Icons.error_outline)),
          TextButton(onPressed: () => unawaited(_loadCoverage()), child: const Text('다시 읽기')),
        ],
      );
    }
    final cov = _coverage;
    if (cov == null) return const ConceptHint('개념 초안 기록을 읽는 중입니다.');
    final p = cov.progress(book);
    if (p.total == 0) return const ConceptHint('이 교재 항목에는 개념 초안을 만들 수 있는 소단원(쪽 범위가 있는 소단원)이 없습니다.');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('개념 초안 진행', style: TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(width: 10),
              Tooltip(
                message: '초안을 만든 소단원(검토 중+확정) ÷ 초안을 만들 수 있는 소단원. 버리거나 다시 정리한 초안은 세지 않습니다.',
                child: Text('${p.percent}%',
                    style: TextStyle(
                      color: p.remaining == 0 ? kThinkSuccess : kThinkAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    )),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('소단원 ${p.total}개 중 ${p.drafted}개',
                    style: const TextStyle(color: kThinkSub, fontSize: 13), overflow: TextOverflow.ellipsis),
              ),
              ThinkToggleChip(
                label: '초안 안 한 소단원만',
                icon: Icons.filter_alt_outlined,
                selected: _undraftedOnly,
                tooltip: '아직 초안을 만들지 않은 소단원만 보입니다.',
                onChanged: (v) => setState(() => _undraftedOnly = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _DraftProgressBar(p, height: 8),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    _legend(kThinkSuccess, '확정 ${p.confirmed}'),
                    _legend(kThinkAccent, '검토 중 ${p.open}'),
                    _legend(kThinkField, '아직 안 함 ${p.remaining}', border: true),
                  ],
                ),
              ),
              TextButton.icon(
                key: const ValueKey('concept-book-order'),
                onPressed: () => unawaited(showConceptBookOrderDialog(context, book: book, load: widget.orderLoader)),
                icon: const Icon(Icons.format_list_numbered, size: 16),
                label: const Text('교재 순서로 보기'),
                style: TextButton.styleFrom(foregroundColor: kThinkLink),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 10),
          _batchBar(book),
        ],
      ),
    );
  }

  Widget _batchBar(ConceptBookEntry book) {
    if (_batchGroups.isEmpty) {
      return const ConceptHint('중단원 이름 앞 네모를 눌러 고르면 그 중단원의 남은 소단원을 차례로 만들 수 있습니다. 확정은 하나씩 검토한 뒤에 합니다.');
    }
    final b = _batchUnits(book, _batchGroups);
    return Row(
      children: [
        Expanded(
          child: Text(
            '중단원 ${_batchGroups.length}개 · 새로 만들 소단원 ${b.run.length}개'
            '${b.tooLong.isEmpty ? '' : ' · $kConceptDraftMaxPages쪽 넘어 빼는 소단원 ${b.tooLong.length}개'}',
            style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _batchGroups.clear()),
          child: const Text('고르기 취소', style: TextStyle(color: kThinkSub)),
        ),
        const SizedBox(width: 6),
        ElevatedButton.icon(
          onPressed: _busy || b.run.isEmpty ? null : () => unawaited(_runBatch(book)),
          style: thinkPrimaryButton(),
          icon: const Icon(Icons.playlist_play, size: 18),
          label: const Text('차례로 만들기'),
        ),
      ],
    );
  }

  Widget _legend(Color color, String label, {bool border = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: border ? Border.all(color: kThinkHint) : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: kThinkSub, fontSize: 12)),
      ],
    );
  }

  Widget _pages() {
    final book = _book;
    if (book == null) return const Center(child: ConceptHint('왼쪽에서 교재를 고르세요.'));
    if (_cropsError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ThinkNotice(text: _cropsError!, color: kThinkError, icon: Icons.error_outline),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => unawaited(_selectBook(book)), child: const Text('다시 읽기')),
            ),
          ],
        ),
      );
    }
    final crops = _crops;
    if (crops == null) return const Center(child: CircularProgressIndicator(color: kThinkAccent));
    final units = conceptBookUnitPages(book.units, crops);
    final hasRecords = crops.isNotEmpty;
    final children = <Widget>[];
    void notice(Widget w) => children.add(Padding(padding: const EdgeInsets.only(bottom: 10), child: w));
    if (units.isEmpty) {
      notice(const ThinkNotice(text: '이 교재 항목에는 저장된 단원 구조가 없습니다. 교재 탭에서 단원 구조(소단원·쪽)를 먼저 저장해야 합니다.'));
    } else if (!hasRecords) {
      notice(const ThinkNotice(text: '이 교재 항목에는 문항 기록이 없어 개념 페이지를 표시하지 않습니다.'));
    }
    if (book.subUnitCount == 0 && book.slotCount > 0) {
      notice(const ConceptHint('실제 소단원 목록이 저장되어 있지 않아 문항 묶음(A·B·C…)의 쪽 범위를 보입니다. 문항 묶음에는 개념 페이지 표시를 하지 않습니다.'));
    }
    if (units.isEmpty || !hasRecords) {
      final others = [
        for (final o in _sameBook(book))
          if (o.units.isNotEmpty && (_counts[o.key] ?? 0) > 0) o,
      ];
      if (others.isNotEmpty) notice(_sameBookNotice(others));
    }
    if (_tracksDrafts && units.isNotEmpty) notice(_progressPanel(book));
    final cov = _coverage;
    final filtering = _undraftedOnly && cov != null;
    final shown = [
      for (final u in units)
        if (!filtering || (_draftable(u) && cov.unit(book, u.path).state == ConceptUnitDraftState.none)) u,
    ];
    if (filtering && shown.isEmpty) notice(const ConceptHint('초안을 만들지 않은 소단원이 없습니다.'));
    String? lastGroup;
    for (final u in shown) {
      final group = _groupOf(u.path);
      if (group != lastGroup) {
        lastGroup = group;
        if (group.isNotEmpty) children.add(_groupHeader(book, group, top: children.isEmpty ? 0 : 14));
      }
      children.add(_unitCard(book, u, bookHasRecords: hasRecords));
    }
    return Scrollbar(
      controller: _pageScroll,
      child: ListView(controller: _pageScroll, padding: const EdgeInsets.all(16), children: children),
    );
  }

  /// 이름·학년이 같은 교재 항목이 여럿일 때. 합치지 않고 그 항목으로 옮겨 보기만 한다.
  Widget _sameBookNotice(List<ConceptBookEntry> others) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkLink.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('이름·학년이 같은 다른 교재 항목에는 문항 기록이 있습니다.',
              style: TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final o in others)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_selectBook(o)),
                  style: thinkOutlineButton(),
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: Text('문항 기록이 ${_counts[o.key]}개인 항목 보기'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 중단원 이름과 그 안 소단원의 초안 진행(필터와 상관없이 전체 기준).
  Widget _groupHeader(ConceptBookEntry book, String group, {required double top}) {
    final p = _coverage?.progress(book, book.units.where((x) => _groupOf(x.path) == group));
    final selectable = _tracksDrafts && _batchUnits(book, [group]).run.isNotEmpty;
    final selected = _batchGroups.contains(group);
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 6),
      child: Row(
        children: [
          if (selectable || selected) ...[
            Tooltip(
              message: selected ? '차례로 만들 중단원에서 뺍니다.' : '이 중단원의 남은 소단원을 차례로 만들 목록에 넣습니다.',
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: _busy
                    ? null
                    : () => setState(() => selected ? _batchGroups.remove(group) : _batchGroups.add(group)),
                child: Icon(selected ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 20, color: selected ? kThinkAccent : kThinkHint),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(group,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w800)),
          ),
          if (p != null && p.total > 0) ...[
            const SizedBox(width: 10),
            SizedBox(width: 80, child: _DraftProgressBar(p, height: 4)),
            const SizedBox(width: 6),
            Text('초안 ${p.drafted}/${p.total}',
                style: TextStyle(
                    color: p.remaining == 0 ? kThinkSuccess : kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ],
      ),
    );
  }

  Widget _unitCard(ConceptBookEntry book, ConceptBookUnitPages u, {required bool bookHasRecords}) {
    final draft = _tracksDrafts && _draftable(u) ? _coverage?.unit(book, u.path) : null;
    final state = draft?.state;
    final accent = switch (state) {
      ConceptUnitDraftState.confirmed => kThinkSuccess,
      ConceptUnitDraftState.open => kThinkAccent,
      _ => null,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: accent == null ? kThinkPanel : Color.alphaBlend(accent.withValues(alpha: 0.06), kThinkPanel),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent?.withValues(alpha: 0.55) ?? kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (state != null) ...[
                Icon(
                  switch (state) {
                    ConceptUnitDraftState.confirmed => Icons.check_circle,
                    ConceptUnitDraftState.open => Icons.pending_outlined,
                    ConceptUnitDraftState.none => Icons.radio_button_unchecked,
                  },
                  size: 16,
                  color: accent ?? kThinkHint,
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(u.path.isEmpty ? '(이름 없는 소단원)' : u.path.last,
                    style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              if (u.slot) ...[const ThinkBadge('문항 묶음'), const SizedBox(width: 6)],
              if (u.isExercise) ...[const ThinkBadge('연습문제'), const SizedBox(width: 6)],
              if (state != null) ...[
                ThinkBadge(
                  switch (state) {
                    ConceptUnitDraftState.confirmed => '초안 확정함',
                    ConceptUnitDraftState.open => '초안 검토 중',
                    ConceptUnitDraftState.none => '초안 안 함',
                  },
                  color: accent ?? kThinkHint,
                ),
                const SizedBox(width: 6),
              ],
              ConceptHint(u.hasRange ? 'PDF ${u.startPage}–${u.endPage}쪽' : '쪽 범위 없음'),
              if (_tracksDrafts && _draftable(u)) ...[
                const SizedBox(width: 8),
                if (draft != null && state == ConceptUnitDraftState.open && draft.openId != null)
                  _reviewButton(draft)
                else
                  _draftButton(u, again: state == ConceptUnitDraftState.confirmed),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (!u.hasRange)
            const ConceptHint('이 소단원은 쪽 범위가 저장되어 있지 않습니다.')
          else ...[
            if (!u.extracted && bookHasRecords && !u.slot)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: ConceptHint('이 소단원은 문항 기록이 없어 쪽 표시를 하지 않았습니다(아직 추출 전일 수 있음).'),
              ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final p in u.pages) _pageChip(u, p)],
            ),
            if (u.capped)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: ConceptHint('쪽 범위가 길어 앞 $kConceptBookMaxPagesPerUnit쪽만 보입니다.'),
              ),
          ],
        ],
      ),
    );
  }

  ButtonStyle _unitButtonStyle(Color color) => OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      );

  /// again: 확정한 초안이 이미 있는 소단원. 새로 만들면 초안이 하나 더 생긴다.
  Widget _draftButton(ConceptBookUnitPages u, {bool again = false}) {
    final tooMany = u.pages.length > kConceptDraftMaxPages || u.capped;
    final blocked = tooMany
        ? '쪽이 ${u.pages.length}쪽이라 한 번에 정리할 수 있는 $kConceptDraftMaxPages쪽을 넘습니다.'
        : (u.pages.isEmpty ? '쪽이 없습니다.' : null);
    return Tooltip(
      message: blocked ??
          (again
              ? '이미 확정한 초안이 있습니다. 다시 만들면 새 초안이 하나 더 생기고, 확정한 개념은 그대로 둡니다.'
              : '이 소단원 쪽을 AI가 옮겨 적고 개념 초안과 넣을 폴더를 제안합니다. 확정은 검토 화면에서 직접 합니다.'),
      child: OutlinedButton.icon(
        onPressed: _busy || blocked != null ? null : () => unawaited(_buildDraft(u)),
        style: _unitButtonStyle(again ? kThinkSub : kThinkAccent),
        icon: Icon(again ? Icons.refresh : Icons.auto_awesome_outlined, size: 16),
        label: Text(again ? '다시 만들기' : '개념 초안 만들기', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _reviewButton(ConceptUnitDraft d) {
    return Tooltip(
      message: d.openCount > 1 ? '검토 중인 초안이 ${d.openCount}개입니다. 가장 최근에 만든 초안을 엽니다.' : '검토 중인 초안을 엽니다.',
      child: OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () {
                Navigator.pop(context);
                widget.onDraftReady?.call(d.openId!);
              },
        style: _unitButtonStyle(kThinkAccent),
        icon: const Icon(Icons.fact_check_outlined, size: 16),
        label: const Text('검토하기', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Future<void> _buildDraft(ConceptBookUnitPages u) async {
    final book = _book;
    if (book == null) return;
    final id = await showConceptDraftBuildDialog(
      context,
      book: book,
      unit: u,
      criteria: _lib.criteria,
      service: widget.draftService,
    );
    if (id == null || !mounted) return;
    Navigator.pop(context);
    widget.onDraftReady?.call(id);
  }

  Widget _pageChip(ConceptBookUnitPages u, ConceptBookPage p) {
    final selected = _picked.containsKey(p.rawPage);
    final concept = u.isConceptPage(p);
    final mark = concept ? ' · 개념 페이지' : (p.problems > 0 ? ' · 문항 ${p.problems}개' : '');
    final color = selected ? kThinkAccent : (concept ? kThinkSuccess : kThinkHint);
    return Tooltip(
      message: p.displayPage != null ? '본문 ${p.displayPage}쪽 (PDF ${p.rawPage}쪽)' : 'PDF ${p.rawPage}쪽',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy ? null : () => _toggle(u, p),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? kThinkAccent.withValues(alpha: 0.2) : color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: selected ? 0.9 : 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[const Icon(Icons.check, size: 14, color: kThinkAccent), const SizedBox(width: 4)],
                Text('${p.rawPage}쪽$mark',
                    style: TextStyle(
                      color: selected ? kThinkText : (concept ? kThinkText : kThinkSub),
                      fontSize: 12,
                      fontWeight: concept || selected ? FontWeight.w700 : FontWeight.w500,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    final book = _book;
    final picked = _pickedSorted;
    final concept = _lib.selectedConcept;
    final conceptOk = concept != null && _lib.isSavedConcept(concept);
    final chatBlocked =
        _chat.link != ConceptChatLink.ready ? (_chat.blockedReason ?? '먼저 이어 갈 Think 대화를 연결하세요.') : null;
    final room = 6 - _chat.pendingAttachments.length - _chat.uploadingCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_notice != null) ...[
            ThinkNotice(
              text: _notice!,
              color: _noticeError ? kThinkError : kThinkSuccess,
              icon: _noticeError ? Icons.error_outline : Icons.check_circle_outline,
              onClose: () => setState(() => _notice = null),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  _progress ??
                      (picked.isEmpty
                          ? '쪽을 고르세요 (최대 ${ConceptBookDialog.maxPages}쪽)'
                          : '${picked.length}/${ConceptBookDialog.maxPages}쪽 고름: ${picked.map((p) => '${p.rawPage}').join(', ')}'),
                  style: const TextStyle(color: kThinkSub, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_busy) ...[
                const SizedBox(
                    width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
                const SizedBox(width: 12),
              ],
              TextButton.icon(
                onPressed: book == null || picked.isEmpty || _busy
                    ? null
                    : () => unawaited(_openOriginal(book, picked.first.rawPage)),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('원본 열기'),
                style: TextButton.styleFrom(foregroundColor: kThinkLink),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Tooltip(
                  message: conceptOk ? '고른 쪽을 "${conceptDisplayName(concept)}"의 출처로 잇습니다.' : '라이브러리에서 저장된 개념을 먼저 여세요.',
                  child: OutlinedButton.icon(
                    onPressed:
                        book == null || picked.isEmpty || _busy || !conceptOk ? null : () => unawaited(_linkSources()),
                    style: thinkOutlineButton(),
                    icon: const Icon(Icons.link, size: 16),
                    label: Text(conceptOk ? '"${conceptDisplayName(concept)}" 출처로 잇기' : '열어 둔 개념의 출처로 잇기',
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: chatBlocked ??
                    (room < picked.length
                        ? '대화 입력창에 이미 첨부가 있어 $room장만 더 붙일 수 있습니다.'
                        : '고른 쪽을 이미지로 대화 입력창에 붙입니다. 보내기는 직접 누릅니다.'),
                child: ElevatedButton.icon(
                  onPressed: book == null || picked.isEmpty || _busy || chatBlocked != null || room <= 0
                      ? null
                      : () => unawaited(_attach()),
                  style: thinkPrimaryButton(),
                  icon: const Icon(Icons.forum_outlined, size: 16),
                  label: const Text('Think 대화에 쪽 이미지 붙이기'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openOriginal(ConceptBookEntry book, int rawPage) async {
    try {
      final url = await _svc.originalUrl(academyId: book.academyId, bookId: book.bookId, gradeLabel: book.gradeLabel);
      if (!mounted) return;
      await openUrlAtPage(url, rawPage);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _notice = '원본을 열지 못했습니다: $e';
        _noticeError = true;
      });
    }
  }

  Future<void> _linkSources() async {
    final book = _book;
    final concept = _lib.selectedConcept;
    if (book == null || concept == null) return;
    final picked = _pickedSorted;
    setState(() {
      _busy = true;
      _notice = null;
      _progress = '출처로 잇는 중';
    });
    var ok = 0;
    final problems = <String>[];
    for (final p in picked) {
      final problem = await _lib.addSource(
        concept: concept,
        academyId: book.academyId,
        bookId: book.bookId,
        gradeLabel: book.gradeLabel,
        rawPage: p.rawPage,
        displayPage: p.displayPage,
        unitPath: p.path,
      );
      if (problem == null) {
        ok += 1;
      } else {
        problems.add('PDF ${p.rawPage}쪽: $problem');
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = null;
      final head = '"${conceptDisplayName(concept)}"에 출처 $ok개를 이었습니다.';
      _notice = problems.isEmpty ? head : '$head\n${problems.join('\n')}';
      _noticeError = problems.isNotEmpty;
      if (problems.isEmpty) _picked.clear();
    });
  }

  Future<void> _attach() async {
    final book = _book;
    if (book == null) return;
    final picked = _pickedSorted;
    setState(() {
      _busy = true;
      _notice = null;
      _progress = '원본 PDF를 받는 중';
    });
    try {
      final paths = await _svc.renderPages(
        book,
        [for (final p in picked) p.rawPage],
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = '쪽 이미지를 만드는 중 ($done/$total)');
        },
      );
      if (!mounted) return;
      setState(() => _progress = 'Think 대화에 올리는 중');
      final problems = await _chat.addFiles(paths);
      _prefillComposer(book, picked);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onAttached?.call(paths.length - problems.length, problems);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _notice = '쪽 이미지를 붙이지 못했습니다: $e';
        _noticeError = true;
      });
    }
  }

  /// 어떤 쪽인지는 저장된 교재 구조의 값만 적는다. 질문은 사용자가 이어서 쓴다.
  void _prefillComposer(ConceptBookEntry book, List<_PickedPage> picked) {
    final byUnit = <String, List<_PickedPage>>{};
    for (final p in picked) {
      byUnit.putIfAbsent(p.path.isEmpty ? '(단원 없음)' : p.path.join(' > '), () => []).add(p);
    }
    final lines = <String>[
      '[개념책 쪽 이미지] ${book.bookName ?? '(책 이름을 볼 수 없음)'} · ${book.gradeLabel}',
      for (final e in byUnit.entries) '- ${e.key}: ${e.value.map((p) => p.label).join(', ')}',
    ];
    final block = lines.join('\n');
    final composer = _chat.composer;
    final current = composer.text.trimRight();
    composer.text = current.isEmpty ? '$block\n\n' : '$current\n\n$block\n\n';
    composer.selection = TextSelection.collapsed(offset: composer.text.length);
  }
}
