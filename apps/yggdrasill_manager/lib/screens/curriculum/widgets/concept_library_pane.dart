import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/concept_book_service.dart';
import '../../../services/concept_library_controller.dart';
import '../../../services/concept_library_service.dart';
import '../../../services/concept_service.dart';
import '../../../services/concept_source_evidence.dart';
import '../../../widgets/latex_text_renderer.dart';
import '../../think/think_style.dart';
import 'concept_anchor_dialogs.dart';
import 'concept_criteria_pane.dart';
import 'concept_relation_section.dart';
import 'concept_source_evidence_view.dart';
import 'concept_statement_section.dart';
import 'concept_type_chip.dart';
import 'concept_workspace.dart';

String conceptDisplayName(ConceptItem c) =>
    c.name.trim().isNotEmpty ? c.name.trim() : (c.kind == ConceptKind.definition ? '정의' : '정리');

/// 라이브러리의 기존 구분(정의·정리). 새 지식 분류가 아니다.
Widget conceptKindBadge(ConceptItem c) => Tooltip(
      message: '라이브러리의 기존 구분입니다. 정리 기준의 지식 분류와 같은 것이 아닙니다.',
      child: ThinkBadge(
        '기존 구분: ${c.kind == ConceptKind.definition ? '정의' : '정리'}${(c.subType ?? '').trim().isEmpty ? '' : ' · ${c.subType!.trim()}'}',
      ),
    );

String conceptSourceLabel(ConceptSourceRef s) {
  final book = s.bookName ?? '(책 이름을 볼 수 없음)';
  final unit = s.unitPath.isEmpty ? '' : ' · ${s.unitPath.join(' > ')}';
  return '$book · ${s.gradeLabel}$unit · ${s.pageLabel}';
}

/// PDF 주소를 그 쪽으로 연다(기본 PDF 보기 프로그램).
Future<void> openUrlAtPage(String url, int page) async {
  final ok = await launchUrl(Uri.parse('$url#page=$page'), mode: LaunchMode.externalApplication);
  if (!ok) throw Exception('PDF를 열 프로그램을 찾지 못했습니다.');
}

/// 원본 PDF를 그 쪽으로 연다. 화면 초점·편집은 건드리지 않는다.
Future<void> openConceptSourceOriginal(BuildContext context, ConceptSourceRef s, {ConceptBookService? service}) async {
  try {
    final url = await (service ?? ConceptBookService())
        .originalUrl(academyId: s.academyId, bookId: s.bookId, gradeLabel: s.gradeLabel);
    await openUrlAtPage(url, s.rawPage);
  } catch (e) {
    if (context.mounted) showThinkSnack(context, '원본을 열지 못했습니다: $e', error: true);
  }
}

/// "출처 N개" 표시. 올리면 책·쪽이 보이고, 누르면 목록 창이 열린다(초점은 바꾸지 않는다).
class ConceptSourcesMark extends StatelessWidget {
  const ConceptSourcesMark({super.key, required this.controller, required this.concept});

  final ConceptLibraryController controller;
  final ConceptItem concept;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isSavedConcept(concept)) return const SizedBox.shrink();
        final err = controller.sourcesError(concept.id);
        final list = controller.sourcesOf(concept.id);
        if (err != null) {
          return Tooltip(
            message: '$err\n누르면 다시 읽습니다.',
            child: _chip('출처 읽지 못함', kThinkError, Icons.error_outline,
                onTap: () => unawaited(controller.loadSources(concept.id))),
          );
        }
        if (list == null) return _chip('출처 확인 중', kThinkHint, Icons.menu_book_outlined);
        if (list.isEmpty) {
          return Tooltip(
            message: '이 개념에 이은 교재 쪽이 없습니다. "개념책 불러오기"에서 쪽을 골라 이을 수 있습니다.',
            child: _chip('출처 없음', kThinkHint, Icons.menu_book_outlined),
          );
        }
        final lines = [
          for (final s in list.take(5)) conceptSourceLabel(s),
          if (list.length > 5) '외 ${list.length - 5}개'
        ];
        return Tooltip(
          message: '${lines.join('\n')}\n누르면 목록과 원본 열기가 나옵니다.',
          child: _chip('출처 ${list.length}개', kThinkLink, Icons.menu_book_outlined,
              onTap: () => showConceptSourcesDialog(context, controller: controller, concept: concept)),
        );
      },
    );
  }

  Widget _chip(String label, Color color, IconData icon, {VoidCallback? onTap}) {
    final body = Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        color: color.withValues(alpha: 0.10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(14), child: body),
    );
  }
}

