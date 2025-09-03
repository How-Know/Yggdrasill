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
  final GlobalKey _gradePanelKey = GlobalKey();
  Rect? _gradePanelRect;
  OverlayEntry? _gradeOverlay;
  bool _isGradeMenuOpen = false;
  bool _isInlineActionMenuOpen = false; // 학년 항목 점세개 메뉴 토글 상태
  OverlayEntry? _inlineActionMenuEntry;
  bool _inlineActionInProgress = false;
  bool _isDialogOpen = false;
  final Map<String, LayerLink> _gradeItemLayerLinks = {};
  Offset? _lastPointerGlobal;
  List<String> _grades = [];
  Map<String, int> _gradeIconCodes = {};
  int _selectedGradeIndex = 0;
  int _lastGradeScrollMs = 0;

  // 트리 레이아웃 상태
  String? _selectedFolderIdForTree; // null = 루트
  final Set<String> _expandedFolderIds = <String>{};
  Set<String> _favoriteFileIds = <String>{};
  String? _draggingFileId;
  String? _reorderFileTargetId;
  String? _draggingFolderId;
  String? _dragIncomingParentId;
  String? _reorderTargetFolderId;
  bool _reorderInsertBefore = true;
  String? _moveToParentFolderId;
  String? _fileDropTargetFolderId;
  String get _currentCategory => _customTabIndex == 0 ? 'textbook' : (_customTabIndex == 1 ? 'exam' : 'other');

  List<_ResourceFolder> _childFoldersOf(String? parentId) {
    final list = _folders.where((f) => (f.parentId ?? '') == (parentId ?? '')).toList();
    list.sort((a, b) {
      final ai = a.orderIndex ?? 1 << 20; // nulls last
      final bi = b.orderIndex ?? 1 << 20;
      if (ai != bi) return ai.compareTo(bi);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  List<_ResourceFile> _childFilesOf(String? parentId) {
    if (parentId == '__FAVORITES__') {
      final favs = _files.where((fi) => _favoriteFileIds.contains(fi.id)).toList();
      favs.sort((a, b) {
        final ai = a.orderIndex ?? 1 << 20;
        final bi = b.orderIndex ?? 1 << 20;
        if (ai != bi) return ai.compareTo(bi);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return favs;
    }
    final list = _files
        .where((fi) => (fi.parentId ?? '') == (parentId ?? ''))
        .toList();
    list.sort((a, b) {
      final ai = a.orderIndex ?? 1 << 20;
      final bi = b.orderIndex ?? 1 << 20;
      if (ai != bi) return ai.compareTo(bi);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  

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

  // 아래 전역 함수 정의를 제거하기 위해 클래스 내부로 이동시킨 동일 시그니처

  Offset _clampPosition(Offset pos, Size size, Size canvasSize) {
    final maxX = (canvasSize.width - size.width).clamp(0.0, double.infinity);
    final maxY = (canvasSize.height - size.height).clamp(0.0, double.infinity);
    return Offset(
      pos.dx.clamp(0.0, maxX),
      pos.dy.clamp(0.0, maxY),
    );
  }

  Future<T?> _showOneDialog<T>({required WidgetBuilder builder, bool barrierDismissible = true}) async {
    _isDialogOpen = true;
    try {
      return await showDialog<T>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: barrierDismissible,
        builder: builder,
      );
    } finally {
      _isDialogOpen = false;
    }
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

  Future<void> _loadGradeIcons() async {
    try {
      final map = await DataManager.instance.getResourceGradeIcons();
      if (mounted) setState(() => _gradeIconCodes = Map<String, int>.from(map));
    } catch (_) {
      if (mounted) setState(() => _gradeIconCodes = {});
    }
  }

  void _openGradeMenu() {
    if (_isGradeMenuOpen) return;
    final box = _gradeButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final overlayLeft = pos.dx;
    final overlayTop = pos.dy + size.height + 6;
    // ignore: avoid_print
    print('[GRADE][overlay-open] left=$overlayLeft top=$overlayTop button=(${pos.dx}, ${pos.dy}) size=(${size.width}, ${size.height})');
    _gradeOverlay = OverlayEntry(
      builder: (context) {
        final overlayRB = Overlay.of(context).context.findRenderObject() as RenderBox?;
        if (overlayRB != null) {
          // ignore: avoid_print
          print('[GRADE][overlay-builder] overlaySize=${overlayRB.size}');
        }
        return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeGradeMenu,
          ),
        ),
        Positioned(
          left: overlayLeft,
          top: overlayTop,
          child: Material(
          color: Colors.transparent,
          child: Container(
            key: _gradePanelKey,
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
                          final result = await _showOneDialog<Map<String, dynamic>>(
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
                              await _loadGradeIcons();
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
                        onTap: null,
                dense: true,
                selected: selected,
                selectedTileColor: const Color(0xFF333333),
                        title: InkWell(
                          onTap: () {
                            setState(() => _selectedGradeIndex = index);
                            _closeGradeMenu();
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Row(
                            children: [
                              if (_gradeIconCodes[g] != null) ...[
                                Icon(IconData(_gradeIconCodes[g]!, fontFamily: 'MaterialIcons'), color: Colors.white60, size: 16),
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
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Builder(builder: (rowCtx) {
                              final layerLink = _gradeItemLayerLinks.putIfAbsent(g, () => LayerLink());
                              return Listener(
                                onPointerDown: (e) => _lastPointerGlobal = e.position,
                                onPointerHover: (e) => _lastPointerGlobal = e.position,
                                child: IconButton(
                                  tooltip: '메뉴',
                                  icon: const Icon(Icons.more_vert, color: Colors.white60, size: 18),
                                  onPressed: () async {
                                    // 토글: 열려있으면 닫기
                                    if (_isInlineActionMenuOpen) { _closeInlineActionMenu(); return; }
                                    _isInlineActionMenuOpen = true;
                                    final overlayBox = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox?;
                                    final buttonBox = rowCtx.findRenderObject() as RenderBox?;
                                    if (overlayBox == null || buttonBox == null) { _isInlineActionMenuOpen = false; return; }
                                    final overlaySize = overlayBox.size;
                                    final fallbackGlobal = buttonBox.localToGlobal(buttonBox.size.bottomRight(Offset.zero));
                                    final baseGlobal = _lastPointerGlobal ?? fallbackGlobal;
                                    final baseLocal = overlayBox.globalToLocal(baseGlobal);
                                    const double menuWidth = 180.0;
                                    const double menuHeight = 112.0; // 2 items + padding
                                    double left = (baseLocal.dx + 8.0).clamp(8.0, overlaySize.width - menuWidth - 8.0);
                                    double top = (baseLocal.dy + 8.0).clamp(8.0, overlaySize.height - menuHeight - 8.0);
                                    _inlineActionMenuEntry = OverlayEntry(builder: (ctx) {
                                      return Stack(children: [
                                        // 바깥 클릭으로 닫기
                                        Positioned.fill(child: GestureDetector(onTap: _closeInlineActionMenu, behavior: HitTestBehavior.opaque)),
                                        Positioned(
                                          left: left,
                                          top: top,
                                          child: Material(
                                            color: Colors.transparent,
                                            child: Container(
                                              width: 180.0,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF2A2A2A),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(color: const Color(0xFF3A3A3A)),
                                                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 16, offset: const Offset(0, 8))],
                                              ),
                                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                                InkWell(
                                                  onTap: () async {
                                                    // ignore: avoid_print
                                                    print('[INLINE][edit] tapped for idx=$index name="$g" inProgress=$_inlineActionInProgress open=$_isDialogOpen');
                                                    if (_inlineActionInProgress) return;
                                                    _inlineActionInProgress = true;
                                                    try {
                                                      _closeInlineActionMenu();
                                                      await WidgetsBinding.instance.endOfFrame;
                                                      if (_isGradeMenuOpen) { _closeGradeMenu(); await WidgetsBinding.instance.endOfFrame; }
                                                      final controller = TextEditingController(text: g);
                                                    final icons = <IconData>[
                                                      Icons.school, Icons.menu_book, Icons.bookmark, Icons.star,
                                                      Icons.favorite, Icons.lightbulb, Icons.flag, Icons.language,
                                                      Icons.calculate, Icons.science, Icons.psychology, Icons.code,
                                                      Icons.draw, Icons.piano, Icons.sports_basketball, Icons.public,
                                                      Icons.attach_file, Icons.folder, Icons.create, Icons.edit_note,
                                                    ];
                                                    final newResult = await _showOneDialog<Map<String, dynamic>>(
                                                      barrierDismissible: true,
                                                      builder: (ctx) {
                                                        // ignore: avoid_print
                                                        print('[INLINE][edit-dialog] build for "$g"');
                                                        return StatefulBuilder(
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
                                                        );
                                                      },
                                                    );
                                                    // ignore: avoid_print
                                                    print('[INLINE][edit] result=${newResult != null} newName="${(newResult?['name'] as String?)?.trim()}"');
                                                    if (newResult != null) {
                                                      final newName = (newResult['name'] as String?)?.trim() ?? '';
                                                      final icon = (newResult['icon'] as int?) ?? 0;
                                                      if (newName.isNotEmpty) {
                                                        setState(() => _grades[index] = newName);
                                                        await DataManager.instance.saveResourceGrades(_grades);
                                                        if (icon != 0) {
                                                          await DataManager.instance.setResourceGradeIcon(newName, icon);
                                                        }
                                                        await _loadGradeIcons();
                                                        Overlay.of(context).setState(() {});
                                                      }
                                                    }
                                                    } finally {
                                                      _inlineActionInProgress = false;
                                                    }
                                                  },
                                                  child: const ListTile(
                                                    dense: true,
                                                    leading: Icon(Icons.edit, color: Colors.white70, size: 18),
                                                    title: Text('이름 변경', style: TextStyle(color: Colors.white)),
                                                  ),
                                                ),
                                                const Divider(height: 1, color: Colors.white12),
                                                InkWell(
                                                  onTap: () async {
                                                    // ignore: avoid_print
                                                    print('[INLINE][delete] tapped for idx=$index name="$g" inProgress=$_inlineActionInProgress open=$_isDialogOpen');
                                                    if (_inlineActionInProgress) return;
                                                    _inlineActionInProgress = true;
                                                    try {
                                                      _closeInlineActionMenu();
                                                      await WidgetsBinding.instance.endOfFrame;
                                                      if (_isGradeMenuOpen) { _closeGradeMenu(); await WidgetsBinding.instance.endOfFrame; }
                                                      final confirm = await _showOneDialog<bool>(
                                                        builder: (ctx) {
                                                          // ignore: avoid_print
                                                          print('[INLINE][delete-dialog] build for "$g"');
                                                          return AlertDialog(
                                                            backgroundColor: const Color(0xFF1F1F1F),
                                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                                            title: const Text('삭제 확인', style: TextStyle(color: Colors.white, fontSize: 20)),
                                                            content: Text('\"$g\" 학년을 삭제할까요?', style: const TextStyle(color: Colors.white70)),
                                                            actions: [
                                                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                                                              FilledButton(
                                                                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                                                                onPressed: () => Navigator.pop(ctx, true),
                                                                child: const Text('삭제'),
                                                              ),
                                                            ],
                                                          );
                                                        },
                                                      );
                                                      // ignore: avoid_print
                                                      print('[INLINE][delete] confirm=$confirm for "$g"');
                                                      if (confirm == true) {
                                                        setState(() => _grades.removeAt(index));
                                                        if (_grades.isEmpty) {
                                                          _selectedGradeIndex = 0;
                                                        } else {
                                                          _selectedGradeIndex = _selectedGradeIndex.clamp(0, _grades.length - 1);
                                                        }
                                                        await DataManager.instance.saveResourceGrades(_grades);
                                                        await _loadGradeIcons();
                                                        Overlay.of(context).setState(() {});
                                                      }
                                                    } finally {
                                                      _inlineActionInProgress = false;
                                                    }
                                                  },
                                                  child: const ListTile(
                                                    dense: true,
                                                    leading: Icon(Icons.delete, color: Colors.white70, size: 18),
                                                    title: Text('삭제', style: TextStyle(color: Colors.white)),
                                                  ),
                                                ),
                                              ]),
                                            ),
                                          ),
                                        ),
                                      ]);
                                    });
                                    Overlay.of(context, rootOverlay: true).insert(_inlineActionMenuEntry!);
                                  },
                                ),
                              );
                            }),
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
      // 패널 실제 렌더 크기로 패널 사각형 저장
      final rb = _gradePanelKey.currentContext?.findRenderObject() as RenderBox?;
      if (rb != null) {
        final topLeft = rb.localToGlobal(Offset.zero);
        final sz = rb.size;
        _gradePanelRect = Rect.fromLTWH(topLeft.dx, topLeft.dy, sz.width, sz.height);
        // ignore: avoid_print
        print('[GRADE][panel-rect] $_gradePanelRect');
      }
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
    _gradePanelRect = null;
  }

  void _closeInlineActionMenu() {
    _inlineActionMenuEntry?.remove();
    _inlineActionMenuEntry = null;
    _isInlineActionMenuOpen = false;
    // ignore: avoid_print
    print('[INLINE][close]');
  }

  Future<void> _onAddFolder() async {
    await _onAddFolderWithParent(_selectedFolderIdForTree);
  }

  Future<void> _onAddFolderWithParent(String? parentId) async {
    final result = await showDialog<_ResourceFolder>(
      context: context,
      builder: (context) => const _FolderCreateDialog(),
    );
    if (result == null) return;
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
          parentId: parentId,
          orderIndex: (_childFoldersOf(parentId).isNotEmpty ? (_childFoldersOf(parentId).map((e) => e.orderIndex ?? 0).reduce((a,b)=> a > b ? a : b) + 1) : 0),
          ),
        );
      // 컨텍스트 메뉴로 생성 시, 방금 추가한 부모를 확장
      if (parentId != null) _expandedFolderIds.add(parentId);
      });
      await _saveLayout();
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
    final merged2 = merged.copyWith(parentId: _selectedFolderIdForTree);
      // 파일 메타 저장 (탭 카테고리 부여)
      await DataManager.instance.saveResourceFileWithCategory({
      'id': merged2.id,
      'name': merged2.name,
      'url': '',
      'color': merged2.color?.value,
      'grade': merged2.primaryGrade ?? '',
      'parent_id': merged2.parentId,
      'pos_x': merged2.position.dx,
      'pos_y': merged2.position.dy,
      'width': merged2.size.width,
      'height': merged2.size.height,
      'text_color': merged2.textColor?.value,
      'icon_code': merged2.icon?.codePoint,
      'icon_image_path': merged2.iconImagePath,
      'description': merged2.description,
      }, _currentCategory);
      // 학년별 링크 저장
    await DataManager.instance.saveResourceFileLinks(merged2.id, merged2.linksByGrade);
    // 상태 반영
    setState(() {
      _files.add(merged2);
    });
  }

  @override
  void initState() {
    super.initState();
    _loadLayout();
    _ensureGradesLoaded();
    _loadGradeIcons();
    _initFavoritesAndDefaultSelection();
  }

  Future<void> _initFavoritesAndDefaultSelection() async {
    _favoriteFileIds = await DataManager.instance.loadResourceFavorites();
    // 교재탭 첫 진입 시 즐겨찾기 선택
    setState(() {
      _selectedFolderIdForTree = '__FAVORITES__';
    });
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
        'parent_id': f.parentId,
        'order_index': f.orderIndex,
      }).toList();
      await DataManager.instance.saveResourceFoldersForCategory(_currentCategory, rows);
    } catch (e) {
      // ignore errors silently for now
    }
  }

  Future<void> _loadLayout() async {
    try {
      final rows = await DataManager.instance.loadResourceFoldersForCategory(_currentCategory);
      final loaded = rows.map<_ResourceFolder>((r) => _ResourceFolder(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? '',
        description: (r['description'] as String?) ?? '',
        color: (r['color'] as int?) != null ? Color(r['color'] as int) : null,
        position: Offset((r['pos_x'] as num?)?.toDouble() ?? 0.0, (r['pos_y'] as num?)?.toDouble() ?? 0.0),
        size: Size((r['width'] as num?)?.toDouble() ?? _defaultFolderSize.width, (r['height'] as num?)?.toDouble() ?? _defaultFolderSize.height),
        shape: (r['shape'] as String?) ?? 'rect',
        parentId: r['parent_id'] as String?,
        orderIndex: (r['order_index'] as num?)?.toInt(),
      )).toList();
      final fileRows = await DataManager.instance.loadResourceFilesForCategory(_currentCategory);
      final List<_ResourceFile> loadedFiles = [];
      for (final r in fileRows) {
        final id = r['id'] as String;
        final links = await DataManager.instance.loadResourceFileLinks(id);
        loadedFiles.add(_ResourceFile(
          id: id,
          name: (r['name'] as String?) ?? '',
          color: (r['color'] as int?) != null ? Color(r['color'] as int) : null,
          icon: (r['icon_code'] as int?) != null ? IconData(r['icon_code'] as int, fontFamily: 'MaterialIcons') : null,
          textColor: (r['text_color'] as int?) != null ? Color(r['text_color'] as int) : null,
          iconImagePath: (r['icon_image_path'] as String?),
          description: (r['description'] as String?),
          parentId: r['parent_id'] as String?,
          position: Offset((r['pos_x'] as num?)?.toDouble() ?? 0.0, (r['pos_y'] as num?)?.toDouble() ?? 0.0),
          size: Size((r['width'] as num?)?.toDouble() ?? 200.0, (r['height'] as num?)?.toDouble() ?? 60.0),
          linksByGrade: links,
          orderIndex: (r['order_index'] as num?)?.toInt(),
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
      // Disable push-away behavior; keep neighbors fixed
    }
    // 파일 이동 + 즉시 저장
    for (int j = 0; j < _files.length; j++) {
      final other = _files[j];
      if (other.id == movedId) continue; // 주체 파일은 제외
      final otherRect = Rect.fromLTWH(other.position.dx, other.position.dy, other.size.width, other.size.height);
      // Disable push-away behavior; keep neighbors fixed
    }
    // ignore: avoid_print
    print('[GROUP][end]');
  }

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('[RES] ResourcesScreen build');
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
                    // 탭 변경 시 데이터 재로딩 및 트리 초기화
                    _expandedFolderIds.clear();
                    _selectedFolderIdForTree = '__FAVORITES__';
                    // 이전 탭 데이터가 잠깐 보이는 플리커 방지: 즉시 클리어
                    _folders.clear();
                    _files.clear();
                  });
                  // 카테고리별 데이터 로드
                  _loadLayout();
                },
              ),
              const SizedBox(height: 1),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 240, // 폴더 리스트 폭과 일치
                  child: OutlinedButton.icon(
                    key: _gradeButtonKey,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38, width: 1.4),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15.4),
                    ),
                    onPressed: () async {
                      if (_isGradeMenuOpen) _closeGradeMenu();
                      await _ensureGradesLoaded();
                      _openGradeMenu();
                    },
                    icon: const Icon(Icons.school, size: 20),
                    label: Text(
                      _grades.isEmpty ? '' : _grades[_selectedGradeIndex],
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            String desc = '';
                            String folderName = '';
                            if (_selectedFolderIdForTree == '__FAVORITES__') {
                              folderName = '즐겨찾기';
                              desc = '';
                            } else {
                              final idx = _folders.indexWhere((x) => x.id == _selectedFolderIdForTree);
                              if (idx != -1) {
                                folderName = _folders[idx].name;
                                desc = _folders[idx].description;
                              }
                            }
                            return Padding(
                              padding: const EdgeInsets.only(left: 15),
                              child: Row(
                                children: [
                                  Text(
                                    folderName,
                                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      desc,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white70, fontSize: 15),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    height: 36,
                                    child: OutlinedButton.icon(
                                      onPressed: () async {
                                        // ignore: avoid_print
                                        print('[Header] 파일 추가 버튼 눌림');
                                        final meta = await showDialog<Map<String, dynamic>>(
                                          context: context,
                                          builder: (ctx) => const _FileCreateDialog(),
                                        );
                                        if (meta == null || meta['meta'] is! _ResourceFile) return;
                                        var created = meta['meta'] as _ResourceFile;
                                        final parentId = _selectedFolderIdForTree;
                                        final childList = _childFilesOf(parentId);
                                        final nextIndex = childList.isEmpty ? 0 : (childList.map((e) => e.orderIndex ?? 0).reduce((a,b)=> a > b ? a : b) + 1);
                                        created = created.copyWith(parentId: parentId, orderIndex: nextIndex);

                                        final linksRes = await showDialog<Map<String, dynamic>>(
                                          context: context,
                                          builder: (ctx) => _FileLinksDialog(meta: created, initialLinks: const {}),
                                        );
                                        Map<String, String> links = {};
                                        if (linksRes != null && linksRes['links'] is Map<String, String>) {
                                          links = Map<String, String>.from(linksRes['links'] as Map);
                                        }
                                        created = created.copyWith(linksByGrade: links);

                                        setState(() { _files.add(created); });
                                        await DataManager.instance.saveResourceFile({
                                          'id': created.id,
                                          'name': created.name,
                                          'description': created.description,
                                          'parent_id': created.parentId,
                                          'order_index': created.orderIndex,
                                          'pos_x': created.position.dx,
                                          'pos_y': created.position.dy,
                                          'width': created.size.width,
                                          'height': created.size.height,
                                          'color': created.color?.value,
                                          'text_color': created.textColor?.value,
                                          'icon_code': created.icon?.codePoint,
                                          'icon_image_path': created.iconImagePath,
                                        });
                                        await DataManager.instance.saveResourceFileLinks(created.id, links);
                                      },
                                      icon: const Icon(Icons.add, size: 18),
                                      label: const Text('파일 추가'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white70,
                                        side: const BorderSide(color: Colors.white24),
                                        shape: const StadiumBorder(),
                                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                                      ),
                                    ),
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
              const Divider(height: 1, color: Colors.white12),
              Expanded(
                child: IndexedStack(
                  index: _customTabIndex,
                  children: [
                    _buildTextbooksTreeLayout(),
                    _buildTextbooksTreeLayout(),
                    _buildTextbooksTreeLayout(),
                  ],
                ),
              ),
              // 하단 플로팅 영역 확보 제거: 버튼을 컨테이너 내부로 재배치
            ],
          ),
        ],
      ),
    );
  }
}

