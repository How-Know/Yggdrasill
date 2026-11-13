import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart'
    show ConfirmedAnswerMathFormatter, ConfirmedAnswerMathLinesView;

import '../../services/answer_render_image_cache.dart';
import '../../services/data_manager.dart';
import '../../services/tenant_service.dart';
import '../../services/textbook_concept_units.dart';
import '../../utils/textbook_problem_source_order.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/bottom_dialog.dart';
import '../../widgets/dialog_tokens.dart';
import '../../widgets/latex_text_renderer.dart';
import '../../widgets/utility_glass_dialog_shell.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

Future<void> showGradingConfirmedAnswerDialog({
  required BuildContext context,
  required String bookId,
  required String bookName,
  required String gradeLabel,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(
      alpha: BottomDialogMetrics.barrierOpacity,
    ),
    builder: (_) => _GradingConfirmedAnswerDialog(
      bookId: bookId,
      bookName: bookName,
      gradeLabel: gradeLabel,
    ),
  );
}

class _GradingConfirmedAnswerDialog extends StatefulWidget {
  const _GradingConfirmedAnswerDialog({
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
  });

  final String bookId;
  final String bookName;
  final String gradeLabel;

  @override
  State<_GradingConfirmedAnswerDialog> createState() =>
      _GradingConfirmedAnswerDialogState();
}

