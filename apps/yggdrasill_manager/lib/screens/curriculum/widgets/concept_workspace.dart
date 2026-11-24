import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_library_controller.dart';
import '../../think/think_style.dart';

enum _RightSheetKind { none, arithmetic, foundations }

/// 개념 탭 작업 공간. 왼쪽은 교육과정 흐름과 개념 라이브러리 중 하나, 오른쪽은 사고 리스트다. 너비는 1:1.
/// 연산 리스트와 사고의 토대는 오른쪽 가장자리 손잡이로 여는 시트다. Think 대화는 칸을 차지하지 않고, 오른쪽 아래 버튼으로 펼친다.
/// 설계: docs/architecture/concept-library.md, docs/architecture/course-map.md
class ConceptWorkspace extends StatefulWidget {
  const ConceptWorkspace({
    super.key,
    required this.controller,
    required this.courseDetail,
    required this.courseSummary,
    required this.libraryDetail,
    required this.librarySummary,
    this.thinking,
    this.arithmetic,
    this.foundations,
    this.showLibrary = false,
    this.chat,
    this.chatExpanded = false,
    this.onExpandChat,
  });

  final ConceptLibraryController controller;
  final Widget courseDetail;
  final Widget courseSummary;
  final Widget libraryDetail;
  final Widget librarySummary;

  /// 오른쪽 절반. 사고 리스트.
  final Widget? thinking;

  /// 오른쪽에서 밀려 나오는 연산 리스트. 없으면 손잡이를 두지 않는다.
  final Widget? arithmetic;

  /// 오른쪽에서 밀려 나오는 사고의 토대(C) 리스트. 없으면 손잡이를 두지 않는다.
  final Widget? foundations;

  /// 왼쪽을 흐름 대신 개념 라이브러리로 보일지. 오른쪽 사고 리스트는 그대로다.
  final bool showLibrary;

  /// Think 대화. 접혀 있으면 오른쪽 아래 버튼만 보이고, [chatExpanded]일 때 그 위에 겹쳐 펼친다.
  final Widget? chat;

  /// [chat]을 펼쳐 둘지. 접히면 작업 영역 폭은 그대로다.
  final bool chatExpanded;

  /// 오른쪽 아래 버튼을 눌렀을 때. 없으면 버튼이 잠긴다.
  final VoidCallback? onExpandChat;

  /// 펼친 대화 폭. 작업 영역에서 빼지 않는다.
  static double chatWidthFor(double total) => (total * 0.3).clamp(340.0, 460.0);

  @override
  State<ConceptWorkspace> createState() => _ConceptWorkspaceState();
}

class _ConceptWorkspaceState extends State<ConceptWorkspace> {
  final _courseDetailKey = GlobalKey(debugLabel: 'courseDetail');
  final _courseSummaryKey = GlobalKey(debugLabel: 'courseSummary');
  final _libraryDetailKey = GlobalKey(debugLabel: 'libraryDetail');
  final _librarySummaryKey = GlobalKey(debugLabel: 'librarySummary');
  final _thinkingKey = GlobalKey(debugLabel: 'thinkingList');
  final _arithmeticKey = GlobalKey(debugLabel: 'arithmeticList');
  final _foundationKey = GlobalKey(debugLabel: 'foundationList');
  final _chatKey = GlobalKey(debugLabel: 'conceptChat');
  _RightSheetKind _openSheet = _RightSheetKind.none;

  static const Duration _sheetDuration = Duration(milliseconds: 220);

  ConceptLibraryController get _c => widget.controller;

  Widget _keep(GlobalKey key, Widget child) => KeyedSubtree(key: key, child: child);

