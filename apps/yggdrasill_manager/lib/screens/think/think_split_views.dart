import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/think/think_models.dart';
import '../../services/think/think_tree.dart';
import 'think_code_views.dart';
import 'think_style.dart';
import 'think_tree_dialogs.dart';

// 대화 나누기: 요약 다섯 칸, 고치기 창, 나눈 대화 위쪽 안내, 기능 상태 줄.
// 설계: docs/architecture/ai-think-actions.md §7

const String kThinkUnfiledLabel = '미분류 (정리 안 됨)';

/// 다섯 칸을 항상 보여 주고, 빈 칸은 "없음"으로 적는다(확정한 것이 없으면 없다고 보이게).
class ThinkSplitSummaryView extends StatelessWidget {
  const ThinkSplitSummaryView({super.key, required this.summary});

  final ThinkSplitSummary summary;

  @override
  Widget build(BuildContext context) {
    Widget text(String v) => v.isEmpty
        ? const Text('없음', style: TextStyle(color: kThinkHint, fontSize: 13))
        : SelectableText(v, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5));
    Widget list(List<String> v) =>
        v.isEmpty ? const Text('없음', style: TextStyle(color: kThinkHint, fontSize: 13)) : thinkCodeBullets(v);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        thinkCodeLabel('목적'),
        text(summary.purpose),
        thinkCodeLabel('이어받을 배경'),
        text(summary.background),
        thinkCodeLabel('사용자가 확정한 사항'),
        list(summary.decided),
        thinkCodeLabel('미결정 사항'),
        list(summary.open),
        thinkCodeLabel('다음 할 일'),
        list(summary.next),
      ],
    );
  }
}

String thinkSplitFolderLabel(ThinkTree tree, String? folderId, {String fallbackPath = ''}) {
  if (folderId == null) return kThinkUnfiledLabel;
  if (tree.byId[folderId] != null) return tree.folderPath(folderId);
  return fallbackPath.isEmpty ? '(없어진 폴더)' : '$fallbackPath (없어진 폴더)';
}

class ThinkSplitEdit {
  const ThinkSplitEdit({required this.title, required this.folderId, required this.summary});

  final String title;

  /// null이면 미분류.
  final String? folderId;
  final ThinkSplitSummary summary;

  Map<String, dynamic> toOverrides() => {'title': title, 'folder_id': folderId, 'summary': summary.toJson()};
}

/// 나누기 전에 제목·폴더·요약을 고친다. 확인하면 고친 내용으로 바로 나눈다.
class ThinkSplitEditDialog extends StatefulWidget {
  const ThinkSplitEditDialog({
    super.key,
    required this.title,
    required this.folderId,
    required this.summary,
    required this.tree,
    this.confirmLabel = '나눠서 이어가기',
  });

  final String title;
  final String? folderId;
  final ThinkSplitSummary summary;
  final ThinkTree tree;
  final String confirmLabel;

  static Future<ThinkSplitEdit?> show(
    BuildContext context, {
    required String title,
    required String? folderId,
    required ThinkSplitSummary summary,
    required ThinkTree tree,
    String confirmLabel = '나눠서 이어가기',
  }) =>
      showDialog<ThinkSplitEdit>(
        context: context,
        builder: (_) => ThinkSplitEditDialog(
          title: title,
          folderId: folderId,
          summary: summary,
          tree: tree,
          confirmLabel: confirmLabel,
        ),
      );

  @override
  State<ThinkSplitEditDialog> createState() => _ThinkSplitEditDialogState();
}