Future<void> showConceptSourcesDialog(
  BuildContext context, {
  required ConceptLibraryController controller,
  required ConceptItem concept,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _ConceptSourcesDialog(controller: controller, concept: concept),
  );
}

class _ConceptSourcesDialog extends StatefulWidget {
  const _ConceptSourcesDialog({required this.controller, required this.concept});

  final ConceptLibraryController controller;
  final ConceptItem concept;

  @override
  State<_ConceptSourcesDialog> createState() => _ConceptSourcesDialogState();
}

class _ConceptSourcesDialogState extends State<_ConceptSourcesDialog> {
  late final ConceptEvidenceController _evidence = widget.controller.evidenceFor(widget.concept.id);

  /// 이 출처 목록으로 한 번 다시 읽었으면 또 읽지 않는다(어긋남이 남아도 되풀이하지 않게).
  String? _reloadedFor;

  @override
  void initState() {
    super.initState();
    unawaited(_evidence.load());
  }

  @override
  void dispose() {
    _evidence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final concept = widget.concept;
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text('출처 — ${conceptDisplayName(concept)}',
          style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 640,
        child: ListenableBuilder(
          listenable: Listenable.merge([controller, controller.statements, _evidence]),
          builder: (context, _) {
            final list = controller.sourcesOf(concept.id) ?? const <ConceptSourceRef>[];
            final statementsLoaded = controller.statements.loaded(concept.id);
            final signature = [
              for (final s in list)
                '${s.id}:${statementsLoaded ? controller.statements.statementOfSource(concept.id, s.id) : ''}'
            ].join(',');
            if (!_evidence.loading &&
                signature != _reloadedFor &&
                conceptEvidenceOutOfDate(_evidence.snapshot, list,
                    statementsLoaded ? (s) => controller.statements.statementOfSource(concept.id, s.id) : null)) {
              _reloadedFor = signature;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) unawaited(_evidence.load());
              });
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (list.isNotEmpty)
                  ConceptEvidenceProposeBar(
                      evidence: _evidence, statements: controller.statements, conceptId: concept.id),
                if (list.isEmpty)
                  const ConceptHint('이은 출처가 없습니다.')
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 460),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(color: kThinkBorder, height: 16),
                      itemBuilder: (context, i) =>
                          _SourceRow(controller: controller, source: list[i], evidence: _evidence),
                    ),
                  ),
                const SizedBox(height: 12),
                const ConceptHint('책 이름·쪽은 이을 때 저장된 교재 구조에서 가져온 값입니다. '
                    '원본은 PDF 보기 프로그램에서 그 쪽으로 열립니다. 근거 범위는 정한 것만 바뀌고, AI 제안은 받아들여야 저장됩니다.'),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.controller, required this.source, required this.evidence});

  final ConceptLibraryController controller;
  final ConceptSourceRef source;
  final ConceptEvidenceController evidence;

  @override
  Widget build(BuildContext context) {
    final s = source;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.bookName ?? '(책 이름을 볼 수 없음)',
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                [s.gradeLabel, if (s.unitPath.isNotEmpty) s.unitPath.join(' > ')].join(' · '),
                style: const TextStyle(color: kThinkSub, fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(s.pageLabel, style: const TextStyle(color: kThinkSub, fontSize: 12)),
              ConceptSourceStatementPicker(store: controller.statements, source: s),
              ConceptSourceEvidenceLine(evidence: evidence, source: s, sourceLabel: conceptSourceLabel(s)),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: () => unawaited(openConceptSourceOriginal(context, s)),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('원본 열기'),
          style: TextButton.styleFrom(foregroundColor: kThinkLink),
        ),
        IconButton(
          tooltip: '출처에서 빼기',
          onPressed: () => unawaited(_remove(context)),
          icon: const Icon(Icons.link_off, size: 18),
          color: kThinkHint,
        ),
      ],
    );
  }

  Future<void> _remove(BuildContext context) async {
    final ok = await confirmThink(
      context,
      title: '출처에서 빼기',
      message: '"${conceptSourceLabel(source)}"을(를) 이 개념의 출처에서 뺍니다. 교재와 개념은 그대로 남습니다.',
      confirmLabel: '빼기',
      destructive: true,
    );
    if (!ok) return;
    final problem = await controller.removeSource(source);
    if (problem != null && context.mounted) showThinkSnack(context, problem, error: true);
  }
}

