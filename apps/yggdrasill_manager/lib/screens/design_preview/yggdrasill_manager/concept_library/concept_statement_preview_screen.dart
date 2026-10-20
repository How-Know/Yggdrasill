import 'package:flutter/material.dart';

import '../../../../widgets/latex_text_renderer.dart';
import '../../../think/think_style.dart';
import 'concept_statement_preview_mock.dart';

/// 개념 상세 "여러 서술" Preview. 목업 데이터와 화면 안 상태만 쓴다(실제 저장 없음).
class ConceptStatementPreviewScreen extends StatelessWidget {
  const ConceptStatementPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kThinkBg,
      appBar: AppBar(
        backgroundColor: kThinkBg,
        foregroundColor: kThinkText,
        title: const Text('Preview · 개념의 여러 서술'),
      ),
      body: const ConceptStatementPreviewBody(),
    );
  }
}

class ConceptStatementPreviewBody extends StatefulWidget {
  const ConceptStatementPreviewBody({super.key, this.initialDesign = 0, this.initialWide = true});

  final int initialDesign;
  final bool initialWide;

  @override
  State<ConceptStatementPreviewBody> createState() => _ConceptStatementPreviewBodyState();
}

class _ConceptStatementPreviewBodyState extends State<ConceptStatementPreviewBody> {
  late int _design = widget.initialDesign;
  late bool _wide = widget.initialWide;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ThinkPillTabs(
                labels: const ['A 고르기 줄', 'B 카드 목록'],
                icons: const [Icons.view_week_outlined, Icons.view_agenda_outlined],
                selected: _design,
                onSelected: (i) => setState(() => _design = i),
              ),
              ThinkPillTabs(
                labels: const ['좁게 320', '넓게 440'],
                icons: const [Icons.crop_portrait, Icons.crop_landscape],
                selected: _wide ? 1 : 0,
                onSelected: (i) => setState(() => _wide = i == 1),
              ),
              const Text('예시는 구조 설명용 목업이며 실제 교재 문장·등장 학년을 확인한 자료가 아닙니다.',
                  style: TextStyle(color: kThinkHint, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _treePlaceholder()),
                const SizedBox(width: 16),
                SizedBox(
                  width: _wide ? 440 : 320,
                  child: ThinkPanel(
                    child: _design == 0
                        ? const _DesignA(key: ValueKey('design-a'))
                        : const _DesignB(key: ValueKey('design-b')),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _treePlaceholder() => ThinkPanel(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('개념 트리 (지금 그대로)', style: TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w800)),
            SizedBox(height: 8),
            Text('트리는 바꾸지 않습니다. 칩에 서술 수만 작게 붙일지 Preview에서 같이 정합니다(예: "확률의 뜻 · 3").',
                style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5)),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────
// 공통 조각
// ─────────────────────────────────────────────────────────────────────────

Widget _sectionTitle(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
              child: Text(text, style: const TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w800))),
          if (trailing != null) trailing,
        ],
      ),
    );

Widget _hint(String text) => Text(text, style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5));

Widget _smallButton(String label, IconData icon, VoidCallback onTap, {Color color = kThinkAccent}) => TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(foregroundColor: color, visualDensity: VisualDensity.compact),
    );

Widget _math(String text, {double size = 14}) => LatexTextRenderer(
      text,
      dollarMath: true,
      style: TextStyle(color: kThinkText, fontSize: size, height: 1.6),
      crossAxisAlignment: CrossAxisAlignment.start,
      blockVerticalPadding: 4,
    );

Widget _labeled(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );

Widget _subText(String text) => Text(text, style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.5));

/// 상세 머리: 이름·배지·버튼(지금과 같음) + 서술 수.
Widget _header(BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(kMockConceptName, style: TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            const ThinkBadge('유형: 정의', color: Color(0xFFDE6A73)),
            const ThinkBadge('기존 구분: 정의'),
            ThinkBadge('서술 ${kMockStatements.length}개', color: kThinkLink),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            _smallButton('Think 대화 참고로 선택', Icons.forum_outlined, () {}),
            _smallButton('수정', Icons.edit_outlined, () {}, color: kThinkSub),
          ],
        ),
      ],
    );

