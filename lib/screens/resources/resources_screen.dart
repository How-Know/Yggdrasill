import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/gestures.dart';
import '../../widgets/app_bar_title.dart';
import '../../widgets/custom_tab_bar.dart';
import '../../services/data_manager.dart';
import 'package:file_selector/file_selector.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:pdfrx/pdfrx.dart';
import 'dart:ui' as ui;
import 'dart:math' as math;

class _ResColors {
  static const Color container1 = Color(0xFF263238);
  static const Color container2 = Color(0xFF37474F);
  static const Color container3 = Color(0xFF455A64);
  static const Color container4 = Color(0xFF546E7A);
  static const Color container5 = Color(0xFF607D8B);
  static const Color blue1 = Color(0xFF166ABD);
  static const Color blue2 = Color(0xFF145EA8);
  static const Color blue3 = Color(0xFF115293);
  static const Color blue4 = Color(0xFF0F467D);
  static const Color blue5 = Color(0xFF0C3A69);
}

const List<IconData> _gradeIconPack = [
  Icons.school,
  Icons.menu_book,
  Icons.bookmark,
  Icons.star,
  Icons.favorite,
  Icons.lightbulb,
  Icons.flag,
  Icons.language,
  Icons.calculate,
  Icons.science,
  Icons.psychology,
  Icons.code,
  Icons.draw,
  Icons.piano,
  Icons.sports_basketball,
  Icons.public,
  Icons.attach_file,
  Icons.folder,
  Icons.create,
  Icons.edit_note,
];

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
  bool _editMode = false;

  final List<_ResourceFolder> _folders = [];
  final List<_ResourceFile> _files = [];

  // 학년 관리 상태
  final GlobalKey _gradeButtonKey = GlobalKey();
  OverlayEntry? _gradeOverlay;
  bool _isGradeMenuOpen = false;
  List<String> _grades = [];
  int _selectedGradeIndex = 0;
  int _lastGradeScrollMs = 0;

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

  void _changeGradeByDelta(int delta) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastGradeScrollMs < 60) return; // 간단 디바운스로 중복 처리 방지
    _lastGradeScrollMs = now;
    if (_grades.isEmpty) return;
    final before = _selectedGradeIndex;
    final next = (_selectedGradeIndex + delta).clamp(0, _grades.length - 1);
    if (before != next) {
      setState(() => _selectedGradeIndex = next as int);
      // ignore: avoid_print
      print('[GRADE] scroll -> index: $_selectedGradeIndex, name: ${_grades[_selectedGradeIndex]}');
    }
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
      builder: (context) {
        return Positioned(
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
      );
      },
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

  Future<void> _ensureGradesLoaded() async {
    try {
      final rows = await DataManager.instance.getResourceGrades();
      final list = rows.map((e) => (e['name'] as String?) ?? '').where((e) => e.isNotEmpty).toList();
      if (list.isEmpty) {
        final defaults = ['초1','초2','초3','초4','초5','초6','중1','중2','중3','고1','고2','고3'];
        await DataManager.instance.saveResourceGrades(defaults);
        _grades = defaults;
      } else {
        _grades = list;
      }
      _selectedGradeIndex = _selectedGradeIndex.clamp(0, _grades.isEmpty ? 0 : _grades.length - 1);
    } catch (_) {
      _grades = [];
      _selectedGradeIndex = 0;
    }
  }

  void _openGradeMenu() {
    if (_isGradeMenuOpen) return;
    final box = _gradeButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    _gradeOverlay = OverlayEntry(
      builder: (context) {
        return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeGradeMenu,
          ),
        ),
        Positioned(
          left: pos.dx,
          top: pos.dy + size.height + 6,
          child: Material(
          color: Colors.transparent,
          child: Container(
            width: 252,
            constraints: const BoxConstraints(maxHeight: 360),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10, width: 1),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 18, offset: const Offset(0,8))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      const Text('과정', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                      const Spacer(),
                      IconButton(
                        tooltip: '추가',
                        onPressed: () async {
                          if (_isGradeMenuOpen) {
                            // ignore: avoid_print
                            print('[GRADE] + 버튼: 먼저 오버레이 닫기');
                            _closeGradeMenu();
                          }
                          final result = await showDialog<Map<String, dynamic>>(
                            context: context,
                            barrierDismissible: true,
                            builder: (ctx) {
                              final controller = TextEditingController();
                              final icons = <IconData>[
                                Icons.school, Icons.menu_book, Icons.bookmark, Icons.star,
                                Icons.favorite, Icons.lightbulb, Icons.flag, Icons.language,
                                Icons.calculate, Icons.science, Icons.psychology, Icons.code,
                                Icons.draw, Icons.piano, Icons.sports_basketball, Icons.public,
                                Icons.attach_file, Icons.folder, Icons.create, Icons.edit_note,
                              ];
                              int selectedIconIndex = 0;
                              return AlertDialog(
                                backgroundColor: const Color(0xFF1F1F1F),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                title: const Text('학년 추가', style: TextStyle(color: Colors.white, fontSize: 20)),
                                content: SizedBox(
                                  width: 520,
                                  child: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                    TextField(
                                      controller: controller,
                                      style: const TextStyle(color: Colors.white),
                                      decoration: const InputDecoration(
                                        hintText: '과정명을 입력하세요',
                                        hintStyle: TextStyle(color: Colors.white38),
                                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                                        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                  // 아이콘 선택 그리드
                                        SizedBox(
                                          height: 120,
                                          child: StatefulBuilder(
                                            builder: (ctx2, setState2) => GridView.builder(
                                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                                crossAxisCount: 10,
                                                mainAxisSpacing: 6,
                                                crossAxisSpacing: 6,
                                              ),
                                              itemCount: icons.length,
                                              shrinkWrap: true,
                                              primary: false,
                                              physics: const NeverScrollableScrollPhysics(),
                                              itemBuilder: (c, i) {
                                                final selected = i == selectedIconIndex;
                                                return InkWell(
                                                  onTap: () => setState2(() => selectedIconIndex = i),
                                                  borderRadius: BorderRadius.circular(8),
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      color: selected ? const Color(0xFF1976D2).withOpacity(0.25) : const Color(0xFF2A2A2A),
                                                      borderRadius: BorderRadius.circular(8),
                                                      border: Border.all(color: selected ? const Color(0xFF1976D2) : Colors.white24),
                                                    ),
                                                    alignment: Alignment.center,
                                                    child: Icon(icons[i], color: Colors.white70, size: 18),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                                  const SizedBox(width: 8),
                                  FilledButton(
                                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                                    onPressed: () => Navigator.pop(ctx, {
                                      'name': controller.text.trim(),
                                      'icon': icons[selectedIconIndex].codePoint,
                                    }),
                                    child: const Text('추가'),
                                  ),
                                ],
                              );
                            },
                          );
                          if (result != null) {
                            final name = (result['name'] as String?)?.trim() ?? '';
                            final icon = (result['icon'] as int?) ?? 0;
                            if (name.isNotEmpty) {
                              setState(() => _grades.add(name));
                              await DataManager.instance.saveResourceGrades(_grades);
                              if (icon != 0) {
                                await DataManager.instance.setResourceGradeIcon(name, icon);
                              }
                              Overlay.of(context).setState(() {});
                              // 다이얼로그 종료 후 다시 메뉴를 열어 사용 흐름 유지
                              _openGradeMenu();
                            }
                          }
                        },
                        icon: const Icon(Icons.add, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Colors.white12),
                SizedBox(
                  height: 280,
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    itemCount: _grades.length,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    buildDefaultDragHandles: false,
                    proxyDecorator: (child, index, animation) {
                      return Material(
                        color: Colors.transparent,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white10, width: 1),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 12, offset: const Offset(0, 6)),
                            ],
                          ),
                          child: child,
                        ),
                      );
                    },
                    onReorder: (oldIndex, newIndex) async {
                      if (newIndex > oldIndex) newIndex -= 1;
                      setState(() {
                        final item = _grades.removeAt(oldIndex);
                        _grades.insert(newIndex, item);
                        _selectedGradeIndex = _selectedGradeIndex.clamp(0, _grades.length - 1);
                      });
                      await DataManager.instance.saveResourceGrades(_grades);
                    },
                    itemBuilder: (context, index) {
                      final g = _grades[index];
                      final selected = index == _selectedGradeIndex;
                      return ListTile(
                        key: ValueKey('grade_${index}_$g'),
                        onTap: () {
                          setState(() => _selectedGradeIndex = index);
                          _closeGradeMenu();
                        },
                dense: true,
                selected: selected,
                selectedTileColor: const Color(0xFF333333),
                        title: FutureBuilder<Map<String, int>>(
                          future: DataManager.instance.getResourceGradeIcons(),
                          builder: (context, snapshot) {
                            final map = snapshot.data ?? const {};
                            final code = map[g];
                            final icon = code != null ? IconData(code, fontFamily: 'MaterialIcons') : null;
                            return Row(
                              children: [
                                if (icon != null) ...[
                                  Icon(icon, color: Colors.white60, size: 16),
                                  const SizedBox(width: 8),
                                ],
                                Expanded(
                                  child: Text(
                                    g,
                                    style: TextStyle(
                                      color: selected ? Colors.white : Colors.white70,
                                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '이름 변경',
                              icon: const Icon(Icons.edit, color: Colors.white54, size: 18),
                              onPressed: () async {
                                final controller = TextEditingController(text: g);
                                final icons = <IconData>[
                                  Icons.school, Icons.menu_book, Icons.bookmark, Icons.star,
                                  Icons.favorite, Icons.lightbulb, Icons.flag, Icons.language,
                                  Icons.calculate, Icons.science, Icons.psychology, Icons.code,
                                  Icons.draw, Icons.piano, Icons.sports_basketball, Icons.public,
                                  Icons.attach_file, Icons.folder, Icons.create, Icons.edit_note,
                                ];
                                if (_isGradeMenuOpen) {
                                  // ignore: avoid_print
                                  print('[GRADE] 수정 다이얼로그: 먼저 오버레이 닫기');
                                  _closeGradeMenu();
                                }
                                final newResult = await showDialog<Map<String, dynamic>>(
                                  context: context,
                                  barrierDismissible: true,
                                  builder: (ctx) => StatefulBuilder(
                                    builder: (ctx2, setState2) {
                                      int selectedIconIndex = 0;
                                      return AlertDialog(
                                    backgroundColor: const Color(0xFF1F1F1F),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        title: const Text('학년 정보 수정', style: TextStyle(color: Colors.white, fontSize: 20)),
                                        content: SizedBox(
                                          width: 520,
                                          child: SingleChildScrollView(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                            TextField(
                                              controller: controller,
                                              style: const TextStyle(color: Colors.white),
                                              decoration: const InputDecoration(
                                                hintText: '새 학년명',
                                                hintStyle: TextStyle(color: Colors.white38),
                                                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                                                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            SizedBox(
                                              height: 120,
                                              child: GridView.builder(
                                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount: 10,
                                                  mainAxisSpacing: 6,
                                                  crossAxisSpacing: 6,
                                                ),
                                                itemCount: icons.length,
                                                shrinkWrap: true,
                                                primary: false,
                                                physics: const NeverScrollableScrollPhysics(),
                                                itemBuilder: (c, i) {
                                                  final selected = i == selectedIconIndex;
                                                  return InkWell(
                                                    onTap: () => setState2(() => selectedIconIndex = i),
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: Container(
                                                      decoration: BoxDecoration(
                                                        color: selected ? const Color(0xFF1976D2).withOpacity(0.25) : const Color(0xFF2A2A2A),
                                                        borderRadius: BorderRadius.circular(8),
                                                        border: Border.all(color: selected ? const Color(0xFF1976D2) : Colors.white24),
                                                      ),
                                                      alignment: Alignment.center,
                                                      child: Icon(icons[i], color: Colors.white70, size: 18),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(ctx2), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                                          FilledButton(
                                            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                                            onPressed: () => Navigator.pop(ctx2, {
                                              'name': controller.text.trim(),
                                              'icon': icons[selectedIconIndex].codePoint,
                                            }),
                                            child: const Text('저장'),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                );
                                if (newResult != null) {
                                  final newName = (newResult['name'] as String?)?.trim() ?? '';
                                  final icon = (newResult['icon'] as int?) ?? 0;
                                  if (newName.isNotEmpty) {
                                    setState(() => _grades[index] = newName);
                                    await DataManager.instance.saveResourceGrades(_grades);
                                    if (icon != 0) {
                                      await DataManager.instance.setResourceGradeIcon(newName, icon);
                                    }
                                    Overlay.of(context).setState(() {});
                                  }
                                }
                              },
                            ),
                            IconButton(
                              tooltip: '삭제',
                              icon: const Icon(Icons.delete_outline, color: Colors.white54, size: 18),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    backgroundColor: const Color(0xFF1F1F1F),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    title: const Text('삭제 확인', style: TextStyle(color: Colors.white, fontSize: 20)),
                                    content: Text('"$g" 학년을 삭제할까요?', style: const TextStyle(color: Colors.white70)),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                                      FilledButton(
                                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: const Text('삭제'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  setState(() {
                                    _grades.removeAt(index);
                                    if (_grades.isEmpty) {
                                      _selectedGradeIndex = 0;
                                    } else {
                                      _selectedGradeIndex = _selectedGradeIndex.clamp(0, _grades.length - 1);
                                    }
                                  });
                                  await DataManager.instance.saveResourceGrades(_grades);
                                  Overlay.of(context).setState(() {});
                                }
                              },
                            ),
                            const SizedBox(width: 6),
                            ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_handle, color: Colors.white38),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        ),
      ]);
      },
    );
    Overlay.of(context).insert(_gradeOverlay!);
    setState(() => _isGradeMenuOpen = true);
    // 외부 클릭/포커스 이동 시 자동 닫기
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).unfocus();
      // Route 변화 감지하여 닫기
      ModalRoute.of(context)?.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () {
        if (_isGradeMenuOpen) _closeGradeMenu();
      }));
    });
  }

  void _closeGradeMenu() {
    _gradeOverlay?.remove();
    _gradeOverlay = null;
    setState(() => _isGradeMenuOpen = false);
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
    // 1단계: 메타 입력
    final metaResult = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const _FileCreateDialog(),
    );
    if (metaResult == null || metaResult['meta'] is! _ResourceFile) return; // 취소 시 중단
    final meta = metaResult['meta'] as _ResourceFile;
    // 2단계: 링크 등록(정답/해설)
    final linksResult = await showDialog<Map<String, Map<String, String>>>(
      context: context,
      builder: (context) => _FileLinksDialog(meta: meta),
    );
    if (linksResult == null) return; // 취소 시 생성 중단 (버그 수정)
    final finalLinks = linksResult['links'] ?? <String, String>{};
    final merged = meta.copyWith(linksByGrade: finalLinks);
      // 파일 메타 저장
      await DataManager.instance.saveResourceFile({
      'id': merged.id,
      'name': merged.name,
      'url': '',
      'color': merged.color?.value,
      'grade': merged.primaryGrade ?? '',
      'parent_id': merged.parentId,
      'pos_x': merged.position.dx,
      'pos_y': merged.position.dy,
      'width': merged.size.width,
      'height': merged.size.height,
      'text_color': merged.textColor?.value,
      'icon_image_path': merged.iconImagePath,
      'description': merged.description,
      });
      // 학년별 링크 저장
    await DataManager.instance.saveResourceFileLinks(merged.id, merged.linksByGrade);
    // 상태 반영
    setState(() {
      _files.add(merged);
    });
  }

  @override
  void initState() {
    super.initState();
    _loadLayout();
    _ensureGradesLoaded();
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
      final List<_ResourceFile> loadedFiles = [];
      for (final r in fileRows) {
        final id = r['id'] as String;
        final links = await DataManager.instance.loadResourceFileLinks(id);
        loadedFiles.add(_ResourceFile(
          id: id,
          name: (r['name'] as String?) ?? '',
          color: (r['color'] as int?) != null ? Color(r['color'] as int) : null,
          textColor: (r['text_color'] as int?) != null ? Color(r['text_color'] as int) : null,
          iconImagePath: (r['icon_image_path'] as String?),
          description: (r['description'] as String?),
          parentId: r['parent_id'] as String?,
          position: Offset((r['pos_x'] as num?)?.toDouble() ?? 0.0, (r['pos_y'] as num?)?.toDouble() ?? 0.0),
          size: Size((r['width'] as num?)?.toDouble() ?? 200.0, (r['height'] as num?)?.toDouble() ?? 60.0),
          linksByGrade: links,
        ));
      }
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

  bool _rectsHorizontallyOverlap(Rect a, Rect b) => !(a.right < b.left || b.right < a.left);
  bool _rectsVerticallyOverlap(Rect a, Rect b) => !(a.bottom < b.top || b.bottom < a.top);
  double _gapX(Rect a, Rect b) {
    if (a.right < b.left) return b.left - a.right;
    if (b.right < a.left) return a.left - b.right;
    return 0.0;
  }
  double _gapY(Rect a, Rect b) {
    if (a.bottom < b.top) return b.top - a.bottom;
    if (b.bottom < a.top) return a.top - b.bottom;
    return 0.0;
  }
  bool _isNear(Rect a, Rect b, double threshold) {
    final gx = _gapX(a, b);
    final gy = _gapY(a, b);
    final overlapX = _rectsHorizontallyOverlap(a, b);
    final overlapY = _rectsVerticallyOverlap(a, b);
    return (gx <= threshold && overlapY) || (gy <= threshold && overlapX);
  }

  void _moveNeighborsTogether({required String movedId, required Rect movedRect, required Offset delta, required Size canvasSize, double threshold = 20}) async {
    // ignore: avoid_print
    print('[GROUP][start] id=$movedId delta=$delta movedRect=$movedRect threshold=$threshold');
    // 폴더 이동
    for (int j = 0; j < _folders.length; j++) {
      final other = _folders[j];
      if (other.id == movedId) continue;
      final otherRect = Rect.fromLTWH(other.position.dx, other.position.dy, other.size.width, other.size.height);
      if (_isNear(movedRect, otherRect, threshold)) {
        final target = _clampPosition(other.position + delta, other.size, canvasSize);
        final candidate = Rect.fromLTWH(target.dx, target.dy, other.size.width, other.size.height);
        if (!_isOverlapping(other.id, candidate)) {
          _folders[j] = other.copyWith(position: target);
          // ignore: avoid_print
          print('[GROUP][folder-move] id=${other.id} -> $target');
        }
      }
    }
    // 파일 이동 + 즉시 저장
    for (int j = 0; j < _files.length; j++) {
      final other = _files[j];
      if (other.id == movedId) continue; // 주체 파일은 제외
      final otherRect = Rect.fromLTWH(other.position.dx, other.position.dy, other.size.width, other.size.height);
      if (_isNear(movedRect, otherRect, threshold)) {
        final target = _clampPosition(other.position + delta, other.size, canvasSize);
        final candidate = Rect.fromLTWH(target.dx, target.dy, other.size.width, other.size.height);
        // 파일은 폴더와 달리 DB에 별도 저장 필요
        _files[j] = other.copyWith(position: target);
        // ignore: avoid_print
        print('[GROUP][file-move] id=${other.id} -> $target');
        await DataManager.instance.saveResourceFile({
          'id': _files[j].id,
          'name': _files[j].name,
          'url': (_files[j].primaryGrade != null) ? (_files[j].linksByGrade[_files[j].primaryGrade!] ?? '') : '',
          'color': _files[j].color?.value,
          'grade': _files[j].primaryGrade ?? '',
          'parent_id': _files[j].parentId,
          'pos_x': target.dx,
          'pos_y': target.dy,
          'width': _files[j].size.width,
          'height': _files[j].size.height,
          'text_color': _files[j].textColor?.value,
          'icon_image_path': _files[j].iconImagePath,
          'description': _files[j].description,
        });
      }
    }
    // ignore: avoid_print
    print('[GROUP][end]');
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
                    // 탭 전환 시에는 드롭다운을 닫되, 탭 전환 직후 build 전에 닫기 로직이 다시 먹지 않도록 여기만 처리
                    if (_isGradeMenuOpen) _closeGradeMenu();
                    _customTabIndex = i;
                  });
                },
              ),
              const SizedBox(height: 1),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: OutlinedButton.icon(
                    key: _gradeButtonKey,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38, width: 1.4),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15.4),
                    ),
                    onPressed: () async {
                      // 버튼 연속 클릭 시만 닫기. 닫혀있으면 열기만 수행
                      if (_isGradeMenuOpen) _closeGradeMenu();
                      await _ensureGradesLoaded();
                      // 오픈만 수행
                      _openGradeMenu();
                    },
                    icon: const Icon(Icons.school, size: 20),
                    label: Text(
                      _grades.isEmpty ? '' : _grades[_selectedGradeIndex],
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: _customTabIndex,
                  children: [
                    _ResourcesCanvas(
                      folders: _folders,
                      files: _files,
                      resizeMode: _resizeMode,
                      editMode: _editMode,
                      currentGrade: _grades.isEmpty ? null : _grades[_selectedGradeIndex],
                      onScrollGrade: (delta) => _changeGradeByDelta(delta),
                      onDeleteFolder: (folderId) async {
                        // UI에서 먼저 제거
                        setState(() {
                          _folders.removeWhere((f) => f.id == folderId);
                        });
                        // 저장
                        await _saveLayout();
                      },
                      onDeleteFile: (fileId) async {
                        // UI에서 제거
                        setState(() {
                          _files.removeWhere((f) => f.id == fileId);
                        });
                        // DB 삭제(메타+링크)
                        await DataManager.instance.deleteResourceFile(fileId);
                      },
                      onFolderMoved: (id, pos, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final prevPos = _folders[i].position;
                            final size = _folders[i].size;
                            final clamped = _clampPosition(pos, size, canvasSize);
                            final delta = clamped - prevPos;
                            final candidate = Rect.fromLTWH(clamped.dx, clamped.dy, size.width, size.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(position: clamped);
                              final movedRect = candidate;
                              _moveNeighborsTogether(movedId: id, movedRect: movedRect, delta: delta, canvasSize: canvasSize);
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
                          final prev = _files[i].position;
                          final size = _files[i].size;
                          final clamped = _clampPosition(pos, size, canvas);
                          final delta = clamped - prev;
                          setState(() {
                            _files[i] = _files[i].copyWith(position: clamped);
                            final movedRect = Rect.fromLTWH(clamped.dx, clamped.dy, size.width, size.height);
                            _moveNeighborsTogether(movedId: id, movedRect: movedRect, delta: delta, canvasSize: canvas);
                          });
                          await DataManager.instance.saveResourceFile({
                            'id': _files[i].id,
                            'name': _files[i].name,
                            'url': (_files[i].primaryGrade != null) ? (_files[i].linksByGrade[_files[i].primaryGrade!] ?? '') : '',
                            'color': _files[i].color?.value,
                            'grade': _files[i].primaryGrade ?? '',
                            'parent_id': _files[i].parentId,
                            'pos_x': clamped.dx,
                            'pos_y': clamped.dy,
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
                            'url': (_files[i].primaryGrade != null) ? (_files[i].linksByGrade[_files[i].primaryGrade!] ?? '') : '',
                            'color': _files[i].color?.value,
                            'grade': _files[i].primaryGrade ?? '',
                            'parent_id': _files[i].parentId,
                            'pos_x': _files[i].position.dx,
                            'pos_y': _files[i].position.dy,
                            'width': newSize.width,
                            'height': newSize.height,
                          });
                        }
                      },
                      onEditFolder: (folder) {
                        // ignore: avoid_print
                        print('[EDIT] Open FolderEditDialog: id=${folder.id}');
                        showDialog(
                          context: context,
                          builder: (ctx) => _FolderEditDialog(initial: folder),
                        );
                      },
                      onEditFile: (file) async {
                        print('[EDIT] Open FileEdit (2-step): id=${file.id}');
                        final metaUpdated = await showDialog<Map<String, dynamic>>(
                          context: context,
                          builder: (ctx) => _FileEditDialog(initial: file),
                        );
                        if (metaUpdated == null) return;
                        final updatedFile = (metaUpdated['file'] as _ResourceFile?) ?? file;
                        final existingLinks = await DataManager.instance.loadResourceFileLinks(file.id);
                        final linksResult = await showDialog<Map<String, Map<String, String>>>(
                          context: context,
                          builder: (ctx) => _FileLinksDialog(meta: updatedFile, initialLinks: existingLinks),
                        );
                        final finalLinks = linksResult?['links'] ?? <String, String>{};
                        // DB 저장
                        await DataManager.instance.saveResourceFile({
                          'id': updatedFile.id,
                          'name': updatedFile.name,
                          'url': '',
                          'color': updatedFile.color?.value,
                          'grade': updatedFile.primaryGrade ?? '',
                          'parent_id': updatedFile.parentId,
                          'pos_x': updatedFile.position.dx,
                          'pos_y': updatedFile.position.dy,
                          'width': updatedFile.size.width,
                          'height': updatedFile.size.height,
                          'text_color': updatedFile.textColor?.value,
                          'icon_image_path': updatedFile.iconImagePath,
                          'description': updatedFile.description,
                        });
                        await DataManager.instance.saveResourceFileLinks(updatedFile.id, finalLinks);
                        // 상태 업데이트
                        setState(() {
                          final idx = _files.indexWhere((f) => f.id == updatedFile.id);
                          if (idx != -1) {
                            _files[idx] = updatedFile.copyWith(linksByGrade: finalLinks);
                          }
                        });
                      },
                    ),
                    _ResourcesCanvas(
                      folders: _folders,
                      files: _files,
                      resizeMode: _resizeMode,
                       editMode: _editMode,
                      currentGrade: _grades.isEmpty ? null : _grades[_selectedGradeIndex],
                      onScrollGrade: (delta) => _changeGradeByDelta(delta),
                      onDeleteFolder: (folderId) async {
                        setState(() { _folders.removeWhere((f) => f.id == folderId); });
                        await _saveLayout();
                      },
                      onDeleteFile: (fileId) async {
                        setState(() { _files.removeWhere((f) => f.id == fileId); });
                        await DataManager.instance.deleteResourceFile(fileId);
                      },
                      onFolderMoved: (id, pos, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final prevPos = _folders[i].position;
                            final size = _folders[i].size;
                            final clamped = _clampPosition(pos, size, canvasSize);
                            final delta = clamped - prevPos;
                            final candidate = Rect.fromLTWH(clamped.dx, clamped.dy, size.width, size.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(position: clamped);
                              final movedRect = candidate;
                              _moveNeighborsTogether(movedId: id, movedRect: movedRect, delta: delta, canvasSize: canvasSize);
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
                          final prev = _files[i].position;
                          final size = _files[i].size;
                          final clamped = _clampPosition(pos, size, canvas);
                          final delta = clamped - prev;
                          setState(() {
                            _files[i] = _files[i].copyWith(position: clamped);
                            final movedRect = Rect.fromLTWH(clamped.dx, clamped.dy, size.width, size.height);
                            _moveNeighborsTogether(movedId: id, movedRect: movedRect, delta: delta, canvasSize: canvas);
                          });
                          await DataManager.instance.saveResourceFile({
                            'id': _files[i].id,
                            'name': _files[i].name,
                            'url': (_files[i].primaryGrade != null) ? (_files[i].linksByGrade[_files[i].primaryGrade!] ?? '') : '',
                            'color': _files[i].color?.value,
                            'grade': _files[i].primaryGrade ?? '',
                            'parent_id': _files[i].parentId,
                            'pos_x': clamped.dx,
                            'pos_y': clamped.dy,
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
                            'url': (_files[i].primaryGrade != null) ? (_files[i].linksByGrade[_files[i].primaryGrade!] ?? '') : '',
                            'color': _files[i].color?.value,
                            'grade': _files[i].primaryGrade ?? '',
                            'parent_id': _files[i].parentId,
                            'pos_x': _files[i].position.dx,
                            'pos_y': _files[i].position.dy,
                            'width': newSize.width,
                            'height': newSize.height,
                          });
                        }
                      },
                      onEditFolder: (folder) {
                        // ignore: avoid_print
                        print('[EDIT] Open FolderEditDialog: id=${folder.id}');
                        showDialog(
                          context: context,
                          builder: (ctx) => _FolderEditDialog(initial: folder),
                        );
                      },
                      onEditFile: (file) async {
                        print('[EDIT] Open FileEdit (2-step): id=${file.id}');
                        final metaUpdated = await showDialog<Map<String, dynamic>>(
                          context: context,
                          builder: (ctx) => _FileEditDialog(initial: file),
                        );
                        if (metaUpdated == null) return;
                        final updatedFile = (metaUpdated['file'] as _ResourceFile?) ?? file;
                        final existingLinks = await DataManager.instance.loadResourceFileLinks(file.id);
                        final linksResult = await showDialog<Map<String, Map<String, String>>>(
                          context: context,
                          builder: (ctx) => _FileLinksDialog(meta: updatedFile, initialLinks: existingLinks),
                        );
                        final finalLinks = linksResult?['links'] ?? <String, String>{};
                        await DataManager.instance.saveResourceFile({
                          'id': updatedFile.id,
                          'name': updatedFile.name,
                          'url': '',
                          'color': updatedFile.color?.value,
                          'grade': updatedFile.primaryGrade ?? '',
                          'parent_id': updatedFile.parentId,
                          'pos_x': updatedFile.position.dx,
                          'pos_y': updatedFile.position.dy,
                          'width': updatedFile.size.width,
                          'height': updatedFile.size.height,
                          'text_color': updatedFile.textColor?.value,
                          'icon_image_path': updatedFile.iconImagePath,
                          'description': updatedFile.description,
                        });
                        await DataManager.instance.saveResourceFileLinks(updatedFile.id, finalLinks);
                        setState(() {
                          final idx = _files.indexWhere((f) => f.id == updatedFile.id);
                          if (idx != -1) {
                            _files[idx] = updatedFile.copyWith(linksByGrade: finalLinks);
                          }
                        });
                      },
                    ),
                    _ResourcesCanvas(
                      folders: _folders,
                      files: _files,
                      resizeMode: _resizeMode,
                       editMode: _editMode,
                      currentGrade: _grades.isEmpty ? null : _grades[_selectedGradeIndex],
                      onScrollGrade: (delta) => _changeGradeByDelta(delta),
                      onDeleteFolder: (folderId) async {
                        setState(() { _folders.removeWhere((f) => f.id == folderId); });
                        await _saveLayout();
                      },
                      onDeleteFile: (fileId) async {
                        setState(() { _files.removeWhere((f) => f.id == fileId); });
                        await DataManager.instance.deleteResourceFile(fileId);
                      },
                      onFolderMoved: (id, pos, canvasSize) {
                        setState(() {
                          final i = _folders.indexWhere((f) => f.id == id);
                          if (i >= 0) {
                            final prevPos = _folders[i].position;
                            final size = _folders[i].size;
                            final clamped = _clampPosition(pos, size, canvasSize);
                            final delta = clamped - prevPos;
                            final candidate = Rect.fromLTWH(clamped.dx, clamped.dy, size.width, size.height);
                            if (!_isOverlapping(id, candidate)) {
                              _folders[i] = _folders[i].copyWith(position: clamped);
                              final movedRect = candidate;
                              _moveNeighborsTogether(movedId: id, movedRect: movedRect, delta: delta, canvasSize: canvasSize);
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
                      onEditFolder: (folder) {
                        // ignore: avoid_print
                        print('[EDIT] Open FolderEditDialog: id=${folder.id}');
                        showDialog(
                          context: context,
                          builder: (ctx) => _FolderEditDialog(initial: folder),
                        );
                      },
                      onEditFile: (file) {
                        // ignore: avoid_print
                        print('[EDIT] Open FileEditDialog: id=${file.id}');
                        showDialog(
                          context: context,
                          builder: (ctx) => _FileEditDialog(initial: file),
                        );
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
                        color: _editMode ? const Color(0xFF0F467D) : const Color(0xFF1976D2),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() { _editMode = !_editMode; if (_editMode) _resizeMode = false; }),
                          child: const Center(
                            child: Icon(Icons.edit, color: Colors.white, size: 18),
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
                          onTap: () => setState(() { _resizeMode = !_resizeMode; if (_resizeMode) _editMode = false; }),
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

class _FileLinksDialog extends StatefulWidget {
  final _ResourceFile meta;
  final Map<String, String>? initialLinks;
  const _FileLinksDialog({required this.meta, this.initialLinks});
  @override
  State<_FileLinksDialog> createState() => _FileLinksDialogState();
}

class _FileLinksDialogState extends State<_FileLinksDialog> {
  List<String> _grades = [];
  late final Map<String, TextEditingController> _answerCtrls;   // 본문
  late final Map<String, TextEditingController> _solutionCtrls; // 해설
  late final Map<String, TextEditingController> _bodyCtrls;     // 정답
  @override
  void initState() {
    super.initState();
    _init();
  }
  Future<void> _init() async {
    final rows = await DataManager.instance.getResourceGrades();
    final list = rows.map((e) => (e['name'] as String?) ?? '').where((e) => e.isNotEmpty).toList();
    _grades = list.isEmpty ? ['초1','초2','초3','초4','초5','초6','중1','중2','중3','고1','고2','고3'] : list;
    _answerCtrls = { for (final g in _grades) g: TextEditingController(text: widget.initialLinks?['$g#body'] ?? '') };
    _solutionCtrls = { for (final g in _grades) g: TextEditingController(text: widget.initialLinks?['$g#sol'] ?? '') };
    _bodyCtrls = { for (final g in _grades) g: TextEditingController(text: widget.initialLinks?['$g#ans'] ?? '') };
    if (mounted) setState(() {});
  }
  @override
  void dispose() {
    for (final c in _answerCtrls.values) { c.dispose(); }
    for (final c in _solutionCtrls.values) { c.dispose(); }
    for (final c in _bodyCtrls.values) { c.dispose(); }
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('링크 등록', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _grades.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final grade = _grades[index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(grade, style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 6),
                      // 본문 행
                      Row(children: [
                        Expanded(child: DropTarget(
                          onDragDone: (detail) {
                            if (detail.files.isEmpty) return;
                            final xf = detail.files.first; final path = xf.path; if (path != null && path.isNotEmpty) {
                              setState(() => _bodyCtrls[grade]!.text = path);
                            }
                          },
                          child: _LinkActionButtons(controller: _bodyCtrls[grade]!, onNameSuggestion: (name){}, label: '본문', grade: grade, kindKey: 'body'),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: TextField(
                          controller: _bodyCtrls[grade],
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(hintText: '본문: https:// 또는 파일 경로', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
                        )),
                      ]),
                      const SizedBox(height: 6),
                      // 해설 행
                      Row(children: [
                        Expanded(child: DropTarget(
                          onDragDone: (detail) {
                            if (detail.files.isEmpty) return;
                            final xf = detail.files.first; final path = xf.path; if (path != null && path.isNotEmpty) {
                              setState(() => _solutionCtrls[grade]!.text = path);
                            }
                          },
                          child: _LinkActionButtons(controller: _solutionCtrls[grade]!, onNameSuggestion: (name){}, label: '해설', grade: grade, kindKey: 'sol'),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: TextField(
                          controller: _solutionCtrls[grade],
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(hintText: '해설: https:// 또는 파일 경로', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
                        )),
                      ]),
                      const SizedBox(height: 6),
                      // 정답 행
                      Row(children: [
                        Expanded(child: DropTarget(
                          onDragDone: (detail) {
                            if (detail.files.isEmpty) return;
                            final xf = detail.files.first; final path = xf.path; if (path != null && path.isNotEmpty) {
                              setState(() => _answerCtrls[grade]!.text = path);
                            }
                          },
                          child: _LinkActionButtons(controller: _answerCtrls[grade]!, onNameSuggestion: (name){}, label: '정답', grade: grade, kindKey: 'ans'),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: TextField(
                          controller: _answerCtrls[grade],
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(hintText: '정답: https:// 또는 파일 경로', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
                        )),
                      ]),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          onPressed: () {
            final links = <String, String>{};
            for (final g in _grades) {
              final body = _answerCtrls[g]!.text.trim();
              final ans = _bodyCtrls[g]!.text.trim();
              final sol = _solutionCtrls[g]!.text.trim();
              if (body.isNotEmpty) links['$g#body'] = body;
              if (ans.isNotEmpty) links['$g#ans'] = ans;
              if (sol.isNotEmpty) links['$g#sol'] = sol;
            }
            Navigator.pop(context, {'links': links});
          },
          child: const Text('완료'),
        ),
      ],
    );
  }
}

class _LinkActionButtons extends StatelessWidget {
  final TextEditingController controller;
  final void Function(String name) onNameSuggestion;
  final String label;
  final String grade;
  final String kindKey; // 'body' | 'ans' | 'sol'
  const _LinkActionButtons({required this.controller, required this.onNameSuggestion, required this.label, required this.grade, required this.kindKey});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
        height: 34,
        child: OutlinedButton.icon(
          onPressed: () async {
            final typeGroup = XTypeGroup(label: 'files', extensions: ['pdf','hwp','hwpx','xlsx','xls','doc','docx','ppt','pptx']);
            final file = await openFile(acceptedTypeGroups: [typeGroup]);
            if (file != null) {
              controller.text = file.path;
              // UI 즉시 반영 보장
              (context as Element).markNeedsBuild();
              onNameSuggestion(file.name);
            }
          },
          icon: const Icon(Icons.folder_open, size: 16),
          label: Text(label),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        height: 34,
        child: OutlinedButton.icon(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('해당 행에 파일을 드래그해서 놓으면 등록됩니다.')));
          },
          icon: const Icon(Icons.file_download, size: 16),
          label: const Text('드롭'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        height: 34,
        child: OutlinedButton.icon(
          onPressed: () async {
            final out = await showDialog<String>(
              context: context,
              builder: (ctx) => _PdfEditorDialog(
                initialInputPath: controller.text.trim().isEmpty ? null : controller.text.trim(),
                grade: grade,
                kindKey: kindKey,
              ),
            );
            if (out != null && out.isNotEmpty) {
              controller.text = out;
              (context as Element).markNeedsBuild();
            }
          },
          icon: const Icon(Icons.picture_as_pdf, size: 16),
          label: const Text('편집'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
        ),
      ),
    ]);
  }
}

class _ResourcesCanvas extends StatefulWidget {
  final List<_ResourceFolder> folders;
  final List<_ResourceFile> files;
  final bool resizeMode;
  final bool editMode;
  final String? currentGrade;
  final void Function(String id, Offset position, Size canvasSize) onFolderMoved;
  final void Function(String id, Size newSize, Size canvasSize)? onFolderResized;
  final VoidCallback? onExitResizeMode;
  final VoidCallback? onMoveEnd;
  final VoidCallback? onResizeEnd;
  final void Function(String id, Offset position, Size canvasSize)? onFileMoved;
  final void Function(String id, Size newSize, Size canvasSize)? onFileResized;
  final void Function(int delta)? onScrollGrade;
  final void Function(String folderId)? onDeleteFolder;
  final void Function(String fileId)? onDeleteFile;
  final void Function(_ResourceFolder folder)? onEditFolder;
  final void Function(_ResourceFile file)? onEditFile;
  const _ResourcesCanvas({required this.folders, required this.files, required this.resizeMode, required this.editMode, required this.currentGrade, required this.onFolderMoved, this.onFolderResized, this.onExitResizeMode, this.onMoveEnd, this.onResizeEnd, this.onFileMoved, this.onFileResized, this.onScrollGrade, this.onDeleteFolder, this.onDeleteFile, this.onEditFolder, this.onEditFile});

  @override
  State<_ResourcesCanvas> createState() => _ResourcesCanvasState();
}

class _ResourcesCanvasState extends State<_ResourcesCanvas> {
  Size _canvasSize = Size.zero;
  final GlobalKey _stackKey = GlobalKey();
  final Set<String> _selectedIds = <String>{}; // 'folder:ID' or 'file:ID'
  Offset? _panStartLocal;
  bool _isDraggingAny = false;

  bool _isSelectedFolder(String id) => _selectedIds.contains('folder:$id');
  bool _isSelectedFile(String id) => _selectedIds.contains('file:$id');
  void _toggleSelectFolder(String id) {
    setState(() {
      final key = 'folder:$id';
      if (_selectedIds.contains(key)) {
        _selectedIds.remove(key);
      } else {
        _selectedIds.add(key);
      }
    });
  }
  void _toggleSelectFile(String id) {
    setState(() {
      final key = 'file:$id';
      if (_selectedIds.contains(key)) {
        _selectedIds.remove(key);
      } else {
        _selectedIds.add(key);
      }
    });
  }
  Iterable<_ResourceFolder> _selectedFolders() => widget.folders.where((f) => _isSelectedFolder(f.id));
  Iterable<_ResourceFile> _selectedFiles() => widget.files.where((f) => _isSelectedFile(f.id));

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

  // 마퀴(박스) 선택 상태
  bool _isMarqueeSelecting = false;
  Offset? _marqueeStart;
  Rect? _marqueeRect;
  void _beginMarquee(Offset local) {
    setState(() {
      _isMarqueeSelecting = true;
      _marqueeStart = local;
      _marqueeRect = Rect.fromLTWH(local.dx, local.dy, 0, 0);
    });
  }
  void _updateMarquee(Offset local) {
    if (!_isMarqueeSelecting || _marqueeStart == null) return;
    final a = _marqueeStart!;
    final rect = Rect.fromLTRB(
      math.min(a.dx, local.dx),
      math.min(a.dy, local.dy),
      math.max(a.dx, local.dx),
      math.max(a.dy, local.dy),
    );
    setState(() => _marqueeRect = rect);
  }
  void _endMarquee() {
    if (!_isMarqueeSelecting) return;
    final rect = _marqueeRect;
    setState(() {
      _isMarqueeSelecting = false;
      _marqueeStart = null;
      _marqueeRect = null;
      if (rect != null) {
        _selectedIds.clear();
        for (final f in widget.folders) {
          final r = Rect.fromLTWH(f.position.dx, f.position.dy, f.size.width, f.size.height);
          if (r.overlaps(rect)) _selectedIds.add('folder:${f.id}');
        }
        for (final fi in widget.files) {
          final r = Rect.fromLTWH(fi.position.dx, fi.position.dy, fi.size.width, fi.size.height);
          if (r.overlaps(rect)) _selectedIds.add('file:${fi.id}');
        }
      }
    });
  }

  // 그룹 드래그(실시간 미리보기)
  bool _groupDragActive = false;
  String? _groupDragAnchorKey; // 'folder:ID' or 'file:ID'
  Offset _groupDragDelta = Offset.zero;
  Offset? _groupDragAnchorBasePos;
  final Map<String, Offset> _groupStartPositions = <String, Offset>{}; // key -> start pos
  bool _isApplyingGroupEnd = false;
  void beginGroupDrag({required String anchorKey, required Offset basePos}) {
    setState(() {
      _groupDragActive = true;
      _groupDragAnchorKey = anchorKey;
      _groupDragAnchorBasePos = basePos;
      _groupDragDelta = Offset.zero;
      _isDraggingAny = true;
      _groupStartPositions.clear();
      // 앵커 포함 현재 선택된 모든 항목의 시작 좌표를 저장
      for (final f in _selectedFolders()) {
        _groupStartPositions['folder:${f.id}'] = f.position;
      }
      for (final fi in _selectedFiles()) {
        _groupStartPositions['file:${fi.id}'] = fi.position;
      }
      // 앵커가 선택되어 있지 않아도 앵커를 포함
      if (!_groupStartPositions.containsKey(anchorKey)) {
        if (anchorKey.startsWith('folder:')) {
          final id = anchorKey.substring('folder:'.length);
          final f = widget.folders.firstWhere((e) => e.id == id, orElse: () => _ResourceFolder(id: '', name: '', color: null, description: '', position: basePos, size: const Size(0,0), shape: 'rect'));
          _groupStartPositions[anchorKey] = f.position;
        } else if (anchorKey.startsWith('file:')) {
          final id = anchorKey.substring('file:'.length);
          final fi = widget.files.firstWhere((e) => e.id == id, orElse: () => _ResourceFile(id: '', name: '', color: null, position: basePos, size: const Size(0,0)));
          _groupStartPositions[anchorKey] = fi.position;
        }
      }
    });
  }
  void updateGroupDrag(Offset newAnchorPos) {
    if (!_groupDragActive || _groupDragAnchorBasePos == null) return;
    setState(() {
      _groupDragDelta = newAnchorPos - _groupDragAnchorBasePos!;
    });
  }
  void endGroupDrag() {
    setState(() {
      _groupDragActive = false;
      _groupDragAnchorKey = null;
      _groupDragAnchorBasePos = null;
      _groupDragDelta = Offset.zero;
      _isDraggingAny = false;
      _groupStartPositions.clear();
    });
  }

  bool _hitAnyItem(Offset localCanvas) {
    for (final f in widget.folders) {
      final r = Rect.fromLTWH(f.position.dx, f.position.dy, f.size.width, f.size.height);
      if (r.contains(localCanvas)) return true;
    }
    for (final fi in widget.files) {
      final r = Rect.fromLTWH(fi.position.dx, fi.position.dy, fi.size.width, fi.size.height);
      if (r.contains(localCanvas)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (!widget.resizeMode && _selectedIds.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _selectedIds.clear());
          });
        }
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              // ignore: avoid_print
              print('[GRADE] pointer signal dy=${signal.scrollDelta.dy}');
              if (widget.onScrollGrade != null) {
                final dy = signal.scrollDelta.dy;
                if (dy != 0) widget.onScrollGrade!(dy > 0 ? 1 : -1);
              }
            }
          },
          onPointerDown: (event) {
            if (!widget.resizeMode) return;
            final local = _globalToCanvasLocal(event.position);
            // 빈 공간 클릭 시 선택 해제
            if (!_hitAnyItem(local)) {
              setState(() => _selectedIds.clear());
              _panStartLocal = local;
            } else {
              _panStartLocal = null; // 카드 드래그가 우선
            }
          },
          onPointerMove: (event) {
            if (!widget.resizeMode) return;
            if (_groupDragActive) return; // 카드 드래그 우선
            final local = _globalToCanvasLocal(event.position);
            if (!_isMarqueeSelecting) {
              if (_panStartLocal != null) {
                final dx = (local.dx - _panStartLocal!.dx).abs();
                final dy = (local.dy - _panStartLocal!.dy).abs();
                if (dx > 6 || dy > 6) {
                  _beginMarquee(_panStartLocal!);
                  _updateMarquee(local);
                }
              }
            } else {
              _updateMarquee(local);
            }
          },
          onPointerUp: (_) {
            if (_isMarqueeSelecting) {
              _endMarquee();
            }
            _panStartLocal = null;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            child: Stack(
              key: _stackKey,
              children: [
                if (widget.folders.isEmpty && widget.files.isEmpty)
                  const Center(
                    child: Text('추가 버튼으로 폴더 또는 파일을 만들어 보세요.', style: TextStyle(color: Colors.white38, fontSize: 16)),
                  ),
                ...widget.folders.map((f) {
                  return _DraggableFolderCard(
                    key: ValueKey(f.id),
                    folder: f,
                    onMoved: (pos) => widget.onFolderMoved(f.id, pos, _canvasSize),
                    onEndMoved: (pos) {
                      final snapped = _applySnap(pos, f.id);
                      // 대표 델타 = 앵커 스냅 좌표 - 앵커 드래그 시작 좌표
                      final anchorKey = 'folder:${f.id}';
                      final startAnchor = _groupStartPositions[anchorKey] ?? f.position;
                      final delta = snapped - startAnchor;
                      // 앵커 및 선택된 항목들을 시작좌표 + delta로 정확히 반영
                      _isApplyingGroupEnd = true;
                      widget.onFolderMoved(f.id, startAnchor + delta, _canvasSize);
                      for (final entry in _groupStartPositions.entries) {
                        if (entry.key == anchorKey) continue;
                        final k = entry.key;
                        final startPos = entry.value;
                        final np = startPos + delta;
                        if (k.startsWith('folder:')) {
                          final id = k.substring('folder:'.length);
                          widget.onFolderMoved(id, np, _canvasSize);
                        } else if (k.startsWith('file:')) {
                          final id = k.substring('file:'.length);
                          if (widget.onFileMoved != null) widget.onFileMoved!(id, np, _canvasSize);
                        }
                      }
                      _isApplyingGroupEnd = false;
                      if (widget.onMoveEnd != null) widget.onMoveEnd!();
                    },
                    globalToCanvasLocal: _globalToCanvasLocal,
                    resizeMode: widget.resizeMode,
                    editMode: widget.editMode,
                    onDeleteRequested: widget.onDeleteFolder,
                    onEditRequested: widget.onEditFolder,
                    onResize: (size) {
                      if (widget.onFolderResized != null) widget.onFolderResized!(f.id, size, _canvasSize);
                    },
                    onBackgroundTap: () {
                      if (widget.onExitResizeMode != null) widget.onExitResizeMode!();
                    },
                    onResizeEnd: () {
                      if (widget.onResizeEnd != null) widget.onResizeEnd!();
                    },
                  );
                }),
                // 파일 카드 렌더링 (간단 placeholder 스타일)
                ...widget.files.map((fi) {
                  return _DraggableFileCard(
                    key: ValueKey('file_${fi.id}')
                  , file: fi,
                    resizeMode: widget.resizeMode,
                    globalToCanvasLocal: _globalToCanvasLocal,
                    currentGrade: widget.currentGrade,
                    editMode: widget.editMode,
                    onDeleteRequested: widget.onDeleteFile,
                    onEditRequested: widget.onEditFile,
                    onMoved: (pos) {
                      // 드래그 중에는 부모 콜백 호출하지 않음 (내부 임시 위치로만 렌더)
                    },
                    onEndMoved: (pos) {
                      final snapped = _applySnap(pos, fi.id);
                      final anchorKey = 'file:${fi.id}';
                      final startAnchor = _groupStartPositions[anchorKey] ?? fi.position;
                      final delta = snapped - startAnchor;
                      _isApplyingGroupEnd = true;
                      if (widget.onFileMoved != null) widget.onFileMoved!(fi.id, startAnchor + delta, _canvasSize);
                      for (final entry in _groupStartPositions.entries) {
                        if (entry.key == anchorKey) continue;
                        final k = entry.key; final startPos = entry.value; final np = startPos + delta;
                        if (k.startsWith('folder:')) {
                          final id = k.substring('folder:'.length);
                          widget.onFolderMoved(id, np, _canvasSize);
                        } else if (k.startsWith('file:')) {
                          final id = k.substring('file:'.length);
                          if (widget.onFileMoved != null) widget.onFileMoved!(id, np, _canvasSize);
                        }
                      }
                      _isApplyingGroupEnd = false;
                      if (widget.onMoveEnd != null) widget.onMoveEnd!();
                    },
                    onResize: (size) {
                      if (widget.onFileResized != null) widget.onFileResized!(fi.id, size, _canvasSize);
                    },
                    onResizeEnd: () { if (widget.onResizeEnd != null) widget.onResizeEnd!(); },
                  );
                }),
                // 선택 강조 오버레이
                IgnorePointer(
                  child: Stack(children: [
                    ...widget.folders.where((f) => _isSelectedFolder(f.id)).map((f) => Positioned(
                      left: f.position.dx - 3,
                      top: f.position.dy - 3,
                      child: Container(
                        width: f.size.width + 6,
                        height: f.size.height + 6,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF64A6DD), width: 2),
                          boxShadow: [BoxShadow(color: const Color(0xFF64A6DD).withOpacity(0.25), blurRadius: 10)],
                        ),
                      ),
                    )),
                    ...widget.files.where((fi) => _isSelectedFile(fi.id)).map((fi) => Positioned(
                      left: fi.position.dx - 3,
                      top: fi.position.dy - 3,
                      child: Container(
                        width: fi.size.width + 6,
                        height: fi.size.height + 6,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF64A6DD), width: 2),
                          boxShadow: [BoxShadow(color: const Color(0xFF64A6DD).withOpacity(0.25), blurRadius: 10)],
                        ),
                      ),
                    )),
                  ]),
                ),
                // 그룹 드래그 고스트 오버레이 (표시 전용)
                if (_groupDragActive)
                  IgnorePointer(
                    child: Stack(children: [
                      for (final entry in _groupStartPositions.entries)
                        () {
                          final key = entry.key;
                          final start = entry.value;
                          final p = start + _groupDragDelta;
                          if (key.startsWith('folder:')) {
                            final id = key.substring('folder:'.length);
                            final f = widget.folders.firstWhere((e) => e.id == id, orElse: () => _ResourceFolder(id: id, name: '', color: null, description: '', position: start, size: const Size(200,120), shape: 'rect'));
                            return Positioned(left: p.dx, top: p.dy, child: Opacity(opacity: 0.28, child: _FolderCard(folder: f.copyWith(position: p))));
                          } else {
                            final id = key.substring('file:'.length);
                            final fi = widget.files.firstWhere((e) => e.id == id, orElse: () => _ResourceFile(id: id, name: '', color: null, position: start, size: const Size(200,60)));
                            return Positioned(left: p.dx, top: p.dy, child: Opacity(opacity: 0.28, child: _FileCard(file: fi.copyWith(position: p))));
                          }
                        }(),
                    ]),
                  ),
                // 마퀴 선택 렌더링
                if (_isMarqueeSelecting && _marqueeRect != null)
                  IgnorePointer(
                    child: Stack(children: [
                      Positioned(
                        left: _marqueeRect!.left,
                        top: _marqueeRect!.top,
                        child: Container(
                          width: _marqueeRect!.width,
                          height: _marqueeRect!.height,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1976D2).withOpacity(0.12),
                            border: Border.all(color: const Color(0xFF1976D2).withOpacity(0.6), width: 1.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ]),
                  ),
              ],
            ),
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
  final bool editMode;
  final void Function(String folderId)? onDeleteRequested;
  final void Function(_ResourceFolder folder)? onEditRequested;
  final void Function(Size newSize)? onResize;
  final VoidCallback? onBackgroundTap;
  final VoidCallback? onResizeEnd;
  const _DraggableFolderCard({super.key, required this.folder, required this.onMoved, this.onEndMoved, required this.globalToCanvasLocal, required this.resizeMode, required this.editMode, this.onDeleteRequested, this.onEditRequested, this.onResize, this.onBackgroundTap, this.onResizeEnd});

  @override
  State<_DraggableFolderCard> createState() => _DraggableFolderCardState();
}

class _DraggableFolderCardState extends State<_DraggableFolderCard> {
  bool _dragging = false;
  Offset _dragStartLocal = Offset.zero;
  bool _resizing = false;
  Offset? _tempPosition;
  Size? _tempSize;
  Offset? _dragAnchor;

  @override
  Widget build(BuildContext context) {
    final handleSize = 14.0;
    final effectivePos = _tempPosition ?? widget.folder.position;
    final effectiveSize = _tempSize ?? widget.folder.size;
    return Positioned(
      left: effectivePos.dx,
      top: effectivePos.dy,
      child: GestureDetector(
        onTap: widget.editMode
            ? () {
                // debug
                // ignore: avoid_print
                print('[EDIT] Folder tap -> open edit dialog: id=${widget.folder.id}');
                if (widget.onEditRequested != null) widget.onEditRequested!(widget.folder);
              }
            : () {
                // 리사이징 모드에서 선택 토글
                if (widget.resizeMode) {
                  final state = context.findAncestorStateOfType<_ResourcesCanvasState>();
                  state?._toggleSelectFolder(widget.folder.id);
                }
              },
        onPanStart: widget.editMode
            ? null
            : (details) {
          // 리사이즈 모드에서만 이동 허용
          if (!_resizing && widget.resizeMode) {
            // DEBUG
            // ignore: avoid_print
            print('[FOLDER][onPanStart] resizeMode=${widget.resizeMode}, editMode=${widget.editMode}');
            setState(() {
              _dragging = true;
              _dragStartLocal = details.localPosition;
              _tempPosition = widget.folder.position;
              // 폴더도 파일과 동일하게 드래그 앵커를 사용해 마우스에 자연스럽게 붙도록
              final canvasPos = widget.globalToCanvasLocal(details.globalPosition);
              _dragAnchor = canvasPos - widget.folder.position;
            });
            // 그룹 드래그 미리보기 시작
            final state = context.findAncestorStateOfType<_ResourcesCanvasState>();
            state?.beginGroupDrag(anchorKey: 'folder:${widget.folder.id}', basePos: widget.folder.position);
          }
        },
        onPanUpdate: widget.editMode
            ? null
            : (details) {
          if (_dragging && !_resizing && widget.resizeMode) {
            // ignore: avoid_print
            print('[FOLDER][onPanUpdate] delta=${details.delta}');
            final canvasPos = widget.globalToCanvasLocal(details.globalPosition);
            final newPos = (_dragAnchor != null) ? (canvasPos - _dragAnchor!) : Offset(effectivePos.dx + details.delta.dx, effectivePos.dy + details.delta.dy);
            // 그룹 드래그 중에는 내부 임시 위치를 사용하지 않고 상위에서 렌더링 위치를 제어
            final state = context.findAncestorStateOfType<_ResourcesCanvasState>();
            if (state != null && state._groupDragActive) {
              state.updateGroupDrag(newPos);
            } else {
              setState(() => _tempPosition = newPos);
              final st = context.findAncestorStateOfType<_ResourcesCanvasState>();
              st?.updateGroupDrag(newPos);
            }
            // 그룹 드래그 미리보기 업데이트 (상단에서 이미 호출)
          }
        },
        onPanEnd: widget.editMode
            ? null
            : (details) {
          // ignore: avoid_print
          print('[FOLDER][onPanEnd] dragging=$_dragging');
          setState(() => _dragging = false);
          Offset endPos;
          final state = context.findAncestorStateOfType<_ResourcesCanvasState>();
          if (state != null && state._groupDragActive) {
            final anchorKey = 'folder:${widget.folder.id}';
            final startAnchor = state._groupStartPositions[anchorKey] ?? widget.folder.position;
            endPos = startAnchor + state._groupDragDelta;
          } else {
            endPos = _tempPosition ?? widget.folder.position;
          }
          if (widget.onEndMoved != null) widget.onEndMoved!(endPos);
          _tempPosition = null;
          _dragAnchor = null;
          // 그룹 드래그 미리보기 종료
          state?.endGroupDrag();
        },
        // 리사이즈 모드 종료는 버튼으로만 수행: 배경 탭 종료 제거
        behavior: HitTestBehavior.translucent,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _dragging ? 0.85 : 1.0,
          child: Stack(
            children: [
              _FolderCard(folder: widget.folder.copyWith(position: effectivePos, size: effectiveSize)),
              if (widget.editMode)
                Positioned(
                  right: 6,
                  top: 6,
                  child: InkWell(
                    onTap: () async {
                      if (widget.onDeleteRequested != null) widget.onDeleteRequested!(widget.folder.id);
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: const Icon(Icons.close, size: 18, color: Colors.white70),
                  ),
                ),
              if (widget.resizeMode && !widget.editMode)
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
              Expanded(
                child: Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 17.5, fontWeight: FontWeight.w700),
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

class _FolderEditDialog extends StatefulWidget {
  final _ResourceFolder initial;
  const _FolderEditDialog({required this.initial});
  @override
  State<_FolderEditDialog> createState() => _FolderEditDialogState();
}

class _FolderEditDialogState extends State<_FolderEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  Color? _color;
  String _shape = 'rect';
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.name);
    _desc = TextEditingController(text: widget.initial.description);
    _color = widget.initial.color;
    _shape = widget.initial.shape;
  }
  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('폴더 수정', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '폴더명',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _desc,
              style: const TextStyle(color: Colors.white),
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '설명',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            const Text('폴더 색상', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [null, ...Colors.primaries].map((c) {
                final selected = _color == c;
                return GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c ?? Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 2 : 1),
                    ),
                    child: c == null ? const Center(child: Icon(Icons.close_rounded, size: 14, color: Colors.white54)) : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            const Text('모양', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            Row(children: [
              _ShapeSelectButton(label: '직사각형', selected: _shape == 'rect', onTap: () => setState(() => _shape = 'rect')),
              const SizedBox(width: 8),
              _ShapeSelectButton(label: '평행사변형', selected: _shape == 'parallelogram', onTap: () => setState(() => _shape = 'parallelogram')),
              const SizedBox(width: 8),
              _ShapeSelectButton(label: '알약', selected: _shape == 'pill', onTap: () => setState(() => _shape = 'pill')),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          onPressed: () {
            Navigator.pop(context, widget.initial.copyWith(name: _name.text.trim(), description: _desc.text.trim(), color: _color, shape: _shape));
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class _ResourceFile {
  final String id;
  final String name;
  final Color? color; // filled style
  final IconData? icon; // file icon
  final String? iconImagePath; // custom image path (square)
  final Color? textColor; // label color
  final String? description; // optional
  final String? parentId; // for nesting
  final Offset position;
  final Size size;
  final Map<String, String> linksByGrade; // 학년별 링크 맵
  const _ResourceFile({
    required this.id,
    required this.name,
    required this.color,
    this.icon,
    this.iconImagePath,
    this.textColor,
    this.description,
    this.parentId,
    required this.position,
    required this.size,
    this.linksByGrade = const {},
  });

  _ResourceFile copyWith({
    String? id,
    String? name,
    Color? color,
    IconData? icon,
    String? iconImagePath,
    Color? textColor,
    String? description,
    String? parentId,
    Offset? position,
    Size? size,
    Map<String, String>? linksByGrade,
  }) {
    return _ResourceFile(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      icon: icon ?? this.icon,
      iconImagePath: iconImagePath ?? this.iconImagePath,
      textColor: textColor ?? this.textColor,
      description: description ?? this.description,
      parentId: parentId ?? this.parentId,
      position: position ?? this.position,
      size: size ?? this.size,
      linksByGrade: linksByGrade ?? this.linksByGrade,
    );
  }

  String? get primaryGrade {
    for (final g in const ['초1','초2','초3','초4','초5','초6','중1','중2','중3','고1','고2','고3']) {
      final ans = linksByGrade['$g#ans']?.trim();
      final sol = linksByGrade['$g#sol']?.trim();
      if ((ans != null && ans.isNotEmpty) || (sol != null && sol.isNotEmpty)) return g;
    }
    // 아무거나 첫번째 (키가 grade#type 꼴일 수 있음)
    for (final e in linksByGrade.entries) {
      if (e.value.trim().isNotEmpty) {
        final k = e.key;
        final i = k.indexOf('#');
        return i > 0 ? k.substring(0, i) : k;
      }
    }
    return null;
  }
}

class _FileCreateDialog extends StatefulWidget {
  const _FileCreateDialog();
  @override
  State<_FileCreateDialog> createState() => _FileCreateDialogState();
}

class _FileEditDialog extends StatefulWidget {
  final _ResourceFile initial;
  const _FileEditDialog({required this.initial});
  @override
  State<_FileEditDialog> createState() => _FileEditDialogState();
}

class _FileEditDialogState extends State<_FileEditDialog> {
  late final TextEditingController _nameController;
  Color? _selectedColor;
  IconData? _selectedIcon;
  String? _iconImagePath;
  Color? _selectedTextColor;
  List<String> _grades = [];
  late final Map<String, TextEditingController> _gradeUrlControllers;
  final List<Color?> _colors = [null, ...Colors.primaries];
  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial.name);
    _selectedColor = widget.initial.color;
    _selectedIcon = widget.initial.icon ?? Icons.insert_drive_file;
    _iconImagePath = widget.initial.iconImagePath;
    _selectedTextColor = widget.initial.textColor;
    _initGrades();
  }
  Future<void> _initGrades() async {
    final rows = await DataManager.instance.getResourceGrades();
    final list = rows.map((e) => (e['name'] as String?) ?? '').where((e) => e.isNotEmpty).toList();
    _grades = list.isEmpty ? ['초1','초2','초3','초4','초5','초6','중1','중2','중3','고1','고2','고3'] : list;
    final currentLinks = await DataManager.instance.loadResourceFileLinks(widget.initial.id);
    _gradeUrlControllers = { for (final g in _grades) g: TextEditingController(text: currentLinks[g] ?? '') };
    if (mounted) setState(() {});
  }
  @override
  void dispose() {
    _nameController.dispose();
    for (final c in _gradeUrlControllers.values) { c.dispose(); }
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('파일 수정', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 560,
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
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
            ),
            const SizedBox(height: 12),
            // 아이콘 선택
            const Text('아이콘', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: const [
                Icons.insert_drive_file,
                Icons.description,
                Icons.picture_as_pdf,
                Icons.table_chart,
                Icons.link,
                Icons.folder,
                Icons.image,
                Icons.movie,
              ].map((ico) {
                return _IconChoice(iconData: ico);
              }).toList(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  height: 34,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final typeGroup = XTypeGroup(label: 'image', extensions: ['png','jpg','jpeg']);
                      final f = await openFile(acceptedTypeGroups: [typeGroup]);
                      if (f != null) setState(() => _iconImagePath = f.path);
                    },
                    icon: const Icon(Icons.upload_file, size: 16, color: Colors.white60),
                    label: const Text('이미지'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white60,
                      side: const BorderSide(color: Colors.white24),
                      shape: const StadiumBorder(),
                      backgroundColor: Color(0xFF2A2A2A),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (_iconImagePath != null && _iconImagePath!.isNotEmpty)
                  Container(width: 34, height: 34, decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), image: DecorationImage(image: FileImage(File(_iconImagePath!)), fit: BoxFit.cover))),
              ],
            ),
            const SizedBox(height: 8),
            StatefulBuilder(
              builder: (context, setSB) {
                return Row(
                  children: [
                    const Text('선택됨: ', style: TextStyle(color: Colors.white60)),
                    Icon(_selectedIcon, color: Colors.white70, size: 18),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            const Text('과정별 링크', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _grades.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final grade = _grades[index];
                  return Row(
                    children: [
                      SizedBox(width: 64, child: Text(grade, style: const TextStyle(color: Colors.white70))),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 36,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final typeGroup = XTypeGroup(label: 'files', extensions: ['pdf','hwp','hwpx','xlsx','xls','doc','docx','ppt','pptx']);
                            final file = await openFile(acceptedTypeGroups: [typeGroup]);
                            if (file != null) {
                              _gradeUrlControllers[grade]!.text = file.path;
                              if (_nameController.text.trim().isEmpty) {
                                _nameController.text = file.name;
                              }
                            }
                          },
                          icon: const Icon(Icons.folder_open, size: 16),
                          label: const Text('찾기'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 36,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('해당 행에 파일을 드래그해서 놓으면 등록됩니다.')),
                            );
                          },
                          icon: const Icon(Icons.file_download, size: 16),
                          label: const Text('드롭'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 36,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('PDF 편집기는 다음 단계에서 구현됩니다.')),
                            );
                          },
                          icon: const Icon(Icons.picture_as_pdf, size: 16),
                          label: const Text('편집'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _gradeUrlControllers[grade],
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: 'https:// 또는 파일 경로',
                            hintStyle: TextStyle(color: Colors.white38),
                            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            const Text('색상 (가득찬 스타일)', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _colors.map((c) {
                final sel = _selectedColor == c;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = c),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c ?? Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: sel ? Colors.white : Colors.white24, width: sel ? 2 : 1),
                    ),
                    child: c == null ? const Center(child: Icon(Icons.close_rounded, size: 14, color: Colors.white54)) : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            const Text('글자 색상', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [Colors.white, Colors.white70, Colors.white60, Colors.white38, Colors.black87, Colors.black54].map((c) {
                final sel = _selectedTextColor == c;
                return GestureDetector(
                  onTap: () => setState(() => _selectedTextColor = c),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: sel ? Colors.white : Colors.white24, width: sel ? 2 : 1),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          onPressed: () {
            final links = <String, String>{};
            for (final g in _grades) {
              final v = _gradeUrlControllers[g]!.text.trim();
              if (v.isNotEmpty) links[g] = v;
            }
            Navigator.pop(context, {
              'file': widget.initial.copyWith(name: _nameController.text.trim(), color: _selectedColor, icon: _selectedIcon, iconImagePath: _iconImagePath, textColor: _selectedTextColor),
              'links': links,
            });
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class _IconChoice extends StatelessWidget {
  final IconData iconData;
  const _IconChoice({required this.iconData});
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_FileEditDialogState>();
    final isSelected = state?._selectedIcon == iconData;
    return InkWell(
      onTap: () => state?.setState(() => state._selectedIcon = iconData),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected == true ? Colors.white : Colors.white24, width: isSelected == true ? 2.0 : 1.0),
        ),
        child: Icon(iconData, size: 18, color: Colors.white70),
      ),
    );
  }
}

class _IconPickItem extends StatelessWidget {
  final IconData iconData;
  const _IconPickItem({required this.iconData});
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_FileCreateDialogState>();
    final selected = state?._selectedIcon == iconData;
    return InkWell(
      onTap: () => state?.setState(() => state._selectedIcon = iconData),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected == true ? Colors.white : Colors.white24, width: selected == true ? 2 : 1),
        ),
        child: Icon(iconData, size: 18, color: Colors.white70),
      ),
    );
  }
}

class _FileCreateDialogState extends State<_FileCreateDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  Color? _selectedColor;
  Color? _selectedTextColor;
  IconData? _selectedIcon;
  String? _iconImagePath;

  final List<Color> _fixedPalette = const [
    _ResColors.container1,
    _ResColors.container2,
    _ResColors.container3,
    _ResColors.container4,
    _ResColors.container5,
    _ResColors.blue1,
    _ResColors.blue2,
    _ResColors.blue3,
    _ResColors.blue4,
    _ResColors.blue5,
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descController = TextEditingController();
    _selectedIcon = Icons.insert_drive_file;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _handleSave() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('이름을 입력하세요.')));
      return;
    }
    Navigator.of(context).pop({
      'meta': _ResourceFile(
        id: UniqueKey().toString(),
        name: name,
        color: _selectedColor,
        icon: _selectedIcon,
        iconImagePath: _iconImagePath,
        textColor: _selectedTextColor,
        description: _descController.text.trim(),
        parentId: null,
        position: const Offset(0, 0),
        size: const Size(220, 70),
      )
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('파일 추가', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 560,
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
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descController,
              style: const TextStyle(color: Colors.white),
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '설명',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            const Text('아이콘 (이미지 업로드 가능)', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _gradeIconPack.map((ico) => _IconPickItem(iconData: ico)).toList(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  height: 36,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final typeGroup = XTypeGroup(label: 'image', extensions: ['png','jpg','jpeg']);
                      final f = await openFile(acceptedTypeGroups: [typeGroup]);
                      if (f != null) setState(() => _iconImagePath = f.path);
                    },
                    icon: const Icon(Icons.upload_file, size: 16),
                    label: const Text('이미지'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                if (_iconImagePath != null && _iconImagePath!.isNotEmpty)
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24, width: 1),
                      image: DecorationImage(image: FileImage(File(_iconImagePath!)), fit: BoxFit.cover),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('배경 색상', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _fixedPalette.map((c) {
                final sel = _selectedColor == c;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = c),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: sel ? Colors.white : Colors.white24, width: sel ? 2 : 1),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            const Text('글자 색상', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [Colors.white, Colors.white70, Colors.white60, Colors.white38, Colors.black87, Colors.black54].map((c) {
                final sel = _selectedTextColor == c;
                return GestureDetector(
                  onTap: () => setState(() => _selectedTextColor = c),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: sel ? Colors.white : Colors.white24, width: sel ? 2 : 1),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('다음'),
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
            Row(children: [
              _ShapeSelectButton(label: '직사각형', selected: _shape == 'rect', onTap: () => setState(() => _shape = 'rect')),
              const SizedBox(width: 8),
              _ShapeSelectButton(label: '평행사변형', selected: _shape == 'parallelogram', onTap: () => setState(() => _shape = 'parallelogram')),
              const SizedBox(width: 8),
              _ShapeSelectButton(label: '알약', selected: _shape == 'pill', onTap: () => setState(() => _shape = 'pill')),
            ]),
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
  final String? currentGrade;
  final bool editMode;
  final void Function(String fileId)? onDeleteRequested;
  final void Function(_ResourceFile file)? onEditRequested;
  const _DraggableFileCard({super.key, required this.file, required this.resizeMode, required this.globalToCanvasLocal, required this.onMoved, this.onEndMoved, this.onResize, this.onResizeEnd, this.onAddChild, this.currentGrade, required this.editMode, this.onDeleteRequested, this.onEditRequested});

  @override
  State<_DraggableFileCard> createState() => _DraggableFileCardState();
}

class _DraggableFileCardState extends State<_DraggableFileCard> {
  bool _dragging = false;
  bool _resizing = false;
  Offset? _tempPosition;
  Size? _tempSize;
  Offset? _dragAnchor;

  @override
  Widget build(BuildContext context) {
    final effectivePos = _tempPosition ?? widget.file.position;
    final effectiveSize = _tempSize ?? widget.file.size;
    return Positioned(
      left: effectivePos.dx,
      top: effectivePos.dy,
      child: GestureDetector(
        onTap: widget.editMode
            ? () {
                // ignore: avoid_print
                print('[EDIT] File tap -> open edit dialog: id=${widget.file.id}');
                if (widget.onEditRequested != null) widget.onEditRequested!(widget.file);
              }
            : () {
                if (widget.resizeMode) {
                  final state = context.findAncestorStateOfType<_ResourcesCanvasState>();
                  state?._toggleSelectFile(widget.file.id);
                }
              },
        onPanStart: (details) {
          if (widget.editMode) return; // 편집 모드에서는 이동 금지
          // 리사이징 모드에서만 이동 허용
          if (!_resizing && widget.resizeMode) {
            // DEBUG
            // ignore: avoid_print
            print('[FILE][onPanStart] resizeMode=${widget.resizeMode}, editMode=${widget.editMode}');
            setState(() {
              _dragging = true;
              _tempPosition = widget.file.position;
              // 캔버스 좌표 기준 앵커 계산 (마우스가 카드 내부 어디를 잡았는지)
              final canvasPos = widget.globalToCanvasLocal(details.globalPosition);
              _dragAnchor = canvasPos - widget.file.position;
            });
            final state = context.findAncestorStateOfType<_ResourcesCanvasState>();
            state?.beginGroupDrag(anchorKey: 'file:${widget.file.id}', basePos: widget.file.position);
          }
        },
        onPanUpdate: (d) {
          if (widget.editMode) return;
          if (_dragging && !_resizing && widget.resizeMode) {
            // ignore: avoid_print
            print('[FILE][onPanUpdate] delta=${d.delta}');
            final canvasPos = widget.globalToCanvasLocal(d.globalPosition);
            final newPos = (_dragAnchor != null) ? (canvasPos - _dragAnchor!) : Offset(effectivePos.dx + d.delta.dx, effectivePos.dy + d.delta.dy);
            // 그룹 드래그 중에는 내부 임시 위치를 사용하지 않고 상위에서 렌더링 위치를 제어
            final state = context.findAncestorStateOfType<_ResourcesCanvasState>();
            if (state != null && state._groupDragActive) {
              state.updateGroupDrag(newPos);
            } else {
              setState(() => _tempPosition = newPos);
              state?.updateGroupDrag(newPos);
            }
            // 실시간 반영: 상태만 업데이트(저장은 onEnd에서)
            if (widget.onMoved != null) widget.onMoved!(newPos);
          }
        },
        onPanEnd: (_) {
          if (widget.editMode) return;
          // ignore: avoid_print
          print('[FILE][onPanEnd] dragging=$_dragging');
          setState(() => _dragging = false);
          Offset endPos;
          final state = context.findAncestorStateOfType<_ResourcesCanvasState>();
          if (state != null && state._groupDragActive) {
            final anchorKey = 'file:${widget.file.id}';
            final startAnchor = state._groupStartPositions[anchorKey] ?? widget.file.position;
            endPos = startAnchor + state._groupDragDelta;
          } else {
            endPos = _tempPosition ?? widget.file.position;
          }
          if (widget.onEndMoved != null) widget.onEndMoved!(endPos);
          _tempPosition = null;
          _dragAnchor = null;
          state?.endGroupDrag();
        },
        behavior: HitTestBehavior.translucent,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _dragging ? 0.9 : 1.0,
          child: Stack(
            children: [
              _FileCard(file: widget.file.copyWith(position: effectivePos, size: effectiveSize)),
              if (widget.editMode)
                Positioned(
                  right: 6,
                  top: 6,
                  child: InkWell(
                    onTap: () async {
                      if (widget.onDeleteRequested != null) widget.onDeleteRequested!(widget.file.id);
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: const Icon(Icons.close, size: 18, color: Colors.white70),
                  ),
                ),
              if (widget.resizeMode && !widget.editMode)
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
    final primaryGrade = (context.findAncestorStateOfType<_DraggableFileCardState>()?.widget.currentGrade) ?? file.primaryGrade;
    final hasForCurrent = primaryGrade != null && (file.linksByGrade['$primaryGrade#body']?.trim().isNotEmpty ?? false);
    final bg = (hasForCurrent ? (file.color ?? const Color(0xFF2D2D2D)) : const Color(0xFF2D2D2D).withOpacity(0.5));
    final primary = primaryGrade;
    return Container(
      width: file.size.width,
      height: file.size.height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
         border: Border.all(color: const Color(0xFF1F1F1F), width: 1.2),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
           if (file.iconImagePath != null && file.iconImagePath!.isNotEmpty)
             Container(
               width: 22,
               height: 22,
               decoration: BoxDecoration(
                 borderRadius: BorderRadius.circular(4),
                 image: DecorationImage(image: FileImage(File(file.iconImagePath!)), fit: BoxFit.cover),
               ),
             )
           else
             Icon(file.icon ?? Icons.insert_drive_file, color: hasForCurrent ? Colors.white70 : Colors.white30, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: file.textColor ?? (hasForCurrent ? Colors.white : Colors.white38), fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 8),
          // 본문/정답/해설 아이콘 버튼 (현재 학년 기준으로 열기)
          _FileLinkButton(file: file, kind: 'ans'),
          const SizedBox(width: 6),
          _FileLinkButton(file: file, kind: 'sol'),
          const SizedBox(width: 6),
          _BookmarkButton(file: file),
          const SizedBox(width: 8),
          if (primary != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.2),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                primary,
                style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }
}

class _FileLinkButton extends StatelessWidget {
  final _ResourceFile file;
  final String kind; // 'body' | 'ans' | 'sol'
  const _FileLinkButton({required this.file, required this.kind});
  @override
  Widget build(BuildContext context) {
    final current = context.findAncestorStateOfType<_DraggableFileCardState>()?.widget.currentGrade;
    final label = kind == 'body' ? '본문' : kind == 'ans' ? '정답' : '해설';
    final icon = kind == 'body' ? Icons.description : kind == 'ans' ? Icons.check_circle : Icons.menu_book;
    final key = current != null ? '${current}#${kind}' : null;
    final link = key != null ? (file.linksByGrade[key]?.trim() ?? '') : '';
    final enabled = link.isNotEmpty;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: !enabled ? null : () async {
          if (link.startsWith('http://') || link.startsWith('https://')) {
            final uri = Uri.parse(link);
            await launchUrl(uri, mode: LaunchMode.platformDefault);
          } else {
            await OpenFilex.open(link);
          }
        },
        borderRadius: BorderRadius.circular(6),
        child: Icon(icon, size: 16, color: enabled ? Colors.white70 : Colors.white30),
      ),
    );
  }
}

class _BookmarkButton extends StatefulWidget {
  final _ResourceFile file;
  const _BookmarkButton({required this.file});
  @override
  State<_BookmarkButton> createState() => _BookmarkButtonState();
}

class _BookmarkButtonState extends State<_BookmarkButton> {
  late Future<List<Map<String, dynamic>>> _future;
  final GlobalKey _btnKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    _future = DataManager.instance.loadResourceFileBookmarks(widget.file.id);
  }
  void _openMenu() async {
    final renderBox = _btnKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayObj = Overlay.of(context)?.context.findRenderObject();
    if (renderBox == null || overlayObj is! RenderBox) return;
    final overlay = overlayObj;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        renderBox!.localToGlobal(Offset.zero, ancestor: overlay),
        renderBox.localToGlobal(renderBox.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final bookmarks = await DataManager.instance.loadResourceFileBookmarks(widget.file.id);
    // Show menu with list + controls
    await showMenu<void>(
      context: context,
      position: position,
      items: <PopupMenuEntry<void>>[
        ...bookmarks.map<PopupMenuEntry<void>>((b) => PopupMenuItem<void>(
          enabled: true,
          onTap: () async {
            final path = (b['path'] as String?)?.trim() ?? '';
            if (path.isEmpty) return;
            try {
              if (path.startsWith('http://') || path.startsWith('https://')) {
                final uri = Uri.parse(path);
                await launchUrl(uri, mode: LaunchMode.platformDefault);
              } else {
                await OpenFilex.open(path);
              }
            } catch (_) {}
          },
          child: Row(
            children: [
              const Icon(Icons.drag_indicator, color: Colors.white60, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(b['name'] ?? '', style: const TextStyle(color: Colors.white)),
                if ((b['description'] as String?)?.isNotEmpty ?? false)
                  Text(b['description'], style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ])),
              PopupMenuButton<void>(
                icon: const Icon(Icons.more_vert, color: Colors.white70, size: 18),
                itemBuilder: (ctx) => <PopupMenuEntry<void>>[
                  PopupMenuItem<void>(onTap: () async {
                    await Future.delayed(const Duration(milliseconds: 0));
                    final edited = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (ctx) => _BookmarkEditDialog(initial: b),
                    );
                    if (edited != null) {
                      final list = List<Map<String, dynamic>>.from(bookmarks);
                      final idx = list.indexOf(b);
                      if (idx != -1) list[idx] = edited;
                      await DataManager.instance.saveResourceFileBookmarks(widget.file.id, list);
                      if (mounted) setState(() => _future = DataManager.instance.loadResourceFileBookmarks(widget.file.id));
                    }
                  }, child: const Text('수정')),
                  PopupMenuItem<void>(onTap: () async {
                    await Future.delayed(const Duration(milliseconds: 0));
                    final list = List<Map<String, dynamic>>.from(bookmarks)..remove(b);
                    await DataManager.instance.saveResourceFileBookmarks(widget.file.id, list);
                    if (mounted) setState(() => _future = DataManager.instance.loadResourceFileBookmarks(widget.file.id));
                  }, child: const Text('삭제')),
                ],
              ),
            ],
          ),
        )),
        const PopupMenuDivider(),
        PopupMenuItem<void>(
          enabled: true,
          child: Row(children: const [Icon(Icons.settings, size: 16, color: Colors.white70), SizedBox(width: 8), Text('관리...', style: TextStyle(color: Colors.white))]),
          onTap: () async {
            await Future.delayed(const Duration(milliseconds: 0));
            await showDialog(
              context: context,
              builder: (ctx) => _BookmarkManageDialog(fileId: widget.file.id),
            );
            if (mounted) setState(() => _future = DataManager.instance.loadResourceFileBookmarks(widget.file.id));
          },
        ),
        const PopupMenuDivider(),
        PopupMenuItem<void>(
          enabled: true,
          child: Row(children: const [Icon(Icons.add, size: 16, color: Colors.white70), SizedBox(width: 8), Text('추가', style: TextStyle(color: Colors.white))]),
          onTap: () async {
            await Future.delayed(const Duration(milliseconds: 0));
            final created = await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (ctx) => _BookmarkCreateDialog(fileId: widget.file.id),
            );
            if (created != null) {
              final list = await DataManager.instance.loadResourceFileBookmarks(widget.file.id);
              list.add(created);
              await DataManager.instance.saveResourceFileBookmarks(widget.file.id, list);
              if (mounted) setState(() => _future = DataManager.instance.loadResourceFileBookmarks(widget.file.id));
            }
          },
        ),
      ],
      color: const Color(0xFF2A2A2A),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF3A3A3A))),
    );
  }
  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: _btnKey,
      onPressed: _openMenu,
      icon: const Icon(Icons.bookmarks, size: 18, color: Colors.white70),
      tooltip: '북마크',
    );
  }
}

class _BookmarkCreateDialog extends StatefulWidget {
  final String fileId;
  const _BookmarkCreateDialog({required this.fileId});
  @override
  State<_BookmarkCreateDialog> createState() => _BookmarkCreateDialogState();
}

class _BookmarkCreateDialogState extends State<_BookmarkCreateDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _desc = TextEditingController();
  final TextEditingController _path = TextEditingController();
  @override
  void dispose() { _name.dispose(); _desc.dispose(); _path.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('북마크 추가', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _name, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: '이름', labelStyle: TextStyle(color: Colors.white70), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))))),
          const SizedBox(height: 10),
          TextField(controller: _desc, style: const TextStyle(color: Colors.white), maxLines: 2, decoration: const InputDecoration(labelText: '설명', labelStyle: TextStyle(color: Colors.white70), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))), alignLabelWithHint: true)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _path,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: '파일 경로 또는 URL',
                  hintStyle: TextStyle(color: Colors.white38),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 드래그앤드롭 수용
            DropTarget(
              onDragDone: (detail) {
                if (detail.files.isEmpty) return;
                final xf = detail.files.first;
                final path = xf.path;
                if (path != null && path.isNotEmpty) {
                  setState(() => _path.text = path);
                }
              },
              child: const SizedBox(width: 1, height: 1),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final typeGroup = XTypeGroup(label: 'files', extensions: ['pdf','hwp','hwpx','xlsx','xls','doc','docx','ppt','pptx']);
                  final file = await openFile(acceptedTypeGroups: [typeGroup]);
                  if (file != null) setState(() => _path.text = file.path);
                },
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('찾기'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: const BorderSide(color: Colors.white24),
                  shape: const StadiumBorder(),
                  backgroundColor: const Color(0xFF2A2A2A),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final result = await showDialog<String>(
                    context: context,
                    builder: (ctx) => _PdfEditorDialog(
                      initialInputPath: _path.text.trim().isEmpty ? null : _path.text.trim(),
                      grade: '',
                      kindKey: 'body',
                    ),
                  );
                  if (result != null && result.isNotEmpty) setState(() => _path.text = result);
                },
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('편집'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: const BorderSide(color: Colors.white24),
                  shape: const StadiumBorder(),
                  backgroundColor: const Color(0xFF2A2A2A),
                ),
              ),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(onPressed: () {
          final map = {'name': _name.text.trim(), 'description': _desc.text.trim(), 'path': _path.text.trim()};
          Navigator.pop(context, map);
        }, style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('추가')),
      ],
    );
  }
}

class _BookmarkEditDialog extends StatefulWidget {
  final Map<String, dynamic> initial;
  const _BookmarkEditDialog({required this.initial});
  @override
  State<_BookmarkEditDialog> createState() => _BookmarkEditDialogState();
}

class _BookmarkEditDialogState extends State<_BookmarkEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _path;
  @override
  void initState() { super.initState(); _name = TextEditingController(text: widget.initial['name'] ?? ''); _desc = TextEditingController(text: widget.initial['description'] ?? ''); _path = TextEditingController(text: widget.initial['path'] ?? ''); }
  @override
  void dispose() { _name.dispose(); _desc.dispose(); _path.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('북마크 수정', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _name, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: '이름', labelStyle: TextStyle(color: Colors.white70), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))))),
          const SizedBox(height: 10),
          TextField(controller: _desc, style: const TextStyle(color: Colors.white), maxLines: 2, decoration: const InputDecoration(labelText: '설명', labelStyle: TextStyle(color: Colors.white70), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))), alignLabelWithHint: true)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _path,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: '파일 경로 또는 URL',
                  hintStyle: TextStyle(color: Colors.white38),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                ),
              ),
            ),
            const SizedBox(width: 8),
            DropTarget(
              onDragDone: (detail) {
                if (detail.files.isEmpty) return;
                final xf = detail.files.first;
                final path = xf.path;
                if (path != null && path.isNotEmpty) {
                  setState(() => _path.text = path);
                }
              },
              child: const SizedBox(width: 1, height: 1),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final typeGroup = XTypeGroup(label: 'files', extensions: ['pdf','hwp','hwpx','xlsx','xls','doc','docx','ppt','pptx']);
                  final file = await openFile(acceptedTypeGroups: [typeGroup]);
                  if (file != null) setState(() => _path.text = file.path);
                },
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('찾기'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: const BorderSide(color: Colors.white24),
                  shape: const StadiumBorder(),
                  backgroundColor: const Color(0xFF2A2A2A),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final result = await showDialog<String>(
                    context: context,
                    builder: (ctx) => _PdfEditorDialog(
                      initialInputPath: _path.text.trim().isEmpty ? null : _path.text.trim(),
                      grade: '',
                      kindKey: 'body',
                    ),
                  );
                  if (result != null && result.isNotEmpty) setState(() => _path.text = result);
                },
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('편집'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: const BorderSide(color: Colors.white24),
                  shape: const StadiumBorder(),
                  backgroundColor: const Color(0xFF2A2A2A),
                ),
              ),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(onPressed: () {
          final map = {'name': _name.text.trim(), 'description': _desc.text.trim(), 'path': _path.text.trim()};
          Navigator.pop(context, map);
        }, style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('저장')),
      ],
    );
  }
}

