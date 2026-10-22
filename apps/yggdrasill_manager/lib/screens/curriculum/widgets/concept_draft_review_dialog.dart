import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_draft_compare.dart';
import '../../../services/concept_draft_models.dart';
import '../../../services/concept_draft_service.dart';
import '../../../services/concept_relation_service.dart';
import '../../../services/think/think_action_models.dart';
import '../../../services/think/think_api.dart';
import '../../../services/think/think_concept_chat_controller.dart';
import '../../../services/think/think_controller.dart';
import '../../../widgets/latex_text_renderer.dart';
import '../../think/think_action_cards.dart';
import '../../think/think_style.dart';
import 'concept_chat_panel.dart';
import 'concept_relation_section.dart';
import 'concept_workspace.dart';

/// 개념 초안 검토. 확정하면 true(라이브러리에 폴더·개념·출처가 들어갔다).
Future<bool> showConceptDraftReviewDialog(
  BuildContext context, {
  required String draftId,
  ConceptDraftService? service,
  ConceptChatController? chat,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ConceptDraftReviewDialog(draftId: draftId, service: service, chat: chat),
  );
  return ok == true;
}

/// AI가 만든 개념 초안과 폴더 제안을 보고 고친 뒤 확정한다. 검토는 저장한 것만 남고, 확정은 저장된 검토로만 한다.
/// AI 결과(초안·근거 블록·검사)는 바꾸지 않는다. 출처 쪽은 근거 블록의 쪽에서만 붙는다(추정하지 않는다).
/// 오른쪽 Think 대화는 저장된 초안을 읽고, 바꾸자는 내용은 카드로 낸다. 승인해야 저장된 검토에 반영된다.
class ConceptDraftReviewDialog extends StatefulWidget {
  const ConceptDraftReviewDialog({super.key, required this.draftId, this.service, this.chat});

  final String draftId;
  final ConceptDraftService? service;

  /// 없으면 [ConceptChatController.draftReview].
  final ConceptChatController? chat;

  @override
  State<ConceptDraftReviewDialog> createState() => _ConceptDraftReviewDialogState();
}

class _ConceptDraftReviewDialogState extends State<ConceptDraftReviewDialog> {
  late final ConceptDraftService _svc = widget.service ?? ConceptDraftService();
  ConceptChatController get _chat => widget.chat ?? ConceptChatController.draftReview;
  final ScrollController _leftScroll = ScrollController();
  final ScrollController _cardScroll = ScrollController();

  /// 다시 정리하면 새 초안으로 바뀐다.
  late String _draftId = widget.draftId;
  bool _chatOpen = true;

  ConceptDraftRecord? _record;
  String? _loadError;
  List<ReviewItem> _items = const [];
  List<ReviewItem> _saved = const [];
  List<ReviewNewType> _newTypes = const [];
  List<ReviewNewType> _savedNewTypes = const [];
  List<ConceptTypeInfo> _types = const [];
  String? _savedAt;
  List<List<String>> _libraryPaths = const [];
  Map<String, List<ConceptPick>>? _sameNamed;

  final Map<String, TextEditingController> _titles = {};
  final Map<String, TextEditingController> _contents = {};
  final Set<String> _editing = {};
  final Set<String> _evidence = {};

  Map<int, ConceptPageImage>? _images;
  bool _imagesLoading = false;
  String? _imagesError;

  bool _busy = false;
  String? _notice;
  bool _noticeError = false;

  /// 비교할 기존 개념(읽기 전용, 개념 id → 내용). 관계에서 고른 개념을 열 때 읽는다.
  final Map<String, ConceptCompareTarget> _targets = {};
  final Set<String> _targetsLoading = {};
  final Map<String, String> _targetErrors = {};

  /// 비교 칸을 연 항목 key.
  final Set<String> _comparing = {};