/// 라이브러리 쪽 상세: 개념 트리 + 열어 둔 개념.
class LibraryDetailPane extends StatefulWidget {
  const LibraryDetailPane({
    super.key,
    required this.tree,
    required this.detail,
    this.badges = const [],
    this.actions = const [],
  });

  final Widget tree;
  final Widget detail;
  final List<Widget> badges;
  final List<Widget> actions;

  @override
  State<LibraryDetailPane> createState() => _LibraryDetailPaneState();
}

class _LibraryDetailPaneState extends State<LibraryDetailPane> {
  /// 요약으로 접혀 있어도 이 칸은 좁은 폭으로 다시 배치된다. 트리(펼친 폴더)·상세(스크롤)가 옮겨 가도 남게 붙잡아 둔다.
  final GlobalKey _treeKey = GlobalKey(debugLabel: 'libraryTree');
  final GlobalKey _detailKey = GlobalKey(debugLabel: 'libraryConcept');

  @override
  Widget build(BuildContext context) {
    final tree = KeyedSubtree(key: _treeKey, child: widget.tree);
    final detail = KeyedSubtree(key: _detailKey, child: widget.detail);
    return ThinkPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConceptPaneHeader(
            icon: Icons.account_tree_outlined,
            title: '개념 라이브러리',
            badges: widget.badges,
            actions: widget.actions,
          ),
          const Divider(color: kThinkBorder, height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 700) {
                  final detailWidth = (constraints.maxWidth * 0.42).clamp(300.0, 440.0);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: Padding(padding: const EdgeInsets.all(12), child: tree)),
                      const VerticalDivider(color: kThinkBorder, width: 1),
                      SizedBox(width: detailWidth, child: detail),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: Padding(padding: const EdgeInsets.all(12), child: tree)),
                    const Divider(color: kThinkBorder, height: 1),
                    Expanded(flex: 2, child: detail),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 열어 둔 개념: 내용, 출처 표시, 사용자가 이은 기준.
class ConceptDetailView extends StatefulWidget {
  const ConceptDetailView({
    super.key,
    required this.controller,
    required this.onEdit,
    required this.onPickForChat,
    this.topicOf,
    this.onChooseAnchor,
    this.onOpenConceptId,
    this.onBaseChanged,
  });

  final ConceptLibraryController controller;
  final void Function(ConceptItem concept) onEdit;
  final void Function(ConceptItem concept) onPickForChat;

  /// 기본 서술이 바뀌었을 때(수정안 확정 등) 개념을 다시 읽는다.
  final Future<void> Function(String conceptId)? onBaseChanged;

  /// 관계·검토 상대 개념을 연다. null이면 여는 버튼을 보이지 않는다.
  final ValueChanged<String>? onOpenConceptId;

  /// 같은 폴더 안 주제 묶음. null이면 묶음 칸을 보이지 않는다.
  final ConceptTopicInfo? Function(ConceptItem concept)? topicOf;
  final Future<void> Function(ConceptItem concept)? onChooseAnchor;

  @override
  State<ConceptDetailView> createState() => _ConceptDetailViewState();
}

class _ConceptDetailViewState extends State<ConceptDetailView> {
  final ScrollController _scroll = ScrollController();