class _BookmarkManageDialog extends StatefulWidget {
  final String fileId;
  const _BookmarkManageDialog({required this.fileId});
  @override
  State<_BookmarkManageDialog> createState() => _BookmarkManageDialogState();
}

class _BookmarkManageDialogState extends State<_BookmarkManageDialog> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }
  Future<void> _load() async {
    final list = await DataManager.instance.loadResourceFileBookmarks(widget.fileId);
    if (mounted) setState(() { _items = List<Map<String, dynamic>>.from(list); _loading = false; });
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('북마크 관리', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 520,
        height: 420,
        child: _loading ? const Center(child: CircularProgressIndicator()) : ReorderableListView(
          buildDefaultDragHandles: false,
          children: [
            for (int i = 0; i < _items.length; i++)
              ListTile(
                key: ValueKey('bm_$i'),
                leading: ReorderableDragStartListener(
                  index: i,
                  child: const Icon(Icons.drag_indicator, color: Colors.white60),
                ),
                title: Text(_items[i]['name'] ?? '', style: const TextStyle(color: Colors.white)),
                subtitle: ((
                  (_items[i]['description'] as String?)?.isNotEmpty ?? false
                ) ? Text(_items[i]['description'], style: const TextStyle(color: Colors.white54)) : null),
                trailing: IconButton(
                  icon: const Icon(Icons.edit, color: Colors.white70),
                  onPressed: () async {
                    final edited = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (ctx) => _BookmarkEditDialog(initial: _items[i]),
                    );
                    if (edited != null) setState(() => _items[i] = edited);
                  },
                ),
              ),
          ],
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex -= 1;
              final item = _items.removeAt(oldIndex);
              _items.insert(newIndex, item);
            });
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: () async {
            await DataManager.instance.saveResourceFileBookmarks(widget.fileId, _items);
            if (context.mounted) Navigator.pop(context);
          },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class _PdfEditorDialog extends StatefulWidget {
  final String? initialInputPath;
  final String grade;
  final String kindKey; // 'body' | 'ans' | 'sol'
  const _PdfEditorDialog({this.initialInputPath, required this.grade, required this.kindKey});
  @override
  State<_PdfEditorDialog> createState() => _PdfEditorDialogState();
}

