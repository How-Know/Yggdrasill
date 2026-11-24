import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/skill/thinking_foundation_screen.dart';
import '../screens/think/think_style.dart';
import '../services/thinking_foundation_service.dart';

/// 문항에 연결할 '사고의 토대(C)' 역량 다중 선택·관련도·이유·관찰 가능성 편집 다이얼로그.
/// 문항검수(스테이징 저장)와 문제은행(직접 저장) 양쪽에서 함께 사용한다.
Future<List<QuestionFoundationLink>?> showQuestionFoundationLinksDialog(
  BuildContext context, {
  required String questionLabel,
  required List<QuestionFoundationLink> initialLinks,
  required Future<void> Function(List<QuestionFoundationLink> links) onSave,
  String? saveHint,
  ThinkingFoundationService? service,
}) {
  return showDialog<List<QuestionFoundationLink>>(
    context: context,
    builder: (ctx) => _QuestionFoundationLinksDialog(
      questionLabel: questionLabel,
      initialLinks: initialLinks,
      onSave: onSave,
      saveHint: saveHint,
      service: service,
    ),
  );
}

class _LinkDraft {
  _LinkDraft({
    required this.item,
    required this.relevanceLevel,
    required String rationale,
    required String observability,
  })  : rationaleCtrl = TextEditingController(text: rationale),
        observability = item.isAttitudeGroup && observability == 'static_item'
            ? 'process_required'
            : observability;

  final ThinkingFoundationItem item;
  String relevanceLevel;
  String observability;
  final TextEditingController rationaleCtrl;

  QuestionFoundationLink toLink() => QuestionFoundationLink(
        foundationId: item.id,
        code: item.code,
        groupCode: item.groupCode,
        groupTitle: item.groupTitle,
        title: item.title,
        relevanceLevel: relevanceLevel,
        rationale: rationaleCtrl.text.trim(),
        observability: item.isAttitudeGroup && observability == 'static_item'
            ? 'process_required'
            : observability,
      );

  void dispose() => rationaleCtrl.dispose();
}

class _QuestionFoundationLinksDialog extends StatefulWidget {
  const _QuestionFoundationLinksDialog({
    required this.questionLabel,
    required this.initialLinks,
    required this.onSave,
    this.saveHint,
    this.service,
  });

  final String questionLabel;
  final List<QuestionFoundationLink> initialLinks;
  final Future<void> Function(List<QuestionFoundationLink> links) onSave;
  final String? saveHint;
  final ThinkingFoundationService? service;

  @override
  State<_QuestionFoundationLinksDialog> createState() => _QuestionFoundationLinksDialogState();
}

class _QuestionFoundationLinksDialogState extends State<_QuestionFoundationLinksDialog> {
  late final ThinkingFoundationService _svc = widget.service ?? ThinkingFoundationService();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String _search = '';