  ConceptLibraryController get _c => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_c, _c.chat.pickedConcept, _c.statements.countsTick, _c.relations.openTick]),
      builder: (context, _) {
        final concept = _c.selectedConcept;
        if (concept == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '개념을 누르면 여기에서 내용·출처·이은 기준을 봅니다.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
              ),
            ),
          );
        }
        final saved = _c.isSavedConcept(concept);
        final picked = _c.chat.conceptId == concept.id;
        return Scrollbar(
          controller: _scroll,
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            children: [
              Text(conceptDisplayName(concept),
                  style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_c.conceptTypeOf(concept.id) != null)
                    Tooltip(
                      message: '개념 초안을 확정할 때 붙은 개념 유형입니다.',
                      child: ThinkBadge('유형: ${_c.conceptTypeOf(concept.id)}',
                          color: conceptTypeStyle(_c.conceptTypeOf(concept.id)).color),
                    )
                  else if (_c.conceptTypeFailed(concept.id))
                    const ThinkBadge('유형을 읽지 못함', color: kThinkError),
                  conceptKindBadge(concept),
                  if (concept.level != null) ThinkBadge('레벨 ${concept.level}'),
                  if ((_c.statements.statementCountOf(concept.id) ?? 0) > 0)
                    ThinkBadge('서술 ${_c.statements.statementCountOf(concept.id)! + 1}개', color: kThinkLink),
                  if (_c.statements.contentDraftOf(concept.id) != null)
                    const Tooltip(
                      message: '기본 서술 수정안이 저장되어 있습니다. 확정 전이라 기본 서술은 그대로입니다.',
                      child: ThinkBadge('수정안 있음', color: kThinkAccent),
                    ),
                  if (_c.relations.reviewOpen(concept.id))
                    const Tooltip(
                      message: '같은 개념인지 판단이 남아 있습니다. 아래 "다른 개념과의 관계"에서 판단합니다.',
                      child: ThinkBadge('검토 필요', color: kThinkAccent),
                    ),
                  ConceptSourcesMark(controller: _c, concept: concept),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (picked)
                    const ThinkBadge('Think 대화 참고 중', color: kThinkAccent)
                  else
                    TextButton.icon(
                      onPressed: saved ? () => widget.onPickForChat(concept) : null,
                      icon: const Icon(Icons.forum_outlined, size: 16),
                      label: const Text('Think 대화 참고로 선택'),
                      style: TextButton.styleFrom(foregroundColor: kThinkAccent, visualDensity: VisualDensity.compact),
                    ),
                  TextButton.icon(
                    onPressed: () => widget.onEdit(concept),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('수정'),
                    style: TextButton.styleFrom(foregroundColor: kThinkSub, visualDensity: VisualDensity.compact),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (saved)
                ConceptStatementSection(
                  controller: _c,
                  concept: concept,
                  onEditBase: () => widget.onEdit(concept),
                  onBaseChanged: widget.onBaseChanged,
                )
              else
                SelectionArea(
                  child: LatexTextRenderer(
                    concept.content,
                    dollarMath: true,
                    style: const TextStyle(color: kThinkSub, fontSize: 14, height: 1.6),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    blockVerticalPadding: 6,
                  ),
                ),
              if (saved) ...[
                const SizedBox(height: 16),
                const Divider(color: kThinkBorder, height: 1),
                const SizedBox(height: 12),
                ConceptRelationSection(controller: _c, concept: concept, onOpenConcept: widget.onOpenConceptId),
              ],
              if (saved && widget.topicOf != null) ..._topic(concept),
              const SizedBox(height: 16),
              const Divider(color: kThinkBorder, height: 1),
              const SizedBox(height: 12),
              _linkedCriteria(concept, saved),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _topic(ConceptItem concept) {
    final info = widget.topicOf!(concept);
    if (info == null) return const [];
    final anchor = info.anchor;
    Widget chipOf(ConceptItem c) => ConceptTypeChip(
          name: conceptDisplayName(c),
          style: conceptTypeStyle(info.typeOf[c.id]),
          onTap: () => _c.selectConcept(c),
        );
    return [
      const SizedBox(height: 16),
      const Divider(color: kThinkBorder, height: 1),
      const SizedBox(height: 12),
      ConceptSectionTitle(
        '주제 묶음',
        trailing: widget.onChooseAnchor == null || info.unavailable || !info.canChoose
            ? null
            : TextButton.icon(
                key: const ValueKey('concept-anchor-choose'),
                onPressed: () => unawaited(widget.onChooseAnchor!(concept)),
                icon: const Icon(Icons.hub_outlined, size: 16),
                label: const Text('바꾸기'),
                style: TextButton.styleFrom(foregroundColor: kThinkAccent, visualDensity: VisualDensity.compact),
              ),
      ),
      if (info.unavailable)
        const ConceptHint('묶음을 아직 읽을 수 없습니다. 유형 순서로만 보입니다.')
      else ...[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('붙은 개념', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
            if (anchor == null)
              const Text('없음 · 이 폴더에서 묶음의 첫 개념', style: TextStyle(color: kThinkHint, fontSize: 12))
            else
              chipOf(anchor),
          ],
        ),
        if (info.dependents.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('이 개념에 붙은 개념 ${info.dependents.length}',
                  style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              for (final d in info.dependents) chipOf(d),
            ],
          ),
        ],
      ],
    ];
  }

  Widget _linkedCriteria(ConceptItem concept, bool saved) {
    const title = '이은 정리 기준';
    if (!saved) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [ConceptSectionTitle(title), ConceptHint('저장 전 개념이라 기준을 이을 수 없습니다.')],
      );
    }
    final err = _c.linkedCriteriaError(concept.id);
    final ids = _c.linkedCriteriaOf(concept.id);
    final sel = _c.selectedCriterion;
    final selLinked = sel != null && (ids?.contains(sel.id) ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConceptSectionTitle(ids == null ? title : '$title (${ids.length})'),
        if (err != null)
          ThinkNotice(text: '이은 기준을 읽지 못했습니다: $err', color: kThinkError, icon: Icons.error_outline)
        else if (ids == null)
          const ConceptHint('이은 기준을 읽는 중입니다.')
        else if (ids.isEmpty)
          const Text('연결된 기준 없음', style: TextStyle(color: kThinkSub, fontSize: 13))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final id in ids)
                InputChip(
                  label: Text(_criterionChipLabel(id)),
                  labelStyle: const TextStyle(color: kThinkText, fontSize: 13),
                  backgroundColor: kThinkField,
                  side: const BorderSide(color: kThinkBorder),
                  tooltip: '정리 기준 쪽에서 열기',
                  onPressed: () => _c.openCriterion(id),
                  deleteIcon: const Icon(Icons.link_off, size: 16),
                  deleteButtonTooltipMessage: '연결 끊기',
                  onDeleted: () => _unlink(id, concept),
                ),
            ],
          ),
        const SizedBox(height: 8),
        if (sel == null)
          const ConceptHint('정리 기준을 고르면 이 개념에 그 기준을 이을 수 있습니다.')
        else if (_c.isLocal(sel.id))
          const ConceptHint('고른 기준은 아직 저장 전입니다. 초안을 저장한 뒤 이을 수 있습니다.')
        else if (selLinked)
          ConceptHint('고른 기준 "${criterionDisplayTitle(sel)}"과(와) 이미 이어져 있습니다.')
        else
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: ids == null ? null : () => _link(sel, concept),
              style: thinkOutlineButton(),
              icon: const Icon(Icons.link, size: 16),
              label: Text('고른 기준 "${criterionDisplayTitle(sel)}" 잇기', overflow: TextOverflow.ellipsis),
            ),
          ),
        const SizedBox(height: 8),
        const ConceptHint('사용자가 직접 이은 기준만 보입니다. 기준에 맞춰 검토했는지는 아직 기록하지 않습니다.'),
      ],
    );
  }

  String _criterionChipLabel(String id) {
    final c = _c.criterionById(id);
    if (c == null) return '(목록에 없는 기준)';
    return '${criterionDisplayTitle(c)} · ${c.confirmed ? '확정 v${c.version}' : '확정 전 초안'}';
  }

  Future<void> _link(ConceptCriterion c, ConceptItem concept) async {
    final problem = await _c.link(c.id, concept);
    if (!mounted) return;
    showThinkSnack(context, problem ?? '"${criterionDisplayTitle(c)}" 기준에 이었습니다.', error: problem != null);
  }

  Future<void> _unlink(String criterionId, ConceptItem concept) async {
    final c = _c.criterionById(criterionId);
    final ok = await confirmThink(
      context,
      title: '연결 끊기',
      message: '"${c == null ? '이 기준' : criterionDisplayTitle(c)}"과(와) 이 개념의 연결을 끊습니다. 개념과 기준은 그대로 남습니다.',
      confirmLabel: '끊기',
      destructive: true,
    );
    if (!ok) return;
    final problem = await _c.unlink(criterionId, concept.id);
    if (!mounted) return;
    if (problem != null) showThinkSnack(context, problem, error: true);
  }
}

