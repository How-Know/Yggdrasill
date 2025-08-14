import 'package:flutter/material.dart';
import '../../widgets/app_bar_title.dart';
import '../../widgets/custom_tab_bar.dart';
import '../../services/data_manager.dart';
import 'package:file_selector/file_selector.dart';

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
  final List<_ResourceFile> _files = [];

  static const Size _defaultFolderSize = Size(220, 120);
  static const List<String> kFolderShapes = ['rect', 'parallelogram', 'pill'];
  String _addType = '폴더';

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
                  selected: _addType == '폴더',
                  onTap: () async {
                    _removeDropdownMenu();
                    setState(() => _addType = '폴더');
                  },
                ),
                _DropdownMenuHoverItem(
                  label: '파일',
                  selected: _addType == '파일',
                  onTap: () async {
                    _removeDropdownMenu();
                    setState(() => _addType = '파일');
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
            shape: result.shape,
          ),
        );
      });
      await _saveLayout();
    }
  }

  Future<void> _onAddFile() async {
    final result = await showDialog<_ResourceFile>(
      context: context,
      builder: (context) => const _FileCreateDialog(),
    );
    if (result != null) {
      await DataManager.instance.saveResourceFile({
        'id': result.id,
        'name': result.name,
        'url': result.url,
        'color': result.color?.value,
        'grade': result.grade,
        'parent_id': result.parentId,
        'pos_x': result.position.dx,
        'pos_y': result.position.dy,
        'width': result.size.width,
        'height': result.size.height,
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadLayout();
  }

  Future<void> _saveLayout() async {
    try {
      // DB 저장으로 변경
      final rows = _folders.map((f) => {
        'id': f.id,
        'name': f.name,
        'description': f.description,
        'color': f.color?.value,
        'pos_x': f.position.dx,
        'pos_y': f.position.dy,
        'width': f.size.width,
        'height': f.size.height,
        'shape': f.shape,
      }).toList();
      await DataManager.instance.saveResourceFolders(rows);
    } catch (e) {
      // ignore errors silently for now
    }
  }

  Future<void> _loadLayout() async {
    try {
      final rows = await DataManager.instance.loadResourceFolders();
      final loaded = rows.map<_ResourceFolder>((r) => _ResourceFolder(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? '',
        description: (r['description'] as String?) ?? '',
        color: (r['color'] as int?) != null ? Color(r['color'] as int) : null,
        position: Offset((r['pos_x'] as num?)?.toDouble() ?? 0.0, (r['pos_y'] as num?)?.toDouble() ?? 0.0),
        size: Size((r['width'] as num?)?.toDouble() ?? _defaultFolderSize.width, (r['height'] as num?)?.toDouble() ?? _defaultFolderSize.height),
        shape: (r['shape'] as String?) ?? 'rect',
      )).toList();
      final fileRows = await DataManager.instance.loadResourceFiles();
      final loadedFiles = fileRows.map<_ResourceFile>((r) => _ResourceFile(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? '',
        url: (r['url'] as String?) ?? '',
        color: (r['color'] as int?) != null ? Color(r['color'] as int) : null,
        grade: (r['grade'] as String?) ?? '초1',
        parentId: r['parent_id'] as String?,
        position: Offset((r['pos_x'] as num?)?.toDouble() ?? 0.0, (r['pos_y'] as num?)?.toDouble() ?? 0.0),
        size: Size((r['width'] as num?)?.toDouble() ?? 200.0, (r['height'] as num?)?.toDouble() ?? 60.0),
      )).toList();
      if (mounted) {
        setState(() {
          _folders
            ..clear()
            ..addAll(loaded);
          _files
            ..clear()
            ..addAll(loadedFiles);
        });
      }
    } catch (_) {
      // file not found or parse error: ignore
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
                      files: _files,
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
                        _saveLayout();
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
                        _saveLayout();
                      },
                      onExitResizeMode: () {
                        if (_resizeMode) setState(() => _resizeMode = false);
                      },
                      onMoveEnd: _saveLayout,
                      onResizeEnd: _saveLayout,
                      onFileMoved: (id, pos, canvas) async {
                        final i = _files.indexWhere((e) => e.id == id);
                        if (i >= 0) {
                          setState(() {
                            _files[i] = _files[i].copyWith(position: pos);
                          });
                          await DataManager.instance.saveResourceFile({
                            'id': _files[i].id,
                            'name': _files[i].name,
                            'url': _files[i].url,
                            'color': _files[i].color?.value,
                            'grade': _files[i].grade,
                            'parent_id': _files[i].parentId,
                            'pos_x': pos.dx,
                            'pos_y': pos.dy,
                            'width': _files[i].size.width,
                            'height': _files[i].size.height,
                          });
                        }
                      },
                      onFileResized: (id, newSize, canvas) async {
                        final i = _files.indexWhere((e) => e.id == id);
                        if (i >= 0) {
                          setState(() {
                            _files[i] = _files[i].copyWith(size: newSize);
                          });
                          await DataManager.instance.saveResourceFile({
                            'id': _files[i].id,
                            'name': _files[i].name,
                            'url': _files[i].url,
                            'color': _files[i].color?.value,
                            'grade': _files[i].grade,
                            'parent_id': _files[i].parentId,
                            'pos_x': _files[i].position.dx,
                            'pos_y': _files[i].position.dy,
                            'width': newSize.width,
                            'height': newSize.height,
                          });
                        }
                      },
                    ),
                    _ResourcesCanvas(
                      folders: _folders,
                      files: _files,
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
                        _saveLayout();
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
                        _saveLayout();
                      },
                      onExitResizeMode: () {
                        if (_resizeMode) setState(() => _resizeMode = false);
                      },
                      onMoveEnd: _saveLayout,
                      onResizeEnd: _saveLayout,
                      onFileMoved: (id, pos, canvas) async {
                        final i = _files.indexWhere((e) => e.id == id);
                        if (i >= 0) {
                          setState(() {
                            _files[i] = _files[i].copyWith(position: pos);
                          });
                          await DataManager.instance.saveResourceFile({
                            'id': _files[i].id,
                            'name': _files[i].name,
                            'url': _files[i].url,
                            'color': _files[i].color?.value,
                            'grade': _files[i].grade,
                            'parent_id': _files[i].parentId,
                            'pos_x': pos.dx,
                            'pos_y': pos.dy,
                            'width': _files[i].size.width,
                            'height': _files[i].size.height,
                          });
                        }
                      },
                      onFileResized: (id, newSize, canvas) async {
                        final i = _files.indexWhere((e) => e.id == id);
                        if (i >= 0) {
                          setState(() {
                            _files[i] = _files[i].copyWith(size: newSize);
                          });
                          await DataManager.instance.saveResourceFile({
                            'id': _files[i].id,
                            'name': _files[i].name,
                            'url': _files[i].url,
                            'color': _files[i].color?.value,
                            'grade': _files[i].grade,
                            'parent_id': _files[i].parentId,
                            'pos_x': _files[i].position.dx,
                            'pos_y': _files[i].position.dy,
                            'width': newSize.width,
                            'height': newSize.height,
                          });
                        }
                      },
                    ),
                    _ResourcesCanvas(
                      folders: _folders,
                      files: _files,
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
                        _saveLayout();
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
                        _saveLayout();
                      },
                      onExitResizeMode: () {
                        if (_resizeMode) setState(() => _resizeMode = false);
                      },
                      onMoveEnd: _saveLayout,
                      onResizeEnd: _saveLayout,
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
                          onTap: () async {
                            if (_addType == '폴더') {
                              await _onAddFolder();
                            } else {
                              await _onAddFile();
                            }
                          },
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
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: Material(
                        color: _resizeMode ? const Color(0xFF0F467D) : const Color(0xFF1976D2),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _resizeMode = !_resizeMode),
                          child: const Center(
                            child: Icon(Icons.open_in_full, color: Colors.white, size: 18),
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
  final List<_ResourceFile> files;
  final bool resizeMode;
  final void Function(String id, Offset position, Size canvasSize) onFolderMoved;
  final void Function(String id, Size newSize, Size canvasSize)? onFolderResized;
  final VoidCallback? onExitResizeMode;
  final VoidCallback? onMoveEnd;
  final VoidCallback? onResizeEnd;
  final void Function(String id, Offset position, Size canvasSize)? onFileMoved;
  final void Function(String id, Size newSize, Size canvasSize)? onFileResized;
  const _ResourcesCanvas({required this.folders, required this.files, required this.resizeMode, required this.onFolderMoved, this.onFolderResized, this.onExitResizeMode, this.onMoveEnd, this.onResizeEnd, this.onFileMoved, this.onFileResized});

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
    const double gap = 8.0;
    const double threshold = 12.0;
    Offset snapped = pos;
    double curW;
    double curH;
    final folderMatch = widget.folders.where((x) => x.id == id).toList();
    if (folderMatch.isNotEmpty) {
      curW = folderMatch.first.size.width;
      curH = folderMatch.first.size.height;
    } else {
      final fileMatch = widget.files.where((x) => x.id == id).toList();
      if (fileMatch.isNotEmpty) {
        curW = fileMatch.first.size.width;
        curH = fileMatch.first.size.height;
      } else {
        curW = 200;
        curH = 60;
      }
    }

    final targets = <Map<String, double>>[];
    for (final f in widget.folders) {
      targets.add({'x': f.position.dx, 'y': f.position.dy, 'w': f.size.width, 'h': f.size.height});
    }
    for (final fi in widget.files) {
      targets.add({'x': fi.position.dx, 'y': fi.position.dy, 'w': fi.size.width, 'h': fi.size.height});
    }

    for (final t in targets) {
      final fx = t['x']!;
      final fy = t['y']!;
      final fw = t['w']!;
      final fh = t['h']!;
      // 수평 스냅(오른쪽에 붙이기)
      final targetRight = fx + fw + gap;
      if ((snapped.dx - targetRight).abs() <= threshold && (snapped.dy - fy).abs() <= 24) {
        snapped = Offset(targetRight, fy);
      }
      // 수평 스냅(왼쪽에 붙이기)
      final targetLeft = fx - curW - gap;
      if ((snapped.dx - targetLeft).abs() <= threshold && (snapped.dy - fy).abs() <= 24) {
        snapped = Offset(targetLeft, fy);
      }
      // 수직 스냅(아래에 붙이기)
      final targetBelow = fy + fh + gap;
      if ((snapped.dy - targetBelow).abs() <= threshold && (snapped.dx - fx).abs() <= 24) {
        snapped = Offset(fx, targetBelow);
      }
      // 수직 스냅(위에 붙이기)
      final targetAbove = fy - curH - gap;
      if ((snapped.dy - targetAbove).abs() <= threshold && (snapped.dx - fx).abs() <= 24) {
        snapped = Offset(fx, targetAbove);
      }
      // 상단 라인 정렬(수평 센터/좌우 맞춤은 다음 라인에서 진행)
      if ((snapped.dy - fy).abs() <= threshold) snapped = Offset(snapped.dx, fy);
      // 수평 센터 정렬
      final centerX = fx + fw / 2;
      if ((snapped.dx + curW / 2 - centerX).abs() <= threshold) {
        snapped = Offset(centerX - curW / 2, snapped.dy);
      }
      // 수직 센터 정렬
      final centerY = fy + fh / 2;
      if ((snapped.dy + curH / 2 - centerY).abs() <= threshold) {
        snapped = Offset(snapped.dx, centerY - curH / 2);
      }
    }
    return snapped;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          onPointerSignal: (_) {},
          child: Stack(
          key: _stackKey,
          children: [
            if (widget.folders.isEmpty && widget.files.isEmpty)
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
                    if (widget.onMoveEnd != null) widget.onMoveEnd!();
                  },
                  globalToCanvasLocal: _globalToCanvasLocal,
                  resizeMode: widget.resizeMode,
                  onResize: (size) {
                    if (widget.onFolderResized != null) widget.onFolderResized!(f.id, size, _canvasSize);
                  },
                  onBackgroundTap: () {
                    if (widget.onExitResizeMode != null) widget.onExitResizeMode!();
                  },
                  onResizeEnd: () {
                    if (widget.onResizeEnd != null) widget.onResizeEnd!();
                  },
                )),
            // 파일 카드 렌더링 (간단 placeholder 스타일)
            ...widget.files.map((fi) => _DraggableFileCard(
                  key: ValueKey('file_${fi.id}')
                , file: fi,
                  resizeMode: widget.resizeMode,
                  globalToCanvasLocal: _globalToCanvasLocal,
                  onMoved: (pos) {
                    if (widget.onFileMoved != null) widget.onFileMoved!(fi.id, pos, _canvasSize);
                  },
                  onEndMoved: (pos) {
                    final snapped = _applySnap(pos, fi.id);
                    if (widget.onFileMoved != null) widget.onFileMoved!(fi.id, snapped, _canvasSize);
                    if (widget.onMoveEnd != null) widget.onMoveEnd!();
                  },
                  onResize: (size) {
                    if (widget.onFileResized != null) widget.onFileResized!(fi.id, size, _canvasSize);
                  },
                  onResizeEnd: () { if (widget.onResizeEnd != null) widget.onResizeEnd!(); },
                )),
          ],
          ),
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
  final VoidCallback? onResizeEnd;
  const _DraggableFolderCard({super.key, required this.folder, required this.onMoved, this.onEndMoved, required this.globalToCanvasLocal, required this.resizeMode, this.onResize, this.onBackgroundTap, this.onResizeEnd});

  @override
  State<_DraggableFolderCard> createState() => _DraggableFolderCardState();
}