  @override
  void didUpdateWidget(ConceptWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatExpanded && !widget.chatExpanded) _releaseChatFocus();
  }

  /// 접을 때 숨은 입력칸에 커서가 남지 않게 한다.
  void _releaseChatFocus() {
    final node = FocusManager.instance.primaryFocus;
    final focused = node?.context;
    final chat = _chatKey.currentContext;
    if (node == null || focused is! Element || chat is! Element) return;
    var inside = identical(focused, chat);
    focused.visitAncestorElements((ancestor) {
      if (identical(ancestor, chat)) inside = true;
      return !inside;
    });
    if (inside) node.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final total = constraints.maxWidth;
          final body = _split(constraints);
          final chat = widget.chat;
          if (chat == null) return body;
          final expanded = widget.chatExpanded;
          final panelWidth = math.min(ConceptWorkspace.chatWidthFor(total), math.max(0.0, total - 32));
          final panelHeight = math.max(0.0, constraints.maxHeight - 32);
          // 저장 줄은 왼쪽 절반에 있다. 버튼은 오른쪽 사고 리스트 위에 둔다.
          return Stack(
            children: [
              Positioned.fill(child: body),
              Positioned(
                key: const ValueKey('concept-chat-overlay'),
                right: 16,
                bottom: 16,
                child: Visibility(
                  visible: expanded,
                  maintainState: true,
                  child: SizedBox(
                    width: panelWidth,
                    height: panelHeight,
                    child: _keep(_chatKey, chat),
                  ),
                ),
              ),
              if (!expanded)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: _ConceptChatButton(onPressed: widget.onExpandChat),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 왼쪽 절반은 흐름 또는 라이브러리, 오른쪽 절반은 사고 리스트. 연산·사고의 토대는 그 위로 덮는 시트다.
  Widget _split(BoxConstraints constraints) {
    final sheetWidth = math.max(0.0, (constraints.maxWidth - 16) / 2);
    final arithmeticOpen = _openSheet == _RightSheetKind.arithmetic && widget.arithmetic != null;
    final foundationOpen = _openSheet == _RightSheetKind.foundations && widget.foundations != null;
    final anySheetOpen = arithmeticOpen || foundationOpen;
    final handleCount = (widget.arithmetic != null ? 1 : 0) + (widget.foundations != null ? 1 : 0);
    final handlesHeight = handleCount == 0 ? 0.0 : (handleCount * 72.0 + (handleCount - 1) * 8.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: IndexedStack(
                key: const ValueKey('concept-workspace-main'),
                index: widget.showLibrary ? 1 : 0,
                sizing: StackFit.expand,
                children: [
                  _keep(_courseDetailKey, widget.courseDetail),
                  _keep(_libraryDetailKey, widget.libraryDetail),
                ],
              ),
            ),
            const VerticalDivider(color: kThinkBorder, width: 16),
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('concept-workspace-thinking'),
                child: _keep(_thinkingKey, widget.thinking ?? const SizedBox.shrink()),
              ),
            ),
          ],
        ),
        Offstage(
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: IndexedStack(
              sizing: StackFit.expand,
              index: 0,
              children: [
                _keep(_courseSummaryKey, widget.courseSummary),
                _keep(_librarySummaryKey, widget.librarySummary),
              ],
            ),
          ),
        ),
        if (anySheetOpen)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: math.max(0.0, constraints.maxWidth - sheetWidth),
            child: GestureDetector(
              key: const ValueKey('arithmetic-sheet-barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _openSheet = _RightSheetKind.none),
              child: ColoredBox(color: kThinkBg.withValues(alpha: 0.45)),
            ),
          ),
        if (widget.arithmetic != null)
          AnimatedPositioned(
            duration: _sheetDuration,
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            width: sheetWidth,
            right: arithmeticOpen ? 0 : -sheetWidth,
            child: DecoratedBox(
              key: const ValueKey('arithmetic-sheet'),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: kThinkBorder)),
              ),
              child: _keep(_arithmeticKey, widget.arithmetic!),
            ),
          ),
        if (widget.foundations != null)
          AnimatedPositioned(
            duration: _sheetDuration,
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            width: sheetWidth,
            right: foundationOpen ? 0 : -sheetWidth,
            child: DecoratedBox(
              key: const ValueKey('foundation-sheet'),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: kThinkBorder)),
              ),
              child: _keep(_foundationKey, widget.foundations!),
            ),
          ),
        if (handleCount > 0)
          AnimatedPositioned(
            duration: _sheetDuration,
            curve: Curves.easeOutCubic,
            right: anySheetOpen ? sheetWidth : 0,
            top: math.max(0.0, (constraints.maxHeight - handlesHeight - 16) / 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.arithmetic != null)
                  _RightSheetHandle(
                    handleKey: const ValueKey('arithmetic-sheet-handle'),
                    tooltip: arithmeticOpen ? '연산 닫기' : '연산',
                    closedIcon: Icons.calculate_outlined,
                    open: arithmeticOpen,
                    onTap: () => setState(() {
                      _openSheet = arithmeticOpen ? _RightSheetKind.none : _RightSheetKind.arithmetic;
                    }),
                  ),
                if (widget.arithmetic != null && widget.foundations != null) const SizedBox(height: 8),
                if (widget.foundations != null)
                  _RightSheetHandle(
                    handleKey: const ValueKey('foundation-sheet-handle'),
                    tooltip: foundationOpen ? '사고의 토대 닫기' : '사고의 토대',
                    closedIcon: Icons.compass_calibration_outlined,
                    open: foundationOpen,
                    onTap: () => setState(() {
                      _openSheet = foundationOpen ? _RightSheetKind.none : _RightSheetKind.foundations;
                    }),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 오른쪽 가장자리 손잡이. 연산 또는 사고의 토대 시트를 열거나 닫는다.
class _RightSheetHandle extends StatelessWidget {
  const _RightSheetHandle({
    required this.handleKey,
    required this.tooltip,
    required this.closedIcon,
    required this.open,
    required this.onTap,
  });

  final Key handleKey;
  final String tooltip;
  final IconData closedIcon;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: kThinkPanel,
        elevation: 4,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
        child: InkWell(
          key: handleKey,
          onTap: onTap,
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
          child: SizedBox(
            width: 28,
            height: 72,
            child: Icon(open ? Icons.chevron_right : closedIcon, size: 18, color: kThinkAccent),
          ),
        ),
      ),
    );
  }
}

/// 개념 정리 대화. 누르면 작업 영역 위에 펼친다.
class _ConceptChatButton extends StatelessWidget {
  const _ConceptChatButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Think와 개념 정리',
      child: Material(
        color: kThinkAccent,
        elevation: 4,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          key: const ValueKey('concept-chat-fab'),
          onTap: onPressed,
          borderRadius: BorderRadius.circular(24),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.forum_outlined, size: 18, color: Colors.white),
                SizedBox(width: 8),
                Text('개념 정리', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
      ),
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