  /// AI 비교 제안(저장하지 않는다). 반영한 줄은 검토 관계로 들어가고 여기서 빠진다.
  ConceptCompareProposal? _proposal;
  bool _proposing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _leftScroll.dispose();
    _cardScroll.dispose();
    for (final c in [..._titles.values, ..._contents.values]) {
      c.dispose();
    }
    // 창을 닫으면 그 초안으로는 보내지 않는다(대화는 남아 다음 초안에서 잇는다).
    _chat.setDraft(null);
    super.dispose();
  }

  /// [quiet]: 화면을 비우지 않고 다시 읽는다(승인 뒤).
  Future<void> _load({bool quiet = false}) async {
    setState(() {
      _loadError = null;
      if (!quiet) _record = null;
    });
    try {
      final results = await Future.wait([_svc.fetchDraft(_draftId), _svc.libraryFolderPaths(), _svc.conceptTypes()]);
      final r = results[0] as ConceptDraftRecord;
      if (!mounted) return;
      final items = initialReview(r);
      final newTypes = initialNewTypes(r);
      for (final c in [..._titles.values, ..._contents.values]) {
        c.dispose();
      }
      _titles.clear();
      _contents.clear();
      for (final it in items) {
        _titles[it.key] = TextEditingController(text: it.title);
        _contents[it.key] = TextEditingController(text: it.content);
      }
      final keys = {for (final it in items) it.key};
      _editing.retainWhere(keys.contains);
      _evidence.retainWhere(keys.contains);
      _comparing.retainWhere(keys.contains);
      if (_record?.id != r.id) {
        _images = null;
        _proposal = null;
      }
      _chat.setDraft(r.id, open: r.isOpen);
      setState(() {
        _record = r;
        _libraryPaths = results[1] as List<List<String>>;
        _types = results[2] as List<ConceptTypeInfo>;
        _items = items;
        _newTypes = newTypes;
        _saved = r.review.isEmpty ? const [] : r.review;
        _savedNewTypes = r.review.isEmpty ? const [] : r.reviewNewTypes;
        _savedAt = r.reviewSavedAt;
      });
      if (r.isOpen) unawaited(_loadSameNames());
    } catch (e) {
      if (mounted) setState(() => _loadError = '초안을 읽지 못했습니다: $e');
    }
  }

  bool get _dirty => !sameReview(_items, _saved, _newTypes, _savedNewTypes);

  /// 남긴 항목 이름과 같은 라이브러리 개념. 읽지 못하면 null(확정 RPC가 다시 본다).
  Future<Map<String, List<ConceptPick>>?> _lookupNames(Iterable<ReviewItem> items) async {
    try {
      return await _svc.libraryConceptsNamed([
        for (final it in items)
          if (it.kept) it.title,
      ]);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSameNames() async {
    final found = await _lookupNames(_items);
    if (mounted) setState(() => _sameNamed = found);
  }

  Future<void> _pickRelationTarget(ReviewItem it, ReviewRelationKind kind) async {
    final pick = await showConceptPickDialog(
      context,
      search: _svc.searchLibraryConcepts,
      title: '${kind.label}: 기존 개념 고르기',
      initialQuery: it.title.trim(),
      hint: switch (kind) {
        ReviewRelationKind.statement => '고른 개념에 이 항목을 확정 전 서술로 더합니다. 기존 확정 내용·본문은 그대로입니다.',
        ReviewRelationKind.source => '고른 개념의 서술에 이 교재 쪽을 출처로만 잇습니다. 새 글은 넣지 않습니다.',
        ReviewRelationKind.revise => '고른 개념의 기본 서술 수정안으로 저장합니다. 본문은 그 개념 창에서 확정해야 바뀝니다.',
        _ => '라이브러리에 있는 개념만 고를 수 있습니다.',
      },
    );
    if (pick == null || !mounted) return;
    _update(
        it.key, (x) => x.copyWith(relation: ReviewRelation(kind: kind, conceptId: pick.id, conceptName: pick.label)));
    unawaited(_loadTarget(pick.id));
  }

  /// 비교할 기존 개념을 읽는다. 이미 읽었으면 [force] 일 때만 다시 읽는다.
  Future<void> _loadTarget(String id, {bool force = false}) async {
    if (_targetsLoading.contains(id) || (!force && _targets.containsKey(id))) return;
    setState(() {
      _targetsLoading.add(id);
      _targetErrors.remove(id);
    });
    try {
      final found = await _svc.compareTargets([id]);
      if (!mounted) return;
      setState(() {
        for (final t in found) {
          _targets[t.id] = t;
        }
        if (found.isEmpty) _targetErrors[id] = '그 개념을 찾지 못했습니다(지워졌을 수 있습니다).';
      });
    } catch (e) {
      if (mounted) setState(() => _targetErrors[id] = '기존 개념을 읽지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _targetsLoading.remove(id));
    }
  }

  void _setSourceStatement(ReviewItem it, String? statementId) {
    final rel = it.relation;
    if (rel == null || rel.kind != ReviewRelationKind.source) return;
    final st = _targets[rel.conceptId]?.statement(statementId);
    _update(
      it.key,
      (x) => x.copyWith(
        relation: ReviewRelation(
          kind: rel.kind,
          conceptId: rel.conceptId,
          conceptName: rel.conceptName,
          statementId: statementId,
          statementLabel: statementId == null ? null : st?.label,
        ),
      ),
    );
  }

  /// 저장된 검토를 기존 개념과 비교한 AI 제안을 받는다. 서버가 저장된 검토를 읽으므로 먼저 저장해야 한다.
  Future<void> _proposeCompare() async {
    final r = _record;
    if (r == null || _proposing) return;
    if (_dirty || _savedAt == null) {
      setState(() {
        _notice = '비교 제안은 저장된 검토로 받습니다. 먼저 "검토 저장"을 누르세요.';
        _noticeError = true;
      });
      return;
    }
    setState(() {
      _proposing = true;
      _notice = null;
    });
    try {
      final p = await _svc.proposeCompare(r.id);
      if (!mounted) return;
      setState(() {
        _proposal = p;
        _notice = p.notice;
        _noticeError = false;
      });
      final ids = {
        for (final s in p.items.values)
          if (s.conceptId != null) s.conceptId!
      };
      for (final id in ids) {
        unawaited(_loadTarget(id));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _notice = '비교 제안을 받지 못했습니다: $e';
          _noticeError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _proposing = false);
    }
  }

  void _applySuggestion(ReviewItem it, ConceptCompareSuggestion s) {
    if (!s.applicable) return;
    final label = _targets[s.conceptId]?.statement(s.statementId)?.label;
    _update(it.key, (x) => x.copyWith(relation: s.relation(statementLabel: label)));
    setState(() => _proposal = _proposal?.without(it.key));
    if (s.conceptId != null) unawaited(_loadTarget(s.conceptId!));
  }

  void _dismissSuggestion(ReviewItem it) => setState(() => _proposal = _proposal?.without(it.key));

  void _setRelationKind(ReviewItem it, ReviewRelationKind? kind) {
    if (kind == null) {
      _update(it.key, (x) => x.copyWith(clearRelation: true));
      return;
    }
    final prev = it.relation;
    final keep = kind.takesTarget && prev?.conceptId != null;
    _update(
      it.key,
      (x) => x.copyWith(
        relation: ReviewRelation(
          kind: kind,
          conceptId: keep ? prev!.conceptId : null,
          conceptName: keep ? prev!.conceptName : null,
        ),
      ),
    );
    if (kind.needsTarget && !keep) unawaited(_pickRelationTarget(it, kind));
    if (keep) unawaited(_loadTarget(prev!.conceptId!));
  }

  void _decideType(String name, bool accept) {
    final r = _record;
    if (r == null) return;
    final next = decideNewType(r, _items, _newTypes, name, accept);
    setState(() {
      _items = next.items;
      _newTypes = next.newTypes;
      _notice = null;
    });
  }

  List<String> get _roots {
    final plan = _record?.folderPlan?.roots ?? const <String>[];
    if (plan.isNotEmpty) return plan;
    return [
      for (final p in _libraryPaths)
        if (p.length == 1) p.first
    ];
  }

  Set<String> get _libraryKeys => {for (final p in _libraryPaths) p.join('\u0000')};

  void _update(String key, ReviewItem Function(ReviewItem) change) {
    setState(() {
      _items = [for (final it in _items) it.key == key ? change(it) : it];
      _notice = null;
    });
  }

  void _textChanged(String key) {
    _update(key, (it) {
      final title = _titles[key]!.text;
      final content = _contents[key]!.text;
      final mark = it.mark == ReviewMark.keep ? ReviewMark.edit : it.mark;
      return it.copyWith(title: title, content: content, mark: mark);
    });
  }

  Future<void> _loadImages() async {
    final r = _record;
    if (r == null || _imagesLoading) return;
    setState(() {
      _imagesLoading = true;
      _imagesError = null;
    });
    try {
      final images = await _svc.pageImages(r);
      if (mounted) setState(() => _images = images);
    } catch (e) {
      if (mounted) setState(() => _imagesError = '쪽 이미지를 만들지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _imagesLoading = false);
    }
  }

  Future<bool> _save({bool quiet = false}) async {
    final r = _record;
    if (r == null) return false;
    setState(() => _busy = true);
    try {
      final at = await _svc.saveReview(r.id, _items, _savedAt, newTypes: _newTypes);
      if (!mounted) return false;
      setState(() {
        _savedAt = at;
        _saved = _items;
        _savedNewTypes = _newTypes;
        _busy = false;
        if (!quiet) {
          _notice = '검토를 저장했습니다. 라이브러리에는 아직 넣지 않았습니다.';
          _noticeError = false;
        }
      });
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _busy = false;
        _notice = '저장하지 못했습니다: $e';
        _noticeError = true;
      });
      return false;
    }
  }

  Future<void> _confirm() async {
    final r = _record;
    if (r == null) return;
    final problem = reviewProblem(_items, _roots, types: _types, newTypes: _newTypes);
    if (problem != null) {
      setState(() {
        _notice = problem;
        _noticeError = true;
      });
      return;
    }
    final kept = _items.where((it) => it.kept).toList();
    final keys = _libraryKeys;
    final fresh = [
      for (final p in reviewFolderPaths(kept))
        if (p.length >= 2 && !keys.contains(p.join('\u0000'))) p.join(' > '),
    ];
    final pages = <int>{
      for (final it in kept)
        if (!it.held) ...r.sourcePagesFor(it)
    };
    final noSource = [
      for (final it in kept)
        if (!it.held && r.sourcePagesFor(it).isEmpty) it.title.trim()
    ];
    final addedTypes = [
      for (final t in _newTypes)
        if (t.accept == true) '· ${t.name} (기존 구분 ${t.legacySubType})'
    ];
    setState(() => _busy = true);
    final named = await _lookupNames(kept);
    final ready = kept.any((it) => it.relation != null) ? await _svc.relationsReady() : true;
    final compareReady = needsCompareMigration(kept) ? await _svc.compareReady() : true;
    final revising = {
      for (final it in kept)
        if (it.relation?.kind == ReviewRelationKind.revise && it.relation?.conceptId != null) it.relation!.conceptId!
    };
    List<ConceptCompareTarget>? revised;
    if (ready && compareReady && revising.isNotEmpty) {
      try {
        revised = await _svc.compareTargets(revising.toList());
      } catch (_) {
        revised = null;
      }
    }
    if (!mounted) return;
    final blockedRevise = [
      for (final t in revised ?? const <ConceptCompareTarget>[])
        if (t.contentDraft) t.name
    ];
    setState(() {
      _busy = false;
      if (named != null) _sameNamed = named;
      for (final t in revised ?? const <ConceptCompareTarget>[]) {
        _targets[t.id] = t;
      }
      if (!ready) {
        _notice = kConceptRelationsNotReady;
        _noticeError = true;
      } else if (!compareReady) {
        _notice = kConceptCompareNotReady;
        _noticeError = true;
      } else if (blockedRevise.isNotEmpty) {
        _notice = '수정안으로 둔 기존 개념에 이미 저장된 수정안이 있습니다: ${blockedRevise.join(', ')}. '
            '그 개념 창에서 기존 수정안을 먼저 확정하거나 버린 뒤 확정하세요(덮어쓰지 않습니다).';
        _noticeError = true;
      }
    });
    if (!ready || !compareReady || blockedRevise.isNotEmpty) return;
    final relations = reviewRelationSummary(r, _items, libraryNames: named?.keys.toSet());
    final relationText = reviewRelationSentence(relations);
    final statements = relations.count(ReviewRelationKind.statement);
    final attached = kept.where((it) => it.noNewConcept).length;
    final ok = await confirmThink(
      context,
      title: '라이브러리에 넣을까요?',
      message: [
        attached == 0
            ? '개념 ${kept.length}개를 넣습니다(뺀 것 ${_items.length - kept.length}개).'
            : attached == statements
                ? '새 개념 ${kept.length - statements}개를 넣고 기존 개념에 서술 $statements개를 더합니다(뺀 것 ${_items.length - kept.length}개).'
                : '새 개념 ${kept.length - attached}개를 넣고, $attached개는 새 개념 없이 기존 개념에 붙이거나 보류합니다'
                    '(뺀 것 ${_items.length - kept.length}개).',
        fresh.isEmpty ? '새로 만드는 폴더는 없습니다.' : '새로 만드는 폴더 ${fresh.length}개:\n${fresh.map((p) => '· $p').join('\n')}',
        if (addedTypes.isNotEmpty) '유형 목록에 더하는 새 유형 ${addedTypes.length}개:\n${addedTypes.join('\n')}',
        '출처: ${r.bookName} ${r.gradeLabel} ${pages.length}개 쪽(근거 블록의 쪽).',
        if (noSource.isNotEmpty) '근거 블록이 없어 출처 없이 들어가는 개념: ${noSource.join(', ')}',
        if (relationText != null) relationText,
        '같은 이름의 폴더가 이미 있으면 그 폴더에 넣습니다. 기존 개념의 확정 내용·본문·폴더는 바꾸지 않습니다.',
      ].join('\n\n'),
      confirmLabel: '확정',
    );
    if (!ok || !mounted) return;
    if (_dirty || _savedAt == null) {
      if (!await _save(quiet: true)) return;
    }
    setState(() => _busy = true);
    try {
      await _svc.confirm(r.id, _savedAt!);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = '확정하지 못했습니다: $e';
        _noticeError = true;
      });
    }
  }

  Future<void> _discard() async {
    final r = _record;
    if (r == null) return;
    final ok = await confirmThink(
      context,
      title: '초안을 버릴까요?',
      message: '이 초안과 검토 내용은 목록에서 사라지고 라이브러리에는 아무것도 들어가지 않습니다. 쪽 전사는 남아 다시 만들 때 씁니다.',
      confirmLabel: '버리기',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await _svc.discard(r.id, _savedAt);
      if (mounted) Navigator.pop(context, false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = '버리지 못했습니다: $e';
        _noticeError = true;
      });
    }
  }

  Future<void> _close() async {
    if (_dirty && _record?.isOpen == true) {
      final ok = await confirmThink(
        context,
        title: '저장하지 않은 편집이 있습니다',
        message: '닫으면 저장하지 않은 편집은 사라집니다.',
        confirmLabel: '닫기',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    Navigator.pop(context, false);
  }

  Future<void> _renameFolder(List<String> path) async {
    final name = await promptThinkText(context, title: '폴더 이름 바꾸기', initial: path.last, confirmLabel: '바꾸기');
    if (name == null || name.trim().isEmpty || !mounted) return;
    setState(() => _items = renameReviewFolder(_items, path, name));
  }

  Future<void> _pickFolder(ReviewItem it) async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _FolderPickerDialog(
        current: it.folder,
        roots: _roots,
        libraryPaths: _libraryPaths,
        reviewPaths: reviewFolderPaths(_items),
      ),
    );
    if (picked == null || !mounted) return;
    _update(it.key, (x) => x.copyWith(folder: picked));
  }

  // ------------------------------------------------------------------ Think 대화
  /// 보내기·승인 전에 저장하지 않은 검토를 먼저 저장한다. 서버는 저장된 검토만 읽는다.
  Future<bool> _ensureSaved() async {
    final r = _record;
    if (r == null || _busy) return false;
    if (!r.isOpen || (!_dirty && _savedAt != null)) return true;
    return _save(quiet: true);
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = text;
      _noticeError = error;
    });
  }

  Future<void> _approveAction(ThinkAction a) async {
    final r = _record;
    if (r == null || a.payload['draft_id']?.toString() != r.id) return;
    if (_busy) return _say('검토 창이 다른 일을 하는 중입니다. 끝난 뒤 다시 승인하세요.', error: true);
    final change = a.kind == ThinkActionKind.conceptDraftChange;
    if (change && !await _ensureSaved()) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ThinkController.instance.applyConceptDraftAction(a);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _say('승인하지 못했습니다: ${ThinkApi.codeErrorMessage(e)}', error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (change) await _load(quiet: true);
    _say(change
        ? 'Think 제안을 검토에 반영하고 저장했습니다. 라이브러리에는 아직 넣지 않았습니다.'
        : '기준 초안으로 저장했습니다. 확정은 정리 기준 화면에서 하고, 다시 정리하면 이 초안도 씁니다.');
  }

  Future<void> _rerunAction(ThinkAction a) async {
    final r = _record;
    if (r == null || !r.isOpen || a.payload['draft_id']?.toString() != r.id) return;
    if (_busy) return _say('검토 창이 다른 일을 하는 중입니다. 끝난 뒤 다시 승인하세요.', error: true);
    final ok = await confirmThink(
      context,
      title: '같은 쪽을 다시 정리할까요?',
      message: [
        '저장된 전사로 같은 쪽의 새 초안을 만듭니다(AI 비용 약 \$0.09, 보통 1~5분). 쪽을 다시 읽지는 않습니다.',
        '지금 초안은 "다시 정리함"으로 닫히고 목록에서 다시 열어 볼 수 있습니다. 지금 검토는 새 초안으로 옮겨지지 않습니다.',
        if (_dirty) '저장하지 않은 편집은 먼저 저장해 지금 초안에 남깁니다.',
      ].join('\n\n'),
      confirmLabel: '다시 정리',
    );
    if (!ok || !mounted) return;
    if (!await _ensureSaved() || !mounted) return;
    setState(() {
      _busy = true;
      _notice = conceptDraftWaitText('같은 쪽을 다시 정리하는 중', null);
      _noticeError = false;
    });
    final String newId;
    try {
      newId = await _svc.rerun(a.id, onWait: (e) {
        if (mounted) setState(() => _notice = conceptDraftWaitText('같은 쪽을 다시 정리하는 중', e));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _say('다시 정리하지 못했습니다: $e', error: true);
      unawaited(ThinkController.instance.loadActions(a.conversationId));
      return;
    }
    String? folderError;
    try {
      await _svc.proposeFolders(newId);
    } catch (e) {
      folderError = '$e';
    }
    unawaited(ThinkController.instance.loadActions(a.conversationId));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _draftId = newId;
    });
    await _load();
    _say(
      folderError == null
          ? '새 초안으로 바꿨습니다. 앞 초안은 "다시 정리함"으로 닫혔습니다.'
          : '새 초안으로 바꿨지만 폴더 제안은 만들지 못했습니다($folderError). 개념마다 폴더를 정하세요.',
      error: folderError != null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: math.min(1440, size.width - 32),
        height: size.height - 32,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ThinkNotice(text: _loadError!, color: kThinkError, icon: Icons.error_outline),
            const SizedBox(height: 10),
            Row(children: [
              TextButton(onPressed: _load, child: const Text('다시 읽기')),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('닫기')),
            ]),
          ],
        ),
      );
    }
    final r = _record;
    if (r == null) return const Center(child: CircularProgressIndicator(color: kThinkAccent));
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1000;
    final chatSide = wide && _chatOpen && width >= 1280;
    final left = _leftPanel(r);
    final cards = _cardList(r);
    final chat = _chatPanel();
    return ConceptDraftCardScope(
      draftId: r.id,
      draftOpen: r.isOpen,
      approve: _approveAction,
      rerun: _rerunAction,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(r),
          const Divider(color: kThinkBorder, height: 1),
          Expanded(
            child: wide && (!_chatOpen || chatSide)
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 360, child: left),
                      const VerticalDivider(color: kThinkBorder, width: 1),
                      Expanded(child: cards),
                      if (chatSide) ...[
                        const VerticalDivider(color: kThinkBorder, width: 1),
                        SizedBox(width: 400, child: Padding(padding: const EdgeInsets.all(8), child: chat)),
                      ],
                    ],
                  )
                : DefaultTabController(
                    length: _chatOpen ? 3 : 2,
                    child: Column(
                      children: [
                        TabBar(
                          labelColor: kThinkText,
                          unselectedLabelColor: kThinkSub,
                          indicatorColor: kThinkAccent,
                          tabs: [
                            const Tab(text: '요약·폴더'),
                            const Tab(text: '개념'),
                            if (_chatOpen) const Tab(text: 'Think'),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(children: [
                            left,
                            cards,
                            if (_chatOpen) Padding(padding: const EdgeInsets.all(8), child: chat),
                          ]),
                        ),
                      ],
                    ),
                  ),
          ),
          const Divider(color: kThinkBorder, height: 1),
          _footer(r),
        ],
      ),
    );
  }

  Widget _chatPanel() {
    return ConceptChatPanel(
      controller: _chat,
      beforeSend: _ensureSaved,
      onClose: () => setState(() => _chatOpen = false),
    );
  }

  Widget _header(ConceptDraftRecord r) {
    final kept = _items.where((it) => it.kept).length;
    final status = (
      conceptDraftStatusLabel(r.status),
      switch (r.status) {
        'confirmed' => kThinkSuccess,
        'discarded' || 'replaced' => kThinkHint,
        _ => kThinkAccent,
      },
    );
    final pages =
        r.pages.isEmpty ? '' : (r.pages.length == 1 ? '${r.pages.first}쪽' : '${r.pages.first}–${r.pages.last}쪽');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 10),
      child: Row(
        children: [
          const Icon(Icons.fact_check_outlined, color: kThinkAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('개념 초안 검토', style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text('${r.bookName} · ${r.gradeLabel} · ${r.unitPath.join(' > ')} · PDF $pages',
                    style: const TextStyle(color: kThinkSub, fontSize: 13), overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Wrap(
            spacing: 6,
            children: [
              ThinkBadge(status.$1, color: status.$2),
              ThinkBadge('넣을 개념 $kept/${_items.length}'),
              if (r.costUsd != null) ThinkBadge('정리 \$${r.costUsd!.toStringAsFixed(3)}', color: kThinkHint),
            ],
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('draft-chat-toggle'),
            tooltip: _chatOpen ? 'Think 대화 닫기' : 'Think와 검토하기',
            onPressed: () => setState(() => _chatOpen = !_chatOpen),
            icon: Icon(_chatOpen ? Icons.forum : Icons.forum_outlined, size: 20),
            color: _chatOpen ? kThinkAccent : kThinkSub,
          ),
          IconButton(
            tooltip: '닫기',
            onPressed: _busy ? null : () => unawaited(_close()),
            icon: const Icon(Icons.close, size: 20),
            color: kThinkSub,
          ),
        ],
      ),
    );
  }

  Widget _leftPanel(ConceptDraftRecord r) {
    final c = r.checks;
    final plan = r.folderPlan;
    final byId = r.blocksById;
    return Scrollbar(
      controller: _leftScroll,
      child: ListView(
        controller: _leftScroll,
        padding: const EdgeInsets.all(16),
        children: [
          const ConceptSectionTitle('결과 요약'),
          SelectableText(r.summary.isEmpty ? '(요약 없음)' : r.summary,
              style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.6)),
          if (r.criteria.isNotEmpty) ...[
            const SizedBox(height: 6),
            ConceptHint('쓴 기준: ${r.criteria.join(', ')}'),
          ],
          if (r.questions.isNotEmpty) ...[
            const SizedBox(height: 14),
            const ConceptSectionTitle('Think가 묻는 것'),
            for (final q in r.questions)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('· $q', style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
              ),
          ],
          const SizedBox(height: 14),
          const ConceptSectionTitle('검사'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ThinkBadge('두 번 읽기 차이 ${r.disagreements.length}곳',
                  color: r.disagreements.isEmpty ? kThinkSub : kThinkLink),
              ThinkBadge('수식 확인 ${c.formulaWarnings.length}',
                  color: c.formulaWarnings.isEmpty ? kThinkSub : kThinkError),
              ThinkBadge('근거 없는 개념 ${c.conceptsWithoutSource.length}',
                  color: c.conceptsWithoutSource.isEmpty ? kThinkSub : kThinkError),
              ThinkBadge('어디에도 안 쓴 블록 ${c.unaccounted.length}', color: c.unaccounted.isEmpty ? kThinkSub : kThinkError),
              if (c.unknownIds.isNotEmpty) ThinkBadge('모르는 블록 id ${c.unknownIds.length}', color: kThinkError),
              if (c.unknownTypes.isNotEmpty) ThinkBadge('목록에 없는 유형 ${c.unknownTypes.length}', color: kThinkError),
            ],
          ),
          if (c.unaccounted.isNotEmpty) ...[
            const SizedBox(height: 8),
            _foldout('어디에도 안 쓴 블록', [
              for (final id in c.unaccounted) _blockLine(r, byId[id], id),
            ]),
          ],
          if (r.excluded.isNotEmpty) ...[
            const SizedBox(height: 8),
            _foldout('뺀 블록 ${r.excluded.fold<int>(0, (n, e) => n + e.blockIds.length)}개', [
              for (final e in r.excluded)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${kDraftExcludeReasonLabels[e.reasonType] ?? e.reasonType} · ${e.reason}',
                          style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                      for (final id in e.blockIds) _blockLine(r, byId[id], id),
                    ],
                  ),
                ),
            ]),
          ],
          const SizedBox(height: 16),
          _typeSection(r),
          const SizedBox(height: 16),
          ConceptSectionTitle(
            '폴더',
            trailing: plan == null ? null : ConceptHint('제안: ${plan.placements.length}개 배치'),
          ),
          if (plan == null)
            const ThinkNotice(text: '폴더 제안이 없습니다. 개념마다 "폴더 정하기"로 자리를 정하세요.')
          else if (plan.notes.isNotEmpty) ...[
            SelectableText(plan.notes, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.6)),
            const SizedBox(height: 4),
            const ConceptHint('교재 단원이 아니라 수학 구조로 나눈 제안입니다. 이름을 바꾸거나 개념마다 폴더를 바꿀 수 있습니다.'),
          ],
          if (plan != null && (plan.pendingDrafts > 0 || plan.overlaps.isNotEmpty)) ...[
            const SizedBox(height: 4),
            ConceptHint([
              if (plan.pendingDrafts > 0) '검토 중인 다른 초안 ${plan.pendingDrafts}개의 폴더도 보고 맞춘 제안입니다.',
              if (plan.overlaps.isNotEmpty) '겹칠 수 있는 개념 ${plan.overlaps.length}개는 카드에 표시했습니다(지우지 않았습니다).',
            ].join(' ')),
          ],
          const SizedBox(height: 8),
          _folderTree(r),
          const SizedBox(height: 16),
          const ConceptSectionTitle('출처 쪽 이미지'),
          if (_images != null)
            ConceptHint('${_images!.length}쪽을 불러왔습니다. 개념 카드의 "근거 보기"에서 잘라 봅니다.')
          else ...[
            if (_imagesError != null) ThinkNotice(text: _imagesError!, color: kThinkError, icon: Icons.error_outline),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _imagesLoading ? null : () => unawaited(_loadImages()),
                icon: _imagesLoading
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent))
                    : const Icon(Icons.image_outlined, size: 16),
                label: Text(_imagesLoading ? '쪽 이미지를 만드는 중' : '원본 쪽 이미지 불러오기'),
                style: TextButton.styleFrom(foregroundColor: kThinkLink),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _foldout(String title, List<Widget> children) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 6),
        iconColor: kThinkSub,
        collapsedIconColor: kThinkSub,
        title: Text(title, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _blockLine(ConceptDraftRecord r, DraftBlock? b, String id) {
    final text =
        b == null ? '(없는 블록)' : [b.title, b.text, b.figureDescription].where((s) => s.trim().isNotEmpty).join(' / ');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text('[${b == null ? id : r.pageLabel(b.rawPage)}] $text',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4)),
    );
  }

  Widget _folderTree(ConceptDraftRecord r) {
    final kept = _items.where((it) => it.kept && !it.noNewConcept).toList();
    final paths = reviewFolderPaths(kept);
    if (paths.isEmpty) return const ConceptHint('아직 폴더를 정한 개념이 없습니다.');
    final keys = _libraryKeys;
    final reasons = r.folderPlan?.newFolderReasons ?? const <String, String>{};
    final unplaced = kept.where((it) => it.folder.length < 2).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in paths)
          () {
            final fresh = p.length >= 2 && !keys.contains(p.join('\u0000'));
            final count = kept.where((it) => it.folder.join('\u0000') == p.join('\u0000')).length;
            final reason = reasons[p.join(' > ')];
            final row = Padding(
              padding: EdgeInsets.only(left: 14.0 * (p.length - 1), bottom: 2),
              child: Row(
                children: [
                  Icon(p.length == 1 ? Icons.account_tree_outlined : Icons.folder_outlined,
                      size: 16, color: fresh ? kThinkAccent : kThinkSub),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(p.last,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: kThinkText,
                            fontSize: 13,
                            fontWeight: p.length == 1 ? FontWeight.w800 : FontWeight.w500)),
                  ),
                  if (count > 0) ...[const SizedBox(width: 6), ConceptHint('$count')],
                  if (fresh) ...[const SizedBox(width: 6), const ThinkBadge('새 폴더', color: kThinkAccent)],
                  const Spacer(),
                  if (fresh && r.isOpen)
                    IconButton(
                      tooltip: '이름 바꾸기',
                      visualDensity: VisualDensity.compact,
                      onPressed: _busy ? null : () => unawaited(_renameFolder(p)),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      color: kThinkSub,
                    ),
                ],
              ),
            );
            return reason == null || reason.isEmpty ? row : Tooltip(message: reason, child: row);
          }(),
        if (unplaced > 0) ...[
          const SizedBox(height: 6),
          ThinkNotice(text: '폴더를 정하지 않은 개념 $unplaced개', color: kThinkError, icon: Icons.folder_off_outlined),
        ],
      ],
    );
  }

  Widget _cardList(ConceptDraftRecord r) {
    if (_items.isEmpty) return const Center(child: ConceptHint('초안에 개념이 없습니다.'));
    return Scrollbar(
      controller: _cardScroll,
      child: ListView.builder(
        controller: _cardScroll,
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        itemBuilder: (context, i) => _card(r, _items[i]),
      ),
    );
  }

  /// 위젯 키. 원래 항목은 예전처럼 번호, 나누거나 Think가 만든 항목은 항목 key.
  String _wkey(ReviewItem it) => it.isOriginal ? '${it.index}' : it.key;

  Widget _card(ConceptDraftRecord r, ReviewItem it) {
    final c = r.concepts[it.index];
    final open = r.isOpen && !_busy;
    final dropped = !it.kept;
    final k = it.key;
    final w = _wkey(it);
    final pages = r.sourcePagesFor(it);
    final formulas = it.isOriginal ? r.formulaWarningsFor(it.index) : const <String>[];
    final disagreements = r.disagreementsForItem(it);
    final placement = it.isOriginal ? r.folderPlan?.placements[it.index] : null;
    final keys = _libraryKeys;
    return Opacity(
      key: ValueKey('draft-card-$w'),
      opacity: dropped ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kThinkPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: it.mark == ReviewMark.edit ? kThinkLink.withValues(alpha: 0.6) : kThinkBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Tooltip(
                  message: 'Think 대화에서 이 항목을 부르는 이름',
                  child: Text(k, style: const TextStyle(color: kThinkHint, fontSize: 13, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: ValueKey('draft-title-$w'),
                    controller: _titles[k],
                    enabled: open && !dropped,
                    onChanged: (_) => _textChanged(k),
                    style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w700),
                    decoration: thinkInputDecoration(hint: '개념 이름', dense: true),
                  ),
                ),
                if (c.typeName.isNotEmpty && conceptTypeKey(c.typeName) != conceptTypeKey(it.type)) ...[
                  const SizedBox(width: 8),
                  Tooltip(message: 'AI가 붙인 유형', child: ThinkBadge('AI: ${c.typeName}', color: kThinkHint)),
                ],
                if (!it.noNewConcept) ...[
                  const SizedBox(width: 8),
                  _typePicker(it, enabled: open && !dropped),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (mark, label, icon) in const [
                  (ReviewMark.keep, '그대로', Icons.check),
                  (ReviewMark.edit, '고쳐서', Icons.edit_note),
                  (ReviewMark.drop, '빼기', Icons.block),
                ])
                  ThinkToggleChip(
                    key: ValueKey('draft-mark-$w-${mark.name}'),
                    label: label,
                    icon: icon,
                    selected: it.mark == mark,
                    enabled: open,
                    onChanged: (_) => _update(k, (x) => x.copyWith(mark: mark, clearMerged: mark != ReviewMark.drop)),
                  ),
              ],
            ),
            if (it.mergedInto != null) ...[
              const SizedBox(height: 6),
              ConceptHint('${it.mergedInto}에 합쳤습니다. 되살리면 따로 넣습니다.'),
            ],
            if (!dropped) ...[
              const SizedBox(height: 10),
              if (_editing.contains(k))
                TextField(
                  key: ValueKey('draft-content-$w'),
                  controller: _contents[k],
                  enabled: open,
                  minLines: 3,
                  maxLines: 14,
                  onChanged: (_) => _textChanged(k),
                  style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
                  decoration: thinkInputDecoration(hint: '개념 내용(수식은 \$...\$)'),
                )
              else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: kThinkBg, borderRadius: BorderRadius.circular(8)),
                  child: it.content.trim().isEmpty
                      ? const ConceptHint('(내용 없음)')
                      : LatexTextRenderer(
                          it.content,
                          dollarMath: true,
                          style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.6),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          blockVerticalPadding: 4,
                        ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed:
                      open ? () => setState(() => _editing.contains(k) ? _editing.remove(k) : _editing.add(k)) : null,
                  icon: Icon(_editing.contains(k) ? Icons.visibility_outlined : Icons.edit_outlined, size: 16),
                  label: Text(_editing.contains(k) ? '미리보기' : '내용 고치기'),
                  style: TextButton.styleFrom(foregroundColor: kThinkLink),
                ),
              ),
              _relationRow(it, enabled: open),
              if (!it.noNewConcept) ...[
                Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 16, color: kThinkSub),
                    const SizedBox(width: 6),
                    Expanded(
                      child: it.folder.length < 2
                          ? const Text('폴더를 정하지 않음', style: TextStyle(color: kThinkError, fontSize: 13))
                          : Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 4,
                              children: [
                                for (var n = 1; n <= it.folder.length; n += 1) ...[
                                  if (n > 1) const Icon(Icons.chevron_right, size: 14, color: kThinkHint),
                                  Text(it.folder[n - 1],
                                      style: TextStyle(
                                        color: n > 1 && !keys.contains(it.folder.sublist(0, n).join('\u0000'))
                                            ? kThinkAccent
                                            : kThinkText,
                                        fontSize: 13,
                                      )),
                                ],
                              ],
                            ),
                    ),
                    TextButton(
                      onPressed: open ? () => unawaited(_pickFolder(it)) : null,
                      style: TextButton.styleFrom(foregroundColor: kThinkLink),
                      child: Text(it.folder.length < 2 ? '폴더 정하기' : '폴더 바꾸기'),
                    ),
                  ],
                ),
                if (placement != null && placement.reason.isNotEmpty) ConceptHint('제안 이유: ${placement.reason}'),
                _anchorRow(it, enabled: open),
              ],
              if (c.needsCheck.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                ThinkNotice(text: '확인 필요: ${c.needsCheck}', color: kThinkAccent, icon: Icons.help_outline),
              ],
              if (r.folderPlan?.overlaps[it.index] case final overlaps? when overlaps.isNotEmpty) ...[
                const SizedBox(height: 6),
                ThinkNotice(
                  key: ValueKey('draft-overlap-$w'),
                  text: '겹칠 수 있음: ${overlaps.map((o) => o.label).join(' · ')}',
                  color: kThinkAccent,
                  icon: Icons.content_copy_outlined,
                ),
              ],
              if (formulas.isNotEmpty) ...[
                const SizedBox(height: 6),
                ThinkNotice(
                  text: '근거 블록에서 찾지 못한 수식: ${formulas.join(', ')}',
                  color: kThinkError,
                  icon: Icons.functions,
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: ConceptHint(pages.isEmpty
                        ? '출처 없음(근거 블록이 없습니다)'
                        : '출처: ${pages.map(r.pageLabel).join(', ')}'
                            '${disagreements.isEmpty ? '' : ' · 두 번 읽기 차이 ${disagreements.length}곳'}'
                            '${c.criterionNotes.isEmpty ? '' : ' · ${c.criterionNotes}'}'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _evidence.contains(k) ? _evidence.remove(k) : _evidence.add(k)),
                    style: TextButton.styleFrom(foregroundColor: kThinkLink),
                    child: Text(_evidence.contains(k) ? '근거 닫기' : '근거 보기'),
                  ),
                ],
              ),
              if (_evidence.contains(k)) _evidenceView(r, it, disagreements),
            ],
          ],
        ),
      ),
    );
  }

  /// 기존 개념과의 관계. 정하지 않으면 같은 이름·겹침이 있을 때 새 개념으로 넣고 "검토 필요"로 표시한다.
  Widget _relationRow(ReviewItem it, {required bool enabled}) {
    final w = _wkey(it);
    final rel = it.relation;
    final same = _sameNamed?[conceptNameKey(it.title)] ?? const <ConceptPick>[];
    final title = it.title.trim().isEmpty ? '이 항목' : '"${it.title.trim()}"';
    final target = rel?.conceptName ?? '고른 개념';
    final String? hint = switch (rel?.kind) {
      null when same.isNotEmpty => '정하지 않으면 새 개념으로 넣고 "검토 필요"로 표시합니다.',
      null => null,
      ReviewRelationKind.newConcept => same.isNotEmpty ? '같은 이름이 있어도 "검토 필요" 표시 없이 따로 새 개념으로 넣습니다.' : null,
      ReviewRelationKind.statement =>
        '새 개념을 만들지 않고 "$target"에 확정 전 서술로 더합니다. 출처 쪽은 그 서술에 이어지고, 기존 확정 내용·본문은 그대로입니다. 유형·폴더·붙일 개념은 쓰지 않습니다.',
      ReviewRelationKind.source =>
        '새 개념·글 없이 이 교재 쪽을 "$target"의 ${rel!.statementId == null ? '기본 서술' : '고른 서술'} 출처로만 잇습니다. '
            '이 항목의 글은 넣지 않고, 근거 범위는 미확인으로 들어갑니다. 유형·폴더·붙일 개념은 쓰지 않습니다.',
      ReviewRelationKind.revise =>
        '이 항목 글을 "$target"의 기본 서술 수정안으로 저장하고 출처를 기본 서술에 잇습니다. 본문은 바뀌지 않고, 그 개념 창에서 이유를 적어 확정해야 바뀝니다. '
            '이미 수정안이 있으면 확정이 막힙니다.',
      ReviewRelationKind.hold => '이번 확정에 넣지 않고 "보류한 항목"에 남깁니다. 개념 초안 목록의 "보류한 항목"에서 다시 검토하거나 버립니다.',
      ReviewRelationKind.extendsOf => '$title을(를) 새 개념으로 넣고 "$target"을(를) 넓힌 개념으로 기록합니다.',
      ReviewRelationKind.specialCase => '$title을(를) 새 개념으로 넣고 "$target"의 특수한 경우로 기록합니다.',
      ReviewRelationKind.review => rel!.conceptId == null
          ? '새 개념으로 넣고 "검토 필요"로 표시합니다. 비교할 개념을 고르면 함께 남깁니다.'
          : '새 개념으로 넣고 "$target"과(와) 같은 개념인지 "검토 필요"로 표시합니다.',
    };
    return Padding(
      key: ValueKey('draft-relation-$w'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.join_inner, size: 16, color: kThinkSub),
              const SizedBox(width: 6),
              const Text('기존 개념과', style: TextStyle(color: kThinkSub, fontSize: 13)),
              const SizedBox(width: 8),
              DropdownButton<String>(
                key: ValueKey('draft-relation-kind-$w'),
                value: rel?.kind.db ?? '',
                dropdownColor: kThinkBg,
                underline: const SizedBox.shrink(),
                style: const TextStyle(color: kThinkText, fontSize: 13),
                items: [
                  const DropdownMenuItem(value: '', child: Text('정하지 않음', style: TextStyle(color: kThinkSub))),
                  for (final k in ReviewRelationKind.values) DropdownMenuItem(value: k.db, child: Text(k.label)),
                ],
                onChanged: enabled ? (v) => _setRelationKind(it, ReviewRelationKind.fromDb(v)) : null,
              ),
              if (rel != null && rel.kind.takesTarget) ...[
                const SizedBox(width: 8),
                if (rel.conceptName != null)
                  Flexible(child: ThinkBadge(rel.conceptName!, color: kThinkLink))
                else if (rel.conceptId != null)
                  const Flexible(child: ThinkBadge('고른 개념', color: kThinkLink)),
                TextButton(
                  key: ValueKey('draft-relation-pick-$w'),
                  onPressed: enabled ? () => unawaited(_pickRelationTarget(it, rel.kind)) : null,
                  style: TextButton.styleFrom(foregroundColor: kThinkLink),
                  child: Text(rel.conceptId == null ? '기존 개념 고르기' : '바꾸기'),
                ),
              ],
            ],
          ),
          if (same.isNotEmpty && (rel == null || rel.kind == ReviewRelationKind.newConcept))
            ThinkNotice(
              key: ValueKey('draft-same-name-$w'),
              text:
                  '라이브러리에 같은 이름 개념 ${same.length}개: ${same.take(3).map((p) => '${p.label} (${p.folderLabel})').join(' · ')}'
                  '${same.length > 3 ? ' 외 ${same.length - 3}개' : ''}. 이름만으로 같은 개념인지 정하지 않습니다.',
              color: kThinkAccent,
              icon: Icons.join_inner,
            ),
          if (rel != null && rel.missingTarget)
            Text('${rel.kind.label}(으)로 두려면 기존 개념을 고르세요.', style: const TextStyle(color: kThinkError, fontSize: 13)),
          if (rel != null && rel.kind == ReviewRelationKind.source && rel.conceptId != null)
            _sourceStatementRow(it, rel, enabled: enabled),
          if (hint != null) ConceptHint(hint),
          if (rel?.conceptId != null && rel!.kind.takesTarget) _compareToggle(it, rel),
          if (_proposal?.items[it.key] case final s? when !s.sameAs(rel)) _suggestionBox(it, s, enabled: enabled),
        ],
      ),
    );
  }

  /// 출처만 연결: 고른 개념의 어느 서술에 이을지(기본 서술 또는 다른 서술 하나).
  Widget _sourceStatementRow(ReviewItem it, ReviewRelation rel, {required bool enabled}) {
    final w = _wkey(it);
    final t = _targets[rel.conceptId];
    if (t == null) {
      final error = _targetErrors[rel.conceptId];
      if (error == null && !_targetsLoading.contains(rel.conceptId)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_loadTarget(rel.conceptId!));
        });
      }
      return Padding(
        padding: const EdgeInsets.only(left: 22, top: 2),
        child: ConceptHint(error ?? '이을 서술을 읽는 중입니다…'),
      );
    }
    final missing = rel.statementId != null && t.statement(rel.statementId) == null;
    return Padding(
      padding: const EdgeInsets.only(left: 22),
      child: Row(
        children: [
          const Text('이을 서술', style: TextStyle(color: kThinkSub, fontSize: 13)),
          const SizedBox(width: 8),
          Flexible(
            child: DropdownButton<String>(
              key: ValueKey('draft-relation-statement-$w'),
              value: missing ? '!' : (rel.statementId ?? ''),
              isExpanded: true,
              dropdownColor: kThinkBg,
              underline: const SizedBox.shrink(),
              style: const TextStyle(color: kThinkText, fontSize: 13),
              items: [
                const DropdownMenuItem(value: '', child: Text('기본 서술')),
                for (final s in t.statements) DropdownMenuItem(value: s.id, child: Text('다른 서술: ${s.label}')),
                if (missing)
                  DropdownMenuItem(
                    value: '!',
                    child:
                        Text('${rel.statementLabel ?? '고른 서술'} (지금은 없음)', style: const TextStyle(color: kThinkError)),
                  ),
              ],
              onChanged: enabled ? (v) => _setSourceStatement(it, v == null || v.isEmpty || v == '!' ? null : v) : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _compareToggle(ReviewItem it, ReviewRelation rel) {
    final w = _wkey(it);
    final open = _comparing.contains(it.key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('draft-compare-toggle-$w'),
            onPressed: () {
              setState(() => open ? _comparing.remove(it.key) : _comparing.add(it.key));
              if (!open) unawaited(_loadTarget(rel.conceptId!));
            },
            icon: Icon(open ? Icons.compare_arrows : Icons.compare_arrows_outlined, size: 16),
            label: Text(open ? '비교 닫기' : '"${rel.conceptName ?? '고른 개념'}"과(와) 비교'),
            style: TextButton.styleFrom(foregroundColor: kThinkLink),
          ),
        ),
        if (open) _comparePanel(it, rel),
      ],
    );
  }

  /// 고른 기존 개념의 지금 모습(읽기 전용). 이 항목 글은 카드 위쪽에 있다.
  Widget _comparePanel(ReviewItem it, ReviewRelation rel) {
    final w = _wkey(it);
    final t = _targets[rel.conceptId];
    final error = _targetErrors[rel.conceptId];
    Widget body;
    if (t == null) {
      body = error != null
          ? Row(
              children: [
                Expanded(child: Text(error, style: const TextStyle(color: kThinkError, fontSize: 13))),
                TextButton(
                  onPressed: () => unawaited(_loadTarget(rel.conceptId!, force: true)),
                  child: const Text('다시 읽기'),
                ),
              ],
            )
          : const ConceptHint('기존 개념을 읽는 중입니다…');
    } else {
      const label = TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(t.name, style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
              if (t.folder.isNotEmpty) ConceptHint(t.folder.join(' > ')),
              ThinkBadge('출처 ${t.sources}줄${t.books.isEmpty ? '' : ' · ${t.books.join(', ')}'}', color: kThinkSub),
              if (t.contentDraft) const ThinkBadge('수정안 있음', color: kThinkAccent),
            ],
          ),
          const SizedBox(height: 8),
          const Text('기본 서술(지금 본문)', style: label),
          const SizedBox(height: 4),
          t.content.trim().isEmpty
              ? const ConceptHint('(비어 있음)')
              : LatexTextRenderer(
                  t.content,
                  dollarMath: true,
                  style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.6),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  blockVerticalPadding: 4,
                ),
          for (final s in t.statements) ...[
            const SizedBox(height: 8),
            Text('다른 서술${s.confirmed ? '' : '(확정 전)'}', style: label),
            const SizedBox(height: 4),
            LatexTextRenderer(
              s.text,
              dollarMath: true,
              style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.6),
              crossAxisAlignment: CrossAxisAlignment.start,
              blockVerticalPadding: 4,
            ),
          ],
          if (rel.kind == ReviewRelationKind.revise && t.contentDraft) ...[
            const SizedBox(height: 8),
            const ThinkNotice(
              text: '이 개념에는 이미 저장된 수정안이 있어 지금은 "대표 서술 수정안"으로 확정할 수 없습니다. '
                  '그 개념 창에서 기존 수정안을 먼저 확정하거나 버리세요.',
              color: kThinkError,
              icon: Icons.block,
            ),
          ],
          const SizedBox(height: 6),
          const ConceptHint('비교만 보여 줍니다. 같은 개념인지, 어느 설명이 옳은지는 정하지 않습니다.'),
        ],
      );
    }
    return Container(
      key: ValueKey('draft-compare-panel-$w'),
      margin: const EdgeInsets.only(top: 2, bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: body,
    );
  }

  /// AI 비교 제안 한 줄. 반영하면 이 항목의 관계(저장 전)가 바뀐다.
  Widget _suggestionBox(ReviewItem it, ConceptCompareSuggestion s, {required bool enabled}) {
    final w = _wkey(it);
    final st = s.statementId == null ? null : _targets[s.conceptId]?.statement(s.statementId);
    final what = [
      s.kind.label,
      if (s.conceptName != null) '"${s.conceptName}"',
      if (s.kind == ReviewRelationKind.source) s.statementId == null ? '기본 서술' : '다른 서술 ${st?.label ?? ''}'.trim(),
    ].join(' · ');
    return Container(
      key: ValueKey('draft-compare-suggest-$w'),
      margin: const EdgeInsets.only(top: 4, bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
      decoration: BoxDecoration(
        color: kThinkAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkAccent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_outlined, size: 16, color: kThinkAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text('AI 비교 제안: $what',
                    style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              TextButton(
                key: ValueKey('draft-compare-apply-$w'),
                onPressed: enabled && s.applicable ? () => _applySuggestion(it, s) : null,
                style: TextButton.styleFrom(foregroundColor: kThinkLink),
                child: const Text('반영'),
              ),
              TextButton(
                key: ValueKey('draft-compare-dismiss-$w'),
                onPressed: enabled ? () => _dismissSuggestion(it) : null,
                style: TextButton.styleFrom(foregroundColor: kThinkSub),
                child: const Text('무시'),
              ),
            ],
          ),
          if (s.reason.isNotEmpty) ConceptHint('이유: ${s.reason}'),
          if (s.differences.isNotEmpty) ConceptHint('다른 점: ${s.differences}'),
          if (!s.applicable)
            const Text('그 개념에 이미 수정안이 있어 반영하지 않습니다. 기존 수정안을 먼저 정리하세요.',
                style: TextStyle(color: kThinkError, fontSize: 13)),
          const ConceptHint('반영하면 이 항목의 관계만 바뀝니다(저장 전). 확정은 직접 합니다.'),
        ],
      ),
    );
  }

  /// 주제 묶음: 이 개념 바로 앞에 알아야 하는 다른 항목. 이 항목에 (여러 단계로) 붙은 항목은 고를 수 없다(고리).
  Widget _anchorRow(ReviewItem it, {required bool enabled}) {
    bool reachesSelf(ReviewItem from) {
      var cur = reviewAnchorTarget(_items, from);
      for (var steps = 0; cur != null && steps <= _items.length; steps++) {
        if (cur.key == it.key) return true;
        cur = reviewAnchorTarget(_items, cur);
      }
      return false;
    }

    final target = reviewAnchorTarget(_items, it);
    final options = [
      for (final o in _items)
        if (o.kept && o.key != it.key && !o.noNewConcept) o
    ];
    final toStatement = target != null && target.noNewConcept;
    final dangling = it.anchor != null && target == null;
    final otherFolder = target != null && target.folder.join('\u0000') != it.folder.join('\u0000');
    final value = it.anchor == null ? '' : (options.any((o) => o.key == it.anchor) ? it.anchor! : '!${it.anchor}');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.hub_outlined, size: 16, color: kThinkSub),
              const SizedBox(width: 6),
              const Tooltip(
                message: '이 개념을 이해하려면 바로 앞에 알아야 하는 개념. 라이브러리에서 그 개념 뒤에 묶여 보입니다.',
                child: Text('붙일 개념', style: TextStyle(color: kThinkSub, fontSize: 13)),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: DropdownButton<String>(
                  key: ValueKey('draft-anchor-${_wkey(it)}'),
                  value: value,
                  isExpanded: true,
                  dropdownColor: kThinkBg,
                  underline: const SizedBox.shrink(),
                  style: const TextStyle(color: kThinkText, fontSize: 13),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('묶지 않음', style: TextStyle(color: kThinkSub))),
                    for (final o in options)
                      DropdownMenuItem(
                        value: o.key,
                        enabled: !reachesSelf(o),
                        child: Text(
                          '${o.key} ${o.title.trim().isEmpty ? '(이름 없음)' : o.title.trim()}${reachesSelf(o) ? ' · 이 개념에 붙어 있음' : ''}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: reachesSelf(o) ? kThinkHint : kThinkText),
                        ),
                      ),
                    if (value.startsWith('!'))
                      DropdownMenuItem(
                        value: value,
                        child: Text(
                            target == null
                                ? '${it.anchor} (빠진 항목)'
                                : toStatement
                                    ? '${it.anchor} (${target.relation!.kind.label})'
                                    : '${it.anchor} (${target.key}에 합침)',
                            style: TextStyle(color: target == null || toStatement ? kThinkError : kThinkText)),
                      ),
                  ],
                  onChanged: enabled
                      ? (v) => _update(
                          it.key,
                          (x) => (v ?? '').isEmpty || v!.startsWith('!')
                              ? x.copyWith(clearAnchor: true)
                              : x.copyWith(anchor: v))
                      : null,
                ),
              ),
            ],
          ),
          if (target != null && target.key != it.anchor && !toStatement)
            ConceptHint('${it.anchor}을(를) ${target.key}에 합쳐서 ${target.key}에 붙입니다.'),
          if (dangling) ConceptHint('붙일 개념(${it.anchor})을 빼서 확정할 때 잇지 않습니다.'),
          if (toStatement)
            ConceptHint('붙일 개념(${target.key})을 "${target.relation!.kind.label}"(으)로 두어 새 개념이 아니라서 확정할 때 잇지 않습니다.'),
          if (otherFolder && !toStatement) const ConceptHint('붙일 개념과 폴더가 달라 확정할 때 잇지 않습니다(같은 폴더끼리만 묶음).'),
        ],
      ),
    );
  }

  /// 확정된 유형과 거절하지 않은 새 유형 중에서 고른다. 기존 구분은 유형에서 정해진다.
  Widget _typePicker(ReviewItem it, {required bool enabled}) {
    final options = <String, String>{};
    for (final t in _types) {
      options[conceptTypeKey(t.name)] = t.name;
    }
    final fresh = <String>{};
    for (final t in _newTypes) {
      final key = conceptTypeKey(t.name);
      if (t.accept == false || options.containsKey(key)) continue;
      options[key] = t.name;
      fresh.add(key);
    }
    final current = conceptTypeKey(it.type);
    final unknown = current.isNotEmpty && !options.containsKey(current);
    final legacy = legacySubTypeOf(it.type, _types, _newTypes);
    return Tooltip(
      message: legacy == null ? '개념 유형. 라이브러리의 기존 구분(정의·연산·정리)은 유형에서 정해집니다.' : '개념 유형. 기존 구분은 "$legacy"으로 들어갑니다.',
      child: DropdownButton<String>(
        key: ValueKey('draft-type-${_wkey(it)}'),
        value: current.isEmpty ? null : current,
        hint: const Text('유형 정하기', style: TextStyle(color: kThinkError, fontSize: 13)),
        dropdownColor: kThinkBg,
        underline: const SizedBox.shrink(),
        style: const TextStyle(color: kThinkText, fontSize: 13),
        items: [
          for (final e in options.entries)
            DropdownMenuItem(
              value: e.key,
              child: Text(fresh.contains(e.key) ? '${e.value} · 새 유형' : e.value,
                  style: TextStyle(color: fresh.contains(e.key) ? kThinkAccent : kThinkText)),
            ),
          if (unknown)
            DropdownMenuItem(
              value: current,
              child: Text('${it.type.trim()} (목록에 없음)', style: const TextStyle(color: kThinkError)),
            ),
        ],
        onChanged: enabled
            ? (v) {
                if (v != null && options[v] != null) _update(it.key, (x) => x.copyWith(type: options[v]));
              }
            : null,
      ),
    );
  }

  Widget _typeSection(ConceptDraftRecord r) {
    final open = r.isOpen && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConceptSectionTitle('개념 유형', trailing: ConceptHint('새 유형 제안 ${_newTypes.length}')),
        ConceptHint(_types.isEmpty ? '확정된 유형이 없습니다.' : '확정된 유형: ${_types.map((t) => t.name).join(' · ')}'),
        if (_newTypes.isEmpty) ...[
          const SizedBox(height: 4),
          const ConceptHint('새 유형 제안이 없습니다. 모두 확정된 유형으로 나눴습니다.'),
        ],
        for (var i = 0; i < _newTypes.length; i += 1) ...[
          const SizedBox(height: 8),
          _newTypeCard(i, _newTypes[i], open),
        ],
      ],
    );
  }

  Widget _newTypeCard(int i, ReviewNewType t, bool open) {
    final uses = newTypeUseCount(_items, t.name);
    final fallback = t.closestExisting.isEmpty ? '유형 미정' : '"${t.closestExisting}"';
    return Container(
      key: ValueKey('draft-newtype-$i'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.accept == null ? kThinkAccent.withValues(alpha: 0.6) : kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(t.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 6),
              ThinkBadge(
                switch (t.accept) { true => '받아들임', false => '거절', null => '새 유형 · 결정 전' },
                color: switch (t.accept) { true => kThinkSuccess, false => kThinkHint, null => kThinkAccent },
              ),
              const Spacer(),
              ConceptHint('개념 $uses개'),
            ],
          ),
          if (t.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(t.description, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
          ],
          if (t.reason.isNotEmpty) ConceptHint('제안 이유: ${t.reason}'),
          const SizedBox(height: 6),
          Row(
            children: [
              const ConceptHint('기존 구분'),
              const SizedBox(width: 8),
              DropdownButton<String>(
                key: ValueKey('draft-newtype-$i-legacy'),
                value: t.legacySubType,
                dropdownColor: kThinkBg,
                underline: const SizedBox.shrink(),
                style: const TextStyle(color: kThinkText, fontSize: 13),
                items: [for (final s in kConceptSubTypes) DropdownMenuItem(value: s, child: Text(s))],
                onChanged: open && t.accept != false
                    ? (v) {
                        if (v == null) return;
                        setState(() {
                          _newTypes = [
                            for (final x in _newTypes)
                              conceptTypeKey(x.name) == conceptTypeKey(t.name) ? x.copyWith(legacySubType: v) : x
                          ];
                          _notice = null;
                        });
                      }
                    : null,
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ThinkToggleChip(
                key: ValueKey('draft-newtype-$i-accept'),
                label: '받아들이기',
                icon: Icons.add_task,
                selected: t.accept == true,
                enabled: open,
                onChanged: (_) => _decideType(t.name, true),
              ),
              ThinkToggleChip(
                key: ValueKey('draft-newtype-$i-reject'),
                label: '거절',
                icon: Icons.block,
                selected: t.accept == false,
                enabled: open,
                onChanged: (_) => _decideType(t.name, false),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConceptHint(t.accept == false
              ? '거절했습니다. 이 유형을 쓰던 개념은 $fallback(으)로 바꿨습니다.'
              : '받아들이면 확정할 때 유형 목록에 더합니다. 거절하면 이 유형을 쓰는 개념을 $fallback(으)로 바꿉니다.'),
        ],
      ),
    );
  }

  Widget _evidenceView(ConceptDraftRecord r, ReviewItem it, List<DraftDisagreement> disagreements) {
    final blocks = r.blocksForItem(it);
    final byId = {for (final d in disagreements) d.id: d};
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: kThinkBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: kThinkBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (blocks.isEmpty) const ConceptHint('근거 블록이 없습니다.'),
          if (_images == null && blocks.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: ConceptHint('왼쪽 "원본 쪽 이미지 불러오기"를 누르면 원본에서 잘라 보입니다.'),
            ),
          for (final b in blocks) ...[
            Text(
                '${r.pageLabel(b.rawPage)} · ${b.kind}${b.read == 'b' ? ' · 두 번째 읽기에만 있음' : ''}${b.uncertain ? ' · 전사 불확실' : ''}',
                style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            if (_images?[b.rawPage] != null && b.bbox1k != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: LayoutBuilder(
                  builder: (context, box) =>
                      _CropView(image: _images![b.rawPage]!, bbox: b.bbox1k!, width: math.min(box.maxWidth, 640)),
                ),
              ),
            SelectionArea(
              child: LatexTextRenderer(
                [b.title, b.text].where((s) => s.trim().isNotEmpty).join('\n'),
                dollarMath: true,
                style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.5),
                crossAxisAlignment: CrossAxisAlignment.start,
              ),
            ),
            if (b.figureDescription.isNotEmpty) ConceptHint('(그림: ${b.figureDescription})'),
            if (byId[b.id] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: ThinkNotice(
                  text: '${byId[b.id]!.label}${byId[b.id]!.bText.isEmpty ? '' : '\n두 번째 읽기: ${byId[b.id]!.bText}'}',
                  color: kThinkLink,
                  icon: Icons.compare_arrows,
                ),
              ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _footer(ConceptDraftRecord r) {
    final kept = _items.where((it) => it.kept).length;
    final state = !r.isOpen
        ? switch (r.status) {
            'confirmed' => '이미 확정한 초안입니다.',
            'replaced' => '다시 정리해 닫힌 초안입니다. 새 초안에서 검토를 이어 가세요.',
            _ => '버린 초안입니다.',
          }
        : (_dirty ? '저장하지 않은 편집이 있습니다.' : (_savedAt == null ? '아직 저장한 적 없습니다.' : '검토를 저장했습니다.'));
    final replacedBy = r.status == 'replaced' ? r.replacedBy : null;
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
              Expanded(child: Text(state, style: const TextStyle(color: kThinkSub, fontSize: 13))),
              if (_busy) ...[
                const SizedBox(
                    width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
                const SizedBox(width: 12),
              ],
              if (replacedBy != null)
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _draftId = replacedBy);
                          unawaited(_load());
                        },
                  style: thinkOutlineButton(),
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  label: const Text('새 초안 열기'),
                ),
              if (r.isOpen) ...[
                TextButton(
                  onPressed: _busy ? null : () => unawaited(_discard()),
                  style: TextButton.styleFrom(foregroundColor: kThinkError),
                  child: const Text('초안 버리기'),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: '저장된 검토 항목마다 같은 이름·겹침·고른 기존 개념과 비교해 넣는 방법을 제안받습니다. 반영은 줄마다 직접 합니다.',
                  child: OutlinedButton.icon(
                    key: const ValueKey('draft-compare-propose'),
                    onPressed: _busy || _proposing ? null : () => unawaited(_proposeCompare()),
                    style: thinkOutlineButton(),
                    icon: _proposing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent))
                        : const Icon(Icons.compare_arrows, size: 16),
                    label: Text(_proposing ? '비교하는 중' : '기존 개념과 비교 제안'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy || (!_dirty && _savedAt != null) ? null : () => unawaited(_save()),
                  style: thinkOutlineButton(),
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('검토 저장'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _busy || kept == 0 ? null : () => unawaited(_confirm()),
                  style: thinkPrimaryButton(),
                  icon: const Icon(Icons.library_add_check_outlined, size: 16),
                  label: Text('확정하고 라이브러리에 넣기 ($kept개)'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 원본 쪽 이미지에서 블록 영역만 잘라 보인다.
class _CropView extends StatelessWidget {
  const _CropView({required this.image, required this.bbox, required this.width});

  final ConceptPageImage image;
  final List<int> bbox;
  final double width;

  @override
  Widget build(BuildContext context) {
    const pad = 6;
    final y0 = math.max(0, bbox[0] - pad) / 1000;
    final x0 = math.max(0, bbox[1] - pad) / 1000;
    final y1 = math.min(1000, bbox[2] + pad) / 1000;
    final x1 = math.min(1000, bbox[3] + pad) / 1000;
    final fullW = width / (x1 - x0);
    final fullH = fullW * image.height / image.width;
    final height = (y1 - y0) * fullH;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: kThinkBorder)),
      width: width,
      height: height,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: fullW,
          maxWidth: fullW,
          minHeight: fullH,
          maxHeight: fullH,
          child: Transform.translate(
            offset: Offset(-x0 * fullW, -y0 * fullH),
            child: Image.file(File(image.path), width: fullW, height: fullH, fit: BoxFit.fill),
          ),
        ),
      ),
    );
  }
}

/// 폴더 고르기. 라이브러리 폴더·검토에서 쓰는 폴더 중에서 고르거나 경로를 직접 쓴다(영역 이름부터).
class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({
    required this.current,
    required this.roots,
    required this.libraryPaths,
    required this.reviewPaths,
  });

  final List<String> current;
  final List<String> roots;
  final List<List<String>> libraryPaths;
  final List<List<String>> reviewPaths;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  late final TextEditingController _path = TextEditingController(text: widget.current.join(' > '));
  final TextEditingController _search = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _path.dispose();
    _search.dispose();
    super.dispose();
  }

  List<String> _parse(String s) => [
        for (final p in s.split('>'))
          if (p.trim().isNotEmpty) p.trim()
      ];

  void _submit() {
    final path = _parse(_path.text);
    if (path.length < 2) {
      setState(() => _error = '영역 아래 폴더까지 쓰세요(예: 대수 > 수와 연산).');
      return;
    }
    if (widget.roots.isNotEmpty && !widget.roots.contains(path.first)) {
      setState(() => _error = '영역(${widget.roots.join('·')}) 이름으로 시작해야 합니다.');
      return;
    }
    if (path.length > 7 || path.any((s) => s.length > 80)) {
      setState(() => _error = '폴더가 너무 깊거나 이름이 깁니다.');
      return;
    }
    Navigator.pop(context, path);
  }

  @override
  Widget build(BuildContext context) {
    final library = {for (final p in widget.libraryPaths) p.join('\u0000')};
    final all = <String, List<String>>{
      for (final p in [...widget.libraryPaths, ...widget.reviewPaths])
        if (p.length >= 2) p.join('\u0000'): p,
    }.values.toList()
      ..sort((a, b) => a.join('\u0000').compareTo(b.join('\u0000')));
    final q = _search.text.trim();
    final shown = q.isEmpty
        ? all
        : [
            for (final p in all)
              if (p.join(' ').contains(q)) p
          ];
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      child: SizedBox(
        width: math.min(560, size.width - 48),
        height: math.min(620, size.height - 48),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('폴더 정하기', style: TextStyle(color: kThinkText, fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: kThinkText, fontSize: 13),
                decoration:
                    thinkInputDecoration(hint: '폴더 찾기', prefixIcon: const Icon(Icons.search, size: 18), dense: true),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    for (final p in shown)
                      ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                        title: Text(p.join(' > '), style: const TextStyle(color: kThinkText, fontSize: 13)),
                        subtitle: library.contains(p.join('\u0000'))
                            ? null
                            : const Text('새 폴더(확정할 때 만들어짐)', style: TextStyle(color: kThinkAccent, fontSize: 11)),
                        selected: p.join('\u0000') == widget.current.join('\u0000'),
                        onTap: () => Navigator.pop(context, p),
                        trailing: IconButton(
                          tooltip: '이 폴더 아래에 새 폴더',
                          icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                          color: kThinkSub,
                          onPressed: () => setState(() {
                            _path.text = '${p.join(' > ')} > ';
                            _path.selection = TextSelection.collapsed(offset: _path.text.length);
                          }),
                        ),
                      ),
                    if (shown.isEmpty) const Padding(padding: EdgeInsets.all(8), child: ConceptHint('맞는 폴더가 없습니다.')),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _path,
                onSubmitted: (_) => _submit(),
                style: const TextStyle(color: kThinkText, fontSize: 13),
                decoration: thinkInputDecoration(label: '경로 직접 쓰기(영역 > 폴더 > …)', dense: true),
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!, style: const TextStyle(color: kThinkError, fontSize: 12)),
              ],
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('취소', style: TextStyle(color: kThinkSub))),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: _submit, style: thinkPrimaryButton(), child: const Text('이 경로로')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