class _DraggableFolderCardState extends State<_DraggableFolderCard> {
  bool _dragging = false;
  Offset _dragStartLocal = Offset.zero;
  bool _resizing = false;
  Offset? _tempPosition;
  Size? _tempSize;

  @override
  Widget build(BuildContext context) {
    final handleSize = 14.0;
    final effectivePos = _tempPosition ?? widget.folder.position;
    final effectiveSize = _tempSize ?? widget.folder.size;
    return Positioned(
      left: effectivePos.dx,
      top: effectivePos.dy,
      child: GestureDetector(
        onPanStart: (details) {
          if (!_resizing && !widget.resizeMode) {
            setState(() {
              _dragging = true;
              _dragStartLocal = details.localPosition;
              _tempPosition = widget.folder.position;
            });
          }
        },
        onPanUpdate: (details) {
          if (_dragging && !_resizing && !widget.resizeMode) {
            final local = details.localPosition;
            final newPos = Offset(effectivePos.dx + details.delta.dx, effectivePos.dy + details.delta.dy);
            setState(() => _tempPosition = newPos);
          }
        },
        onPanEnd: (details) {
          setState(() => _dragging = false);
          final endPos = _tempPosition ?? widget.folder.position;
          if (widget.onEndMoved != null) widget.onEndMoved!(endPos);
          _tempPosition = null;
        },
        // 리사이즈 모드 종료는 버튼으로만 수행: 배경 탭 종료 제거
        behavior: HitTestBehavior.translucent,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _dragging ? 0.85 : 1.0,
          child: Stack(
            children: [
              _FolderCard(folder: widget.folder.copyWith(position: effectivePos, size: effectiveSize)),
              if (widget.resizeMode)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    // 내부 터치 영역(도형 내부)으로 이동
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) {
                        setState(() {
                          _resizing = true;
                          _tempSize = widget.folder.size;
                        });
                      },
                    onPanUpdate: (d) {
                        if (widget.onResize != null) {
                        double newW = ( _tempSize ?? widget.folder.size ).width + d.delta.dx;
                        double newH = ( _tempSize ?? widget.folder.size ).height + d.delta.dy;
                        // 최소/최대 가드: 음수/0 방지
                        if (newW < 120) newW = 120;
                        if (newH < 60) newH = 60;
                        setState(() => _tempSize = Size(newW, newH));
                        }
                      },
                    onPanEnd: (_) {
                      setState(() => _resizing = false);
                        final finalSize = _tempSize ?? widget.folder.size;
                        if (widget.onResize != null) widget.onResize!(finalSize);
                        if (widget.onResizeEnd != null) widget.onResizeEnd!();
                        _tempSize = null;
                    },
                      child: const Icon(Icons.open_in_full, size: 16, color: Colors.white70),
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
    final baseDecoration = BoxDecoration(
      color: const Color(0xFF1F1F1F),
      borderRadius: folder.shape == 'pill' ? BorderRadius.circular(999) : BorderRadius.circular(12),
      border: Border.all(color: (folder.color ?? Colors.white24).withOpacity(0.75), width: 2.5),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 10, offset: const Offset(0, 6)),
      ],
    );
    final EdgeInsets contentPadding = folder.shape == 'pill' ? const EdgeInsets.fromLTRB(22, 14, 14, 14) : const EdgeInsets.all(14);
    final double minHeight = 60;
    final double currentHeight = folder.size.height < minHeight ? minHeight : folder.size.height;
    Widget content = Container(
      width: folder.size.width,
      height: currentHeight,
      padding: contentPadding,
      decoration: baseDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 26, // 10 줄임
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
          Expanded(
            child: Text(
              folder.description.isEmpty ? '-' : folder.description,
              maxLines: (currentHeight / 20).clamp(2, 20).toInt(),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
    if (folder.shape == 'parallelogram') {
      // 기울기를 더 작게 (완만하게)
      content = Transform(
        transform: Matrix4.skewX(-0.15),
        origin: const Offset(0, 0),
        child: content,
      );
    }
    return content;
  }
}

class _ResourceFolder {
  final String id;
  final String name;
  final Color? color;
  final String description;
  final Offset position;
  final Size size;
  final String shape;
  _ResourceFolder({required this.id, required this.name, required this.color, required this.description, required this.position, required this.size, required this.shape});

  _ResourceFolder copyWith({String? id, String? name, Color? color, String? description, Offset? position, Size? size, String? shape}) {
    return _ResourceFolder(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      description: description ?? this.description,
      position: position ?? this.position,
      size: size ?? this.size,
      shape: shape ?? this.shape,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color != null ? {'r': color!.red, 'g': color!.green, 'b': color!.blue, 'a': color!.alpha} : null,
    'description': description,
    'position': {'x': position.dx, 'y': position.dy},
    'size': {'w': size.width, 'h': size.height},
  };

  factory _ResourceFolder.fromJson(Map<String, dynamic> json) {
    final c = json['color'];
    final color = c == null ? null : Color.fromARGB(c['a'] ?? 255, c['r'] ?? 0, c['g'] ?? 0, c['b'] ?? 0);
    final pos = json['position'] ?? {'x': 0.0, 'y': 0.0};
    final sz = json['size'] ?? {'w': 220.0, 'h': 120.0};
    return _ResourceFolder(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      color: color,
      description: json['description'] as String? ?? '',
      position: Offset((pos['x'] as num).toDouble(), (pos['y'] as num).toDouble()),
      size: Size((sz['w'] as num).toDouble(), (sz['h'] as num).toDouble()),
      shape: (json['shape'] as String?) ?? 'rect',
    );
  }
}

class _FolderCreateDialog extends StatefulWidget {
  const _FolderCreateDialog();
  @override
  State<_FolderCreateDialog> createState() => _FolderCreateDialogState();
}

class _ResourceFile {
  final String id;
  final String name;
  final String url; // hyperlink or path
  final Color? color; // filled style
  final String grade; // 초1..고3
  final String? parentId; // for nesting
  final Offset position;
  final Size size;
  const _ResourceFile({required this.id, required this.name, required this.url, required this.color, required this.grade, this.parentId, required this.position, required this.size});

  _ResourceFile copyWith({String? id, String? name, String? url, Color? color, String? grade, String? parentId, Offset? position, Size? size}) {
    return _ResourceFile(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      color: color ?? this.color,
      grade: grade ?? this.grade,
      parentId: parentId ?? this.parentId,
      position: position ?? this.position,
      size: size ?? this.size,
    );
  }
}

class _FileCreateDialog extends StatefulWidget {
  const _FileCreateDialog();
  @override
  State<_FileCreateDialog> createState() => _FileCreateDialogState();
}

class _FileCreateDialogState extends State<_FileCreateDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  Color? _selectedColor;
  String _grade = '초1';
  final List<String> _grades = [
    '초1','초2','초3','초4','초5','초6',
    '중1','중2','중3',
    '고1','고2','고3',
  ];
  final List<Color?> _colors = [null, ...Colors.primaries];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _urlController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _handleSave() {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이름과 위치(하이퍼링크)를 입력하세요.')),
      );
      return;
    }
    Navigator.of(context).pop(
      _ResourceFile(
        id: UniqueKey().toString(),
        name: name,
        url: url,
        color: _selectedColor,
        grade: _grade,
        parentId: null,
        position: const Offset(0, 0),
        size: const Size(200, 60),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('파일 추가', style: TextStyle(color: Colors.white)),
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
                labelText: '파일 이름',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: '위치(하이퍼링크)',
                      labelStyle: TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final typeGroup = XTypeGroup(label: 'files', extensions: ['pdf','hwp','hwpx','xlsx','xls','doc','docx','ppt','pptx']);
                      final file = await openFile(acceptedTypeGroups: [typeGroup]);
                      if (file != null) {
                        _urlController.text = file.path;
                        if (_nameController.text.trim().isEmpty) {
                          _nameController.text = file.name;
                        }
                      }
                    },
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('찾기'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text('색상 (가득찬 스타일)', style: TextStyle(color: Colors.white70, fontSize: 15)),
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
            const SizedBox(height: 18),
            const Text('학년', style: TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _grade,
              dropdownColor: const Color(0xFF2A2A2A),
              items: _grades.map((g) => DropdownMenuItem(value: g, child: Text(g, style: const TextStyle(color: Colors.white)))).toList(),
              onChanged: (v) => setState(() => _grade = v ?? _grade),
              decoration: const InputDecoration(
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
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

class _FolderCreateDialogState extends State<_FolderCreateDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  Color? _selectedColor;
  final List<Color?> _colors = [null, ...Colors.primaries];
  String _shape = 'rect';

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
        shape: _shape,
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
            const SizedBox(height: 18),
            const Text('모양', style: TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('직사각형'),
                  selected: _shape == 'rect',
                  onSelected: (_) => setState(() => _shape = 'rect'),
                ),
                ChoiceChip(
                  label: const Text('평행사변형'),
                  selected: _shape == 'parallelogram',
                  onSelected: (_) => setState(() => _shape = 'parallelogram'),
                ),
                ChoiceChip(
                  label: const Text('알약'),
                  selected: _shape == 'pill',
                  onSelected: (_) => setState(() => _shape = 'pill'),
                ),
              ],
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


class _DraggableFileCard extends StatefulWidget {
  final _ResourceFile file;
  final bool resizeMode;
  final Offset Function(Offset global) globalToCanvasLocal;
  final void Function(Offset newPosition) onMoved;
  final void Function(Offset newPosition)? onEndMoved;
  final void Function(Size newSize)? onResize;
  final VoidCallback? onResizeEnd;
  final VoidCallback? onAddChild;
  const _DraggableFileCard({super.key, required this.file, required this.resizeMode, required this.globalToCanvasLocal, required this.onMoved, this.onEndMoved, this.onResize, this.onResizeEnd, this.onAddChild});

  @override
  State<_DraggableFileCard> createState() => _DraggableFileCardState();
}

class _DraggableFileCardState extends State<_DraggableFileCard> {
  bool _dragging = false;
  bool _resizing = false;
  Offset? _tempPosition;
  Size? _tempSize;

  @override
  Widget build(BuildContext context) {
    final effectivePos = _tempPosition ?? widget.file.position;
    final effectiveSize = _tempSize ?? widget.file.size;
    return Positioned(
      left: effectivePos.dx,
      top: effectivePos.dy,
      child: GestureDetector(
        onPanStart: (_) {
          if (!_resizing && !widget.resizeMode) {
            setState(() {
              _dragging = true;
              _tempPosition = widget.file.position;
            });
          }
        },
        onPanUpdate: (d) {
          if (_dragging && !_resizing && !widget.resizeMode) {
            setState(() => _tempPosition = Offset(effectivePos.dx + d.delta.dx, effectivePos.dy + d.delta.dy));
          }
        },
        onPanEnd: (_) {
          setState(() => _dragging = false);
          final endPos = _tempPosition ?? widget.file.position;
          if (widget.onEndMoved != null) widget.onEndMoved!(endPos);
          _tempPosition = null;
        },
        behavior: HitTestBehavior.translucent,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _dragging ? 0.9 : 1.0,
          child: Stack(
            children: [
              _FileCard(file: widget.file.copyWith(position: effectivePos, size: effectiveSize)),
              if (widget.resizeMode)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) {
                      setState(() {
                        _resizing = true;
                        _tempSize = widget.file.size;
                      });
                    },
                    onPanUpdate: (d) {
                      double newW = (_tempSize ?? widget.file.size).width + d.delta.dx;
                      double newH = (_tempSize ?? widget.file.size).height + d.delta.dy;
                      if (newW < 140) newW = 140;
                      if (newH < 48) newH = 48;
                      setState(() => _tempSize = Size(newW, newH));
                    },
                    onPanEnd: (_) {
                      setState(() => _resizing = false);
                      final finalSize = _tempSize ?? widget.file.size;
                      if (widget.onResize != null) widget.onResize!(finalSize);
                      if (widget.onResizeEnd != null) widget.onResizeEnd!();
                      _tempSize = null;
                    },
                    child: const Icon(Icons.open_in_full, size: 16, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  final _ResourceFile file;
  const _FileCard({required this.file});

  @override
  Widget build(BuildContext context) {
    final bg = file.color ?? const Color(0xFF2D2D2D);
    return Container(
      width: file.size.width,
      height: file.size.height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24, width: 1.2),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.insert_drive_file, color: Colors.white70, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.2),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              file.grade,
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