class _GradingConfirmedAnswerDialogState
    extends State<_GradingConfirmedAnswerDialog> {
  static const int _initialSubunitBatch = 6;
  static const int _moreSubunitBatch = 3;
  static const double _preloadScrollThreshold = 1400.0;

  /// 문제은행 A4 2단 한 단 폭. 용지 595.28pt, 여백 46pt, 단 사이 18pt.
  static const double _a4WidthPt = 595.28;
  static const double _a4MarginPt = 46;
  static const double _a4ColumnGapPt = 18;
  static const double _ptToDp = 96 / 72;
  static const double _solutionColumnWidth =
      (_a4WidthPt - _a4MarginPt * 2 - _a4ColumnGapPt) / 2 * _ptToDp;

  static final RegExp _digitsCleanupRe = RegExp(r'[^0-9]');

  bool _loading = true;
  String? _error;
  List<_UnitBigNode> _units = const <_UnitBigNode>[];
  List<_UnitSmallNode> _confirmedSmalls = const <_UnitSmallNode>[];
  Map<String, _ConfirmedSubunitScope> _confirmedByKey =
      const <String, _ConfirmedSubunitScope>{};
  List<Map<String, dynamic>> _cropRows = const <Map<String, dynamic>>[];

  final ValueNotifier<_UnitSmallNode?> _activeSmallNotifier =
      ValueNotifier<_UnitSmallNode?>(null);
  final ValueNotifier<int> _activePageNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool> _loadingMoreNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<_PageBlockVm>> _pageBlocksNotifier =
      ValueNotifier<List<_PageBlockVm>>(const <_PageBlockVm>[]);

  bool _answersErrorOccurred = false;
  int _loadedConfirmedCount = 0;
  final Map<String, List<_AnswerItemVm>> _answersCache =
      <String, List<_AnswerItemVm>>{};

  final ScrollController _answerScrollCtrl = ScrollController();
  final ScrollController _treeScrollCtrl = ScrollController();
  final GlobalKey _answerViewportKey = GlobalKey();
  final GlobalKey _treeViewportKey = GlobalKey();
  final Map<String, GlobalKey> _treeRowKeyByStateKey = <String, GlobalKey>{};
  final TextEditingController _pageInputCtrl = TextEditingController();
  final FocusNode _pageInputFocus = FocusNode();
  bool _programmaticScroll = false;

  @override
  void initState() {
    super.initState();
    _answerScrollCtrl.addListener(_handleAnswerScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _answerScrollCtrl.removeListener(_handleAnswerScroll);
    _answerScrollCtrl.dispose();
    _treeScrollCtrl.dispose();
    _pageInputCtrl.dispose();
    _pageInputFocus.dispose();
    _activeSmallNotifier.dispose();
    _activePageNotifier.dispose();
    _loadingMoreNotifier.dispose();
    _pageBlocksNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;
      final results = await Future.wait<Object?>([
        DataManager.instance.loadTextbookMetadataPayload(
          bookId: widget.bookId,
          gradeLabel: widget.gradeLabel,
        ),
        DataManager.instance.loadTextbookProblemRegions(
          bookId: widget.bookId,
          gradeLabel: widget.gradeLabel,
        ),
        supa
            .from('textbook_subunit_workflows')
            .select(
              'big_order, mid_order, scope_key, confirmed_at, work_order',
            )
            .eq('academy_id', academyId)
            .eq('book_id', widget.bookId)
            .eq('grade_label', widget.gradeLabel)
            .not('confirmed_at', 'is', null),
      ]);

      final payloadRow = results[0] as Map<String, dynamic>?;
      final cropRows = (results[1] as List<Map<String, dynamic>>?) ??
          const <Map<String, dynamic>>[];
      final wfRows =
          results[2] is List ? results[2] as List : const <dynamic>[];

      final payload = payloadRow?['payload'] is Map
          ? Map<String, dynamic>.from(payloadRow!['payload'] as Map)
          : const <String, dynamic>{};

      final confirmedByKey = <String, _ConfirmedSubunitScope>{};
      if (payload['auto_analyzed_scopes'] is Map) {
        final rawAuto = payload['auto_analyzed_scopes'] as Map;
        for (final entry in rawAuto.entries) {
          final key = '${entry.key}'.trim();
          final val = '${entry.value ?? ''}'.trim();
          if (key.isEmpty || val.isEmpty) continue;
          final parts = key.split('/');
          if (parts.length < 3) continue;
          final big = int.tryParse(parts[0]);
          final mid = int.tryParse(parts[1]);
          final scopeKey = parts.sublist(2).join('/').trim();
          if (big == null || mid == null || scopeKey.isEmpty) continue;
          confirmedByKey['$big/$mid/$scopeKey'] = _ConfirmedSubunitScope(
            bigOrder: big,
            midOrder: mid,
            scopeKey: scopeKey,
          );
        }
      }

      for (final raw in wfRows) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        final big = _asInt(map['big_order']);
        final mid = _asInt(map['mid_order']);
        final scopeKey = '${map['scope_key'] ?? ''}'.trim();
        if (big == null || mid == null || scopeKey.isEmpty) continue;
        final wo = map['work_order'] is Map
          ? Map<String, dynamic>.from(map['work_order'] as Map)
          : const <String, dynamic>{};
        confirmedByKey['$big/$mid/$scopeKey'] = _ConfirmedSubunitScope(
          bigOrder: big,
          midOrder: mid,
          scopeKey: scopeKey,
          reviewSubKeys: [
            for (final k in (wo['review_sub_keys'] as List?) ?? const [])
              '$k'.trim(),
          ],
          indexedSubKeys: [
            for (final k in (wo['indexed_sub_keys'] as List?) ?? const [])
              '$k'.trim(),
          ],
          reviewSubIndex: _asInt(wo['review_sub_index']) ?? 0,
          rawPageFrom: _asInt(wo['raw_page_from']),
          rawPageTo: _asInt(wo['raw_page_to']),
        );
      }

      final units = _parseUnits(payload, confirmedByKey);
      final confirmedSmalls = <_UnitSmallNode>[];
      for (final big in units) {
        for (final mid in big.middles) {
          for (final small in mid.smalls) {
            _treeRowKeyByStateKey[small.stateKey] = GlobalKey();
            if (small.confirmed) confirmedSmalls.add(small);
          }
        }
      }

      if (!mounted) return;
      _activeSmallNotifier.value =
          confirmedSmalls.isNotEmpty ? confirmedSmalls.first : null;
      setState(() {
        _units = units;
        _confirmedSmalls = confirmedSmalls;
        _confirmedByKey = confirmedByKey;
        _cropRows = cropRows;
        _loading = false;
      });

      if (confirmedSmalls.isNotEmpty) {
        await _ensureLoadedUpTo(
          math.min(_initialSubunitBatch, confirmedSmalls.length),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '단원 정보를 불러오지 못했습니다.';
      });
    }
  }

  Future<void> _ensureLoadedUpTo(int targetCount) async {
    final clamped = targetCount.clamp(0, _confirmedSmalls.length);
    if (_loadingMoreNotifier.value || _loadedConfirmedCount >= clamped) return;

    _answersErrorOccurred = false;
    _loadingMoreNotifier.value = true;

    try {
      final toLoad = _confirmedSmalls
          .sublist(_loadedConfirmedCount, clamped)
          .where((s) => !_answersCache.containsKey(s.stateKey))
          .toList(growable: false);

      if (toLoad.isNotEmpty) {
        final cropIdsBySmall = <String, List<String>>{};
        final unionCropIds = <String>{};
        for (final small in toLoad) {
          final ids = <String>[];
          for (final row in _cropRows) {
            if (_rowBelongsToSmall(row, small)) {
              final id = '${row['id'] ?? ''}'.trim();
              if (id.isNotEmpty) {
                ids.add(id);
                unionCropIds.add(id);
              }
            }
          }
          cropIdsBySmall[small.stateKey] = ids;
        }

        final rowByCropId = <String, Map<String, dynamic>>{};
        if (unionCropIds.isNotEmpty) {
          final rows =
              await DataManager.instance.loadTextbookProblemRegionsForGrading(
            bookId: widget.bookId,
            gradeLabel: widget.gradeLabel,
            cropIds: unionCropIds,
          );
          for (final row in rows) {
            final id = '${row['id'] ?? ''}'.trim();
            if (id.isNotEmpty) rowByCropId[id] = row;
          }
        }

        final solutionByCrop = await _loadSolutions(unionCropIds);

        for (final small in toLoad) {
          final ids = cropIdsBySmall[small.stateKey] ?? const <String>[];
          final items = <_AnswerItemVm>[];
          for (final id in ids) {
            final row = rowByCropId[id];
            if (row == null || row['is_set_header'] == true) continue;
            final number = '${row['problem_number'] ?? ''}'.trim();
            if (number.isEmpty) continue;
            final displayPage =
                _asInt(row['display_page']) ?? _asInt(row['raw_page']) ?? 0;
            final kind = '${row['answer_kind'] ?? ''}'.trim().toLowerCase();
            final answerText = '${row['answer_text'] ?? ''}'.trim();
            final latex2d = '${row['answer_latex_2d'] ?? ''}'.trim();
            final imageUrl = '${row['answer_image_url'] ?? ''}'.trim();
            final String displayAnswer;
            if (kind == 'subjective' && latex2d.isNotEmpty) {
              displayAnswer = latex2d;
            } else if (answerText.isNotEmpty) {
              displayAnswer = answerText;
            } else if (latex2d.isNotEmpty) {
              displayAnswer = latex2d;
            } else {
              displayAnswer = '-';
            }

            final rawParts = _splitSetAnswerParts(displayAnswer);
            final precomputedParts = rawParts.length >= 2
                ? rawParts
                    .map(
                      (p) => (
                        label: p.label,
                        normalizedLines:
                            _normalizeAnswerLinesForDisplay(p.value),
                      ),
                    )
                    .toList(growable: false)
                : const <({String label, List<String> normalizedLines})>[];

            items.add(
              _AnswerItemVm(
                cropId: id,
                small: small,
                problemNumber: number,
                page: displayPage,
                answerKind: kind,
                answer: displayAnswer,
                normalizedLines: precomputedParts.isNotEmpty
                    ? const <String>[]
                    : _normalizeAnswerLinesForDisplay(displayAnswer),
                setParts: precomputedParts,
                imageUrl: imageUrl,
                solutionText: solutionByCrop[id] ?? '',
                orderKey: _orderKeyFromRow(row),
              ),
            );
          }
          items.sort(
            (a, b) => compareTextbookProblemSourceOrder(a.orderKey, b.orderKey),
          );
          _answersCache[small.stateKey] = items;
        }
      }

      if (!mounted) return;
      _loadedConfirmedCount = clamped;
      final nextBlocks = _rebuildPageBlocks();
      _pageBlocksNotifier.value = nextBlocks;
      if (_activePageNotifier.value == 0 && nextBlocks.isNotEmpty) {
        _activePageNotifier.value = nextBlocks.first.page;
        _activeSmallNotifier.value = nextBlocks.first.primarySmall;
      }
      _loadingMoreNotifier.value = false;
    } catch (_) {
      if (!mounted) return;
      _answersErrorOccurred = true;
      _loadingMoreNotifier.value = false;
    }
  }

  List<_PageBlockVm> _rebuildPageBlocks() {
    final prevBlocks = _pageBlocksNotifier.value;
    final prevById = <String, _PageBlockVm>{
      for (final b in prevBlocks) b.blockId: b,
    };
    final blocks = <_PageBlockVm>[];
    for (var i = 0; i < _loadedConfirmedCount; i += 1) {
      final small = _confirmedSmalls[i];
      final items = _answersCache[small.stateKey] ?? const <_AnswerItemVm>[];
      for (final item in items) {
        if (blocks.isNotEmpty && blocks.last.page == item.page) {
          blocks.last.items.add(item);
        } else {
          final blockId = '${small.stateKey}|p${item.page}|${blocks.length}';
          final prev = prevById[blockId];
          blocks.add(
            _PageBlockVm(
              blockId: blockId,
              page: item.page,
              primarySmall: small,
              items: <_AnswerItemVm>[item],
              anchorKey: prev?.anchorKey ?? GlobalKey(),
              measuredHeight: prev?.measuredHeight,
            ),
          );
        }
      }
    }
    return blocks;
  }

  void _handleAnswerScroll() {
    if (!_answerScrollCtrl.hasClients) return;
    final pos = _answerScrollCtrl.position;
    if (!_loadingMoreNotifier.value &&
        _loadedConfirmedCount < _confirmedSmalls.length &&
        pos.pixels >= pos.maxScrollExtent - _preloadScrollThreshold) {
      unawaited(
        _ensureLoadedUpTo(_loadedConfirmedCount + _moreSubunitBatch),
      );
    }
    if (!_programmaticScroll) {
      _syncActiveFromScrollOffset();
    }
  }

  void _syncActiveFromScrollOffset() {
    final blocks = _pageBlocksNotifier.value;
    if (blocks.isEmpty) return;
    final viewportBox =
        _answerViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final probeY = viewportTop + 88.0;

    _PageBlockVm? current;
    for (var i = 0; i < blocks.length; i += 1) {
      final block = blocks[i];
      final ctx = block.anchorKey.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy <= probeY) {
        current = block;
      } else {
        current ??= block;
        break;
      }
    }
    if (current == null) return;

    final nextSmall = _resolveSmallForPage(current.page, current.primarySmall);
    final prevSmallKey = _activeSmallNotifier.value?.stateKey;
    if (_activePageNotifier.value != current.page) {
      _activePageNotifier.value = current.page;
    }
    if (prevSmallKey != nextSmall.stateKey) {
      _activeSmallNotifier.value = nextSmall;
      _scrollTreeRowIntoViewIfNeeded(nextSmall.stateKey, forceCenter: false);
    }
  }

  _UnitSmallNode _resolveSmallForPage(int page, _UnitSmallNode fallback) {
    if (page <= 0) return fallback;
    for (final small in _confirmedSmalls) {
      final start = small.startPage;
      final end = small.endPage ?? start;
      if (start != null &&
          end != null &&
          start > 0 &&
          page >= start &&
          page <= end) {
        return small;
      }
    }
    return fallback;
  }

  void _scrollTreeRowIntoViewIfNeeded(
    String stateKey, {
    required bool forceCenter,
  }) {
    final ctx = _treeRowKeyByStateKey[stateKey]?.currentContext;
    if (ctx == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rowBox = ctx.findRenderObject() as RenderBox?;
      if (rowBox == null || !rowBox.attached || !rowBox.hasSize) return;

      if (!forceCenter) {
        final treeBox =
            _treeViewportKey.currentContext?.findRenderObject() as RenderBox?;
        if (treeBox != null && treeBox.hasSize) {
          final treeTop = treeBox.localToGlobal(Offset.zero).dy;
          final treeBottom = treeTop + treeBox.size.height;
          final rowTop = rowBox.localToGlobal(Offset.zero).dy;
          final rowBottom = rowTop + rowBox.size.height;
          if (rowTop >= treeTop + 44.0 && rowBottom <= treeBottom - 44.0) {
            return;
          }
        }
      }

      Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _jumpToSubunit(_UnitSmallNode small) async {
    if (!small.confirmed) return;
    final idx =
        _confirmedSmalls.indexWhere((s) => s.stateKey == small.stateKey);
    if (idx < 0) return;

    _activeSmallNotifier.value = small;
    if (_loadedConfirmedCount <= idx) {
      await _ensureLoadedUpTo(idx + 2);
    }
    if (!mounted) return;

    final blocks = _pageBlocksNotifier.value;
    var targetIndex = -1;
    for (var i = 0; i < blocks.length; i += 1) {
      if (blocks[i].items.any((it) => it.small.stateKey == small.stateKey)) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex >= 0) {
      await _scrollToPageBlockIndex(targetIndex, highlightSmall: small);
    }
  }

  Future<void> _jumpToPageInput() async {
    final raw = _pageInputCtrl.text.trim().replaceAll(_digitsCleanupRe, '');
    final targetPage = int.tryParse(raw);
    if (targetPage == null || targetPage <= 0) return;

    var blockIdx = _findPageBlockIndex(targetPage);
    if (blockIdx < 0 && _loadedConfirmedCount < _confirmedSmalls.length) {
      final ownerIdx = _confirmedSmalls.indexWhere((s) {
        final start = s.startPage;
        final end = s.endPage ?? start;
        if (start != null && end != null && start > 0) {
          return targetPage >= start && targetPage <= end;
        }
        return false;
      });
      if (ownerIdx >= 0) {
        await _ensureLoadedUpTo(ownerIdx + 2);
        blockIdx = _findPageBlockIndex(targetPage);
      }
      if (blockIdx < 0 && _loadedConfirmedCount < _confirmedSmalls.length) {
        await _ensureLoadedUpTo(_confirmedSmalls.length);
        blockIdx = _findPageBlockIndex(targetPage);
      }
    }

    if (!mounted) return;
    if (blockIdx < 0) {
      showAppSnackBar(context, '확정된 소단원에 p.$targetPage 정답이 없습니다.');
      return;
    }
    final block = _pageBlocksNotifier.value[blockIdx];
    final small = _resolveSmallForPage(targetPage, block.primarySmall);
    await _scrollToPageBlockIndex(blockIdx, highlightSmall: small);
    _scrollTreeRowIntoViewIfNeeded(small.stateKey, forceCenter: true);
  }

  int _findPageBlockIndex(int page) {
    final blocks = _pageBlocksNotifier.value;
    for (var i = 0; i < blocks.length; i += 1) {
      if (blocks[i].page == page) return i;
    }
    return -1;
  }

  double _estimatedBlockHeight(_PageBlockVm block, {required bool isFirst}) {
    final measured = block.measuredHeight;
    if (measured != null && measured > 0) return measured;
    final headerH = (isFirst ? 0.0 : 24.0) + 16.0 + 32.0;
    var cardsH = 0.0;
    for (var i = 0; i < block.items.length; i += 1) {
      if (i > 0) cardsH += 8.0;
      final item = block.items[i];
      final partsCount = item.setParts.length;
      if (partsCount >= 2) {
        cardsH += 24.0 + partsCount * 42.0;
      } else {
        final lineCount =
            item.normalizedLines.isEmpty ? 1 : item.normalizedLines.length;
        cardsH += 22.0 + lineCount * 40.0;
      }
    }
    return headerH + cardsH;
  }

  Future<void> _scrollToPageBlockIndex(
    int targetIndex, {
    required _UnitSmallNode highlightSmall,
  }) async {
    final initialBlocks = _pageBlocksNotifier.value;
    if (targetIndex < 0 || targetIndex >= initialBlocks.length) return;
    final targetBlock = initialBlocks[targetIndex];
    _activePageNotifier.value = targetBlock.page;
    _activeSmallNotifier.value = highlightSmall;

    _programmaticScroll = true;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_answerScrollCtrl.hasClients) return;

      var jumpedOffscreen = false;
      for (var attempt = 0; attempt < 6; attempt += 1) {
        if (!mounted || !_answerScrollCtrl.hasClients) return;
        final ctx = targetBlock.anchorKey.currentContext;
        if (ctx != null && ctx.findRenderObject() != null) {
          break;
        }
        jumpedOffscreen = true;
        final blocks = _pageBlocksNotifier.value;
        if (targetIndex >= blocks.length) break;

        final viewportBox =
            _answerViewportKey.currentContext?.findRenderObject() as RenderBox?;
        final viewportTop = viewportBox != null && viewportBox.hasSize
            ? viewportBox.localToGlobal(Offset.zero).dy
            : 0.0;

        int? nearestMountedIdx;
        double? nearestScrollOffset;
        for (var i = 0; i < blocks.length; i += 1) {
          final mCtx = blocks[i].anchorKey.currentContext;
          if (mCtx == null) continue;
          final box = mCtx.findRenderObject() as RenderBox?;
          if (box == null || !box.attached || !box.hasSize) continue;
          if (nearestMountedIdx == null ||
              (i - targetIndex).abs() <
                  (nearestMountedIdx - targetIndex).abs()) {
            nearestMountedIdx = i;
            final relDy = box.localToGlobal(Offset.zero).dy - viewportTop;
            nearestScrollOffset = _answerScrollCtrl.offset + relDy;
          }
        }

        double estOffset;
        if (nearestMountedIdx != null && nearestScrollOffset != null) {
          var delta = 0.0;
          if (targetIndex > nearestMountedIdx) {
            for (var i = nearestMountedIdx; i < targetIndex; i += 1) {
              delta += _estimatedBlockHeight(blocks[i], isFirst: i == 0);
            }
          } else {
            for (var i = targetIndex; i < nearestMountedIdx; i += 1) {
              delta -= _estimatedBlockHeight(blocks[i], isFirst: i == 0);
            }
          }
          estOffset = nearestScrollOffset + delta;
        } else {
          estOffset = 0.0;
          for (var i = 0; i < targetIndex; i += 1) {
            estOffset += _estimatedBlockHeight(blocks[i], isFirst: i == 0);
          }
        }

        final pos = _answerScrollCtrl.position;
        final clamped =
            estOffset.clamp(pos.minScrollExtent, pos.maxScrollExtent);
        _answerScrollCtrl.jumpTo(clamped);
        await WidgetsBinding.instance.endOfFrame;
      }

      if (!mounted) return;
      final finalCtx = targetBlock.anchorKey.currentContext;
      if (finalCtx != null && finalCtx.findRenderObject() != null) {
        await Scrollable.ensureVisible(
          finalCtx,
          alignment: 0.02,
          duration: Duration(milliseconds: jumpedOffscreen ? 120 : 200),
          curve: Curves.easeOutCubic,
        );
      }
    } finally {
      _programmaticScroll = false;
    }
  }

  List<_UnitBigNode> _parseUnits(
    Map<String, dynamic> payload,
    Map<String, _ConfirmedSubunitScope> confirmedByKey,
  ) {
    final unitsRaw = payload['units'];
    if (unitsRaw is! List) return const <_UnitBigNode>[];
    final bigMaps = unitsRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    bigMaps.sort(
      (a, b) => (_asInt(a['order_index']) ?? 0)
          .compareTo(_asInt(b['order_index']) ?? 0),
    );

    final out = <_UnitBigNode>[];
    for (var bi = 0; bi < bigMaps.length; bi += 1) {
      final b = bigMaps[bi];
      final bigOrder = _asInt(b['order_index']) ?? bi;
      final bigName = '${b['name'] ?? ''}'.trim();
      final midsRaw = b['middles'];
      final midNodes = <_UnitMidNode>[];
      if (midsRaw is List) {
        final midMaps = midsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        midMaps.sort(
          (a, b) => (_asInt(a['order_index']) ?? 0)
              .compareTo(_asInt(b['order_index']) ?? 0),
        );
        for (var mi = 0; mi < midMaps.length; mi += 1) {
          final m = midMaps[mi];
          final midOrder = _asInt(m['order_index']) ?? mi;
          final midName = '${m['name'] ?? ''}'.trim();
          final hasSubUnits = midHasSubUnits(m);
          final display = displaySubUnitsForMid(m);
          final smallNodes = <_UnitSmallNode>[];
          for (var si = 0; si < display.length; si += 1) {
            final d = display[si];
            final wfKey = hasSubUnits ? 'W$si' : d.subKey.trim();
            final stateKey = '$bigOrder/$midOrder/$wfKey';
            final altKey = '$bigOrder/$midOrder/${d.subKey.trim()}';
            final confirmedScope =
                confirmedByKey[stateKey] ?? confirmedByKey[altKey];
            smallNodes.add(
              _UnitSmallNode(
                stateKey: stateKey,
                bigOrder: bigOrder,
                bigName: bigName.isEmpty ? '대단원 ${bigOrder + 1}' : bigName,
                midOrder: midOrder,
                midName: midName.isEmpty ? '중단원 ${midOrder + 1}' : midName,
                smallOrder: d.order,
                subKey: d.subKey,
                wfScopeKey: wfKey,
                rowIndex: si,
                hasSubUnits: hasSubUnits,
                name: d.name,
                startPage: d.startPage,
                endPage: d.endPage,
                confirmed: confirmedScope != null,
                confirmedScope: confirmedScope,
              ),
            );
          }
          midNodes.add(
            _UnitMidNode(
              order: midOrder,
              name: midName.isEmpty ? '중단원 ${midOrder + 1}' : midName,
              smalls: smallNodes,
            ),
          );
        }
      }
      out.add(
        _UnitBigNode(
          order: bigOrder,
          name: bigName.isEmpty ? '대단원 ${bigOrder + 1}' : bigName,
          middles: midNodes,
        ),
      );
    }
    return out;
  }

  bool _rowBelongsToSmall(Map<String, dynamic> row, _UnitSmallNode small) {
    if (row['is_set_header'] == true) return false;
    final big = _asInt(row['big_order']);
    final mid = _asInt(row['mid_order']);
    if (big != small.bigOrder || mid != small.midOrder) return false;

    final subKey = '${row['sub_key'] ?? ''}'.trim();
    final subIndex = _asInt(row['sub_index']) ?? 0;
    final rawPage = _asInt(row['raw_page']) ?? 0;
    final displayPage = _asInt(row['display_page']) ?? rawPage;
    final scope = small.confirmedScope;

    if (scope != null &&
        (scope.reviewSubKeys.isNotEmpty ||
            scope.indexedSubKeys.isNotEmpty ||
            (scope.rawPageFrom != null && scope.rawPageTo != null))) {
      if (scope.reviewSubKeys.isNotEmpty &&
          !scope.reviewSubKeys.contains(subKey)) {
        return false;
      }
      if (scope.indexedSubKeys.contains(subKey)) {
        return subIndex == scope.reviewSubIndex;
      }
      if (scope.rawPageFrom != null && scope.rawPageTo != null) {
        return rawPage >= scope.rawPageFrom! && rawPage <= scope.rawPageTo!;
      }
      return true;
    }

    if (small.hasSubUnits) {
      final start = small.startPage;
      final end = small.endPage ?? start;
      if (start != null && end != null && start > 0 && end >= start) {
        return displayPage >= start && displayPage <= end;
      }
      return subIndex == small.rowIndex;
    }
    return subKey.toUpperCase() == small.subKey.trim().toUpperCase();
  }

  TextbookProblemSourceOrderKey _orderKeyFromRow(Map<String, dynamic> row) {
    final bbox = row['bbox_1k'] is List ? row['bbox_1k'] as List : const [];
    final region =
        row['item_region_1k'] is List ? row['item_region_1k'] as List : const [];
    final coords = region.length >= 4 ? region : bbox;
    final ymin = coords.isNotEmpty ? (_asDouble(coords[0]) ?? 0) / 1000.0 : 0.0;
    final xmin =
        coords.length > 1 ? (_asDouble(coords[1]) ?? 0) / 1000.0 : 0.0;
    return TextbookProblemSourceOrderKey(
      bigOrder: _asInt(row['big_order']) ?? 0,
      midOrder: _asInt(row['mid_order']) ?? 0,
      subIndex: _asInt(row['sub_index']) ?? 0,
      subKey: '${row['sub_key'] ?? ''}'.trim(),
      page: _asInt(row['display_page']) ?? _asInt(row['raw_page']) ?? 0,
      problemNumber: '${row['problem_number'] ?? ''}'.trim(),
      ymin: ymin,
      xmin: xmin,
      stableId: '${row['id'] ?? ''}'.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final confirmedCount = _confirmedByKey.length;
    final mediumStyle = TextStyle(
      color: dlg.textSub,
      fontSize: BottomDialogMetrics.mediumFontSize,
      fontWeight: FontWeight.w600,
    );
    return BottomDialog(
      center: true,
      preferredWidth: 1520,
      maxHeight: 980,
      icon: Icons.fact_check_outlined,
      title: '${widget.bookName} · ${widget.gradeLabel} 정답',
      onClose: () => Navigator.of(context).pop(),
      child: _loading
          ? const Center(child: YggLoadingIndicator(size: 24))
          : _error != null
              ? Center(
                  child: Text(
                    _error!,
                    style: mediumStyle,
                  ),
                )
              : ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        key: _treeViewportKey,
                        width: 460,
                        child: _buildUnitTreeColumn(
                          dlg,
                          confirmedCount: confirmedCount,
                        ),
                      ),
                      VerticalDivider(
                        width: 24,
                        thickness: 1,
                        color: dlg.divider,
                      ),
                      Expanded(
                        child: _buildAnswerListColumn(dlg),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildUnitTreeColumn(
    YggDialogColors dlg, {
    required int confirmedCount,
  }) {
    if (_units.isEmpty) {
      return Center(
        child: Text(
          '등록된 단원 정보가 없습니다.',
          style: TextStyle(
            color: dlg.textSub,
            fontSize: BottomDialogMetrics.mediumFontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _treeScrollCtrl,
      cacheExtent: 600,
      itemCount: _units.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              confirmedCount > 0
                  ? '확정된 소단원 $confirmedCount개 · 스크롤 위치에 따라 자동 하이라이트'
                  : '확정된 소단원이 아직 없습니다',
              style: TextStyle(
                color: dlg.textSub,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        final bi = index - 1;
        return Padding(
          padding: EdgeInsets.only(top: bi > 0 ? 12 : 0),
          child: RepaintBoundary(
            child: _buildBigGroup(dlg, _units[bi]),
          ),
        );
      },
    );
  }

  Widget _buildBigGroup(YggDialogColors dlg, _UnitBigNode big) {
    return Container(
      decoration: BoxDecoration(
        color: dlg.cardBg,
        borderRadius: BorderRadius.circular(BottomDialogMetrics.cardRadius),
        border: Border.all(color: dlg.cardBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LatexTextRenderer(
            '${big.order + 1}. ${big.name}',
            style: TextStyle(
              color: dlg.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          for (final mid in big.middles) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: LatexTextRenderer(
                '${mid.order + 1}) ${mid.name}',
                style: TextStyle(
                  color: dlg.textSub,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ),
            for (var si = 0; si < mid.smalls.length; si += 1) ...[
              if (si > 0) const SizedBox(height: 4),
              _SmallRowHighlightBuilder(
                key: _treeRowKeyByStateKey[mid.smalls[si].stateKey],
                activeSmallListenable: _activeSmallNotifier,
                small: mid.smalls[si],
                dlg: dlg,
                pageText: _pageRangeLabel(
                  mid.smalls[si].startPage,
                  mid.smalls[si].endPage,
                ),
                onTapConfirmed: () => unawaited(_jumpToSubunit(mid.smalls[si])),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildAnswerListColumn(YggDialogColors dlg) {
    final mediumStyle = TextStyle(
      color: dlg.textSub,
      fontSize: BottomDialogMetrics.mediumFontSize,
      fontWeight: FontWeight.w600,
    );
    if (_confirmedSmalls.isEmpty) {
      return Center(
        child: Text(
          '확정된 소단원이 아직 없습니다.',
          style: mediumStyle,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  _activeSmallNotifier,
                  _activePageNotifier,
                ]),
                builder: (context, _) {
                  final small =
                      _activeSmallNotifier.value ?? _confirmedSmalls.first;
                  final activePage = _activePageNotifier.value;
                  final pageRange =
                      _pageRangeLabel(small.startPage, small.endPage);
                  final headerMeta = [
                    small.midName,
                    if (activePage > 0) '현재 p.$activePage',
                    if (pageRange.isNotEmpty) '범위 $pageRange',
                  ].join(' · ');
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LatexTextRenderer(
                        small.name,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: dlg.text,
                          fontSize: BottomDialogMetrics.largeFontSize,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        headerMeta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: dlg.textSub,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            _buildPageJumpField(dlg),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          key: _answerViewportKey,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              _pageBlocksNotifier,
              _loadingMoreNotifier,
            ]),
            builder: (context, _) {
              final blocks = _pageBlocksNotifier.value;
              final loadingMore = _loadingMoreNotifier.value;
              if (blocks.isEmpty && loadingMore) {
                return const Center(child: YggLoadingIndicator());
              }
              if (blocks.isEmpty && _answersErrorOccurred) {
                return Center(
                  child: Text(
                    '정답 목록을 불러오지 못했습니다.',
                    style: mediumStyle,
                  ),
                );
              }
              if (blocks.isEmpty) {
                return Center(
                  child: Text(
                    '확정된 소단원에 연결된 정답이 없습니다.',
                    style: mediumStyle,
                  ),
                );
              }
              return ListView.builder(
                controller: _answerScrollCtrl,
                cacheExtent: 900,
                addAutomaticKeepAlives: false,
                itemCount: blocks.length + 1,
                itemBuilder: (context, index) {
                  if (index == blocks.length) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: _loadingMoreNotifier,
                      builder: (context, isLoading, _) {
                        if (!isLoading) return const SizedBox(height: 24);
                        return const Padding(
                          padding: EdgeInsets.only(top: 16, bottom: 24),
                          child: Center(
                            child: YggLoadingIndicator(size: 20),
                          ),
                        );
                      },
                    );
                  }
                  final block = blocks[index];
                  return RepaintBoundary(
                    key: ValueKey<String>(block.blockId),
                    child: _MeasureSize(
                      onPerformLayout: (size) {
                        block.measuredHeight = size.height;
                      },
                      child: _buildPageSection(
                        dlg,
                        block,
                        isFirst: index == 0,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPageJumpField(YggDialogColors dlg) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 112,
          height: 38,
          child: TextField(
            controller: _pageInputCtrl,
            focusNode: _pageInputFocus,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => unawaited(_jumpToPageInput()),
            style: TextStyle(
              color: dlg.text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            cursorColor: kDlgAccent,
            decoration: InputDecoration(
              hintText: '페이지 이동',
              hintStyle: TextStyle(
                color: dlg.textSub,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
              prefixText: 'p. ',
              prefixStyle: TextStyle(
                color: dlg.textSub,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
              isDense: true,
              filled: true,
              fillColor: dlg.fieldBg,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: dlg.cardBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: kDlgAccent, width: 1.3),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 38,
          child: Material(
            color: dlg.cardBg,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: () => unawaited(_jumpToPageInput()),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: dlg.cardBorder),
                ),
                alignment: Alignment.center,
                child: Text(
                  '이동',
                  style: TextStyle(
                    color: dlg.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPageSection(
    YggDialogColors dlg,
    _PageBlockVm block, {
    required bool isFirst,
  }) {
    return Column(
      key: block.anchorKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPageDividerLabel(dlg, block.page, isFirst: isFirst),
        for (var ii = 0; ii < block.items.length; ii += 1) ...[
          if (ii > 0) const SizedBox(height: 8),
          RepaintBoundary(
            child: _buildAnswerCard(dlg, block.items[ii]),
          ),
        ],
      ],
    );
  }

  /// 우측 채점 정답리스트와 같은 구획 방식(풀폭 가로선 + 오른쪽 페이지 번호).
  Widget _buildPageDividerLabel(
    YggDialogColors dlg,
    int pageNumber, {
    required bool isFirst,
  }) {
    return Padding(
      padding: EdgeInsets.only(
        top: isFirst ? 0 : 24,
        bottom: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColoredBox(
            color: dlg.divider,
            child: const SizedBox(height: 2),
          ),
          if (pageNumber > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 10, 0),
              child: Row(
                children: [
                  const Spacer(),
                  Text(
                    'p.$pageNumber',
                    style: TextStyle(
                      color: dlg.text,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 크롭별 확정 해설(문제은행 쪽 원본 해설). 검수 기록의 해설·AI 풀이는 확정 전 값이라 읽지 않는다.
  Future<Map<String, String>> _loadSolutions(Set<String> cropIds) async {
    final out = <String, String>{};
    if (cropIds.isEmpty) return out;
    try {
      final supa = Supabase.instance.client;
      final ids = cropIds.toList(growable: false);
      for (var i = 0; i < ids.length; i += 200) {
        final end = math.min(i + 200, ids.length);
        final rows = await supa
            .from('pb_question_solutions')
            .select('source_crop_id, body, version')
            .eq('kind', 'original')
            .inFilter('source_crop_id', ids.sublist(i, end))
            .order('version', ascending: false);
        for (final row in rows) {
          final id = '${row['source_crop_id'] ?? ''}'.trim();
          if (id.isEmpty || out.containsKey(id)) continue;
          out[id] = '${row['body'] ?? ''}'.trim();
        }
      }
    } catch (_) {}
    out.removeWhere((_, body) => body.isEmpty);
    return out;
  }

  Widget _buildSolutionButton(YggDialogColors dlg, _AnswerItemVm item) {
    final hasSolution = item.solutionText.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => unawaited(_openSolution(item)),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hasSolution
                  ? kDlgAccent.withValues(alpha: 0.14)
                  : dlg.fieldBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hasSolution
                    ? kDlgAccent.withValues(alpha: 0.55)
                    : dlg.cardBorder,
              ),
            ),
            child: Text(
              '해설',
              style: TextStyle(
                color: hasSolution ? kDlgAccent : dlg.textSub,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSolution(_AnswerItemVm item) async {
    if (!mounted) return;
    final text = item.solutionText.trim();
    final caption = text.isEmpty ? '' : '교재 해설';
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(
        alpha: BottomDialogMetrics.barrierOpacity,
      ),
      builder: (dialogContext) => BottomDialog(
        center: true,
        preferredWidth: 760,
        maxHeight: 860,
        icon: Icons.menu_book_outlined,
        title: '${item.problemNumber}번 해설',
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        onClose: () => Navigator.of(dialogContext).pop(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (caption.isNotEmpty) ...[
              Text(
                caption,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF4A4A4A),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
            ],
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: _solutionColumnWidth,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(dialogContext)
                        .copyWith(scrollbars: false),
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        text.isEmpty
                            ? const Text(
                                '등록된 해설이 없습니다.',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontFamily: LatexTextRenderer.v2TextFontFamily,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  height: 1.45,
                                ),
                              )
                            : LatexTextRenderer(
                                text,
                                dollarMath: true,
                                softWrap: true,
                                enableDisplayMath: true,
                                displayMathOverflow: DisplayMathOverflow.scaleDown,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontFamily: LatexTextRenderer.v2TextFontFamily,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w400,
                                  height: 1.45,
                                ),
                              ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerCard(YggDialogColors dlg, _AnswerItemVm item) {
    final parts = item.setParts;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: dlg.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: dlg.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                item.problemNumber,
                style: TextStyle(
                  color: dlg.text,
                  fontFamily: LatexTextRenderer.v2TextFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: item.answerKind == 'image' && item.imageUrl.isNotEmpty
                ? _ZoomableAnswerImage(
                    url: item.imageUrl,
                    problemNumber: item.problemNumber,
                    fallback: _buildMathAnswerLines(
                      dlg,
                      item.normalizedLines.isNotEmpty
                          ? item.normalizedLines
                          : _normalizeAnswerLinesForDisplay(item.answer),
                    ),
                  )
                : parts.length >= 2
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < parts.length; i += 1) ...[
                            if (i > 0) const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 38,
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      parts[i].label,
                                      style: TextStyle(
                                        color: dlg.textSub,
                                        fontFamily:
                                            LatexTextRenderer.v2TextFontFamily,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        height: 1.25,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: _buildMathAnswerLines(
                                    dlg,
                                    parts[i].normalizedLines,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      )
                    : _buildMathAnswerLines(dlg, item.normalizedLines),
          ),
          const SizedBox(width: 12),
          _buildSolutionButton(dlg, item),
        ],
      ),
    );
  }

  Widget _buildMathAnswerLines(YggDialogColors dlg, List<String> lines) {
    return ConfirmedAnswerMathLinesView(
      lines: lines,
      textColor: dlg.text,
      fontSize: 24,
    );
  }

  List<String> _normalizeAnswerLinesForDisplay(String raw) =>
      ConfirmedAnswerMathFormatter.normalizeAnswerLinesForDisplay(raw);

  List<({String label, String value})> _splitSetAnswerParts(String raw) =>
      ConfirmedAnswerMathFormatter.splitSetAnswerParts(raw);

  String _pageRangeLabel(int? start, int? end) {
    if (start == null || start <= 0) return '';
    if (end == null || end <= start) return 'p.$start';
    return 'p.$start~$end';
  }

  int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  double? _asDouble(dynamic v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }
}

/// 오른쪽 채점 정답리스트의 이미지 확대와 같은 뷰어.
/// 채점 상태가 없는 화면이라 정답·오답 버튼은 두지 않고 확대·이동만 제공한다.
class _ZoomableAnswerImage extends StatefulWidget {
  const _ZoomableAnswerImage({
    required this.url,
    required this.problemNumber,
    required this.fallback,
  });

  final String url;
  final String problemNumber;
  final Widget fallback;

  @override
  State<_ZoomableAnswerImage> createState() => _ZoomableAnswerImageState();
}

class _ZoomableAnswerImageState extends State<_ZoomableAnswerImage> {
  bool _failed = false;

  Future<void> _openZoom() async {
    final url = widget.url.trim();
    if (url.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(
        alpha: BottomDialogMetrics.barrierOpacity,
      ),
      builder: (dialogContext) => Center(
        child: _ConfirmedAnswerImageZoomDialog(
          title: '${widget.problemNumber}번 이미지 정답',
          url: url,
          onClose: () => Navigator.of(dialogContext).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_openZoom()),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image(
              image: AnswerRenderImageProvider(widget.url),
              height: 60,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, __, ___) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && !_failed) setState(() => _failed = true);
                });
                return const SizedBox(height: 60);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfirmedAnswerImageZoomDialog extends StatefulWidget {
  const _ConfirmedAnswerImageZoomDialog({
    required this.title,
    required this.url,
    required this.onClose,
  });

  final String title;
  final String url;
  final VoidCallback onClose;

  @override
  State<_ConfirmedAnswerImageZoomDialog> createState() =>
      _ConfirmedAnswerImageZoomDialogState();
}

class _ConfirmedAnswerImageZoomDialogState
    extends State<_ConfirmedAnswerImageZoomDialog> {
  static const double _initialScale = 2.0;
  static const double _dialogWidth = 720;
  static const double _dialogHeight = 680;

  late final TransformationController _controller;
  bool _didSetInitialTransform = false;

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setInitialCenteredTransform(BoxConstraints constraints) {
    if (_didSetInitialTransform) return;
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    _didSetInitialTransform = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.value = Matrix4.identity()
        ..translate(
          width * (1 - _initialScale) / 2,
          height * (1 - _initialScale) / 2,
        )
        ..scale(_initialScale);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final width = math.min(_dialogWidth, media.width - 48);
    final height = math.min(_dialogHeight, media.height - 48);
    final imageBg = FabTabBarTokens.previewAcademyInfoPanelFor(
      Theme.of(context).brightness,
    );
    return SizedBox(
      width: width,
      height: height,
      child: UtilityGlassDialogShell(
        title: widget.title,
        icon: Icons.image_outlined,
        preferredWidth: width,
        maxHeight: height,
        onClose: widget.onClose,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ColoredBox(
                    color: imageBg,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        _setInitialCenteredTransform(constraints);
                        return InteractiveViewer(
                          transformationController: _controller,
                          boundaryMargin: const EdgeInsets.all(320),
                          minScale: 0.8,
                          maxScale: 8,
                          child: Center(
                            child: Image(
                              image: AnswerRenderImageProvider(widget.url),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 선택 상태가 실제로 바뀐 소단원 행만 리빌드한다.
class _SmallRowHighlightBuilder extends StatefulWidget {
  const _SmallRowHighlightBuilder({
    super.key,
    required this.activeSmallListenable,
    required this.small,
    required this.dlg,
    required this.pageText,
    required this.onTapConfirmed,
  });

  final ValueNotifier<_UnitSmallNode?> activeSmallListenable;
  final _UnitSmallNode small;
  final YggDialogColors dlg;
  final String pageText;
  final VoidCallback onTapConfirmed;

  @override
  State<_SmallRowHighlightBuilder> createState() =>
      _SmallRowHighlightBuilderState();
}

class _SmallRowHighlightBuilderState extends State<_SmallRowHighlightBuilder> {
  late bool _selected;

  @override
  void initState() {
    super.initState();
    _selected =
        widget.activeSmallListenable.value?.stateKey == widget.small.stateKey;
    widget.activeSmallListenable.addListener(_onActiveChanged);
  }

  @override
  void didUpdateWidget(covariant _SmallRowHighlightBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeSmallListenable != widget.activeSmallListenable) {
      oldWidget.activeSmallListenable.removeListener(_onActiveChanged);
      widget.activeSmallListenable.addListener(_onActiveChanged);
    }
    _selected =
        widget.activeSmallListenable.value?.stateKey == widget.small.stateKey;
  }

  @override
  void dispose() {
    widget.activeSmallListenable.removeListener(_onActiveChanged);
    super.dispose();
  }

  void _onActiveChanged() {
    final nextSelected =
        widget.activeSmallListenable.value?.stateKey == widget.small.stateKey;
    if (nextSelected != _selected) {
      setState(() => _selected = nextSelected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dlg = widget.dlg;
    final small = widget.small;
    final enabled = small.confirmed;
    final selected = _selected;
    return Container(
      decoration: BoxDecoration(
        color: selected
            ? kDlgAccent.withValues(alpha: 0.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: selected
            ? Border.all(color: kDlgAccent.withValues(alpha: 0.65))
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: enabled ? widget.onTapConfirmed : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  enabled ? Icons.verified_rounded : Icons.lock_outline_rounded,
                  size: 16,
                  color: enabled
                      ? (selected ? kDlgAccent : dlg.text)
                      : dlg.textSub.withValues(alpha: 0.45),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LatexTextRenderer(
                    small.name,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled
                          ? dlg.text
                          : dlg.textSub.withValues(alpha: 0.45),
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
                if (widget.pageText.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    widget.pageText,
                    style: TextStyle(
                      color: enabled
                          ? (selected ? kDlgAccent : dlg.textSub)
                          : dlg.textSub.withValues(alpha: 0.40),
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: enabled
                        ? kDlgAccent.withValues(alpha: 0.18)
                        : dlg.fieldBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: enabled
                          ? kDlgAccent.withValues(alpha: 0.55)
                          : dlg.divider,
                    ),
                  ),
                  child: Text(
                    enabled ? '확정' : '미확정',
                    style: TextStyle(
                      color: enabled
                          ? kDlgAccent
                          : dlg.textSub.withValues(alpha: 0.55),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
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

class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({
    required this.onPerformLayout,
    required super.child,
  });

  final ValueChanged<Size> onPerformLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onPerformLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasureSize renderObject,
  ) {
    renderObject.onPerformLayout = onPerformLayout;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onPerformLayout);

  ValueChanged<Size> onPerformLayout;

  @override
  void performLayout() {
    super.performLayout();
    onPerformLayout(size);
  }
}

class _ConfirmedSubunitScope {
  const _ConfirmedSubunitScope({
    required this.bigOrder,
    required this.midOrder,
    required this.scopeKey,
    this.reviewSubKeys = const <String>[],
    this.indexedSubKeys = const <String>[],
    this.reviewSubIndex = 0,
    this.rawPageFrom,
    this.rawPageTo,
  });

  final int bigOrder;
  final int midOrder;
  final String scopeKey;
  final List<String> reviewSubKeys;
  final List<String> indexedSubKeys;
  final int reviewSubIndex;
  final int? rawPageFrom;
  final int? rawPageTo;
}

class _UnitBigNode {
  const _UnitBigNode({
    required this.order,
    required this.name,
    required this.middles,
  });

  final int order;
  final String name;
  final List<_UnitMidNode> middles;
}

class _UnitMidNode {
  const _UnitMidNode({
    required this.order,
    required this.name,
    required this.smalls,
  });

  final int order;
  final String name;
  final List<_UnitSmallNode> smalls;
}

class _UnitSmallNode {
  const _UnitSmallNode({
    required this.stateKey,
    required this.bigOrder,
    required this.bigName,
    required this.midOrder,
    required this.midName,
    required this.smallOrder,
    required this.subKey,
    required this.wfScopeKey,
    required this.rowIndex,
    required this.hasSubUnits,
    required this.name,
    required this.startPage,
    required this.endPage,
    required this.confirmed,
    required this.confirmedScope,
  });

  final String stateKey;
  final int bigOrder;
  final String bigName;
  final int midOrder;
  final String midName;
  final int smallOrder;
  final String subKey;
  final String wfScopeKey;
  final int rowIndex;
  final bool hasSubUnits;
  final String name;
  final int? startPage;
  final int? endPage;
  final bool confirmed;
  final _ConfirmedSubunitScope? confirmedScope;
}

class _AnswerItemVm {
  const _AnswerItemVm({
    required this.cropId,
    required this.small,
    required this.problemNumber,
    required this.page,
    required this.answerKind,
    required this.answer,
    required this.normalizedLines,
    required this.setParts,
    required this.imageUrl,
    required this.solutionText,
    required this.orderKey,
  });

  final String cropId;
  final _UnitSmallNode small;
  final String problemNumber;
  final int page;
  final String answerKind;
  final String answer;
  final List<String> normalizedLines;
  final List<({String label, List<String> normalizedLines})> setParts;
  final String imageUrl;
  final String solutionText;
  final TextbookProblemSourceOrderKey orderKey;
}

class _PageBlockVm {
  _PageBlockVm({
    required this.blockId,
    required this.page,
    required this.primarySmall,
    required this.items,
    required this.anchorKey,
    this.measuredHeight,
  });

  final String blockId;
  final int page;
  final _UnitSmallNode primarySmall;
  final List<_AnswerItemVm> items;
  final GlobalKey anchorKey;
  double? measuredHeight;
}
