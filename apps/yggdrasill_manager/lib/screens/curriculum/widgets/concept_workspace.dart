import 'package:flutter/material.dart';

import '../../../services/concept_library_controller.dart';
import '../../think/think_style.dart';

/// 개념 탭 작업 공간. 왼쪽은 정리 기준, 오른쪽은 개념 라이브러리(정리 결과)로 위치를 고정하고,
/// 크게 보는 쪽(초점)에 따라 너비와 보이는 정보만 바꾼다. 네 칸(기준 상세·요약, 라이브러리 상세·요약)과
/// 대화 패널은 GlobalKey로 붙잡아 두어 초점·화면 폭이 바뀌어도 선택·스크롤·입력이 남는다.
/// 설계: docs/architecture/concept-library.md
class ConceptWorkspace extends StatefulWidget {
  const ConceptWorkspace({
    super.key,
    required this.controller,
    required this.criteriaDetail,
    required this.criteriaSummary,
    required this.libraryDetail,
    required this.librarySummary,
    this.chat,
  });

  final ConceptLibraryController controller;
  final Widget criteriaDetail;
  final Widget criteriaSummary;
  final Widget libraryDetail;
  final Widget librarySummary;

  /// 열려 있으면 Think 대화 패널. 옆에 둘 자리가 없으면 칸 전환으로 본다(세 번째 세로 영역을 억지로 만들지 않는다).
  final Widget? chat;

  /// 작업 영역이 이보다 좁으면 두 쪽을 나란히 두지 않고 한 쪽씩 본다.
  static const double twoPaneMinWidth = 880;

  /// 대화 패널을 옆에 둘 때 남는 작업 영역의 최소 폭.
  static const double chatSideMinWork = 440;
  static const double gap = 16;

  static double chatWidthFor(double total) => (total * 0.3).clamp(340.0, 460.0);

  @override
  State<ConceptWorkspace> createState() => _ConceptWorkspaceState();
}

class _ConceptWorkspaceState extends State<ConceptWorkspace> {
  final _criteriaDetailKey = GlobalKey(debugLabel: 'criteriaDetail');
  final _criteriaSummaryKey = GlobalKey(debugLabel: 'criteriaSummary');
  final _libraryDetailKey = GlobalKey(debugLabel: 'libraryDetail');
  final _librarySummaryKey = GlobalKey(debugLabel: 'librarySummary');
  final _chatKey = GlobalKey(debugLabel: 'conceptChat');

  ConceptLibraryController get _c => widget.controller;

  Widget _keep(GlobalKey key, Widget child) => KeyedSubtree(key: key, child: child);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final total = constraints.maxWidth;
          final chat = widget.chat;
          final chatWidth = ConceptWorkspace.chatWidthFor(total);
          final chatSide = chat != null && total - chatWidth - ConceptWorkspace.gap >= ConceptWorkspace.chatSideMinWork;
          final work = chatSide ? total - chatWidth - ConceptWorkspace.gap : total;
          final body =
              work >= ConceptWorkspace.twoPaneMinWidth ? _twoPane(context, work) : _onePane(chatSide ? null : chat);
          if (!chatSide) return body;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: body),
              const SizedBox(width: ConceptWorkspace.gap),
              SizedBox(width: chatWidth, child: _keep(_chatKey, chat)),
            ],
          );
        },
      ),
    );
  }

  Widget _twoPane(BuildContext context, double work) {
    final criteriaFocused = _c.focus == ConceptWorkspaceFocus.criteria;
    final inner = work - ConceptWorkspace.gap;
    final left = criteriaFocused ? inner * 2 / 3 : inner / 3;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedContainer(
          duration: still ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: left,
          child: IndexedStack(
            index: criteriaFocused ? 0 : 1,
            sizing: StackFit.expand,
            children: [
              _keep(_criteriaDetailKey, widget.criteriaDetail),
              _keep(_criteriaSummaryKey, widget.criteriaSummary),
            ],
          ),
        ),
        const SizedBox(width: ConceptWorkspace.gap),
        Expanded(
          child: IndexedStack(
            index: criteriaFocused ? 1 : 0,
            sizing: StackFit.expand,
            children: [
              _keep(_libraryDetailKey, widget.libraryDetail),
              _keep(_librarySummaryKey, widget.librarySummary),
            ],
          ),
        ),
      ],
    );
  }

  /// 좁은 화면: 한 칸씩 본다. 요약 칸은 쓰지 않고(상세만), 겹치지 않는다.
  Widget _onePane(Widget? chat) {
    final showChat = chat != null && _c.narrowChat;
    final index = showChat ? 2 : (_c.focus == ConceptWorkspaceFocus.criteria ? 0 : 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ThinkPillTabs(
              labels: ['정리 기준', '개념 라이브러리', if (chat != null) 'Think 대화'],
              icons: [Icons.rule_folder_outlined, Icons.account_tree_outlined, if (chat != null) Icons.forum_outlined],
              selected: index,
              onSelected: (i) {
                if (i == 2) {
                  _c.showNarrowChat();
                } else {
                  _c.setFocus(i == 0 ? ConceptWorkspaceFocus.criteria : ConceptWorkspaceFocus.library);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: IndexedStack(
            index: index,
            sizing: StackFit.expand,
            children: [
              _keep(_criteriaDetailKey, widget.criteriaDetail),
              _keep(_libraryDetailKey, widget.libraryDetail),
              if (chat != null) _keep(_chatKey, chat),
            ],
          ),
        ),
      ],
    );
  }
}

/// 각 칸 머리. 요약 칸에는 "크게 보기"가 붙는다.
class ConceptPaneHeader extends StatelessWidget {
  const ConceptPaneHeader({
    super.key,
    required this.icon,
    required this.title,
    this.badges = const [],
    this.actions = const [],
    this.onExpand,
  });

  final IconData icon;
  final String title;
  final List<Widget> badges;
  final List<Widget> actions;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: kThinkAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(title, style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
                ...badges,
              ],
            ),
          ),
          ...actions,
          if (onExpand != null)
            TextButton.icon(
              onPressed: onExpand,
              icon: const Icon(Icons.open_in_full, size: 16),
              label: const Text('크게 보기'),
              style: TextButton.styleFrom(foregroundColor: kThinkAccent),
            ),
        ],
      ),
    );
  }
}

/// 칸 안의 소제목.
class ConceptSectionTitle extends StatelessWidget {
  const ConceptSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: const TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w800)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 연한 안내 글.
class ConceptHint extends StatelessWidget {
  const ConceptHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5));
  }
}