/// 개념 공통 내용. 모든 서술에 해당한다고 머리에 적는다.
Widget _coreBox(BuildContext context) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kThinkAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hub_outlined, size: 16, color: kThinkAccent),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('개념 공통 내용 · 모든 서술에 해당',
                    style: TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800)),
              ),
              ThinkBadge(kMockCore.status, color: kThinkSuccess),
              IconButton(
                tooltip: '공통 내용 고치기',
                onPressed: () => _showEditDialog(context, core: true),
                icon: const Icon(Icons.edit_outlined, size: 16),
                color: kThinkSub,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          _labeled('공통 의미', _subText(kMockCore.meaning)),
          _labeled('적용 범위', _subText(kMockCore.scope)),
          _labeled('공통 조건', _subText(kMockCore.conditions)),
        ],
      ),
    );

/// 고른 서술 한 개의 내용. A·B 안 모두 이 몸통을 쓴다.
class _StatementBody extends StatefulWidget {
  const _StatementBody({super.key, required this.s});

  final MockStatement s;

  @override
  State<_StatementBody> createState() => _StatementBodyState();
}

class _StatementBodyState extends State<_StatementBody> {
  bool _showSource = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ThinkBadge(s.status, color: s.status.startsWith('확정') ? kThinkSuccess : kThinkHint),
            if (!s.base) ThinkBadge(s.verbatim ? '원문 그대로' : '우리가 정리한 글', color: s.verbatim ? kThinkLink : kThinkSub),
            if (s.conditionsInSource != null)
              ThinkBadge(s.conditionsInSource!, color: s.conditionsInSource!.contains('확인') ? kThinkAccent : kThinkSub),
          ],
        ),
        const SizedBox(height: 8),
        SelectionArea(child: _math(s.body)),
        if (s.conditions != null) _labeled('이 서술의 적용 조건', _subText(s.conditions!)),
        if (s.terms.isNotEmpty)
          _labeled(
            '필요한 용어',
            Wrap(spacing: 6, runSpacing: 6, children: [for (final t in s.terms) ThinkBadge(t, color: kThinkSub)]),
          ),
        if (s.quote != null || s.supplementNote != null || s.unverifiedNote != null) ...[
          const SizedBox(height: 4),
          InkWell(
            onTap: () => setState(() => _showSource = !_showSource),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_showSource ? Icons.expand_less : Icons.expand_more, size: 18, color: kThinkLink),
                  const SizedBox(width: 4),
                  const Text('원문과 보완한 점',
                      style: TextStyle(color: kThinkLink, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          if (_showSource) ...[
            if (s.quote != null)
              _labeled(
                  '원문(책에 적힌 문장)',
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
                    child: _math(s.quote!, size: 13),
                  )),
            if (s.supplementNote != null) _labeled('보완·수정한 부분과 이유', _subText(s.supplementNote!)),
            if (s.unverifiedNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ThinkNotice(text: '확인 안 됨: ${s.unverifiedNote!}', color: kThinkAccent, icon: Icons.help_outline),
              ),
          ],
        ],
        const SizedBox(height: 10),
        _sectionTitle(
          '등장 위치',
          trailing: _smallButton('등장 위치 더하기', Icons.add, () => _showAppearanceDialog(context)),
        ),
        for (final a in s.appearances)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                const Icon(Icons.school_outlined, size: 14, color: kThinkHint),
                const SizedBox(width: 6),
                Expanded(child: Text(a, style: const TextStyle(color: kThinkSub, fontSize: 12))),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Tooltip(
          message: s.sources.join('\n'),
          child: InkWell(
            onTap: () => _showSourcesDialog(context),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kThinkLink.withValues(alpha: 0.6)),
                color: kThinkLink.withValues(alpha: 0.10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.menu_book_outlined, size: 14, color: kThinkLink),
                  const SizedBox(width: 6),
                  Text('이 서술의 출처 ${s.sources.length}개',
                      style: const TextStyle(color: kThinkLink, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            _smallButton(s.base ? '개념 본문 수정' : '서술 고치기', Icons.edit_outlined, () {
              if (!s.base) _showEditDialog(context);
            }, color: kThinkSub),
            _smallButton(s.base ? '고친 기록' : '확정 기록', Icons.history, () {}, color: kThinkSub),
          ],
        ),
      ],
    );
  }
}

