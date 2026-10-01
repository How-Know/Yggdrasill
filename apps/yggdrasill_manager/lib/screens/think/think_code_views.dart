import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/think/think_code_models.dart';
import 'think_markdown.dart';
import 'think_style.dart';

// 코드 조사·수정 결과를 그리는 위젯. 채팅 카드와 '전체 코드 요청' 창이 함께 쓴다.

Color thinkCodeStatusColor(ThinkCodeStatus s) => switch (s) {
      ThinkCodeStatus.draft => kThinkSub,
      ThinkCodeStatus.queued ||
      ThinkCodeStatus.followupQueued ||
      ThinkCodeStatus.applyQueued ||
      ThinkCodeStatus.revertQueued =>
        kThinkBlue,
      ThinkCodeStatus.running || ThinkCodeStatus.applying || ThinkCodeStatus.reverting => kThinkAccent,
      ThinkCodeStatus.ready || ThinkCodeStatus.applied => kThinkSuccess,
      ThinkCodeStatus.needsReview => kThinkLink,
      ThinkCodeStatus.failed || ThinkCodeStatus.applyFailed || ThinkCodeStatus.revertFailed => kThinkError,
      ThinkCodeStatus.cancelled || ThinkCodeStatus.reverted => kThinkHint,
    };

Color _riskColor(String risk) => switch (risk) {
      'low' => kThinkSuccess,
      'high' => kThinkError,
      _ => kThinkLink,
    };

String thinkDuration(int? ms) {
  if (ms == null) return '-';
  final s = (ms / 1000).round();
  return s < 60 ? '$s초' : '${s ~/ 60}분 ${s % 60}초';
}

Widget thinkCodeLabel(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(text, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
    );

Widget thinkCodeBullets(List<String> items, {Color color = kThinkText, bool mono = false}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SelectableText(
              mono ? t : '· $t',
              style: TextStyle(
                color: color,
                fontSize: mono ? 12 : 13,
                height: 1.5,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
      ],
    );

class ThinkCodeSection extends StatelessWidget {
  const ThinkCodeSection({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: kThinkBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(title, style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w800)),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// 제목만 있고 누르면 펼치는 칸. 테두리 없이 쓴다.
class ThinkCodeExpansion extends StatelessWidget {
  const ThinkCodeExpansion({super.key, required this.title, required this.children, this.initiallyExpanded = false, this.trailing});

  final String title;
  final List<Widget> children;
  final bool initiallyExpanded;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        iconColor: kThinkSub,
        collapsedIconColor: kThinkSub,
        trailing: trailing,
        title: Text(title, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
        children: children,
      ),
    );
  }
}

/// 요청 내용. 수정 모드는 '할 일'을, 조사 모드는 '확인할 질문'을 보여 준다.
class ThinkCodeSpecView extends StatelessWidget {
  const ThinkCodeSpecView({super.key, required this.spec, this.mode = ThinkCodeMode.investigate, this.showGoal = true});

  final ThinkCodeSpec spec;
  final ThinkCodeMode mode;
  final bool showGoal;

  @override
  Widget build(BuildContext context) {
    final s = spec;
    final change = mode == ThinkCodeMode.change;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showGoal) SelectableText(s.goal, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
        if (change && s.instructions.isNotEmpty) ...[thinkCodeLabel('할 일'), thinkCodeBullets(s.instructions)],
        if (s.questions.isNotEmpty) ...[thinkCodeLabel('확인할 질문'), thinkCodeBullets(s.questions)],
        thinkCodeLabel(change ? '고칠 범위' : '우선 볼 폴더'),
        s.focusPaths.isEmpty
            ? const Text('저장소 전체', style: TextStyle(color: kThinkHint, fontSize: 13))
            : thinkCodeBullets(s.focusPaths, color: kThinkLink),
        if (s.constraints.isNotEmpty) ...[thinkCodeLabel('지켜야 할 제약'), thinkCodeBullets(s.constraints)],
        if (s.doNot.isNotEmpty) ...[thinkCodeLabel(change ? '하지 말 것' : '제안하지 말 것'), thinkCodeBullets(s.doNot)],
        if (s.background.isNotEmpty)
          ThinkCodeExpansion(
            title: '배경',
            children: [SelectableText(s.background, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5))],
          ),
      ],
    );
  }
}

