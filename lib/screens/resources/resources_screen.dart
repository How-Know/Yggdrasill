import 'package:flutter/material.dart';
import '../../widgets/app_bar_title.dart';
import '../../widgets/custom_tab_bar.dart';

class ResourcesScreen extends StatefulWidget {
  const ResourcesScreen({super.key});

  @override
  State<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends State<ResourcesScreen> {
  int _customTabIndex = 0;
  final GlobalKey _dropdownButtonKey = GlobalKey();
  OverlayEntry? _dropdownOverlay;
  bool _isDropdownOpen = false;
  bool _resizeMode = false;

  final List<_ResourceFolder> _folders = [];

  static const Size _defaultFolderSize = Size(220, 120);

  Rect _rectOfFolder(_ResourceFolder f) => Rect.fromLTWH(f.position.dx, f.position.dy, f.size.width, f.size.height);

  bool _isOverlapping(String id, Rect candidate) {
    for (final other in _folders) {
      if (other.id == id) continue;
      if (candidate.overlaps(_rectOfFolder(other))) return true;
    }
    return false;
  }

  Offset _clampPosition(Offset pos, Size size, Size canvasSize) {
    final maxX = (canvasSize.width - size.width).clamp(0.0, double.infinity);
    final maxY = (canvasSize.height - size.height).clamp(0.0, double.infinity);
    return Offset(
      pos.dx.clamp(0.0, maxX),
      pos.dy.clamp(0.0, maxY),
    );
  }

  void _showDropdownMenu() {
    final RenderBox buttonRenderBox = _dropdownButtonKey.currentContext!.findRenderObject() as RenderBox;
    final Offset buttonPosition = buttonRenderBox.localToGlobal(Offset.zero);
    final Size buttonSize = buttonRenderBox.size;
    _dropdownOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: buttonPosition.dx,
        top: buttonPosition.dy - 8 - 80, // 버튼 위쪽 살짝
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 160,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _DropdownMenuHoverItem(
                  label: '폴더',
                  selected: false,
                  onTap: () async {
                    _removeDropdownMenu();
                    await _onAddFolder();
                  },
                ),
                _DropdownMenuHoverItem(
                  label: '파일',
                  selected: false,
                  onTap: () async {
                    _removeDropdownMenu();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('파일 추가는 곧 지원됩니다.')),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_dropdownOverlay!);
    setState(() => _isDropdownOpen = true);
  }

  void _removeDropdownMenu() {
    _dropdownOverlay?.remove();
    _dropdownOverlay = null;
    if (mounted) {
      setState(() => _isDropdownOpen = false);
    }
  }

  Future<void> _onAddFolder() async {
    final result = await showDialog<_ResourceFolder>(
      context: context,
      builder: (context) => const _FolderCreateDialog(),
    );
    if (result != null) {
      // 기본 위치를 간단한 그리드 규칙으로 배치 (겹침 방지)
      final double stepX = _defaultFolderSize.width + 20.0;
      final double stepY = _defaultFolderSize.height + 20.0;
      double baseX = 24.0 + (_folders.length % 4) * stepX;
      double baseY = 24.0 + (_folders.length ~/ 4) * stepY;
      Rect candidate = Rect.fromLTWH(baseX, baseY, _defaultFolderSize.width, _defaultFolderSize.height);
      int guard = 0;
      while (_isOverlapping(result.id, candidate) && guard < 100) {
        baseX += stepX;
        if (baseX + _defaultFolderSize.width > MediaQuery.of(context).size.width - 24.0) {
          baseX = 24.0;
          baseY += stepY;
        }
        candidate = Rect.fromLTWH(baseX, baseY, _defaultFolderSize.width, _defaultFolderSize.height);
        guard++;
      }
      setState(() {
        _folders.add(
          _ResourceFolder(
            id: result.id,
            name: result.name,
            color: result.color,
            description: result.description,
            position: Offset(baseX, baseY),
            size: _defaultFolderSize,
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: const AppBarTitle(title: '자료'),
      body: Stack(
        children: [
          Column(
            children: [
              const SizedBox(height: 0),
              SizedBox(height: 5),
              CustomTabBar(
                selectedIndex: _customTabIndex,
                tabs: const ['교재', '시험', '기타'],
                onTabSelected: (i) {
                  setState(() {
                    _customTabIndex = i;
                  });
                },
              ),
              const SizedBox(height: 1),
              Expanded(
                child: IndexedStack(
                  index: _customTabIndex,
                  children: [
                    _ResourcesCanvas(
                      folders: _folders,
                      resizeMode: _resizeMode,
                      onFolderMoved: (id, pos, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final size = _folders[i].size;
                            final clamped = _clampPosition(pos, size, canvasSize);
                            final candidate = Rect.fromLTWH(clamped.dx, clamped.dy, size.width, size.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(position: clamped);
                            }
                          }
                        });
                      },
                      onFolderResized: (id, newSize, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final minW = 160.0;
                            final minH = 90.0;
                            final pos = _folders[i].position;
                            final maxW = (canvasSize.width - pos.dx).clamp(minW, canvasSize.width);
                            final maxH = (canvasSize.height - pos.dy).clamp(minH, canvasSize.height);
                            final w = newSize.width.clamp(minW, maxW);
                            final h = newSize.height.clamp(minH, maxH);
                            final clampedSize = Size(w, h);
                            final candidate = Rect.fromLTWH(pos.dx, pos.dy, clampedSize.width, clampedSize.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(size: clampedSize);
                            }
                          }
                        });
                      },
                      onExitResizeMode: () {
                        if (_resizeMode) setState(() => _resizeMode = false);
                      },
                    ),
                    _ResourcesCanvas(
                      folders: _folders,
                      resizeMode: _resizeMode,
                      onFolderMoved: (id, pos, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final size = _folders[i].size;
                            final clamped = _clampPosition(pos, size, canvasSize);
                            final candidate = Rect.fromLTWH(clamped.dx, clamped.dy, size.width, size.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(position: clamped);
                            }
                          }
                        });
                      },
                      onFolderResized: (id, newSize, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final minW = 160.0;
                            final minH = 90.0;
                            final pos = _folders[i].position;
                            final maxW = (canvasSize.width - pos.dx).clamp(minW, canvasSize.width);
                            final maxH = (canvasSize.height - pos.dy).clamp(minH, canvasSize.height);
                            final w = newSize.width.clamp(minW, maxW);
                            final h = newSize.height.clamp(minH, maxH);
                            final clampedSize = Size(w, h);
                            final candidate = Rect.fromLTWH(pos.dx, pos.dy, clampedSize.width, clampedSize.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(size: clampedSize);
                            }
                          }
                        });
                      },
                      onExitResizeMode: () {
                        if (_resizeMode) setState(() => _resizeMode = false);
                      },
                    ),
                    _ResourcesCanvas(
                      folders: _folders,
                      resizeMode: _resizeMode,
                      onFolderMoved: (id, pos, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final size = _folders[i].size;
                            final clamped = _clampPosition(pos, size, canvasSize);
                            final candidate = Rect.fromLTWH(clamped.dx, clamped.dy, size.width, size.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(position: clamped);
                            }
                          }
                        });
                      },
                      onFolderResized: (id, newSize, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final minW = 160.0;
                            final minH = 90.0;
                            final pos = _folders[i].position;
                            final maxW = (canvasSize.width - pos.dx).clamp(minW, canvasSize.width);
                            final maxH = (canvasSize.height - pos.dy).clamp(minH, canvasSize.height);
                            final w = newSize.width.clamp(minW, maxW);
                            final h = newSize.height.clamp(minH, maxH);
                            final clampedSize = Size(w, h);
                            final candidate = Rect.fromLTWH(pos.dx, pos.dy, clampedSize.width, clampedSize.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(size: clampedSize);
                            }
                          }
                        });
                      },
                      onExitResizeMode: () {
                        if (_resizeMode) setState(() => _resizeMode = false);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 96), // 하단 플로팅 영역 확보
            ],
          ),
          // 하단 중앙 플로팅 버튼 그룹
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 10, offset: const Offset(0, 6)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
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
                          onTap: _onAddFolder,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.max,
                            children: const [
                              Icon(Icons.add, color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Text('추가', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 113,
                      height: 44,
                      child: Material(
                        color: _resizeMode ? const Color(0xFF0F467D) : const Color(0xFF1976D2),
                        borderRadius: BorderRadius.circular(22),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: () => setState(() => _resizeMode = !_resizeMode),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.max,
                            children: [
                              const Icon(Icons.open_in_full, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Text(_resizeMode ? '크기 해제' : '크기', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Container(
                      height: 44,
                      width: 3.0,
                      color: Colors.transparent,
                      child: Center(
                        child: Container(
                          width: 2,
                          height: 28,
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.5),
                      child: GestureDetector(
                        key: _dropdownButtonKey,
                        onTap: () {
                          if (_dropdownOverlay == null) {
                            _showDropdownMenu();
                          } else {
                            _removeDropdownMenu();
                          }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 350),
                          width: 44,
                          height: 44,
                          decoration: ShapeDecoration(
                            color: const Color(0xFF1976D2),
                            shape: RoundedRectangleBorder(
                              borderRadius: _isDropdownOpen
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
                              turns: _isDropdownOpen ? 0.5 : 0.0,
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
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourcesCanvas extends StatefulWidget {
  final List<_ResourceFolder> folders;
  final bool resizeMode;
  final void Function(String id, Offset position, Size canvasSize) onFolderMoved;
  final void Function(String id, Size newSize, Size canvasSize)? onFolderResized;
  final VoidCallback? onExitResizeMode;
  const _ResourcesCanvas({required this.folders, required this.resizeMode, required this.onFolderMoved, this.onFolderResized, this.onExitResizeMode});

  @override
  State<_ResourcesCanvas> createState() => _ResourcesCanvasState();
}

class _ResourcesCanvasState extends State<_ResourcesCanvas> {
  Size _canvasSize = Size.zero;
  final GlobalKey _stackKey = GlobalKey();

  Offset _globalToCanvasLocal(Offset global) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return global;
    return box.globalToLocal(global);
  }

  Offset _applySnap(Offset pos, String id) {
    const double cardWidth = 220.0;
    const double gap = 8.0;
    const double threshold = 12.0;
    Offset snapped = pos;
    for (final f in widget.folders) {
      if (f.id == id) continue;
      final fx = f.position.dx;
      final fy = f.position.dy;
      // 수평 스냅(오른쪽에 붙이기)
      final targetRight = fx + cardWidth + gap;
      if ((snapped.dx - targetRight).abs() <= threshold && (snapped.dy - fy).abs() <= 24) {
        snapped = Offset(targetRight, fy);
      }
      // 수평 스냅(왼쪽에 붙이기)
      final targetLeft = fx - cardWidth - gap;
      if ((snapped.dx - targetLeft).abs() <= threshold && (snapped.dy - fy).abs() <= 24) {
        snapped = Offset(targetLeft, fy);
      }
      // 수직 정렬(상단 라인 맞춤)
      if ((snapped.dy - fy).abs() <= threshold) {
        snapped = Offset(snapped.dx, fy);
      }
    }
    return snapped;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          key: _stackKey,
          children: [
            if (widget.folders.isEmpty)
              const Center(
                child: Text('추가 버튼으로 폴더 또는 파일을 만들어 보세요.', style: TextStyle(color: Colors.white38, fontSize: 16)),
              ),
            ...widget.folders.map((f) => _DraggableFolderCard(
                  key: ValueKey(f.id),
                  folder: f,
                  onMoved: (pos) => widget.onFolderMoved(f.id, pos, _canvasSize),
                  onEndMoved: (pos) {
                    final snapped = _applySnap(pos, f.id);
                    widget.onFolderMoved(f.id, snapped, _canvasSize);
                  },
                  globalToCanvasLocal: _globalToCanvasLocal,
                  resizeMode: widget.resizeMode,
                  onResize: (size) {
                    if (widget.onFolderResized != null) widget.onFolderResized!(f.id, size, _canvasSize);
                  },
                  onBackgroundTap: () {
                    if (widget.onExitResizeMode != null) widget.onExitResizeMode!();
                  },
                )),
          ],
        );
      },
    );
  }
}

class _DraggableFolderCard extends StatefulWidget {
  final _ResourceFolder folder;
  final void Function(Offset newPosition) onMoved;
  final void Function(Offset newPosition)? onEndMoved;
  final Offset Function(Offset global) globalToCanvasLocal;
  final bool resizeMode;
  final void Function(Size newSize)? onResize;
  final VoidCallback? onBackgroundTap;
  const _DraggableFolderCard({super.key, required this.folder, required this.onMoved, this.onEndMoved, required this.globalToCanvasLocal, required this.resizeMode, this.onResize, this.onBackgroundTap});

  @override
  State<_DraggableFolderCard> createState() => _DraggableFolderCardState();
}

class _DraggableFolderCardState extends State<_DraggableFolderCard> {
  bool _dragging = false;
  Offset _dragStartLocal = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final handleSize = 14.0;
    return Positioned(
      left: widget.folder.position.dx,
      top: widget.folder.position.dy,
      child: GestureDetector(
        onLongPressStart: (details) {
          setState(() {
            _dragging = true;
            _dragStartLocal = details.localPosition;
          });
        },
        onLongPressMoveUpdate: (details) {
          if (_dragging) {
            final global = details.globalPosition;
            final local = widget.globalToCanvasLocal(global);
            final newPos = Offset(local.dx - _dragStartLocal.dx, local.dy - _dragStartLocal.dy);
            widget.onMoved(newPos);
          }
        },
        onLongPressEnd: (details) {
          setState(() => _dragging = false);
          final global = details.globalPosition;
          final local = widget.globalToCanvasLocal(global);
          final endPos = Offset(local.dx - _dragStartLocal.dx, local.dy - _dragStartLocal.dy);
          if (widget.onEndMoved != null) widget.onEndMoved!(endPos);
        },
        onTapDown: (_) {
          if (widget.onBackgroundTap != null && widget.resizeMode) widget.onBackgroundTap!();
        },
        behavior: HitTestBehavior.translucent,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _dragging ? 0.85 : 1.0,
          child: Stack(
            children: [
              _FolderCard(folder: widget.folder),
              if (widget.resizeMode)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) {
                      if (widget.onResize != null) {
                        final newW = widget.folder.size.width + d.delta.dx;
                        final newH = widget.folder.size.height + d.delta.dy;
                        widget.onResize!(Size(newW, newH));
                      }
                    },
                    child: Container(
                      width: handleSize,
                      height: handleSize,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1976D2),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: Colors.white24, width: 1),
                      ),
                      child: const Icon(Icons.open_in_full, size: 10, color: Colors.white),
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

class _FolderCard extends StatelessWidget {
  final _ResourceFolder folder;
  const _FolderCard({required this.folder});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: folder.size.width,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: (folder.color ?? Colors.white24).withOpacity(0.75), width: 2.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 10, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 색상 인디케이터: 기둥형
              Container(
                width: 6,
                height: 36,
                decoration: BoxDecoration(
                  color: folder.color ?? const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            folder.description.isEmpty ? '-' : folder.description,
            maxLines: (folder.size.height / 20).clamp(2, 6).toInt(),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _ResourceFolder {
  final String id;
  final String name;
  final Color? color;
  final String description;
  final Offset position;
  final Size size;
  _ResourceFolder({required this.id, required this.name, required this.color, required this.description, required this.position, required this.size});

  _ResourceFolder copyWith({String? id, String? name, Color? color, String? description, Offset? position, Size? size}) {
    return _ResourceFolder(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      description: description ?? this.description,
      position: position ?? this.position,
      size: size ?? this.size,
    );
  }
}

class _FolderCreateDialog extends StatefulWidget {
  const _FolderCreateDialog();
  @override
  State<_FolderCreateDialog> createState() => _FolderCreateDialogState();
}

class _FolderCreateDialogState extends State<_FolderCreateDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  Color? _selectedColor;
  final List<Color?> _colors = [null, ...Colors.primaries];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _handleSave() {
    final name = _nameController.text.trim();
    final desc = _descController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('폴더명을 입력하세요.')),
      );
      return;
    }
    Navigator.of(context).pop(
      _ResourceFolder(
        id: UniqueKey().toString(),
        name: name,
        color: _selectedColor,
        description: desc,
        position: Offset.zero, // 임시, 호출측에서 배치 계산
        size: const Size(220, 120),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('폴더 추가', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '폴더명',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              style: const TextStyle(color: Colors.white),
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '설명',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 18),
            const Text('폴더 색상', style: TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _colors.map((color) {
                final isSelected = _selectedColor == color;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = color),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: color ?? Colors.transparent,
                      border: Border.all(
                        color: isSelected ? Colors.white : Colors.white24,
                        width: isSelected ? 2.2 : 1.2,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: color == null
                        ? const Center(child: Icon(Icons.close_rounded, color: Colors.white54, size: 16))
                        : null,
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('추가'),
        ),
      ],
    );
  }
}

class _DropdownMenuHoverItem extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DropdownMenuHoverItem({required this.label, required this.selected, required this.onTap});

  @override
  State<_DropdownMenuHoverItem> createState() => _DropdownMenuHoverItemState();
}

class _DropdownMenuHoverItemState extends State<_DropdownMenuHoverItem> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final highlight = _hovered || widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 160,
          height: 40,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          decoration: BoxDecoration(
            color: highlight ? const Color(0xFF383838).withOpacity(0.7) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            widget.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}