Widget _differenceHint() => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.compare_arrows, size: 16, color: kThinkHint),
          const SizedBox(width: 8),
          Expanded(child: _hint('서술 사이 차이·판단 이유는 아직 기록하지 않습니다(4단계). 지금은 서술마다 조건·용어·원문 여부만 비교해 봅니다.')),
        ],
      ),
    );

// ─────────────────────────────────────────────────────────────────────────
// A: 공통 내용 + 서술 고르기 줄 + 고른 서술만 펼침
// ─────────────────────────────────────────────────────────────────────────

class _DesignA extends StatefulWidget {
  const _DesignA({super.key});

  @override
  State<_DesignA> createState() => _DesignAState();
}

class _DesignAState extends State<_DesignA> {
  int _selected = 2;

  @override
  Widget build(BuildContext context) {
    final s = kMockStatements[_selected];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(context),
        const SizedBox(height: 12),
        _coreBox(context),
        const SizedBox(height: 16),
        _sectionTitle(
          '서술 ${kMockStatements.length}',
          trailing: _smallButton('서술 더하기', Icons.add, () => _showEditDialog(context)),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < kMockStatements.length; i++)
              ThinkToggleChip(
                key: ValueKey('statement-pick-$i'),
                label: kMockStatements[i].chipLabel,
                icon: kMockStatements[i].base ? Icons.notes : Icons.short_text,
                selected: i == _selected,
                onChanged: (_) => setState(() => _selected = i),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kThinkBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kThinkLink.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.short_text, size: 16, color: kThinkLink),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      s.base ? '서술 · 기본(개념 본문)' : '서술 ${_selected + 1}/${kMockStatements.length} · ${s.title}',
                      style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _StatementBody(key: ValueKey(s.id), s: s),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _differenceHint(),
        const SizedBox(height: 16),
        _hint('아래는 지금과 같음: 주제 묶음 · 이은 정리 기준'),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// B: 공통 내용 + 서술마다 접힌 카드(하나만 펼침)
// ─────────────────────────────────────────────────────────────────────────

class _DesignB extends StatefulWidget {
  const _DesignB({super.key});

  @override
  State<_DesignB> createState() => _DesignBState();
}

class _DesignBState extends State<_DesignB> {
  int? _open = 2;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(context),
        const SizedBox(height: 12),
        _coreBox(context),
        const SizedBox(height: 16),
        _sectionTitle(
          '서술 ${kMockStatements.length}',
          trailing: _smallButton('서술 더하기', Icons.add, () => _showEditDialog(context)),
        ),
        for (var i = 0; i < kMockStatements.length; i++) ...[
          _card(i),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        _differenceHint(),
        const SizedBox(height: 16),
        _hint('아래는 지금과 같음: 주제 묶음 · 이은 정리 기준'),
      ],
    );
  }