  List<ThinkingFoundationItem> _catalog = const [];
  final Map<String, _LinkDraft> _draftsByFoundationId = <String, _LinkDraft>{};
  String? _inspectingFoundationId;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCatalog());
  }

  @override
  void dispose() {
    for (final d in _draftsByFoundationId.values) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _svc.fetchAll();
      if (!mounted) return;
      final byId = {for (final x in list) x.id: x};
      final byCode = {for (final x in list) x.code: x};
      for (final d in _draftsByFoundationId.values) {
        d.dispose();
      }
      _draftsByFoundationId.clear();

      for (final link in widget.initialLinks) {
        final target = byId[link.foundationId] ?? byCode[link.code];
        if (target == null) continue;
        _draftsByFoundationId[target.id] = _LinkDraft(
          item: target,
          relevanceLevel: link.relevanceLevel,
          rationale: link.rationale,
          observability: link.observability,
        );
      }

      setState(() {
        _catalog = list.where((x) => x.isActive || _draftsByFoundationId.containsKey(x.id)).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '사고의 토대 목록을 불러오지 못했습니다: $e';
      });
    }
  }

  void _toggleFoundation(ThinkingFoundationItem item) {
    setState(() {
      final existing = _draftsByFoundationId.remove(item.id);
      if (existing != null) {
        existing.dispose();
      } else {
        _draftsByFoundationId[item.id] = _LinkDraft(
          item: item,
          relevanceLevel: 'core',
          rationale: '',
          observability: item.isAttitudeGroup ? 'process_required' : 'static_item',
        );
      }
    });
  }

  Future<void> _submit() async {
    final ordered = <QuestionFoundationLink>[
      for (final item in _catalog)
        if (_draftsByFoundationId.containsKey(item.id)) _draftsByFoundationId[item.id]!.toLink(),
    ];
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(ordered);
      if (!mounted) return;
      Navigator.pop(context, ordered);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '저장하지 못했습니다: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inspected = _inspectingFoundationId == null
        ? null
        : _catalog.where((x) => x.id == _inspectingFoundationId).firstOrNull;

    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      title: Row(
        children: [
          const Icon(Icons.compass_calibration_outlined, size: 20, color: kThinkAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${widget.questionLabel} · 사고의 토대(C) 연결',
              style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
          ThinkBadge('선택 ${_draftsByFoundationId.length}개', color: kThinkAccent),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '닫기',
            onPressed: _saving ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close, size: 18, color: kThinkSub),
          ),
        ],
      ),
      content: SizedBox(
        width: 960,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ThinkNotice(
              text:
                  '모든 문항에 억지로 부여하지 않고, 이 문항에서 구체적으로 관련성을 설명할 수 있는 역량만 연결합니다. '
                  'C3(탐구의 태도)는 문항 내용만으로 직접 평가하지 않으며 풀이 과정·수업 활동 관찰이 필요합니다.'
                  '${widget.saveHint != null ? ' ${widget.saveHint}' : ''}',
              color: kThinkLink,
              icon: Icons.info_outline,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: kThinkAccent))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 좌측: C1·C2·C3 12개 선택 트리
                        SizedBox(
                          width: 340,
                          child: ThinkPanel(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  height: 36,
                                  child: TextField(
                                    onChanged: (v) => setState(() => _search = v),
                                    style: const TextStyle(color: kThinkText, fontSize: 13),
                                    decoration: thinkInputDecoration(
                                      hint: '이름, 정의, 키워드, 예시 검색...',
                                      dense: true,
                                      prefixIcon: const Icon(Icons.search, size: 17, color: kThinkSub),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Expanded(
                                  child: ListView(
                                    children: [
                                      for (final g in kThinkingFoundationGroups) ...[
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                                          child: Text(
                                            '${g.code}. ${g.title}',
                                            style: const TextStyle(
                                              color: kThinkSub,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                        for (final item in _catalog.where(
                                          (x) => x.groupCode == g.code && x.matchesQuery(_search),
                                        ))
                                          _buildCatalogTile(item),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // 우측: 선택된 연결 편집 또는 역량 상세 열람
                        Expanded(
                          child: ThinkPanel(
                            padding: const EdgeInsets.all(14),
                            child: inspected != null
                                ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          TextButton.icon(
                                            onPressed: () => setState(() => _inspectingFoundationId = null),
                                            style: TextButton.styleFrom(foregroundColor: kThinkAccent),
                                            icon: const Icon(Icons.arrow_back, size: 16),
                                            label: const Text('연결 목록으로 돌아가기'),
                                          ),
                                          const Spacer(),
                                          OutlinedButton.icon(
                                            onPressed: () => _toggleFoundation(inspected),
                                            style: thinkOutlineButton().copyWith(
                                              visualDensity: VisualDensity.compact,
                                            ),
                                            icon: Icon(
                                              _draftsByFoundationId.containsKey(inspected.id)
                                                  ? Icons.remove_circle_outline
                                                  : Icons.add_circle_outline,
                                              size: 16,
                                              color: kThinkAccent,
                                            ),
                                            label: Text(
                                              _draftsByFoundationId.containsKey(inspected.id)
                                                  ? '연결 해제'
                                                  : '이 문항에 연결',
                                            ),
                                          ),
                                        ],
                                      ),
                                      const Divider(color: kThinkBorder, height: 12),
                                      Expanded(child: ThinkingFoundationDetailBody(item: inspected)),
                                    ],
                                  )
                                : _buildSelectedLinksEditor(),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (_draftsByFoundationId.isNotEmpty)
          TextButton(
            onPressed: _saving
                ? null
                : () => setState(() {
                      for (final d in _draftsByFoundationId.values) {
                        d.dispose();
                      }
                      _draftsByFoundationId.clear();
                    }),
            child: const Text('모두 해제', style: TextStyle(color: kThinkError)),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton.icon(
          onPressed: _loading || _saving ? null : () => unawaited(_submit()),
          style: thinkPrimaryButton(),
          icon: _saving
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white),
                )
              : const Icon(Icons.save_outlined, size: 17),
          label: const Text('연결 저장'),
        ),
      ],
    );
  }

  Widget _buildCatalogTile(ThinkingFoundationItem item) {
    final checked = _draftsByFoundationId.containsKey(item.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: checked ? kThinkAccent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: checked ? kThinkAccent.withValues(alpha: 0.55) : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _toggleFoundation(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 18,
                color: checked ? kThinkAccent : kThinkSub,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item.code}  ${item.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kThinkText,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      item.definition,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kThinkHint, fontSize: 11),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '역량 상세 보기',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _inspectingFoundationId = item.id),
                icon: const Icon(Icons.menu_book_outlined, size: 15, color: kThinkSub),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedLinksEditor() {
    final selectedItems = [
      for (final item in _catalog)
        if (_draftsByFoundationId.containsKey(item.id)) item,
    ];
    if (selectedItems.isEmpty) {
      return const Center(
        child: Text(
          '연결된 사고의 토대(C) 태그가 없습니다.\n왼쪽 목록에서 이 문항과 직접 관련된 역량이 있을 때만 선택하세요.',
          textAlign: TextAlign.center,
          style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
        ),
      );
    }

    return ListView.separated(
      itemCount: selectedItems.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, idx) {
        final item = selectedItems[idx];
        final draft = _draftsByFoundationId[item.id]!;
        final obsOptions = <DropdownMenuItem<String>>[
          if (!item.isAttitudeGroup)
            const DropdownMenuItem(value: 'static_item', child: Text('정적 문항 관찰 가능')),
          const DropdownMenuItem(value: 'process_required', child: Text('풀이 과정 필요')),
          const DropdownMenuItem(value: 'class_activity', child: Text('수업 활동 필요')),
        ];

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kThinkBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kThinkBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ThinkBadge(item.code, color: kThinkAccent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.title,
                      style: const TextStyle(color: kThinkText, fontSize: 13.5, fontWeight: FontWeight.w800),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() => _inspectingFoundationId = item.id),
                    style: TextButton.styleFrom(
                      foregroundColor: kThinkLink,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.menu_book_outlined, size: 15),
                    label: const Text('상세', style: TextStyle(fontSize: 12)),
                  ),
                  IconButton(
                    tooltip: '연결 해제',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _toggleFoundation(item),
                    icon: const Icon(Icons.close, size: 17, color: kThinkSub),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('관련 정도', style: TextStyle(color: kThinkSub, fontSize: 11.5)),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          initialValue: draft.relevanceLevel,
                          dropdownColor: kThinkPanel,
                          style: const TextStyle(color: kThinkText, fontSize: 12.5),
                          decoration: thinkInputDecoration(dense: true),
                          items: const [
                            DropdownMenuItem(value: 'core', child: Text('핵심')),
                            DropdownMenuItem(value: 'supplementary', child: Text('보조')),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => draft.relevanceLevel = v);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.isAttitudeGroup ? '관찰 가능성 (C3 정적 제외)' : '관찰 가능성',
                          style: const TextStyle(color: kThinkSub, fontSize: 11.5),
                        ),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          initialValue: draft.observability,
                          dropdownColor: kThinkPanel,
                          style: const TextStyle(color: kThinkText, fontSize: 12.5),
                          decoration: thinkInputDecoration(dense: true),
                          items: obsOptions,
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => draft.observability = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('관련 이유 (문항과의 구체적 연결 근거)', style: TextStyle(color: kThinkSub, fontSize: 11.5)),
              const SizedBox(height: 4),
              TextField(
                controller: draft.rationaleCtrl,
                minLines: 1,
                maxLines: 2,
                style: const TextStyle(color: kThinkText, fontSize: 12.5, height: 1.35),
                decoration: thinkInputDecoration(
                  hint: '예: 분모가 0이 되지 않는 조건을 끝까지 유지해야 무연근을 걸러낼 수 있음',
                  dense: true,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