class _ThinkSplitEditDialogState extends State<ThinkSplitEditDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.title);
  late final TextEditingController _purpose = TextEditingController(text: widget.summary.purpose);
  late final TextEditingController _background = TextEditingController(text: widget.summary.background);
  late final TextEditingController _decided = TextEditingController(text: widget.summary.decided.join('\n'));
  late final TextEditingController _open = TextEditingController(text: widget.summary.open.join('\n'));
  late final TextEditingController _next = TextEditingController(text: widget.summary.next.join('\n'));
  late String? _folderId = widget.folderId;

  @override
  void dispose() {
    for (final c in [_title, _purpose, _background, _decided, _open, _next]) {
      c.dispose();
    }
    super.dispose();
  }

  static List<String> _lines(TextEditingController c) => [
        for (final raw in c.text.split('\n'))
          if (raw.trim().replaceFirst(RegExp(r'^[·•\-*]\s*'), '').isNotEmpty)
            raw.trim().replaceFirst(RegExp(r'^[·•\-*]\s*'), ''),
      ];

  bool get _valid => _title.text.trim().isNotEmpty && _purpose.text.trim().isNotEmpty;

  void _submit() {
    if (!_valid) return;
    Navigator.pop(
      context,
      ThinkSplitEdit(
        title: _title.text.trim(),
        folderId: _folderId,
        summary: ThinkSplitSummary(
          purpose: _purpose.text.trim(),
          background: _background.text.trim(),
          decided: _lines(_decided),
          open: _lines(_open),
          next: _lines(_next),
        ),
      ),
    );
  }

  Future<void> _pickFolder() async {
    final picked = await showThinkFolderPicker(
      context,
      tree: widget.tree,
      currentParentId: _folderId,
      allowRoot: false,
      title: '새 대화를 넣을 폴더',
    );
    if (picked == null || picked == kThinkRootFolder || !mounted) return;
    setState(() => _folderId = picked);
  }

  Widget _field(TextEditingController c, String label, {int minLines = 1, int maxLines = 4, int? maxLength}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          minLines: minLines,
          maxLines: maxLines,
          inputFormatters: maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)],
          style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
          decoration: thinkInputDecoration(label: label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('나눌 내용 고치기', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(_title, '새 대화 제목', maxLines: 1, maxLength: 120),
              const Text('들어갈 폴더', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(_folderId == null ? Icons.inbox_outlined : Icons.folder_outlined, size: 16, color: kThinkSub),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      thinkSplitFolderLabel(widget.tree, _folderId),
                      style: const TextStyle(color: kThinkText, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: _pickFolder,
                    child: const Text('폴더 고르기', style: TextStyle(color: kThinkLink)),
                  ),
                  if (_folderId != null)
                    TextButton(
                      onPressed: () => setState(() => _folderId = null),
                      child: const Text('미분류로', style: TextStyle(color: kThinkSub)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _field(_purpose, '목적 (필수)', maxLines: 3, maxLength: 2000),
              _field(_background, '이어받을 배경', minLines: 2, maxLines: 6, maxLength: 4000),
              _field(_decided, '사용자가 확정한 사항 (한 줄에 하나, 12줄까지)', minLines: 2, maxLines: 6),
              _field(_open, '미결정 사항 (한 줄에 하나, 12줄까지)', minLines: 2, maxLines: 6),
              _field(_next, '다음 할 일 (한 줄에 하나, 12줄까지)', minLines: 2, maxLines: 6),
              const Text(
                '"사용자가 확정한 사항"에는 실제로 정한 것만 적어 주세요. Think의 제안은 미결정 사항이나 다음 할 일에 둡니다. '
                '요약은 새 대화에서 참고 자료로만 쓰고 기억으로 저장하지 않습니다.',
                style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_title, _purpose]),
          builder: (context, _) => ElevatedButton.icon(
            onPressed: _valid ? _submit : null,
            style: thinkPrimaryButton(),
            icon: const Icon(Icons.call_split, size: 16),
            label: Text(widget.confirmLabel),
          ),
        ),
      ],
    );
  }
}

/// 나눠 온 대화의 위쪽 안내. 방금 나눴으면 요약을 펼쳐 보여 주고, 그 뒤로는 접어 둔다.
class ThinkSplitBanner extends StatefulWidget {
  const ThinkSplitBanner({super.key, required this.detail, required this.justSplit, this.onOpenOriginal});

  final ThinkConversationDetail detail;
  final bool justSplit;

  /// 원본 대화가 지워졌으면 null.
  final VoidCallback? onOpenOriginal;

  @override
  State<ThinkSplitBanner> createState() => _ThinkSplitBannerState();
}

class _ThinkSplitBannerState extends State<ThinkSplitBanner> {
  late bool _open = widget.justSplit;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ThinkSplitBanner old) {
    super.didUpdateWidget(old);
    if (old.detail.id != widget.detail.id || (widget.justSplit && !old.justSplit)) _open = widget.justSplit;
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.detail.splitSummary;
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kThinkQuote,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.call_split, size: 16, color: kThinkAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.justSplit ? '새 대화로 나눴습니다. 원본은 그대로 남아 있습니다.' : '앞 대화에서 나눠 온 대화입니다.',
                  style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              if (summary != null)
                TextButton(
                  onPressed: () => setState(() => _open = !_open),
                  child: Text(_open ? '요약 접기' : '요약 보기', style: const TextStyle(color: kThinkSub)),
                ),
              if (widget.onOpenOriginal != null)
                TextButton.icon(
                  onPressed: widget.onOpenOriginal,
                  icon: const Icon(Icons.subdirectory_arrow_left, size: 16, color: kThinkLink),
                  label: const Text('원본 대화로 가기', style: TextStyle(color: kThinkLink)),
                )
              else
                const Text('원본 대화는 지워졌습니다', style: TextStyle(color: kThinkHint, fontSize: 12)),
            ],
          ),
          if (_open && summary != null) ...[
            // 요약이 길면 잘린 채로 보이므로 스크롤 막대를 늘 보인다. 데스크톱 기본 막대는 겹치지 않게 끈다.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.only(right: 14),
                    child: ThinkSplitSummaryView(summary: summary),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '이번 질문과 답변만 복사했습니다. 작업 카드·코드 요청·실행 기록은 원본 대화에 남아 있습니다. '
              '이 요약은 이 대화에서 Think가 참고하는 자료이고, 기억으로 저장되지 않습니다.',
              style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}