  Widget _card(int i) {
    final s = kMockStatements[i];
    final open = _open == i;
    return Container(
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: open ? kThinkLink.withValues(alpha: 0.5) : kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('statement-card-$i'),
            onTap: () => setState(() => _open = open ? null : i),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: kThinkSub),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.base ? '기본 서술 · 개념 본문' : s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(
                          [if (s.approach != null) s.approach!, '출처 ${s.sources.length}', '등장 ${s.appearances.length}']
                              .join(' · '),
                          style: const TextStyle(color: kThinkHint, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (!open)
                    ThinkBadge(s.status.split(' · ').first,
                        color: s.status.startsWith('확정') ? kThinkSuccess : kThinkHint),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _StatementBody(key: ValueKey(s.id), s: s),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 창(목업): 서술 고치기, 출처, 등장 위치 더하기
// ─────────────────────────────────────────────────────────────────────────

Future<void> _showEditDialog(BuildContext context, {bool core = false}) => showDialog<void>(
      context: context,
      builder: (ctx) => core ? const _CoreDialogMock() : const _EditDialogMock(),
    );

class _CoreDialogMock extends StatelessWidget {
  const _CoreDialogMock();

  Widget _field(String label, String initial) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          initialValue: initial,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: kThinkText, fontSize: 14),
          decoration: thinkInputDecoration(label: label, dense: true),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Row(
        children: [
          Icon(Icons.hub_outlined, size: 20, color: kThinkAccent),
          SizedBox(width: 8),
          Expanded(
            child: Text('개념 공통 내용 고치기', style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          ThinkBadge('확정 v1', color: kThinkSuccess),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _hint('모든 서술에 해당하는 내용만 씁니다. 저장하면 초안으로 남고, 확정은 따로 누릅니다.'),
            const SizedBox(height: 12),
            _field('공통 의미', kMockCore.meaning),
            _field('적용 범위', kMockCore.scope),
            _field('공통 조건', kMockCore.conditions),
            _hint('공통 조건은 그 조건을 정말 함께 쓰는 서술 범위에서만 둡니다. 상위 개념 전체의 조건으로 올리지 않습니다.'),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: kThinkSub))),
        OutlinedButton(onPressed: () {}, style: thinkOutlineButton(), child: const Text('초안 저장')),
        ElevatedButton(onPressed: null, style: thinkPrimaryButton(), child: const Text('확정')),
      ],
    );
  }
}

class _EditDialogMock extends StatefulWidget {
  const _EditDialogMock();

  @override
  State<_EditDialogMock> createState() => _EditDialogMockState();
}

class _EditDialogMockState extends State<_EditDialogMock> {
  bool _verbatim = false;
  int _cis = 2;