/// 라이브러리 쪽 요약(기준을 크게 볼 때). 현재 선택한 개념과, 고른 기준에 실제로 이은 개념만 보인다.
class LibrarySummaryPane extends StatefulWidget {
  const LibrarySummaryPane({super.key, required this.controller, required this.onOpenConcept});

  final ConceptLibraryController controller;
  final void Function(String conceptId) onOpenConcept;

  @override
  State<LibrarySummaryPane> createState() => _LibrarySummaryPaneState();
}

class _LibrarySummaryPaneState extends State<LibrarySummaryPane> {
  final ScrollController _scroll = ScrollController();

  ConceptLibraryController get _c => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => ThinkPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConceptPaneHeader(
              icon: Icons.account_tree_outlined,
              title: '개념 라이브러리',
              onExpand: () => _c.setFocus(ConceptWorkspaceFocus.library),
            ),
            const Divider(color: kThinkBorder, height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scroll,
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(14),
                  children: [
                    ..._current(),
                    const SizedBox(height: 18),
                    ..._forCriterion(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _current() {
    final concept = _c.selectedConcept;
    final out = <Widget>[const ConceptSectionTitle('현재 선택한 개념')];
    if (concept == null) {
      out.add(const ConceptHint('라이브러리에서 개념을 누르면 여기에 요약이 보입니다.'));
      return out;
    }
    final sel = _c.selectedCriterion;
    final ids = _c.linkedCriteriaOf(concept.id);
    String? linkLine;
    if (sel != null && !_c.isLocal(sel.id) && ids != null) {
      linkLine = ids.contains(sel.id) ? '고른 기준과 이어져 있음' : '고른 기준과 잇지 않음';
    }
    out.add(Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _c.openConcept(concept),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(conceptDisplayName(concept),
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              conceptKindBadge(concept),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 84),
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: LatexTextRenderer(
                    concept.content,
                    dollarMath: true,
                    style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    blockVerticalPadding: 4,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ConceptSourcesMark(controller: _c, concept: concept),
                  if (linkLine != null) ConceptHint(linkLine),
                ],
              ),
            ],
          ),
        ),
      ),
    ));
    return out;
  }

  List<Widget> _forCriterion() {
    final sel = _c.selectedCriterion;
    final localSel = _c.selectedCriterionId != null && _c.isLocal(_c.selectedCriterionId!);
    final out = <Widget>[
      ConceptSectionTitle(sel == null ? '고른 기준에 이은 개념' : '"${criterionDisplayTitle(sel)}"에 이은 개념'),
    ];
    if (localSel) {
      out.add(const ConceptHint('고른 기준은 저장 전이라 이은 개념이 없습니다.'));
      return out;
    }
    if (sel == null) {
      out.add(const ConceptHint('정리 기준을 고르면 그 기준에 이은 개념이 보입니다.'));
      return out;
    }
    final err = _c.linkedConceptsError(sel.id);
    final list = _c.linkedConceptsOf(sel.id);
    if (err != null) {
      out.add(ThinkNotice(text: '이은 개념을 읽지 못했습니다: $err', color: kThinkError, icon: Icons.error_outline));
    } else if (list == null) {
      out.add(const ConceptHint('이은 개념을 읽는 중입니다.'));
    } else if (list.isEmpty) {
      out.add(const Text('연결된 개념 없음', style: TextStyle(color: kThinkSub, fontSize: 13)));
    } else {
      for (final x in list) {
        out.add(InkWell(
          onTap: () => widget.onOpenConcept(x.conceptId),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                Icon(
                  x.conceptId == _c.selectedConcept?.id ? Icons.radio_button_checked : Icons.circle_outlined,
                  size: 12,
                  color: x.conceptId == _c.selectedConcept?.id ? kThinkAccent : kThinkHint,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(x.name.isEmpty ? '(이름 없음)' : x.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kThinkText, fontSize: 13)),
                ),
                if (x.kind != null) ThinkBadge(x.kind == ConceptKind.definition ? '정의' : '정리'),
              ],
            ),
          ),
        ));
      }
    }
    out.add(const SizedBox(height: 8));
    out.add(const ConceptHint('사용자가 직접 이은 개념만 보입니다. 이 기준으로 개념을 검토했는지는 아직 기록하지 않습니다.'));
    return out;
  }
}