// --- 교재 탭: 좌측 트리 + 우측 그리드 ---
extension _ResourcesScreenTree on _ResourcesScreenState {
  Widget _buildDragFeedback(_ResourceFolder f) {
    final children = _childFoldersOf(f.id);
    return Material(
      color: Colors.transparent,
              child: Container(
        width: 240,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A).withOpacity(0.92),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 6))],
        ),
        child: Row(
          children: [
            Icon(Icons.folder, color: (f.color ?? Colors.amber).withOpacity(0.9), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            if (children.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text('${children.length}', style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
          ],
        ),
      ),
    );
  }

  void _reorderSiblings({required _ResourceFolder target, required _ResourceFolder incoming}) {
    final parent = target.parentId;
    final siblings = _childFoldersOf(parent);
    final minIndex = siblings.map((e) => e.orderIndex ?? 0).fold<int>(0, (a, b) => a < b ? a : b);
    final maxIndex = siblings.map((e) => e.orderIndex ?? 0).fold<int>(0, (a, b) => a > b ? a : b);
    // 기본 인덱스 부여
    for (int i = 0; i < siblings.length; i++) {
      final idx = _folders.indexWhere((x) => x.id == siblings[i].id);
      if (idx != -1) _folders[idx] = _folders[idx].copyWith(orderIndex: i);
    }
    // incoming을 target 위치로 이동
    final from = siblings.indexWhere((x) => x.id == incoming.id);
    final to = siblings.indexWhere((x) => x.id == target.id);
    if (from == -1 || to == -1) return;
    final ordered = List<_ResourceFolder>.from(siblings);
    final moved = ordered.removeAt(from);
    ordered.insert(to, moved);
    // 반영
    for (int i = 0; i < ordered.length; i++) {
      final idx = _folders.indexWhere((x) => x.id == ordered[i].id);
      if (idx != -1) _folders[idx] = _folders[idx].copyWith(orderIndex: i);
    }
    setState(() {});
    _saveLayout();
  }

  void _moveToAsChild({required _ResourceFolder targetParent, required _ResourceFolder incoming}) {
    // 부모만 바꾸고, 마지막 인덱스로 부여
    final childList = _childFoldersOf(targetParent.id);
    final nextIndex = childList.isEmpty ? 0 : (childList.map((e) => e.orderIndex ?? 0).reduce((a,b)=> a > b ? a : b) + 1);
    final idx = _folders.indexWhere((x) => x.id == incoming.id);
    if (idx != -1) {
      _folders[idx] = _folders[idx].copyWith(parentId: targetParent.id, orderIndex: nextIndex);
    }
    setState(() {});
    _saveLayout();
  }
  Widget _buildTextbooksTreeLayout() {
    return Listener(
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) {
          final dy = signal.scrollDelta.dy;
          if (dy != 0) _changeGradeByDelta(dy > 0 ? 1 : -1);
        }
      },
                child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
            width: 260,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF232323),
                border: Border(right: BorderSide(color: Colors.white.withOpacity(0.06), width: 1)),
              ),
              child: Column(children: [
                Expanded(child: _buildFolderTreePanel()),
                // 하단 버튼 영역이 겹치지 않도록 추가 여백 없이 스크롤 영역만 확장
              ]),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 15, left: 0),
                    child: _buildFolderContentGrid(),
                  ),
                ),
                // [RES] bottom +파일 버튼 제거 (헤더 우측 버튼으로 대체)
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderTreePanel() {
    final flattened = <Map<String, dynamic>>[];
    void visit(String? parentId, int depth) {
      final children = _childFoldersOf(parentId);
      for (final f in children) {
        flattened.add({'folder': f, 'depth': depth});
        if (_expandedFolderIds.contains(f.id)) {
          visit(f.id, depth + 1);
        }
      }
    }
    // root pseudo node omitted; 바로 폴더 목록으로 시작
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
                    Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text('폴더', style: TextStyle(color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  tooltip: '최상위 폴더 추가',
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  onPressed: () async => await _onAddFolderWithParent(null),
                  icon: const Icon(Icons.add, color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              flattened.clear();
              visit(null, 0);
              return ListView.builder(
                itemCount: flattened.length,
                itemBuilder: (context, index) {
                  final f = flattened[index]['folder'] as _ResourceFolder;
                  final depth = flattened[index]['depth'] as int;
                  final children = _childFoldersOf(f.id);
                  final isExpanded = _expandedFolderIds.contains(f.id);
                  final isSelected = _selectedFolderIdForTree == f.id;
                  return InkWell(
                    onTap: () => setState(() {
                      _selectedFolderIdForTree = f.id;
                      if (children.isNotEmpty) {
                        if (isExpanded) {
                          _expandedFolderIds.remove(f.id);
                        } else {
                          _expandedFolderIds.add(f.id);
                        }
                      }
                    }),
                    onSecondaryTapDown: (details) async {
                      // 우클릭 컨텍스트 메뉴: 하위 폴더 만들기
                      final overlay = Overlay.of(context)?.context.findRenderObject();
                      if (overlay is! RenderBox) return;
                      final position = RelativeRect.fromRect(
                        Rect.fromPoints(
                          details.globalPosition,
                          details.globalPosition,
                        ),
                        Offset.zero & overlay.size,
                      );
                      final action = await showMenu<String>(
                        context: context,
                        position: position,
                        color: const Color(0xFF2A2A2A),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Color(0xFF3A3A3A))),
                        items: [
                          const PopupMenuItem<String>(
                            value: 'new-folder',
                            child: Text('하위 폴더 만들기', style: TextStyle(color: Colors.white)),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem<String>(
                            value: 'edit-folder',
                            child: Text('수정', style: TextStyle(color: Colors.white)),
                          ),
                          const PopupMenuItem<String>(
                            value: 'delete-folder',
                            child: Text('삭제', style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      );
                      if (action == 'new-folder') {
                        await _onAddFolderWithParent(f.id);
                      } else if (action == 'edit-folder') {
                        final result = await showDialog<_ResourceFolder>(
                          context: context,
                          builder: (ctx) => _FolderEditDialog(initial: f),
                        );
                        if (result != null) {
                          setState(() {
                            final idx = _folders.indexWhere((x) => x.id == f.id);
                            if (idx != -1) _folders[idx] = result.copyWith(parentId: f.parentId, orderIndex: f.orderIndex);
                          });
                          await _saveLayout();
                        }
                      } else if (action == 'delete-folder') {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: const Color(0xFF1F1F1F),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            title: const Text('삭제 확인', style: TextStyle(color: Colors.white)),
                            content: Text('"${f.name}" 폴더를 삭제할까요?', style: const TextStyle(color: Colors.white70)),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('삭제')),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          setState(() {
                            _folders.removeWhere((x) => x.id == f.id);
                          });
                          await _saveLayout();
                        }
                      }
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LongPressDraggable<_ResourceFolder>(
                      data: f,
                      hapticFeedbackOnStart: true,
                      feedback: _buildDragFeedback(f),
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      onDragStarted: () {
                        setState(() { _draggingFolderId = f.id; _moveToParentFolderId = null; _reorderTargetFolderId = null;});
                      },
                      onDragEnd: (_) {
                        setState(() { _draggingFolderId = null; _moveToParentFolderId = null; _reorderTargetFolderId = null;});
                      },
                      // 1) 폴더 재정렬/이동 DragTarget
                      child: DragTarget<_ResourceFolder>(
                        onWillAccept: (incoming) {
                          if (incoming == null) return false;
                          if (incoming.id == f.id) return false; // self
                          final sameLevel = (incoming.parentId ?? '') == (f.parentId ?? '');
                          // 같은 레벨: 재정렬 표시, 다른 레벨: 이동 하이라이트
                          setState(() { 
                            if (sameLevel) {
                              _reorderTargetFolderId = f.id;
                          } else {
                              _moveToParentFolderId = f.id;
                            }
                          });
                          return true;
                        },
                        onAcceptWithDetails: (details) {
                          final incoming = details.data;
                          final sameLevel = (incoming.parentId ?? '') == (f.parentId ?? '');
                          if (sameLevel) {
                            _reorderSiblings(target: f, incoming: incoming);
                          } else {
                            _moveToAsChild(targetParent: f, incoming: incoming);
                          }
                          setState(() { _moveToParentFolderId = null; _reorderTargetFolderId = null; });
                        },
                        onLeave: (_) { setState(() { if (_reorderTargetFolderId == f.id) _reorderTargetFolderId = null; if (_moveToParentFolderId == f.id) _moveToParentFolderId = null; }); },
                        builder: (context, candidate, rejected) {
                          final highlightMove = _moveToParentFolderId == f.id && _draggingFolderId != null && _draggingFolderId != f.id;
                          final highlightReorder = _reorderTargetFolderId == f.id && _draggingFolderId != null && _draggingFolderId != f.id;
                          return Stack(
                            children: [
                              Container(
                                color: highlightMove ? const Color(0xFF2F3A4A) : isSelected ? const Color(0xFF2A2A2A) : Colors.transparent,
                                padding: EdgeInsets.only(left: 12.0 + depth * 16.0, right: 12.0, top: 8.0, bottom: 8.0),
                                child: Row(
                                  children: [
                                    if (children.isNotEmpty)
                                      InkWell(
                                        onTap: () => setState(() {
                                          if (isExpanded) {
                                            _expandedFolderIds.remove(f.id);
                                          } else {
                                            _expandedFolderIds.add(f.id);
                                          }
                                        }),
                                        child: Icon(isExpanded ? Icons.expand_more : Icons.chevron_right, color: Colors.white54, size: 18),
                                      )
                                    else
                                      const SizedBox(width: 18),
                                    const SizedBox(width: 4),
                                    Icon(Icons.folder, color: (f.color ?? Colors.amber).withOpacity(0.85), size: 18),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        f.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16),
                                      ),
                                    ),
                                    if (highlightMove)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 8.0),
                                        child: Text('"${f.name}"으로 이동', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                                      ),
                                  ],
                                ),
                              ),
                              if (highlightReorder)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: SizedBox(height: 2, child: DecoratedBox(decoration: BoxDecoration(color: const Color(0xFF64A6DD)))),
                                ),
                              Positioned.fill(
                                child: DragTarget<_ResourceFile>(
                                  onWillAccept: (incomingFile) {
                                    final ok = incomingFile != null;
                                    if (ok) setState(() { _fileDropTargetFolderId = f.id; });
                                    return ok;
                                  },
                                  onAcceptWithDetails: (details) async {
                                    final incoming = details.data;
                                    final idx = _files.indexWhere((x) => x.id == incoming.id);
                                    if (idx != -1) {
                                      final childList = _childFilesOf(f.id);
                                      final nextIndex = childList.isEmpty ? 0 : (childList.map((e) => e.orderIndex ?? 0).reduce((a,b)=> a > b ? a : b) + 1);
                                      setState(() {
                                        _files[idx] = _files[idx].copyWith(parentId: f.id, orderIndex: nextIndex);
                                        _fileDropTargetFolderId = null;
                                      });
                                      await DataManager.instance.saveResourceFile({'id': incoming.id, 'parent_id': f.id, 'order_index': nextIndex});
                                    }
                                  },
                                  onLeave: (_) => setState(() { if (_fileDropTargetFolderId == f.id) _fileDropTargetFolderId = null; }),
                                  builder: (context, candFiles, rejFiles) {
                                    final active = _fileDropTargetFolderId == f.id && candFiles.isNotEmpty;
                                    return AnimatedContainer(
                                      duration: const Duration(milliseconds: 120),
                                      decoration: active
                                          ? BoxDecoration(
                                              border: Border.all(color: const Color(0xFF64A6DD), width: 2),
                                              borderRadius: BorderRadius.circular(8),
                                            )
                                          : const BoxDecoration(),
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    // 2) 파일을 이 폴더로 이동시키는 DragTarget (다른 타입)
                    DragTarget<_ResourceFile>(
                      onWillAccept: (incomingFile) {
                        final ok = incomingFile != null; // 어떤 파일이든 허용
                        if (ok) setState(() { _fileDropTargetFolderId = f.id; });
                        return ok;
                      },
                      onAcceptWithDetails: (details) async {
                        final incoming = details.data;
                        final idx = _files.indexWhere((x) => x.id == incoming.id);
                        if (idx != -1) {
                          // 새 부모 폴더의 마지막 인덱스 계산
                          final childList = _childFilesOf(f.id);
                          final nextIndex = childList.isEmpty ? 0 : (childList.map((e) => e.orderIndex ?? 0).reduce((a,b)=> a > b ? a : b) + 1);
                          setState(() {
                            _files[idx] = _files[idx].copyWith(parentId: f.id, orderIndex: nextIndex);
                            _fileDropTargetFolderId = null;
                          });
                          await DataManager.instance.saveResourceFile({'id': incoming.id, 'parent_id': f.id, 'order_index': nextIndex});
                        }
                      },
                      onLeave: (_) => setState(() { if (_fileDropTargetFolderId == f.id) _fileDropTargetFolderId = null; }),
                      builder: (context, cand, rej) {
                        final highlight = _fileDropTargetFolderId == f.id && cand.isNotEmpty;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          height: 2,
                          margin: EdgeInsets.only(left: 12.0 + depth * 16.0),
                          color: highlight ? const Color(0xFF64A6DD) : Colors.transparent,
                        );
                      },
                    ),
                  ],
                ),
                  );
                },
              );
            },
          ),
        ),
        // 즐겨찾기 고정 항목
        Container(
          height: 40,
                        child: InkWell(
            onTap: () => setState(() => _selectedFolderIdForTree = '__FAVORITES__'),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.bookmark, color: _selectedFolderIdForTree == '__FAVORITES__' ? Colors.amber : Colors.white54, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('즐겨찾기', style: TextStyle(color: Colors.white.withOpacity(0.95), fontWeight: FontWeight.w700)),
                ),
              ],
                        ),
                      ),
                    ),
      ],
    );
  }

  Widget _buildFolderContentGrid() {
    final files = _childFilesOf(_selectedFolderIdForTree);
    final selectedFolder = _folders.firstWhere(
      (f) => f.id == _selectedFolderIdForTree,
      orElse: () => _ResourceFolder(id: '', name: '', color: null, description: '', position: Offset.zero, size: const Size(0,0), shape: 'rect', parentId: null),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const double gridCardWidth = 290.0; // +10%
          const double gridCardHeight = 170.0; // +10%
          const double spacing = 16;
          final cols = (constraints.maxWidth / (gridCardWidth + spacing)).floor().clamp(1, 999);
          final double gridWidth = (cols * gridCardWidth) + ((cols - 1) * spacing);
          // ignore: avoid_print
          print('[GRID] constraints=' + constraints.maxWidth.toStringAsFixed(1) + 'x' + constraints.maxHeight.toStringAsFixed(1) +
              ', fixed=' + gridCardWidth.toString() + 'x' + gridCardHeight.toString() + ', cols=' + cols.toString() +
              ', aspect=' + (gridCardWidth / gridCardHeight).toStringAsFixed(3));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 폴더 설명은 상단 행(과정 버튼 옆)으로 이동했으므로 여기서는 렌더링하지 않음
              Expanded(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: gridWidth,
                    child: GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: spacing,
                        crossAxisSpacing: spacing,
                        childAspectRatio: gridCardWidth / gridCardHeight, // 고정 비율 유지
                      ),
                      itemCount: files.length,
                      itemBuilder: (context, index) {
                    final fi = files[index];
                    // ignore: avoid_print
                    print('[GRID:item] idx=' + index.toString() + ' id=' + fi.id);
                    return LongPressDraggable<_ResourceFile>(
                      data: fi,
                      hapticFeedbackOnStart: true,
                      feedback: Opacity(
                        opacity: 0.9,
                      child: Material(
                          color: Colors.transparent,
                          child: SizedBox(width: gridCardWidth, height: gridCardHeight, child: _GridFileCard(file: fi)),
                        ),
                      ),
                      onDragStarted: () => setState(() { _draggingFileId = fi.id; }),
                      onDragEnd: (_) => setState(() { _draggingFileId = null; _reorderFileTargetId = null; }),
                      childWhenDragging: AnimatedOpacity(duration: const Duration(milliseconds: 150), opacity: 0.25, child: _GridFileCard(file: fi)),
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      child: Row(
                        children: [
                          // 왼쪽 폴더 트리 드롭 영역: 폴더로 이동 허용
                          DragTarget<_ResourceFolder>(
                            onWillAccept: (incomingFolder) {
                              // 파일을 트리로 드롭할 때만 하이라이트 (incomingFolder는 null, candidate는 상위 DragTarget의 데이터)
                              return false; // 폴더 재정렬용, 여기서는 파일 받지 않음
                            },
                            builder: (context, candF, rejF) {
                              return const SizedBox(width: 0);
                            },
                          ),
                          // 카드 간 재정렬 영역
                          Expanded(child: DragTarget<_ResourceFile>(
                        onWillAccept: (incoming) {
                          final ok = incoming != null && incoming.id != fi.id;
                          if (ok) setState(() { _reorderFileTargetId = fi.id; });
                          return ok;
                        },
                        onAcceptWithDetails: (details) {
                          final incoming = details.data;
                          // 같은 폴더에서 재정렬
                          final sameParent = (incoming.parentId ?? '') == (fi.parentId ?? _selectedFolderIdForTree ?? '');
                          if (sameParent) {
                            // 같은 폴더 내 재정렬: order_index를 기준으로 드롭 대상 위치로 이동
                            final siblings = _childFilesOf(fi.parentId ?? _selectedFolderIdForTree);
                            final fromIdx = siblings.indexWhere((x) => x.id == incoming.id);
                            final toIdx = siblings.indexWhere((x) => x.id == fi.id);
                            if (fromIdx != -1 && toIdx != -1) {
                              final ordered = List<_ResourceFile>.from(siblings);
                              final moved = ordered.removeAt(fromIdx);
                              ordered.insert(toIdx, moved);
                              // Re-assign order_index 0..N and persist
                              for (int i = 0; i < ordered.length; i++) {
                                final gIdx = _files.indexWhere((x) => x.id == ordered[i].id);
                                if (gIdx != -1) {
                                  _files[gIdx] = _files[gIdx].copyWith(orderIndex: i);
                                  DataManager.instance.saveResourceFile({'id': ordered[i].id, 'order_index': i});
                                }
                              }
                              setState(() {});
                            }
                          } else {
                            // 폴더 트리로의 이동은 폴더 DragTarget에서만 허용. 여기서는 막음.
                          }
                          setState(() { _reorderFileTargetId = null; });
                        },
                        onLeave: (_) => setState(() { if (_reorderFileTargetId == fi.id) _reorderFileTargetId = null; }),
                        builder: (context, cand, rej) {
                          final draggingId = _draggingFileId;
                          final isTarget = _reorderFileTargetId == fi.id && draggingId != null && draggingId != fi.id;
                          // 마우스 x 기준으로 좌/우 표시를 나눔 (기본 좌측 우선 강조)
                          bool showLeft = false;
                          bool showRight = false;
                          return LayoutBuilder(builder: (ctx, cons) {
                            if (isTarget && cand.isNotEmpty) {
                              showLeft = true;
                              showRight = false;
                            }
                            return Stack(children: [
                              // 고정 크기 카드 (그리드 셀 내에서 항상 동일 크기)
                              Center(
                                child: SizedBox(
                                  width: gridCardWidth,
                                  height: gridCardHeight,
                                  child: _GridFileCard(file: fi),
                                ),
                              ),
                              // 좌/우 하이라이트는 오버레이로 표시하여 실제 레이아웃에 영향 없음
                              if (isTarget && showLeft)
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  bottom: 0,
                                  width: 10,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF64A6DD).withOpacity(0.25),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              if (isTarget && showRight)
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  bottom: 0,
                                  width: 10,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF64A6DD).withOpacity(0.25),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                            ]);
                          });
                        },
                      )),
                        ],
                      ),
                    );
                  },
                    ),
                  ),
                ),
              ),
            ],
          );
        },
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
  late final Map<String, TextEditingController> _bodyCtrls;     // 본문
  late final Map<String, TextEditingController> _solutionCtrls; // 해설
  late final Map<String, TextEditingController> _answerCtrls;   // 정답
  @override
  void initState() {
    super.initState();
    _init();
  }
  Future<void> _init() async {
    final rows = await DataManager.instance.getResourceGrades();
    final list = rows.map((e) => (e['name'] as String?) ?? '').where((e) => e.isNotEmpty).toList();
    _grades = list.isEmpty ? ['초1','초2','초3','초4','초5','초6','중1','중2','중3','고1','고2','고3'] : list;
    _bodyCtrls = { for (final g in _grades) g: TextEditingController(text: widget.initialLinks?['$g#body'] ?? '') };
    _solutionCtrls = { for (final g in _grades) g: TextEditingController(text: widget.initialLinks?['$g#sol'] ?? '') };
    _answerCtrls = { for (final g in _grades) g: TextEditingController(text: widget.initialLinks?['$g#ans'] ?? '') };
    if (mounted) setState(() {});
  }
  @override
  void dispose() {
    for (final c in _bodyCtrls.values) { c.dispose(); }
    for (final c in _solutionCtrls.values) { c.dispose(); }
    for (final c in _answerCtrls.values) { c.dispose(); }
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
                        DropTarget(
                          onDragDone: (detail) {
                            if (detail.files.isEmpty) return;
                            final xf = detail.files.first; final path = xf.path; if (path != null && path.isNotEmpty) {
                              setState(() => _bodyCtrls[grade]!.text = path);
                            }
                          },
                          child: _LinkActionButtons(controller: _bodyCtrls[grade]!, onNameSuggestion: (name){}, label: '본문', grade: grade, kindKey: 'body'),
                        ),
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
                        DropTarget(
                          onDragDone: (detail) {
                            if (detail.files.isEmpty) return;
                            final xf = detail.files.first; final path = xf.path; if (path != null && path.isNotEmpty) {
                              setState(() => _solutionCtrls[grade]!.text = path);
                            }
                          },
                          child: _LinkActionButtons(controller: _solutionCtrls[grade]!, onNameSuggestion: (name){}, label: '해설', grade: grade, kindKey: 'sol'),
                        ),
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
                        DropTarget(
                          onDragDone: (detail) {
                            if (detail.files.isEmpty) return;
                            final xf = detail.files.first; final path = xf.path; if (path != null && path.isNotEmpty) {
                              setState(() => _answerCtrls[grade]!.text = path);
                            }
                          },
                          child: _LinkActionButtons(controller: _answerCtrls[grade]!, onNameSuggestion: (name){}, label: '정답', grade: grade, kindKey: 'ans'),
                        ),
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
              final body = _bodyCtrls[g]!.text.trim();
              final ans = _answerCtrls[g]!.text.trim();
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
    // New snap logic: compute X/Y independently, exclude currently moved group items
    const double gap = 8.0;
    const double threshold = 10.0;

    double currentWidth;
    double currentHeight;
    final folderMatch = widget.folders.where((x) => x.id == id).toList();
    if (folderMatch.isNotEmpty) {
      currentWidth = folderMatch.first.size.width;
      currentHeight = folderMatch.first.size.height;
    } else {
      final fileMatch = widget.files.where((x) => x.id == id).toList();
      if (fileMatch.isNotEmpty) {
        currentWidth = fileMatch.first.size.width;
        currentHeight = fileMatch.first.size.height;
      } else {
        currentWidth = 200;
        currentHeight = 60;
      }
    }

    final excludedIds = <String>{id};
    // Exclude selected group items (so anchor doesn't snap to its group)
    for (final key in _groupStartPositions.keys) {
      if (key.startsWith('folder:')) {
        excludedIds.add(key.substring('folder:'.length));
      } else if (key.startsWith('file:')) {
        excludedIds.add(key.substring('file:'.length));
      }
    }

    final xCandidates = <double>[];
    final yCandidates = <double>[];

    for (final f in widget.folders) {
      if (excludedIds.contains(f.id)) continue;
      final r = Rect.fromLTWH(f.position.dx, f.position.dy, f.size.width, f.size.height);
      // X candidates
      xCandidates.addAll([
        r.left - currentWidth - gap, // left of target
        r.right + gap,               // right of target
        r.left,                      // align left edge
        r.right - currentWidth,      // align right edge
        r.center.dx - currentWidth / 2, // align center X
      ]);
      // Y candidates
      yCandidates.addAll([
        r.top - currentHeight - gap, // above target
        r.bottom + gap,              // below target
        r.top,                       // align top edge
        r.bottom - currentHeight,    // align bottom edge
        r.center.dy - currentHeight / 2, // align center Y
      ]);
    }
    for (final fi in widget.files) {
      if (excludedIds.contains(fi.id)) continue;
      final r = Rect.fromLTWH(fi.position.dx, fi.position.dy, fi.size.width, fi.size.height);
      xCandidates.addAll([
        r.left - currentWidth - gap,
        r.right + gap,
        r.left,
        r.right - currentWidth,
        r.center.dx - currentWidth / 2,
      ]);
      yCandidates.addAll([
        r.top - currentHeight - gap,
        r.bottom + gap,
        r.top,
        r.bottom - currentHeight,
        r.center.dy - currentHeight / 2,
      ]);
    }

    double? snappedX;
    double minDx = double.infinity;
    for (final cx in xCandidates) {
      final dx = (pos.dx - cx).abs();
      if (dx < minDx && dx <= threshold) {
        minDx = dx;
        snappedX = cx;
      }
    }

    double? snappedY;
    double minDy = double.infinity;
    for (final cy in yCandidates) {
      final dy = (pos.dy - cy).abs();
      if (dy < minDy && dy <= threshold) {
        minDy = dy;
        snappedY = cy;
      }
    }

    return Offset(snappedX ?? pos.dx, snappedY ?? pos.dy);
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
  // Snap guide lines while dragging
  double? _snapGuideX;
  double? _snapGuideY;
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
      // Compute snap guides (magnet lines)
      const double gap = 8.0;
      const double threshold = 10.0;
      String? movedId;
      if (_groupDragAnchorKey != null) {
        if (_groupDragAnchorKey!.startsWith('folder:')) {
          movedId = _groupDragAnchorKey!.substring('folder:'.length);
        } else if (_groupDragAnchorKey!.startsWith('file:')) {
          movedId = _groupDragAnchorKey!.substring('file:'.length);
        }
      }
      double currentWidth = 200, currentHeight = 60;
      if (movedId != null) {
        final fm = widget.folders.where((x) => x.id == movedId).toList();
        if (fm.isNotEmpty) {
          currentWidth = fm.first.size.width;
          currentHeight = fm.first.size.height;
        } else {
          final fim = widget.files.where((x) => x.id == movedId).toList();
          if (fim.isNotEmpty) {
            currentWidth = fim.first.size.width;
            currentHeight = fim.first.size.height;
          }
        }
      }
      final excludedIds = <String>{if (movedId != null) movedId};
      for (final key in _groupStartPositions.keys) {
        if (key.startsWith('folder:')) excludedIds.add(key.substring('folder:'.length));
        if (key.startsWith('file:')) excludedIds.add(key.substring('file:'.length));
      }
      final xCandidates = <double>[];
      final yCandidates = <double>[];
      for (final f in widget.folders) {
        if (excludedIds.contains(f.id)) continue;
        final r = Rect.fromLTWH(f.position.dx, f.position.dy, f.size.width, f.size.height);
        xCandidates.addAll([r.left - currentWidth - gap, r.right + gap, r.left, r.right - currentWidth, r.center.dx - currentWidth / 2]);
        yCandidates.addAll([r.top - currentHeight - gap, r.bottom + gap, r.top, r.bottom - currentHeight, r.center.dy - currentHeight / 2]);
      }
      for (final fi in widget.files) {
        if (excludedIds.contains(fi.id)) continue;
        final r = Rect.fromLTWH(fi.position.dx, fi.position.dy, fi.size.width, fi.size.height);
        xCandidates.addAll([r.left - currentWidth - gap, r.right + gap, r.left, r.right - currentWidth, r.center.dx - currentWidth / 2]);
        yCandidates.addAll([r.top - currentHeight - gap, r.bottom + gap, r.top, r.bottom - currentHeight, r.center.dy - currentHeight / 2]);
      }
      double? gx; double? gy;
      double minDx = double.infinity; double minDy = double.infinity;
      for (final cx in xCandidates) {
        final dx = (newAnchorPos.dx - cx).abs();
        if (dx < minDx && dx <= threshold) { minDx = dx; gx = cx; }
      }
      for (final cy in yCandidates) {
        final dy = (newAnchorPos.dy - cy).abs();
        if (dy < minDy && dy <= threshold) { minDy = dy; gy = cy; }
      }
      _snapGuideX = gx;
      _snapGuideY = gy;
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
      _snapGuideX = null;
      _snapGuideY = null;
    });
  }

  bool _groupWouldOverlap(Offset delta) {
    // Build set of group ids
    final groupFolderIds = <String>{};
    final groupFileIds = <String>{};
    for (final key in _groupStartPositions.keys) {
      if (key.startsWith('folder:')) groupFolderIds.add(key.substring('folder:'.length));
      if (key.startsWith('file:')) groupFileIds.add(key.substring('file:'.length));
    }
    // Precompute rectangles for non-group items
    final otherRects = <Rect>[];
    for (final f in widget.folders) {
      if (groupFolderIds.contains(f.id)) continue;
      otherRects.add(Rect.fromLTWH(f.position.dx, f.position.dy, f.size.width, f.size.height));
    }
    for (final fi in widget.files) {
      if (groupFileIds.contains(fi.id)) continue;
      otherRects.add(Rect.fromLTWH(fi.position.dx, fi.position.dy, fi.size.width, fi.size.height));
    }
    // Check each group item candidate against others
    for (final entry in _groupStartPositions.entries) {
      final key = entry.key;
      final start = entry.value;
      final p = start + delta;
      Rect candidate;
      if (key.startsWith('folder:')) {
        final id = key.substring('folder:'.length);
        final f = widget.folders.firstWhere((e) => e.id == id, orElse: () => _ResourceFolder(id: id, name: '', color: null, description: '', position: start, size: const Size(200,120), shape: 'rect'));
        candidate = Rect.fromLTWH(p.dx, p.dy, f.size.width, f.size.height);
      } else {
        final id = key.substring('file:'.length);
        final fi = widget.files.firstWhere((e) => e.id == id, orElse: () => _ResourceFile(id: id, name: '', color: null, position: start, size: const Size(200,60)));
        candidate = Rect.fromLTWH(p.dx, p.dy, fi.size.width, fi.size.height);
      }
      for (final r in otherRects) {
        if (candidate.overlaps(r)) return true;
      }
    }
    return false;
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
                      var delta = snapped - startAnchor;
                      // Prevent overlap after snapping by reducing delta if needed
                      int guard = 0;
                      while (_groupWouldOverlap(delta) && guard < 20) {
                        delta *= 0.8; // back off
                        guard++;
                      }
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
                      var delta = snapped - startAnchor;
                      int guard = 0;
                      while (_groupWouldOverlap(delta) && guard < 20) {
                        delta *= 0.8;
                        guard++;
                      }
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
      color: (folder.color != null) ? folder.color!.withOpacity(0.18) : const Color(0xFF1F1F1F),
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
  final String? parentId;
  final int? orderIndex;
  _ResourceFolder({required this.id, required this.name, required this.color, required this.description, required this.position, required this.size, required this.shape, this.parentId, this.orderIndex});

  _ResourceFolder copyWith({String? id, String? name, Color? color, String? description, Offset? position, Size? size, String? shape, String? parentId, int? orderIndex}) {
    return _ResourceFolder(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      description: description ?? this.description,
      position: position ?? this.position,
      size: size ?? this.size,
      shape: shape ?? this.shape,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color != null ? {'r': color!.red, 'g': color!.green, 'b': color!.blue, 'a': color!.alpha} : null,
    'description': description,
    'position': {'x': position.dx, 'y': position.dy},
    'size': {'w': size.width, 'h': size.height},
    'parent_id': parentId,
    'order_index': orderIndex,
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
      parentId: json['parent_id'] as String?,
      orderIndex: (json['order_index'] as num?)?.toInt(),
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
              controller: _desc,
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
  final int? orderIndex;
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
    this.orderIndex,
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
    int? orderIndex,
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
      orderIndex: orderIndex ?? this.orderIndex,
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

class _GridFileCard extends StatelessWidget {
  final _ResourceFile file;
  const _GridFileCard({required this.file});

  @override
  Widget build(BuildContext context) {
    // 고정형 카드 스타일: 일관된 크기/패딩, 드래그/리사이즈 없음
    // ignore: avoid_print
    print('[GridFileCard] build id=' + file.id + ' size=' + file.size.toString());
    final resState = context.findAncestorStateOfType<_ResourcesScreenState>();
    final grades = resState?._grades ?? const <String>[];
    final selectedIndex = resState?._selectedGradeIndex ?? -1;
    final currentGrade = (selectedIndex >= 0 && selectedIndex < grades.length) ? grades[selectedIndex] : null;
    final hasForCurrent = currentGrade != null && (file.linksByGrade['$currentGrade#body']?.trim().isNotEmpty ?? false);
    final bg = hasForCurrent ? (file.color ?? const Color(0xFF2B2B2B)) : const Color(0xFF2B2B2B).withOpacity(0.22);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            // ignore: avoid_print
            print('[GridFileCard] tap id=' + file.id);
            if (currentGrade == null) return;
            final key = '${currentGrade}#body';
            final link = file.linksByGrade[key]?.trim() ?? '';
            if (link.isEmpty) return;
            try {
              if (link.startsWith('http://') || link.startsWith('https://')) {
                final uri = Uri.parse(link);
                await launchUrl(uri, mode: LaunchMode.platformDefault);
              } else {
                await OpenFilex.open(link);
              }
            } catch (_) {}
          },
          splashColor: Colors.white.withOpacity(0.06),
          highlightColor: Colors.white.withOpacity(0.03),
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.05), width: 0.8),
              boxShadow: [
                if (hasForCurrent) ...[
                  BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 18, offset: const Offset(0, 12)),
                  BoxShadow(color: Colors.white.withOpacity(0.03), blurRadius: 2, offset: const Offset(0, 1)),
                ],
              ],
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
            child: LayoutBuilder(
              builder: (context, box) {
                // ignore: avoid_print
                print('[GridFileCard:layout] id=' + file.id + ' box=' + box.maxWidth.toStringAsFixed(1) + 'x' + box.maxHeight.toStringAsFixed(1) + ' model=' + file.size.toString());
                return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (file.iconImagePath != null && file.iconImagePath!.isNotEmpty)
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(7),
                          image: DecorationImage(image: FileImage(File(file.iconImagePath!)), fit: BoxFit.cover),
                        ),
                      )
                    else
                      Icon(file.icon ?? Icons.insert_drive_file, color: hasForCurrent ? (file.textColor ?? Colors.white70) : Colors.white24, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: file.textColor ?? (hasForCurrent ? Colors.white : Colors.white38.withOpacity(0.6)), fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                      ),
                    ),
                    if (currentGrade != null) ...[
                      const SizedBox(width: 8),
                      _MiniPill(text: currentGrade, fontSize: 12, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5)),
                    ],
                    const SizedBox(width: 12),
                    // 즐겨찾기 토글 (아이콘: 북마크)
                    InkWell(
                      onTap: () async {
                        final isFav = (context.findAncestorStateOfType<_ResourcesScreenState>()?._favoriteFileIds.contains(file.id)) ?? false;
                        final state = context.findAncestorStateOfType<_ResourcesScreenState>();
                        if (state != null) {
                          if (isFav) {
                            state._favoriteFileIds.remove(file.id);
                            await DataManager.instance.removeResourceFavorite(file.id);
                          } else {
                            state._favoriteFileIds.add(file.id);
                            await DataManager.instance.addResourceFavorite(file.id);
                          }
                          state.setState(() {});
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6.0),
                        child: Icon(
                          Icons.bookmark,
                          size: 20,
                          color: (context.findAncestorStateOfType<_ResourcesScreenState>()?._favoriteFileIds.contains(file.id) ?? false)
                              ? Colors.amber
                              : Colors.white38,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if ((file.description ?? '').isNotEmpty)
                  Text(file.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 13.5)),
                const Spacer(),
                Row(
                  children: [
                    // 새 가로 버튼 UI
                    _SmallLinkButtonPill(file: file, kind: 'ans', currentGrade: currentGrade),
                    const SizedBox(width: 8),
                    _SmallLinkButtonPill(file: file, kind: 'sol', currentGrade: currentGrade),
                    const SizedBox(width: 10),
                    _BodyExtBadge(file: file, currentGrade: currentGrade),
                    const Spacer(),
                    _MoreMenuButton(file: file),
                  ],
                ),
              ],
            );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  final String text;
  final double fontSize;
  final EdgeInsetsGeometry? padding;
  const _MiniPill({required this.text, this.fontSize = 11, this.padding});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: TextStyle(color: Colors.white70, fontSize: fontSize, fontWeight: FontWeight.w700)),
    );
  }
}