  Widget _field(String label, {int lines = 1, String? initial}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          initialValue: initial,
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 2,
          style: const TextStyle(color: kThinkText, fontSize: 14),
          decoration: thinkInputDecoration(label: label, dense: true),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = kMockStatements[1];
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Row(
        children: [
          Icon(Icons.short_text, size: 20, color: kThinkLink),
          SizedBox(width: 8),
          Expanded(
            child: Text('서술 고치기 · 경우의 수로 본 확률',
                style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          ThinkBadge('확정 v1', color: kThinkSuccess),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _hint('저장하면 초안으로 남고 확정본은 그대로입니다. 확정은 저장한 뒤 따로 누릅니다.'),
              const SizedBox(height: 12),
              _field('제목', initial: s.title),
              _field('서술 방식(예: 경우의 수, 집합과 기호, 직관적 설명)', initial: s.approach),
              _field(r'본문 ($…$ 수식)', lines: 3, initial: s.body),
              _field('이 서술의 적용 대상·조건', lines: 2, initial: s.conditions),
              _sectionTitle('원문에 조건이 적혀 있나요'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (i, label) in const ['적혀 있음', '없음(보완함)', '안 보임 · 앞뒤 문맥 확인 필요', '모름'].indexed)
                    ThinkToggleChip(
                      label: label,
                      icon: Icons.rule,
                      selected: _cis == i,
                      onChanged: (_) => setState(() => _cis = i),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _field('필요한 용어(쉼표로 나눔)', initial: s.terms.join(', ')),
              _sectionTitle('글의 바탕'),
              Wrap(
                spacing: 6,
                children: [
                  ThinkToggleChip(
                    label: '우리가 정리한 글',
                    icon: Icons.edit_note,
                    selected: !_verbatim,
                    onChanged: (_) => setState(() => _verbatim = false),
                  ),
                  ThinkToggleChip(
                    label: '원문 그대로',
                    icon: Icons.format_quote,
                    selected: _verbatim,
                    onChanged: (_) => setState(() => _verbatim = true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _field('원문(책에 적힌 문장 또는 원문 참조)', lines: 2),
              _field('보완·수정한 부분과 이유', lines: 2, initial: s.supplementNote),
              _field('확인되지 않은 사항', lines: 2, initial: s.unverifiedNote),
              _hint('우리가 보완한 문장은 원문 칸에 쓰지 않습니다. 책 이름·쪽은 출처에서 잇고 여기서 추정해 쓰지 않습니다.'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: kThinkSub))),
        OutlinedButton(onPressed: () {}, style: thinkOutlineButton(), child: const Text('초안 저장')),
        ElevatedButton(onPressed: null, style: thinkPrimaryButton(), child: const Text('확정')),
      ],
    );
  }
}

Future<void> _showSourcesDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kThinkBg,
        shape: thinkDialogShape,
        title: const Text('출처 — $kMockConceptName', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final st in kMockStatements)
                for (final src in st.sources) ...[
                  Row(
                    children: [
                      Expanded(child: Text(src, style: const TextStyle(color: kThinkText, fontSize: 13))),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 170,
                        child: DropdownButtonFormField<String>(
                          initialValue: st.id,
                          isExpanded: true,
                          dropdownColor: kThinkPanel,
                          style: const TextStyle(color: kThinkText, fontSize: 13),
                          decoration: thinkInputDecoration(label: '어느 서술의 출처', dense: true),
                          items: [
                            for (final o in kMockStatements)
                              DropdownMenuItem(value: o.id, child: Text(o.chipLabel, overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (_) {},
                        ),
                      ),
                      IconButton(onPressed: () {}, icon: const Icon(Icons.open_in_new, size: 16), color: kThinkLink),
                    ],
                  ),
                  const Divider(color: kThinkBorder, height: 16),
                ],
              _hint('한 쪽은 한 서술에만 붙습니다. 서술을 바꿔도 책·쪽은 그대로입니다.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기', style: TextStyle(color: kThinkSub))),
        ],
      ),
    );

Future<void> _showAppearanceDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => const _AppearanceDialogMock(),
    );

class _AppearanceDialogMock extends StatefulWidget {
  const _AppearanceDialogMock();

  @override
  State<_AppearanceDialogMock> createState() => _AppearanceDialogMockState();
}

class _AppearanceDialogMockState extends State<_AppearanceDialogMock> {
  String? _curriculum;
  int _level = 2;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('등장 위치 더하기 · 표본공간으로 본 확률',
          style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String?>(
              initialValue: _curriculum,
              dropdownColor: kThinkPanel,
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(label: '교육과정 판', dense: true),
              items: const [
                DropdownMenuItem(value: null, child: Text('모름(미기록)')),
                DropdownMenuItem(value: 'rev_2015', child: Text('2015 개정')),
                DropdownMenuItem(value: 'rev_2022', child: Text('2022 개정')),
              ],
              onChanged: (v) => setState(() => _curriculum = v),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: [
                for (final (i, label) in const ['초', '중', '고'].indexed)
                  ThinkToggleChip(
                    label: label,
                    icon: Icons.school_outlined,
                    selected: _level == i,
                    onChanged: (_) => setState(() => _level = i),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              initialValue: '확률과 통계',
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(label: '학년·과목(예: 2-2, 확률과 통계)', dense: true),
            ),
            const SizedBox(height: 10),
            TextFormField(
              initialValue: '확률 > 확률의 뜻과 활용',
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(label: '단원(> 로 나눔, 3단계까지)', dense: true),
            ),
            const SizedBox(height: 10),
            TextFormField(
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(label: '메모', dense: true),
            ),
            const SizedBox(height: 10),
            _hint('교육과정 판은 확인한 것만 고릅니다. 교재 이름·과목으로 추정하지 않습니다. 새 판을 더해도 이전 등장 위치는 남습니다.'),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: kThinkSub))),
        ElevatedButton(onPressed: () {}, style: thinkPrimaryButton(), child: const Text('더하기')),
      ],
    );
  }
}