class _PdfEditorDialogState extends State<_PdfEditorDialog> {
  final TextEditingController _inputPath = TextEditingController();
  final TextEditingController _ranges = TextEditingController();
  final TextEditingController _fileName = TextEditingController();
  String? _outputPath;
  bool _busy = false;
  final List<int> _selectedPages = [];
  final Map<int, List<Rect>> _regionsByPage = {};
  Rect? _dragRect;
  Offset? _dragStart;
  final GlobalKey _previewKey = GlobalKey();
  int _currentPreviewPage = 1;
  PdfDocument? _previewDoc;
  @override
  void initState() {
    super.initState();
    if (widget.initialInputPath != null && widget.initialInputPath!.isNotEmpty) {
      _inputPath.text = widget.initialInputPath!;
      final base = p.basenameWithoutExtension(widget.initialInputPath!);
      final suffix = widget.kindKey == 'body' ? '본문' : widget.kindKey == 'ans' ? '정답' : '해설';
      _fileName.text = '${base}_${widget.grade}_$suffix.pdf';
    }
  }

  List<int> _parseRanges(String input, int maxPages) {
    final Set<int> pages = {};
    for (final part in input.split(',')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      if (t.contains('-')) {
        final sp = t.split('-');
        if (sp.length != 2) continue;
        final a = int.tryParse(sp[0].trim());
        final b = int.tryParse(sp[1].trim());
        if (a == null || b == null) continue;
        final start = a < 1 ? 1 : a;
        final end = b > maxPages ? maxPages : b;
        for (int i = start; i <= end; i++) pages.add(i);
      } else {
        final v = int.tryParse(t);
        if (v != null && v >= 1 && v <= maxPages) pages.add(v);
      }
    }
    final list = pages.toList()..sort();
    return list;
  }