class _SmallLinkButton extends StatelessWidget {
  final _ResourceFile file;
  final String kind; // 'ans' | 'sol'
  final String? currentGrade;
  const _SmallLinkButton({required this.file, required this.kind, required this.currentGrade});
  @override
  Widget build(BuildContext context) {
    final key = currentGrade != null ? '${currentGrade}#${kind}' : null;
    final link = key != null ? (file.linksByGrade[key]?.trim() ?? '') : '';
    final enabled = link.isNotEmpty;
    final icon = kind == 'ans' ? Icons.check_circle : Icons.menu_book;
    return Tooltip(
      message: kind == 'ans' ? '정답' : '해설',
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
        child: Icon(icon, size: 18, color: enabled ? Colors.white70 : Colors.white30),
      ),
    );
  }
}

class _SmallLinkButtonPill extends StatelessWidget {
  final _ResourceFile file;
  final String kind; // 'ans' | 'sol'
  final String? currentGrade;
  const _SmallLinkButtonPill({required this.file, required this.kind, required this.currentGrade});
  @override
  Widget build(BuildContext context) {
    final key = currentGrade != null ? '${currentGrade}#${kind}' : null;
    final link = key != null ? (file.linksByGrade[key]?.trim() ?? '') : '';
    final enabled = link.isNotEmpty;
    final isAns = kind == 'ans';
    // 확장자 계산 (호버 시에만 보여줌)
    String? ext;
    if (link.endsWith('.pdf')) ext = 'PDF';
    else if (link.endsWith('.hwp')) ext = 'HWP';
    return Tooltip(
      message: ext ?? (isAns ? '정답' : '해설'),
      child: InkWell(
        onTap: !enabled ? null : () async {
          if (link.startsWith('http://') || link.startsWith('https://')) {
            final uri = Uri.parse(link);
            await launchUrl(uri, mode: LaunchMode.platformDefault);
          } else {
            await OpenFilex.open(link);
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: enabled ? const Color(0xFF3A3F44) : const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(8),
            // 윤곽선 제거
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(isAns ? '정답' : '해설', style: TextStyle(color: enabled ? Colors.white70 : Colors.white38, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

class _BodyExtBadge extends StatelessWidget {
  final _ResourceFile file;
  final String? currentGrade;
  const _BodyExtBadge({required this.file, required this.currentGrade});
  @override
  Widget build(BuildContext context) {
    final key = currentGrade != null ? '${currentGrade}#body' : null;
    final link = key != null ? (file.linksByGrade[key]?.trim() ?? '') : '';
    if (link.isEmpty) return const SizedBox();
    String? ext;
    if (link.endsWith('.pdf')) ext = 'PDF';
    else if (link.endsWith('.hwp')) ext = 'HWP';
    else ext = null;
    if (ext == null) return const SizedBox();
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(8),
        // 윤곽선 제거
      ),
      alignment: Alignment.center,
      child: Text(ext!, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
    );
  }
}

class _MoreMenuButton extends StatelessWidget {
  final _ResourceFile file;
  const _MoreMenuButton({required this.file});
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '메뉴',
      position: PopupMenuPosition.under,
      offset: const Offset(8, -6),
      icon: Icon(Icons.more_horiz, size: 18, color: Colors.white.withOpacity(0.6)),
      itemBuilder: (ctx) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'edit',
          child: Row(children: const [Icon(Icons.edit, size: 16, color: Colors.white70), SizedBox(width: 8), Text('수정', style: TextStyle(color: Colors.white))]),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(children: const [Icon(Icons.delete, size: 16, color: Colors.white70), SizedBox(width: 8), Text('삭제', style: TextStyle(color: Colors.white))]),
        ),
      ],
      color: const Color(0xFF2A2A2A),
      surfaceTintColor: Colors.transparent,
      onSelected: (value) async {
        if (value == 'edit') {
          final metaRes = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (ctx) => _FileMetaDialog(initial: file),
          );
          if (metaRes != null && metaRes['file'] is _ResourceFile) {
            var edited = metaRes['file'] as _ResourceFile;
            // 링크 수정 다이얼로그로 이어짐 (기존 링크 불러와서 초기값으로)
            Map<String, String> initialLinks = {};
            try {
              initialLinks = await DataManager.instance.loadResourceFileLinks(file.id);
            } catch (_) {}
            final linksRes = await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (ctx) => _FileLinksDialog(meta: edited, initialLinks: initialLinks),
            );
            Map<String, String>? newLinks;
            if (linksRes != null && linksRes['links'] is Map<String, String>) {
              newLinks = Map<String, String>.from(linksRes['links'] as Map);
            }

            // 상태 업데이트
            final resourcesState = context.findAncestorStateOfType<_ResourcesScreenState>();
            if (resourcesState != null) {
              final idx = resourcesState._files.indexWhere((e) => e.id == file.id);
              if (idx != -1) {
                if (newLinks != null) {
                  edited = edited.copyWith(linksByGrade: newLinks);
                }
                resourcesState.setState(() {
                  resourcesState._files[idx] = edited;
                });
              }
            }
            // 메타 저장 (이름/색상/텍스트색상/아이콘/이미지/설명) 반영
            try {
              await DataManager.instance.saveResourceFile({
                'id': edited.id,
                'name': edited.name,
                'description': edited.description,
                if (edited.color != null) 'color': edited.color!.value,
                // 위치/사이즈/부모 등의 변경은 별도 흐름에서 저장됨
              });
            } catch (_) {}
            // 링크 저장
            if (newLinks != null) {
              try { await DataManager.instance.saveResourceFileLinks(edited.id, newLinks); } catch (_) {}
            }
          }
        } else if (value == 'delete') {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1F1F1F),
              title: const Text('삭제', style: TextStyle(color: Colors.white)),
              content: const Text('이 파일을 삭제할까요?', style: TextStyle(color: Colors.white70)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소', style: TextStyle(color: Colors.white70))),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('삭제')),
              ],
            ),
          );
          if (ok == true) {
            // 화면 상단의 상태를 찾아 삭제 요청을 위임
            final resourcesState = context.findAncestorStateOfType<_ResourcesScreenState>();
            if (resourcesState != null) {
              final idx = resourcesState._files.indexWhere((e) => e.id == file.id);
              if (idx != -1) {
                resourcesState.setState(() {
                  resourcesState._files.removeAt(idx);
                });
                await DataManager.instance.deleteResourceFile(file.id);
              }
            }
          }
        }
      },
    );
  }
}