/// 작업자가 정리한 결과(JSON). 조사 모드와 수정 모드의 칸이 다르다.
class ThinkCodeResultView extends StatelessWidget {
  const ThinkCodeResultView({super.key, required this.result, this.mode = ThinkCodeMode.investigate});

  final ThinkCodeResult result;
  final ThinkCodeMode mode;

  @override
  Widget build(BuildContext context) {
    final res = result;
    final change = mode == ThinkCodeMode.change;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!change) ...[
          Row(children: [ThinkBadge(kThinkFeasibilityLabels[res.feasibility] ?? res.feasibility, color: kThinkAccent)]),
          const SizedBox(height: 8),
        ],
        ThinkMarkdown(res.summary, fontSize: 13),
        if (res.changes.isNotEmpty) ...[
          thinkCodeLabel('바꾼 내용'),
          for (final c in res.changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (c.path.isNotEmpty)
                    SelectableText(
                      c.path,
                      style: const TextStyle(color: kThinkLink, fontSize: 12, fontFamily: 'monospace', height: 1.5),
                    ),
                  if (c.what.isNotEmpty)
                    SelectableText(c.what, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
                ],
              ),
            ),
        ],
        if (res.answers.isNotEmpty) ...[
          thinkCodeLabel('질문별 답'),
          for (final a in res.answers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (a.question.isNotEmpty)
                    Text(a.question, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                  SelectableText(a.answer, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
                ],
              ),
            ),
        ],
        if (res.findings.isNotEmpty) ...[
          thinkCodeLabel('찾은 것'),
          for (final f in res.findings)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText('· ${f.point}', style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5)),
                  for (final e in f.evidence)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: SelectableText(
                        e.label,
                        style: const TextStyle(color: kThinkLink, fontSize: 12, fontFamily: 'monospace', height: 1.5),
                      ),
                    ),
                ],
              ),
            ),
        ],
        if (res.proposals.isNotEmpty) ...[
          thinkCodeLabel('수정 제안 (적용하지 않음)'),
          for (final p in res.proposals)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          p.title.isEmpty ? '제안' : p.title,
                          style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ThinkBadge('위험 ${kThinkRiskLabels[p.risk] ?? p.risk}', color: _riskColor(p.risk)),
                    ],
                  ),
                  if (p.change.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ThinkMarkdown(p.change, fontSize: 13),
                  ],
                  if (p.files.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      p.files.join('\n'),
                      style: const TextStyle(color: kThinkLink, fontSize: 12, fontFamily: 'monospace', height: 1.5),
                    ),
                  ],
                ],
              ),
            ),
        ],
        if (res.checks.isNotEmpty) ...[thinkCodeLabel('적용 뒤 돌려 볼 검사'), thinkCodeBullets(res.checks, mono: true)],
        if (res.risks.isNotEmpty) ...[thinkCodeLabel('위험·주의'), thinkCodeBullets(res.risks)],
        if (res.questionsForThink.isNotEmpty) ...[
          thinkCodeLabel('Think에게 되묻는 질문'),
          thinkCodeBullets(res.questionsForThink, color: kThinkSub),
        ],
      ],
    );
  }
}

/// 한 회차의 결과·원문·실행 정보. 수정 모드면 diff도 함께 보여 준다.
class ThinkCodeRoundView extends StatelessWidget {
  const ThinkCodeRoundView({super.key, required this.round, this.numbered = false, this.mode = ThinkCodeMode.investigate});

  final ThinkCodeRound round;
  final bool numbered;
  final ThinkCodeMode mode;