  @override
  void dispose() {
    _inputPath.dispose();
    _ranges.dispose();
    _fileName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('PDF 편집기', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: 760,
        child: DefaultTabController(
          length: 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Theme(
                data: Theme.of(context).copyWith(
                  tabBarTheme: const TabBarThemeData(
                    indicatorColor: Color(0xFF1976D2),
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white54,
                  ),
                ),
                child: const TabBar(tabs: [
                  Tab(text: '범위 입력'),
                  Tab(text: '미리보기 선택'),
                ]),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 520,
                child: TabBarView(children: <Widget>[
                  // Tab 1: 텍스트 범위 입력
                  SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('입력 PDF', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(child: TextField(controller: _inputPath, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))))),
                        const SizedBox(width: 8),
                        SizedBox(height: 36, child: OutlinedButton.icon(onPressed: () async {
                          final typeGroup = XTypeGroup(label: 'pdf', extensions: ['pdf']);
                          final f = await openFile(acceptedTypeGroups: [typeGroup]);
                          if (f != null) setState(() {
                            _inputPath.text = f.path;
                            final base = p.basenameWithoutExtension(f.path);
                            final suffix = widget.kindKey == 'body' ? '본문' : widget.kindKey == 'ans' ? '정답' : '해설';
                            _fileName.text = '${base}_${widget.grade}_$suffix.pdf';
                          });
                        }, icon: const Icon(Icons.folder_open, size: 16), label: const Text('찾기'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          shape: const StadiumBorder(),
                          backgroundColor: const Color(0xFF2A2A2A),
                        ))),
                      ]),
                      const SizedBox(height: 12),
                      const Text('페이지 범위 (예: 1-3,5,7-9)', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 6),
                      TextField(controller: _ranges, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: '쉼표로 구분, 범위는 하이픈', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))))),
                      const SizedBox(height: 12),
                      const Text('파일명', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 6),
                      TextField(controller: _fileName, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: '원본명_과정_종류.pdf', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))))),
                    ]),
                  ),
                  // Tab 2: 미리보기 선택 (썸네일 + 본문 + 영역 드래그)
                  Column(
                    children: [
                      Expanded(
                        child: _inputPath.text.trim().isEmpty
                            ? const Center(child: Text('PDF를 먼저 선택하세요', style: TextStyle(color: Colors.white54)))
                            : FutureBuilder<PdfDocument>(
                                future: PdfDocument.openFile(_inputPath.text.trim()),
                                builder: (context, snapshot) {
                                  if (snapshot.hasError) {
                                    return Center(child: Text('열기 오류: ${snapshot.error}', style: const TextStyle(color: Colors.redAccent)));
                                  }
                                  if (!snapshot.hasData) {
                                    return const Center(child: CircularProgressIndicator());
                                  }
                                  final doc = snapshot.data!;
                                  final pageCount = doc.pages.length;
                                  _currentPreviewPage = _currentPreviewPage.clamp(1, pageCount).toInt();
                                  return Row(
                                    children: [
                                      SizedBox(
                                        width: 96,
                                        child: ListView.builder(
                                          itemCount: pageCount,
                                          itemBuilder: (c, i) => InkWell(
                                            onTap: () => setState(() { _currentPreviewPage = i + 1; }),
                                            child: Padding(
                                              padding: const EdgeInsets.all(6.0),
                                              child: AspectRatio(
                                                aspectRatio: 1 / 1.4,
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    border: Border.all(color: Colors.white24),
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: PdfPageView(document: doc, pageNumber: i + 1),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: LayoutBuilder(
                                          builder: (ctx, constraints) {
                                            final showPage = _currentPreviewPage;
                                            final regions = _regionsByPage[showPage] ?? [];
                                            return GestureDetector(
                                              onPanStart: (d) {
                                                setState(() {
                                                  _dragStart = d.localPosition;
                                                  _dragRect = Rect.fromLTWH(_dragStart!.dx, _dragStart!.dy, 0, 0);
                                                });
                                              },
                                              onPanUpdate: (d) {
                                                if (_dragStart == null) return;
                                                setState(() { _dragRect = Rect.fromPoints(_dragStart!, d.localPosition); });
                                              },
                                              onPanEnd: (_) {
                                                final Size size = constraints.biggest;
                                                if (_dragRect != null) {
                                                  final r = _dragRect!;
                                                  final norm = Rect.fromLTWH(
                                                    (r.left / size.width).clamp(0.0, 1.0),
                                                    (r.top / size.height).clamp(0.0, 1.0),
                                                    (r.width / size.width).abs().clamp(0.0, 1.0),
                                                    (r.height / size.height).abs().clamp(0.0, 1.0),
                                                  );
                                                  setState(() {
                                                    final list = List<Rect>.from(_regionsByPage[showPage] ?? []);
                                                    list.add(norm);
                                                    _regionsByPage[showPage] = list;
                                                    _dragRect = null;
                                                    _dragStart = null;
                                                  });
                                                } else {
                                                  setState(() { _dragRect = null; _dragStart = null; });
                                                }
                                              },
                                              child: Stack(
                                                key: _previewKey,
                                                children: [
                                                  Container(
                                                    decoration: BoxDecoration(border: Border.all(color: Colors.white24)),
                                                    child: PdfPageView(document: doc, pageNumber: showPage),
                                                  ),
                                                  Positioned.fill(
                                                    child: Builder(
                                                      builder: (context) {
                                                        final Size size = constraints.biggest;
                                                        return Stack(
                                                          children: [
                                                            for (final nr in regions)
                                                              Positioned(
                                                                left: nr.left * size.width,
                                                                top: nr.top * size.height,
                                                                width: nr.width * size.width,
                                                                height: nr.height * size.height,
                                                                child: Container(
                                                                  decoration: BoxDecoration(
                                                                    color: Colors.blueAccent.withOpacity(0.15),
                                                                    border: Border.all(color: Colors.blueAccent),
                                                                  ),
                                                                ),
                                                              ),
                                                            if (_dragRect != null)
                                                              Positioned(
                                                                left: _dragRect!.left,
                                                                top: _dragRect!.top,
                                                                width: _dragRect!.width,
                                                                height: _dragRect!.height,
                                                                child: Container(
                                                                  decoration: BoxDecoration(
                                                                    color: Colors.orangeAccent.withOpacity(0.15),
                                                                    border: Border.all(color: Colors.orangeAccent),
                                                                  ),
                                                                ),
                                                              ),
                                                          ],
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        SizedBox(
                        height: 34,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final p = _currentPreviewPage;
                            setState(() {
                              if (!_selectedPages.contains(p)) _selectedPages.add(p);
                            });
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('현재 페이지 추가'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('선택: ${_selectedPages.join(', ')}', style: const TextStyle(color: Colors.white60)),
                      const SizedBox(width: 12),
                      if (_previewDoc != null) Text('페이지: $_currentPreviewPage/${_previewDoc!.pages.length}', style: const TextStyle(color: Colors.white54)),
                    ]),
                      const SizedBox(height: 8),
                      SizedBox(
                      height: 100,
                      child: ReorderableListView(
                        scrollDirection: Axis.horizontal,
                        buildDefaultDragHandles: false,
                        children: [
                          for (int i = 0; i < _selectedPages.length; i++)
                            Container(
                              key: ValueKey('sel_$i'),
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator, color: Colors.white60)),
                                const SizedBox(width: 6),
                                SizedBox(
                                  width: 56,
                                  height: 78,
                                  child: _previewDoc == null
                                      ? const SizedBox()
                                      : ClipRRect(
                                          borderRadius: BorderRadius.circular(4),
                                          child: PdfPageView(document: _previewDoc!, pageNumber: _selectedPages[i]),
                                        ),
                                ),
                                const SizedBox(width: 6),
                                InkWell(onTap: () => setState(() { _selectedPages.removeAt(i); }), child: const Icon(Icons.close, size: 16, color: Colors.white54)),
                              ]),
                            ),
                        ],
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final v = _selectedPages.removeAt(oldIndex);
                            _selectedPages.insert(newIndex, v);
                          });
                        },
                      ),
                    ),
                    ],
                  ),
                ]),
              ),
              if (_outputPath != null)
                Text('저장 경로: $_outputPath', style: const TextStyle(color: Colors.white60)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
        FilledButton(onPressed: _busy ? null : () async {
          final inPath = _inputPath.text.trim();
          final ranges = _ranges.text.trim();
          var outName = _fileName.text.trim();
          if (inPath.isEmpty) return;
          if (ranges.isEmpty && _selectedPages.isEmpty) return;
          if (outName.isEmpty) {
            final base = p.basenameWithoutExtension(inPath);
            final suffix = widget.kindKey == 'body' ? '본문' : widget.kindKey == 'ans' ? '정답' : '해설';
            outName = '${base}_${widget.grade}_$suffix.pdf';
          }
          setState(() => _busy = true);
          try {
            // 1) 사용자 정의 경로 선택 (파일 저장 대화상자)
            final saveLoc = await getSaveLocation(suggestedName: outName);
            if (saveLoc == null) {
              if (mounted) setState(() => _busy = false);
              return;
            }
            final outPath = saveLoc.path;
            // 2) Syncfusion로 inPath에서 ranges/선택 추출→ outPath 저장
            final inputBytes = await File(inPath).readAsBytes();
            final src = sf.PdfDocument(inputBytes: inputBytes);
            final selected = _selectedPages.isNotEmpty ? List<int>.from(_selectedPages) : _parseRanges(ranges, src.pages.count);

            // 임시: pdfrx API 정착 전까지는 선택된 페이지만 유지해 저장 (벡터 보존)
            final keep = selected.toSet();
            for (int i = src.pages.count - 1; i >= 0; i--) {
              if (!keep.contains(i + 1)) {
                src.pages.removeAt(i);
              }
            }
            final outBytes = await src.save();
            src.dispose();
            await File(outPath).writeAsBytes(outBytes, flush: true);
            setState(() => _outputPath = outPath);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF 생성이 완료되었습니다.')));
              Navigator.pop(context, outPath);
            }
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        }, style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('생성')),
      ],
    );
  }
}

class _ShapeSelectButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ShapeSelectButton({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2A2A2A) : const Color(0xFF252525),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? const Color(0xFF1976D2) : Colors.white24, width: selected ? 2 : 1),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5)),
      ),
    );
  }
}