class _FileCreateDialog extends StatefulWidget {
  const _FileCreateDialog();
  @override
  State<_FileCreateDialog> createState() => _FileCreateDialogState();
}

class _FileMetaDialog extends StatefulWidget {
  final _ResourceFile initial;
  const _FileMetaDialog({required this.initial});
  @override
  State<_FileMetaDialog> createState() => _FileMetaDialogState();
}

class _FileMetaDialogState extends State<_FileMetaDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  Color? _selectedColor;
  IconData? _selectedIcon;
  String? _iconImagePath;
  Color? _selectedTextColor;
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
    Color(0xFF212A31), // UltraDark c1
    Color(0xFF1E252E), // UltraDark c2
    Color(0xFF1B2029), // UltraDark c3
    Color(0xFF181B24), // UltraDark c4
    Color(0xFF15181F), // UltraDark c5
  ];
  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial.name);
    _descController = TextEditingController(text: widget.initial.description ?? '');
    _selectedColor = widget.initial.color;
    _selectedIcon = widget.initial.icon ?? Icons.insert_drive_file;
    _iconImagePath = widget.initial.iconImagePath;
    _selectedTextColor = widget.initial.textColor;
  }
  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('파일 정보 수정', style: TextStyle(color: Colors.white)),
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
              children: _gradeIconPack.map((ico) => _IconChoice(iconData: ico)).toList(),
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
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          onPressed: () {
            Navigator.pop(context, {
              'file': widget.initial.copyWith(
                name: _nameController.text.trim(),
                description: _descController.text.trim(),
                color: _selectedColor,
                icon: _selectedIcon,
                iconImagePath: _iconImagePath,
                textColor: _selectedTextColor,
              ),
            });
          },
          child: const Text('다음'),
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
    final state = context.findAncestorStateOfType<_FileMetaDialogState>();
    final isSelected = state?._selectedIcon == iconData;
    return InkWell(
      onTap: () => state?.setState(() {
        state._selectedIcon = iconData;
        // 아이콘을 선택하면 이미지 사용을 비활성화하여 카드가 아이콘을 표시하도록 함
        state._iconImagePath = null;
      }),
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
      onTap: () => state?.setState(() {
        state._selectedIcon = iconData;
        // 아이콘을 선택하면 이미지 사용을 비활성화하여 카드가 아이콘을 표시하도록 함
        state._iconImagePath = null;
      }),
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
    Color(0xFF212A31), // UltraDark c1
    Color(0xFF1E252E), // UltraDark c2
    Color(0xFF1B2029), // UltraDark c3
    Color(0xFF181B24), // UltraDark c4
    Color(0xFF15181F), // UltraDark c5
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
        size: const Size(230, 80),
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
    // ignore: avoid_print
    print('[Canvas] _DraggableFileCard used for id=' + widget.file.id + ' resizeMode=' + widget.resizeMode.toString());
    final effectivePos = _tempPosition ?? widget.file.position;
    final effectiveSize = _tempSize ?? widget.file.size;
    return Positioned(
      left: effectivePos.dx,
      top: effectivePos.dy,
      child: GestureDetector(
        onDoubleTap: () async {
          final current = widget.currentGrade;
          if (current == null) return;
          final key = '${current}#body';
          final link = widget.file.linksByGrade[key]?.trim() ?? '';
          if (link.isEmpty) return;
          try {
            if (link.startsWith('http://') || link.startsWith('https://')) {
              final uri = Uri.parse(link);
              await launchUrl(uri, mode: LaunchMode.platformDefault);
            } else {
              await OpenFilex.open(link);
            }
          } catch (_) {}
        },
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
    final bg = hasForCurrent ? (file.color ?? const Color(0xFF2D2D2D)) : const Color(0xFF2D2D2D).withOpacity(0.22);
    final primary = primaryGrade;
    // ignore: avoid_print
    print('[FileCard] build id=' + file.id + ' size=' + file.size.toString());
    return Container(
      width: file.size.width,
      height: file.size.height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
         border: Border.all(color: const Color(0xFF1F1F1F), width: 1.2),
        boxShadow: hasForCurrent ? [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))] : [],
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
             Icon(file.icon ?? Icons.insert_drive_file, color: hasForCurrent ? Colors.white70 : Colors.white24, size: 22),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: file.textColor ?? (hasForCurrent ? Colors.white : Colors.white38.withOpacity(0.6)), fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 8),
          // 하단 액션: 정답/해설만 노출, 본문 버튼 제거
          _FileLinkButton(file: file, kind: 'ans'),
          const SizedBox(width: 6),
          _FileLinkButton(file: file, kind: 'sol'),
          const SizedBox(width: 6),
          _BookmarkButton(file: file),
          const SizedBox(width: 4),
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
    final label = kind == 'ans' ? '정답' : '해설';
    final icon = kind == 'ans' ? Icons.check_circle : Icons.menu_book;
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

class _PdfEditorDialogState extends State<_PdfEditorDialog> with SingleTickerProviderStateMixin {
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
  late TabController _tabController;
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() { if (mounted) setState(() {}); });
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
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isPreviewTab = _tabController.index == 1;
    final double dialogWidth = isPreviewTab ? 1520 : 760;
    final double dialogHeight = isPreviewTab ? 1248 : 624;
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('PDF 편집기', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
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
                child: TabBar(controller: _tabController, tabs: const [
                  Tab(text: '범위 입력'),
                  Tab(text: '미리보기 선택'),
                ]),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(controller: _tabController, children: <Widget>[
                  // Tab 1: 텍스트 범위 입력
                  SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('입력 PDF', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(child: TextField(controller: _inputPath, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))))),
                        const SizedBox(width: 8),
                        SizedBox(height: 36, width: 1.2 * 200, child: OutlinedButton.icon(onPressed: () async {
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
                      const SizedBox(height: 10),
                      // 드래그 박스: 여기에 PDF 파일을 드래그하여 선택
                      DropTarget(
                        onDragDone: (detail) {
                          if (detail.files.isEmpty) return;
                          final xf = detail.files.first;
                          final path = xf.path;
                          if (path != null && path.toLowerCase().endsWith('.pdf')) {
                            setState(() {
                              _inputPath.text = path;
                              final base = p.basenameWithoutExtension(path);
                              final suffix = widget.kindKey == 'body' ? '본문' : widget.kindKey == 'ans' ? '정답' : '해설';
                              _fileName.text = '${base}_${widget.grade}_$suffix.pdf';
                            });
                          }
                        },
                        child: Container(
                          width: double.infinity,
                          height: 120,
                          alignment: Alignment.center,
                          margin: const EdgeInsets.only(top: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            border: Border.all(color: Colors.white24, width: 1.2, style: BorderStyle.solid),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.picture_as_pdf, color: Colors.white60, size: 28),
                              SizedBox(height: 8),
                              Text('여기로 PDF를 드래그하여 선택', style: TextStyle(color: Colors.white60)),
                            ],
                          ),
                        ),
                      ),
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
                                  _previewDoc = doc;
                                  _currentPreviewPage = _currentPreviewPage.clamp(1, pageCount).toInt();
                                  return Row(
                                    children: [
                                      SizedBox(
                                        width: 160,
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
                                            return Column(
                                              crossAxisAlignment: CrossAxisAlignment.stretch,
                                              children: [
                                                Padding(
                                                  padding: const EdgeInsets.only(bottom: 6),
                                                  child: Row(
                                                    children: [
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                        decoration: BoxDecoration(
                                                          color: const Color(0xFF2A2A2A),
                                                          borderRadius: BorderRadius.circular(999),
                                                          border: Border.all(color: Colors.white24),
                                                        ),
                                                        child: Text('$showPage / $pageCount', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Listener(
                                                    onPointerSignal: (signal) {
                                                      if (signal is PointerScrollEvent) {
                                                        final dy = signal.scrollDelta.dy;
                                                        if (dy != 0) {
                                                          setState(() {
                                                            _currentPreviewPage = (_currentPreviewPage + (dy > 0 ? 1 : -1)).clamp(1, pageCount);
                                                          });
                                                        }
                                                      }
                                                    },
                                                    child: GestureDetector(
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
                                                            child: PdfPageView(key: ValueKey('preview_'+showPage.toString()), document: doc, pageNumber: showPage),
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
                                                    ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                      ),
                                      const SizedBox(width: 8),
                                      SizedBox(
                                        width: 160,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.stretch,
                                          children: [
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
                                                label: const Text('페이지 추가'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24), shape: const StadiumBorder()),
                        ),
                      ),
                      const SizedBox(height: 8),
                                            Expanded(
                      child: ReorderableListView(
                        buildDefaultDragHandles: false,
                        proxyDecorator: (child, index, animation) {
                          return Material(
                            type: MaterialType.transparency,
                            child: _SelectedPageThumb(
                              document: _previewDoc,
                              pageNumber: _selectedPages[index],
                              height: 120,
                              outerRadius: 12,
                              innerRadius: 8,
                              showNumberBadge: true,
                            ),
                          );
                        },
                        children: [
                          for (int i = 0; i < _selectedPages.length; i++)
                                                    ReorderableDelayedDragStartListener(
                                                      key: ValueKey('sel_v_$i'),
                                                      index: i,
                                                      child: Container(
                                                        margin: const EdgeInsets.only(bottom: 8),
                                                        padding: const EdgeInsets.all(8),
                                                        decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(12)),
                                                        child: Row(
                                                          children: [
                                                            Expanded(
                                                              child: SizedBox(
                                                                height: 120,
                                                                child: _SelectedPageThumb(
                                                                  document: _previewDoc,
                                                                  pageNumber: _selectedPages[i],
                                                                  height: 120,
                                                                  outerRadius: 8,
                                                                  innerRadius: 8,
                                                                  showNumberBadge: true,
                                                                  numberText: '${_selectedPages[i]}',
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(width: 6),
                                                            InkWell(onTap: () => setState(() { _selectedPages.removeAt(i); }), child: const Icon(Icons.close, size: 16, color: Colors.white54)),
                                                          ],
                                                        ),
                                                      ),
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
                                      ),
                                    ],
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        Text('선택: ${_selectedPages.join(', ')}', style: const TextStyle(color: Colors.white60)),
                        const SizedBox(width: 12),
                        if (_previewDoc != null) Text('페이지: $_currentPreviewPage/${_previewDoc!.pages.length}', style: const TextStyle(color: Colors.white54)),
                      ]),
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
            var outPath = saveLoc.path;
            if (!outPath.toLowerCase().endsWith('.pdf')) {
              outPath = outPath + '.pdf';
            }
            // 2) Syncfusion로 inPath에서 선택 페이지를 "선택 순서대로" 새 문서에 복사 저장 (벡터 보존)
            final inputBytes = await File(inPath).readAsBytes();
            final src = sf.PdfDocument(inputBytes: inputBytes);
            final selected = _selectedPages.isNotEmpty ? List<int>.from(_selectedPages) : _parseRanges(ranges, src.pages.count);

            final dst = sf.PdfDocument();
            // 원본 기본 페이지 설정을 가능하면 유지
            try {
              dst.pageSettings.size = src.pageSettings.size;
              dst.pageSettings.orientation = src.pageSettings.orientation;
              dst.pageSettings.margins.all = 0;
            } catch (_) {}

            for (final pageNum in selected) {
              if (pageNum < 1 || pageNum > src.pages.count) continue;
              final srcPage = src.pages[pageNum - 1];
              final tmpl = srcPage.createTemplate();
              final newPage = dst.pages.add();
              // 템플릿을 좌상단(0,0)에 그려 원본 페이지 내용을 복사
              try {
                newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
              } catch (_) {
                // draw 실패 시에도 페이지는 유지
              }
            }

            final outBytes = await dst.save();
            src.dispose();
            dst.dispose();
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

 

class _SelectedPageThumb extends StatelessWidget {
  final PdfDocument? document;
  final int pageNumber;
  final double? width;
  final double? height;
  final double outerRadius;
  final double innerRadius;
  final bool showNumberBadge;
  final String? numberText;
  const _SelectedPageThumb({super.key, required this.document, required this.pageNumber, this.width, this.height, this.outerRadius = 12, this.innerRadius = 8, this.showNumberBadge = false, this.numberText});
  @override
  Widget build(BuildContext context) {
    final pdf = document;
    final child = pdf == null
        ? const SizedBox()
        : ClipRRect(
            borderRadius: BorderRadius.circular(innerRadius),
            clipBehavior: Clip.hardEdge,
            child: Stack(
              children: [
                Positioned.fill(child: PdfPageView(document: pdf, pageNumber: pageNumber)),
                if (showNumberBadge)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(numberText ?? '$pageNumber', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                  ),
              ],
            ),
          );
    final a4 = AspectRatio(aspectRatio: 1 / 1.4, child: child);
    final sized = width != null
        ? SizedBox(width: width, child: a4)
        : height != null
            ? SizedBox(height: height, child: a4)
            : a4;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(outerRadius),
        border: Border.all(color: Colors.white24),
      ),
      child: sized,
    );
  }
}