  @override
  Widget build(BuildContext context) {
    final res = round.result;
    final change = mode == ThinkCodeMode.change;
    final meta = [
      if (round.model != null) round.model!,
      '입력 ${formatTokens(round.inputTokens)} · 출력 ${formatTokens(round.outputTokens)} 토큰',
      if (round.toolCalls.isNotEmpty) '도구 ${round.toolCalls.map((t) => '${t.name} ${t.count}').join(', ')}',
      '걸린 시간 ${thinkDuration(round.durationMs)}',
      if (round.repoHead != null)
        '저장소 ${round.repoBranch ?? '-'}@${round.repoHead!.length > 7 ? round.repoHead!.substring(0, 7) : round.repoHead}'
            '${(round.repoDirtyFiles ?? 0) > 0 ? ' (커밋 안 된 파일 ${round.repoDirtyFiles}개 포함)' : ''}',
    ].join(' · ');
    final label = change ? '수정 결과' : '조사 결과';
    return ThinkCodeSection(
      title: numbered ? '$label (${round.round}회차)' : label,
      trailing: round.status == 'running'
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: kThinkAccent))
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (round.status == 'running' && round.resultText == null)
            Text(change ? '수정 중입니다…' : '조사 중입니다…', style: const TextStyle(color: kThinkSub, fontSize: 13)),
          if (round.error != null) ThinkNotice(text: round.error!, color: kThinkError, icon: Icons.error_outline),
          if (res != null) ThinkCodeResultView(result: res, mode: mode),
          if (round.diff != null) ...[
            thinkCodeLabel('변경 (diff)'),
            ThinkDiffView(diff: round.diff!, stats: round.diffStats),
          ],
          if (round.resultText != null)
            ThinkCodeExpansion(
              title: 'Cursor 답변 원문',
              initiallyExpanded: res == null,
              trailing: IconButton(
                tooltip: '원문 복사',
                iconSize: 16,
                color: kThinkSub,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: round.resultText!));
                  showThinkSnack(context, '원문을 복사했습니다.');
                },
                icon: const Icon(Icons.copy),
              ),
              children: [ThinkMarkdown(round.resultText!, fontSize: 13)],
            ),
          const SizedBox(height: 8),
          Text(meta, style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5)),
        ],
      ),
    );
  }
}

/// git diff를 파일별로 접어서 보여 준다. 긴 파일은 앞부분만 그린다(전체는 복사로 확인).
class ThinkDiffView extends StatefulWidget {
  const ThinkDiffView({super.key, required this.diff, this.stats});

  final String diff;
  final ThinkDiffStats? stats;

  static const int maxLinesPerFile = 600;

  @override
  State<ThinkDiffView> createState() => _ThinkDiffViewState();
}

class _ThinkDiffViewState extends State<ThinkDiffView> {
  late List<ThinkDiffFile> _files = parseThinkDiff(widget.diff);
  final Set<String> _open = {};

  @override
  void didUpdateWidget(covariant ThinkDiffView old) {
    super.didUpdateWidget(old);
    if (old.diff != widget.diff) _files = parseThinkDiff(widget.diff);
  }

  Color _lineColor(String l) {
    if (l.startsWith('@@')) return kThinkLink;
    if (l.startsWith('+')) return kThinkSuccess;
    if (l.startsWith('-')) return kThinkError;
    return kThinkSub;
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    final adds = stats?.additions ?? _files.fold<int>(0, (n, f) => n + f.additions);
    final dels = stats?.deletions ?? _files.fold<int>(0, (n, f) => n + f.deletions);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '파일 ${stats?.files ?? _files.length}개',
              style: const TextStyle(color: kThinkText, fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            Text('+$adds', style: const TextStyle(color: kThinkSuccess, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 4),
            Text('-$dels', style: const TextStyle(color: kThinkError, fontSize: 12, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.diff));
                showThinkSnack(context, 'diff를 복사했습니다.');
              },
              icon: const Icon(Icons.copy, size: 14, color: kThinkSub),
              label: const Text('diff 복사', style: TextStyle(color: kThinkSub, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final f in _files) _file(f),
      ],
    );
  }

  Widget _file(ThinkDiffFile f) {
    final open = _open.contains(f.path);
    final shown = f.lines.length > ThinkDiffView.maxLinesPerFile ? f.lines.sublist(0, ThinkDiffView.maxLinesPerFile) : f.lines;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => open ? _open.remove(f.path) : _open.add(f.path)),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_less : Icons.expand_more, size: 16, color: kThinkSub),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      f.oldPath == null ? f.path : '${f.oldPath} → ${f.path}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kThinkText, fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (f.binary)
                    const ThinkBadge('바이너리')
                  else ...[
                    Text('+${f.additions}', style: const TextStyle(color: kThinkSuccess, fontSize: 12)),
                    const SizedBox(width: 4),
                    Text('-${f.deletions}', style: const TextStyle(color: kThinkError, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          if (open && !f.binary)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText.rich(
                  TextSpan(
                    children: [
                      for (final l in shown)
                        TextSpan(text: '$l\n', style: TextStyle(color: _lineColor(l))),
                      if (shown.length < f.lines.length)
                        TextSpan(
                          text: '… ${f.lines.length - shown.length}줄 더 있음 (diff 복사로 전체 확인)',
                          style: const TextStyle(color: kThinkHint),
                        ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