String thinkFeatureHeadline(ThinkFeatureStatus f) => switch (f.state) {
      ThinkFeatureState.ready => '사용 가능',
      ThinkFeatureState.dbRequired || ThinkFeatureState.appUpdateRequired => '준비 필요',
      ThinkFeatureState.unknown || ThinkFeatureState.edgeMissing => '확인 불가',
    };

String thinkFeatureReason(ThinkFeatureStatus f) => switch (f.state) {
      ThinkFeatureState.ready => '주제가 바뀌면 Think가 카드로 제안하고, 승인할 때만 새 대화를 만듭니다.',
      ThinkFeatureState.dbRequired =>
        'DB 반영 필요 — 운영 DB에 마이그레이션 20261009100000_ai_think_conversation_split.sql이 아직 없습니다.',
      ThinkFeatureState.appUpdateRequired => '앱 업데이트 필요 — 이 앱이 나누기 카드를 처리한다고 알리지 않았습니다.',
      ThinkFeatureState.unknown => '서버가 DB 준비 여부를 확인하지 못했습니다. 확인되기 전에는 쓰지 않습니다.',
      ThinkFeatureState.edgeMissing => 'Edge 배포 필요 — 연결된 ai_think가 기능 상태를 보내지 않는 이전 버전입니다.',
    };

String thinkRolesFeatureReason(ThinkFeatureStatus f) => switch (f.state) {
      ThinkFeatureState.ready => '대화마다 역할을 고르고, 역할에 맞는 기억·연결한 자료만 Think에 보냅니다.',
      ThinkFeatureState.dbRequired =>
        'DB 반영 필요 — 운영 DB에 마이그레이션 20261010160000_ai_think_roles.sql이 아직 없습니다. 그동안 총괄로 답하고 부서 기억은 쓰지 않습니다.',
      ThinkFeatureState.appUpdateRequired => '앱 업데이트 필요 — 이 앱이 역할 기능을 처리한다고 알리지 않았습니다.',
      ThinkFeatureState.unknown => '서버가 DB 준비 여부를 확인하지 못했습니다. 확인되기 전에는 쓰지 않습니다.',
      ThinkFeatureState.edgeMissing => 'Edge 배포 필요 — 연결된 ai_think가 역할 기능을 모르는 이전 버전입니다.',
    };

Color thinkFeatureColor(ThinkFeatureStatus f) => switch (f.state) {
      ThinkFeatureState.ready => kThinkSuccess,
      ThinkFeatureState.dbRequired || ThinkFeatureState.appUpdateRequired => kThinkLink,
      ThinkFeatureState.unknown || ThinkFeatureState.edgeMissing => kThinkError,
    };

/// "대화 나누기: 사용 가능/준비 필요/확인 불가"와 이유. 서버가 요청마다 계산한 값을 그대로 보여 준다.
class ThinkFeatureStatusView extends StatelessWidget {
  const ThinkFeatureStatusView({
    super.key,
    required this.feature,
    this.dbError,
    this.detailed = false,
    this.label = '대화 나누기',
    this.reason = thinkFeatureReason,
  });

  final ThinkFeatureStatus feature;
  final String? dbError;
  final String label;
  final String Function(ThinkFeatureStatus) reason;

  /// 버전과 DB 확인 오류까지 보여 준다(연결 상태 창).
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    final f = feature;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 8, color: thinkFeatureColor(f)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$label: ${thinkFeatureHeadline(f)}',
                style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(reason(f), style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5)),
        if (detailed && f.state != ThinkFeatureState.edgeMissing) ...[
          const SizedBox(height: 4),
          Text(
            '버전 · Edge ${f.edge} · DB ${f.db ?? '확인 못 함'} · 앱 ${f.app}',
            style: const TextStyle(color: kThinkHint, fontSize: 11),
          ),
        ],
        if (detailed && dbError != null) ...[
          const SizedBox(height: 4),
          SelectableText(
            'DB 확인 오류: ${dbError!.replaceAll(RegExp(r'https?://\S+'), '[URL]')}',
            style: const TextStyle(color: kThinkHint, fontSize: 11, height: 1.4),
          ),
        ],
      ],
    );
  }
}
