import 'package:flutter/material.dart';

class TimetableContentWrapper extends StatelessWidget {
  final Widget timetableChild;
  final VoidCallback onRegisterPressed;
  final String splitButtonSelected;
  final bool isDropdownOpen;
  final ValueChanged<bool> onDropdownOpenChanged;
  final ValueChanged<String> onDropdownSelected;

  const TimetableContentWrapper({
    Key? key,
    required this.timetableChild,
    required this.onRegisterPressed,
    required this.splitButtonSelected,
    required this.isDropdownOpen,
    required this.onDropdownOpenChanged,
    required this.onDropdownSelected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 시간표 컨테이너 (3/4)
        Expanded(
          flex: 3,
          child: timetableChild,
        ),
        // 등록 버튼 컨테이너 (1/4)
        Expanded(
          flex: 1,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 48, left: 24, right: 24),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF18181A),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    SizedBox(
                      width: 113,
                      height: 44,
                      child: Material(
                        color: const Color(0xFF1976D2),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(32),
                          bottomLeft: Radius.circular(32),
                          topRight: Radius.circular(6),
                          bottomRight: Radius.circular(6),
                        ),
                        child: InkWell(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(32),
                            bottomLeft: Radius.circular(32),
                            topRight: Radius.circular(6),
                            bottomRight: Radius.circular(6),
                          ),
                          onTap: onRegisterPressed,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.max,
                            children: const [
                              Icon(Icons.edit, color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Text('등록', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 구분선
                    Container(
                      height: 44,
                      width: 4.5,
                      color: Colors.transparent,
                      child: Center(
                        child: Container(
                          width: 2,
                          height: 28,
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                    ),
                    // 드롭다운 버튼
                    _BouncyDropdownButton(
                      isOpen: isDropdownOpen,
                      child: _DropdownMenuButton(
                        isOpen: isDropdownOpen,
                        onOpenChanged: onDropdownOpenChanged,
                        onSelected: onDropdownSelected,
                      ),
                    ),
                    // 선택 버튼
                    SizedBox(width: 8),
                    _SelectButtonAnimated(),
                  ],
                ),
              ),
              // 비어있는 컨테이너 (예시)
              Container(
                margin: const EdgeInsets.only(top: 24, left: 24, right: 24),
                height: 180,
                decoration: BoxDecoration(
                  color: const Color(0xFF18181A),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Center(
                  child: Text(
                    '',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// 아래는 기존 SplitButton 관련 위젯 복사 (간단화)
class _DropdownMenuButton extends StatelessWidget {
  final bool isOpen;
  final ValueChanged<bool> onOpenChanged;
  final ValueChanged<String> onSelected;
  const _DropdownMenuButton({required this.isOpen, required this.onOpenChanged, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onOpenChanged(!isOpen),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        width: 44,
        height: 44,
        decoration: ShapeDecoration(
          color: const Color(0xFF1976D2),
          shape: RoundedRectangleBorder(
            borderRadius: isOpen
              ? BorderRadius.circular(50)
              : const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  bottomLeft: Radius.circular(6),
                  topRight: Radius.circular(32),
                  bottomRight: Radius.circular(32),
                ),
          ),
        ),
        child: Center(
          child: AnimatedRotation(
            turns: isOpen ? 0.5 : 0.0, // 0.5turn = 180도
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
            child: const Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white,
              size: 28,
              key: ValueKey('arrow'),
            ),
          ),
        ),
      ),
    );
  }
}

class _BouncyDropdownButton extends StatefulWidget {
  final bool isOpen;
  final Widget child;
  const _BouncyDropdownButton({required this.isOpen, required this.child});

  @override
  State<_BouncyDropdownButton> createState() => _BouncyDropdownButtonState();
}

class _BouncyDropdownButtonState extends State<_BouncyDropdownButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  bool _prevIsOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.08)
        .chain(CurveTween(curve: Curves.elasticOut))
        .animate(_controller);
    _prevIsOpen = widget.isOpen;
  }

  @override
  void didUpdateWidget(covariant _BouncyDropdownButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOpen != widget.isOpen) {
      if (widget.isOpen) {
        _controller.forward(from: 0);
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: widget.child,
    );
  }
}

// 선택 버튼 애니메이션 위젯
class _SelectButtonAnimated extends StatefulWidget {
  @override
  State<_SelectButtonAnimated> createState() => _SelectButtonAnimatedState();
}

class _SelectButtonAnimatedState extends State<_SelectButtonAnimated> with SingleTickerProviderStateMixin {
  bool _isSelecting = false;
  late AnimationController _controller;
  late Animation<double> _splitAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _splitAnim = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  void _onSelectPressed() {
    setState(() {
      _isSelecting = true;
      _controller.forward();
    });
  }

  void _onCancelPressed() {
    setState(() {
      _isSelecting = false;
      _controller.reverse();
    });
  }

  void _onSelectAllPressed() {
    // TODO: 전체 선택 로직 연결
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _splitAnim,
      builder: (context, child) {
        final split = _splitAnim.value;
        if (!_isSelecting && split == 0) {
          // 선택 버튼
          return SizedBox(
            width: 113,
            height: 44,
            child: Material(
              color: const Color(0xFF1976D2),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(32),
                bottomLeft: Radius.circular(32),
                topRight: Radius.circular(6),
                bottomRight: Radius.circular(6),
              ),
              child: InkWell(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(32),
                  bottomLeft: Radius.circular(32),
                  topRight: Radius.circular(6),
                  bottomRight: Radius.circular(6),
                ),
                onTap: _onSelectPressed,
                child: const Center(
                  child: Text('선택', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          );
        } else {
          // 분리된 버튼 (모두, 취소)
          return Row(
            children: [
              SizedBox(
                width: 60 + 53 * (1 - split), // 애니메이션으로 자연스럽게 넓이 변화
                height: 44,
                child: Material(
                  color: const Color(0xFF1976D2),
                  borderRadius: BorderRadius.horizontal(
                    left: const Radius.circular(32),
                    right: Radius.circular(6 * (1 - split) + 32 * split),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.horizontal(
                      left: const Radius.circular(32),
                      right: Radius.circular(6 * (1 - split) + 32 * split),
                    ),
                    onTap: _onSelectAllPressed,
                    child: Center(
                      child: Text('모두', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 4 * split),
              Opacity(
                opacity: split,
                child: SizedBox(
                  width: 53 * split,
                  height: 44,
                  child: Material(
                    color: const Color(0xFF1976D2),
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(32),
                      bottomRight: Radius.circular(32),
                      topLeft: Radius.circular(6),
                      bottomLeft: Radius.circular(6),
                    ),
                    child: InkWell(
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(32),
                        bottomRight: Radius.circular(32),
                        topLeft: Radius.circular(6),
                        bottomLeft: Radius.circular(6),
                      ),
                      onTap: _onCancelPressed,
                      child: const Center(
                        child: Icon(Icons.close, color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
      },
    );
  }
} 