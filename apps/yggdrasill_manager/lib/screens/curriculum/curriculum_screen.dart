import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'widgets/category_tree.dart';
import 'widgets/concept_input_dialog.dart';
import '../../services/concept_service.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import '../../services/concept_category_service.dart';

class CurriculumScreen extends StatefulWidget {
  const CurriculumScreen({super.key});

  @override
  State<CurriculumScreen> createState() => _CurriculumScreenState();
}

class _Tuple2 {
  final String item1;
  final ConceptItem item2;
  _Tuple2(this.item1, this.item2);
}

class _CurriculumScreenState extends State<CurriculumScreen> {
  final _supabase = Supabase.instance.client;
  final ConceptCategoryService _cc = ConceptCategoryService(Supabase.instance.client);
  final ConceptService _conceptSvc = ConceptService(Supabase.instance.client);
  
  // 학년 선택 상태
  String? _selectedCurriculumId;
  String? _selectedGradeId;
  String _schoolLevel = '중'; // '중' or '고'
  // 데이터 목록
  List<Map<String, dynamic>> _curriculums = [];
  List<Map<String, dynamic>> _grades = [];
  List<CategoryNode> _categoryTree = [];
  String? _domainRootId;
  bool _treeBusy = false;
  String? _lastSelectedCategoryId;
  String? _forceExpandNodeId;
  
  // 도메인 탭 상태
  String _selectedDomain = '대수'; // 대수, 해석, 확률통계, 기하
  
  
  
  bool _isLoading = true;
  
  
  @override
  void initState() {
    super.initState();
    _loadCurriculums();
    _reloadCategoryTree();
  }
  
  // 교육과정 목록 불러오기
  Future<void> _loadCurriculums() async {
    try {
      final data = await _supabase
          .from('curriculum')
          .select()
          .order('created_at');
      
      setState(() {
        _curriculums = List<Map<String, dynamic>>.from(data);
        if (_curriculums.isNotEmpty) {
          _selectedCurriculumId = _curriculums[0]['id'];
          _loadGrades();
        }
      });
    } catch (e) {
      _showError('교육과정 로드 실패: $e');
    }
  }
  
  // 학년 목록 불러오기
  Future<void> _loadGrades() async {
    if (_selectedCurriculumId == null) return;
    
    try {
      final data = await _supabase
          .from('grade')
          .select()
          .eq('curriculum_id', _selectedCurriculumId!)
          .eq('school_level', _schoolLevel)
          .order('display_order');
      
      setState(() {
        _grades = List<Map<String, dynamic>>.from(data);
        _selectedGradeId = _grades.isNotEmpty ? _grades[0]['id'] as String : null;
        _isLoading = false;
      });
    } catch (e) {
      _showError('학년 로드 실패: $e');
    }
  }
  
  
  
  
  
  
  
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
  
  
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: const Color(0xFF1F1F1F),
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xFF4A9EFF)),
        ),
      );
    }
    
    return Container(
      color: const Color(0xFF1F1F1F),
      child: Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 상단: 교육과정 드롭다운 + 도메인 탭
            _buildHeaderRow(),
            const SizedBox(height: 16),
            // 아래: Concept Library 트리
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF3A3A3A)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _selectedDomain,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _onAddConcept,
                          icon: const Icon(Icons.add_circle_outline, color: Color(0xFF4A9EFF), size: 18),
                          label: const Text('개념 추가', style: TextStyle(color: Color(0xFF4A9EFF))),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _onAddRootFolder,
                          icon: const Icon(Icons.create_new_folder, color: Color(0xFF4A9EFF), size: 18),
                          label: const Text('새 폴더', style: TextStyle(color: Color(0xFF4A9EFF))),
                        )
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: CategoryTree(
                        roots: _categoryTree,
                        forceExpandNodeId: _forceExpandNodeId,
                        onSelect: (node) {
                          _lastSelectedCategoryId = node.id;
                        },
                        onAddChild: _onAddChildFolder,
                        onRename: _onRenameFolder,
                        onDelete: _onDeleteFolder,
                        onTapConcept: _onTapConcept,
                        onEditConcept: _onEditConcept,
                        onDeleteConcept: _onDeleteConcept,
                        onMoveConcept: _onMoveConcept,
                        onMoveFolder: _onMoveFolder,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  // 상단: 교육과정 드롭다운 + 도메인 탭
  Widget _buildHeaderRow() {
    return Row(
      children: [
        // 교육과정 드롭다운
        if (_curriculums.isNotEmpty)
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF3A3A3A)),
            ),
            child: DropdownButton<String>(
              value: _selectedCurriculumId,
              dropdownColor: const Color(0xFF2A2A2A),
              underline: const SizedBox(),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              icon: const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 20),
              items: _curriculums
                  .map((curriculum) => DropdownMenuItem(
                        value: curriculum['id'] as String,
                        child: Text(curriculum['name'] as String),
                      ))
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _selectedCurriculumId = value;
                  _loadGrades();
                });
              },
            ),
          ),
        
        const SizedBox(width: 12),
        
        // 도메인 탭 (대수, 해석, 확률통계, 기하)
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF3A3A3A)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              _buildDomainChip('대수'),
              _buildDomainChip('해석'),
              _buildDomainChip('확률통계'),
              _buildDomainChip('기하'),
            ],
          ),
        ),
      ],
    );
  }
  
  // 도메인 선택 칩
  Widget _buildDomainChip(String label) {
    final isSelected = _selectedDomain == label;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedDomain = label;
        });
        _reloadCategoryTree();
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF4A9EFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 15,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // ===== 서버 연동: 트리 로드 및 폴더 조작 =====
  Future<void> _reloadCategoryTree() async {
    setState(() => _treeBusy = true);
    try {
      final tree = await _cc.fetchDomainTree(_selectedDomain);
      setState(() {
        _domainRootId = tree.rootId;
        _categoryTree = tree.nodes;
      });
    } catch (e) {
      _showError('카테고리 로드 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  Future<void> _onAddRootFolder() async {
    final name = await _promptText(title: '새 폴더 이름');
    if (name == null || name.trim().isEmpty) return;
    try {
      setState(() => _treeBusy = true);
      // 보장: 도메인 루트가 존재
      if (_domainRootId == null) {
        await _reloadCategoryTree();
      }
      await _cc.createCategory(name: name.trim(), parentId: _domainRootId);
      await _reloadCategoryTree();
    } catch (e) {
      _showError('폴더 생성 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  Future<void> _onAddChildFolder(CategoryNode parent) async {
    final name = await _promptText(title: '하위 폴더 이름');
    if (name == null || name.trim().isEmpty) return;
    try {
      setState(() => _treeBusy = true);
      await _cc.createCategory(name: name.trim(), parentId: parent.id);
      await _reloadCategoryTree();
    } catch (e) {
      _showError('하위 폴더 생성 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  Future<void> _onRenameFolder(CategoryNode node) async {
    final name = await _promptText(title: '이름 바꾸기', initial: node.name);
    if (name == null || name.trim().isEmpty || name.trim() == node.name) return;
    try {
      setState(() => _treeBusy = true);
      await _cc.renameCategory(id: node.id, name: name.trim());
      await _reloadCategoryTree();
    } catch (e) {
      _showError('이름 변경 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  Future<void> _onDeleteFolder(CategoryNode node) async {
    final ok = await _confirmDelete('폴더를 삭제하시겠습니까?\\n하위 항목도 함께 삭제됩니다.');
    if (ok != true) return;
    try {
      setState(() => _treeBusy = true);
      await _cc.deleteCategory(id: node.id);
      await _reloadCategoryTree();
    } catch (e) {
      _showError('삭제 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  Future<String?> _promptText({required String title, String? initial}) async {
    String value = initial ?? '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: TextField(
          autofocus: true,
          controller: TextEditingController(text: value)
            ..selection = TextSelection(baseOffset: 0, extentOffset: value.length),
          onChanged: (v) => value = v,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소', style: TextStyle(color: Colors.white70))),
          TextButton(onPressed: () => Navigator.pop(ctx, value.trim()), child: const Text('확인', style: TextStyle(color: Color(0xFF4A9EFF)))),
        ],
      ),
    );
  }

  Future<bool?> _confirmDelete(String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('삭제 확인', style: TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소', style: TextStyle(color: Colors.white70))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
  }

  List<CategoryNode> _addChildRecursive(List<CategoryNode> list, String parentId, CategoryNode child) {
    return list.map((n) {
      if (n.id == parentId) {
        final children = List<CategoryNode>.from(n.children)..add(child);
        return CategoryNode(id: n.id, name: n.name, children: children, isShortcut: n.isShortcut, concepts: n.concepts);
      }
      if (n.children.isEmpty) return n;
      return CategoryNode(
        id: n.id,
        name: n.name,
        children: _addChildRecursive(n.children, parentId, child),
        isShortcut: n.isShortcut,
        concepts: n.concepts,
      );
    }).toList();
  }

  List<CategoryNode> _renameRecursive(List<CategoryNode> list, String id, String newName) {
    return list.map((n) {
      if (n.id == id) {
        return CategoryNode(id: n.id, name: newName, children: n.children, isShortcut: n.isShortcut, concepts: n.concepts);
      }
      if (n.children.isEmpty) return n;
      return CategoryNode(
        id: n.id,
        name: n.name,
        children: _renameRecursive(n.children, id, newName),
        isShortcut: n.isShortcut,
        concepts: n.concepts,
      );
    }).toList();
  }

  List<CategoryNode> _removeRecursive(List<CategoryNode> list, String id) {
    final out = <CategoryNode>[];
    for (final n in list) {
      if (n.id == id) continue;
      if (n.children.isEmpty) {
        out.add(n);
      } else {
        out.add(CategoryNode(
          id: n.id,
          name: n.name,
          children: _removeRecursive(n.children, id),
          isShortcut: n.isShortcut,
          concepts: n.concepts,
        ));
      }
    }
    return out;
  }

  List<CategoryNode> _addConceptRecursive(List<CategoryNode> list, String categoryId, ConceptItem concept) {
    return list.map((n) {
      if (n.id == categoryId) {
        final concepts = List<ConceptItem>.from(n.concepts)..add(concept);
        return CategoryNode(id: n.id, name: n.name, children: n.children, isShortcut: n.isShortcut, concepts: concepts);
      }
      if (n.children.isEmpty) return n;
      return CategoryNode(
        id: n.id,
        name: n.name,
        children: _addConceptRecursive(n.children, categoryId, concept),
        isShortcut: n.isShortcut,
        concepts: n.concepts,
      );
    }).toList();
  }

  Future<void> _onAddConcept() async {
    if (_lastSelectedCategoryId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('먼저 폴더를 선택하세요.')),
      );
      return;
    }
    final result = await showConceptInputDialog(context);
    if (result == null) return;
    try {
      setState(() => _treeBusy = true);
      await _conceptSvc.createConcept(
        mainCategoryId: _lastSelectedCategoryId!,
        kind: result.kind,
        subType: result.subType,
        name: result.name,
        content: result.content,
        level: result.level,
      );
      _forceExpandNodeId = _lastSelectedCategoryId;
      await _reloadCategoryTree();
    } catch (e) {
      _showError('개념 추가 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  void _onTapConcept(CategoryNode parent, ConceptItem concept) {
    _showConceptDetail(concept);
  }

  Future<void> _onEditConcept(CategoryNode parent, ConceptItem concept) async {
    final edited = await showConceptInputDialog(context, initial: concept);
    if (edited == null) return;
    try {
      setState(() => _treeBusy = true);
      await _conceptSvc.updateConcept(
        id: concept.id,
        kind: edited.kind,
        subType: edited.subType,
        name: edited.name,
        content: edited.content,
        level: edited.level,
      );
      await _reloadCategoryTree();
    } catch (e) {
      _showError('개념 수정 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  Future<void> _onDeleteConcept(CategoryNode parent, ConceptItem concept) async {
    final ok = await _confirmDelete('이 개념을 삭제하시겠습니까?');
    if (ok != true) return;
    try {
      setState(() => _treeBusy = true);
      await _conceptSvc.deleteConcept(concept.id);
      await _reloadCategoryTree();
    } catch (e) {
      _showError('개념 삭제 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  Future<void> _onMoveConcept({
    required String conceptId,
    required String fromParentId,
    required String toParentId,
    int? toIndex,
  }) async {
    try {
      setState(() => _treeBusy = true);
      // 임시(비-UUID) 개념은 서버에 없으므로, 대상 폴더로 먼저 저장 후 이동 처리로 간주
      if (!_isUuid(conceptId)) {
        final local = _findLocalConcept(conceptId, fromParentId);
        if (local != null) {
          await _conceptSvc.createConcept(
            mainCategoryId: toParentId,
            kind: local.item2.kind,
            subType: local.item2.subType,
            name: local.item2.name,
            content: local.item2.content,
            level: local.item2.level ?? 1,
          );
          // 로컬 임시 칩 제거
          _removeLocalConcept(conceptId, fromParentId);
          await _reloadCategoryTree();
          _forceExpandNodeId = toParentId;
          return;
        }
      }
      // If moving across parents
      if (fromParentId != toParentId) {
        await _conceptSvc.moveConcept(conceptId: conceptId, toCategoryId: toParentId);
      }
      // Reorder within destination parent if index provided
      if (toIndex != null) {
        final destNode = _findNodeById(_categoryTree, toParentId);
        if (destNode != null) {
          final ids = destNode.concepts.map((c) => c.id).toList();
          // If concept moved from same parent, remove old spot
          ids.remove(conceptId);
          // Insert at index
          final safeIndex = toIndex.clamp(0, ids.length);
          ids.insert(safeIndex, conceptId);
          await _conceptSvc.reorderConcepts(categoryId: toParentId, orderedConceptIds: ids);
        }
      }
      await _reloadCategoryTree();
      _forceExpandNodeId = toParentId;
    } catch (e) {
      _showError('개념 이동 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  bool _isUuid(String s) {
    final r = RegExp(r'^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$');
    return r.hasMatch(s);
  }

  // returns (parentId, concept)
  _Tuple2? _findLocalConcept(String cid, String parentId) {
    ConceptItem? found;
    void dfs(List<CategoryNode> list) {
      for (final n in list) {
        if (n.id == parentId) {
          for (final c in n.concepts) {
            if (c.id == cid) {
              found = c;
              return;
            }
          }
        }
        if (n.children.isNotEmpty) dfs(n.children);
        if (found != null) return;
      }
    }
    dfs(_categoryTree);
    if (found == null) return null;
    return _Tuple2(parentId, found!);
  }

  void _removeLocalConcept(String cid, String parentId) {
    List<CategoryNode> rec(List<CategoryNode> list) {
      return list.map((n) {
        if (n.id == parentId) {
          final next = List<ConceptItem>.from(n.concepts)..removeWhere((c) => c.id == cid);
          return CategoryNode(id: n.id, name: n.name, children: n.children, isShortcut: n.isShortcut, concepts: next);
        }
        if (n.children.isEmpty) return n;
        return CategoryNode(
          id: n.id,
          name: n.name,
          children: rec(n.children),
          isShortcut: n.isShortcut,
          concepts: n.concepts,
        );
      }).toList();
    }
    setState(() {
      _categoryTree = rec(_categoryTree);
    });
  }

  

  Future<void> _onMoveFolder({
    required String folderId,
    required String? newParentId,
    int? newIndex,
  }) async {
    try {
      setState(() => _treeBusy = true);
      // 새 부모로 이동만 지원 (정렬은 추후 확장)
      await _cc.moveCategory(id: folderId, newParentId: newParentId);
      await _reloadCategoryTree();
    } catch (e) {
      _showError('폴더 이동 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  CategoryNode? _findNodeById(List<CategoryNode> list, String id) {
    for (final n in list) {
      if (n.id == id) return n;
      if (n.children.isNotEmpty) {
        final f = _findNodeById(n.children, id);
        if (f != null) return f;
      }
    }
    return null;
  }

  void _showConceptDetail(ConceptItem c) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(c.name.isEmpty ? (c.kind == ConceptKind.definition ? '정의' : '정리') : c.name,
            style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: _renderConceptContent(c.content),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
        ],
      ),
    );
  }

  Widget _renderConceptContent(String text) {
    // 재사용: LaTeX 블록/인라인 렌더링
    const baseStyle = TextStyle(color: Color(0xFFB3B3B3), fontSize: 13);
    final blockRegex = RegExp(r'\$\$([\s\S]*?)\$\$', dotAll: true);
    final blocks = blockRegex.allMatches(text).toList();
    if (blocks.isEmpty) {
      return _renderInlineMath(text, baseStyle);
    }
    int lastIndex = 0;
    final children = <Widget>[];
    for (final m in blocks) {
      final before = text.substring(lastIndex, m.start);
      if (before.isNotEmpty) {
        children.add(_renderInlineMath(before, baseStyle));
      }
      final formula = m.group(1) ?? '';
      if (formula.trim().isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Math.tex(
                formula,
                mathStyle: MathStyle.display,
                textStyle: baseStyle.copyWith(color: Colors.white),
              ),
            ),
          ),
        );
      }
      lastIndex = m.end;
    }
    final tail = text.substring(lastIndex);
    if (tail.isNotEmpty) {
      children.add(_renderInlineMath(tail, baseStyle));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _renderInlineMath(String text, TextStyle baseStyle) {
    final inlineRegex = RegExp(r'\\\( (.*?) \\\)');
    final spans = <InlineSpan>[];
    int lastIndex = 0;
    for (final match in inlineRegex.allMatches(text)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(text: text.substring(lastIndex, match.start), style: baseStyle));
      }
      final formula = match.group(1) ?? '';
      if (formula.isNotEmpty) {
        spans.add(
          WidgetSpan(
            child: Math.tex(
              formula,
              textStyle: baseStyle.copyWith(color: Colors.white),
            ),
          ),
        );
      }
      lastIndex = match.end;
    }
    if (lastIndex < text.length) {
      spans.add(TextSpan(text: text.substring(lastIndex), style: baseStyle));
    }
    return RichText(text: TextSpan(children: spans));
  }

  // 임시 목업 카테고리 트리 데이터 (도메인별)
  List<CategoryNode> _mockCategoriesFor(String domain) {
    switch (domain) {
      case '대수':
        return [
          CategoryNode(id: 'alg-1', name: '수와 식', children: [
            CategoryNode(id: 'alg-1-1', name: '정수와 유리수'),
            CategoryNode(id: 'alg-1-2', name: '다항식', children: [
              CategoryNode(id: 'alg-1-2-1', name: '인수분해'),
              CategoryNode(id: 'alg-1-2-2', name: '항등식'),
            ]),
          ]),
          CategoryNode(id: 'alg-2', name: '방정식과 부등식', children: [
            CategoryNode(id: 'alg-2-1', name: '이차방정식'),
            CategoryNode(id: 'alg-2-2', name: '연립방정식'),
          ]),
          CategoryNode(id: 'alg-3', name: '수열', children: [
            CategoryNode(id: 'alg-3-1', name: '등차수열'),
            CategoryNode(id: 'alg-3-2', name: '등비수열'),
          ]),
        ];
      case '해석':
        return [
          CategoryNode(id: 'an-1', name: '미분', children: [
            CategoryNode(id: 'an-1-1', name: '도함수와 미분법'),
            CategoryNode(id: 'an-1-2', name: '극값/증가감소'),
          ]),
          CategoryNode(id: 'an-2', name: '적분', children: [
            CategoryNode(id: 'an-2-1', name: '부정적분'),
            CategoryNode(id: 'an-2-2', name: '정적분과 넓이'),
          ]),
        ];
      case '확률통계':
        return [
          CategoryNode(id: 'ps-1', name: '확률', children: [
            CategoryNode(id: 'ps-1-1', name: '조건부확률'),
            CategoryNode(id: 'ps-1-2', name: '확률분포'),
          ]),
          CategoryNode(id: 'ps-2', name: '통계', children: [
            CategoryNode(id: 'ps-2-1', name: '표본과 추정'),
          ]),
        ];
      case '기하':
      default:
        return [
          CategoryNode(id: 'geo-1', name: '평면기하', children: [
            CategoryNode(id: 'geo-1-1', name: '삼각형'),
            CategoryNode(id: 'geo-1-2', name: '사각형'),
            CategoryNode(id: 'geo-1-3', name: '원'),
          ]),
          CategoryNode(id: 'geo-2', name: '좌표기하', children: [
            CategoryNode(id: 'geo-2-1', name: '직선의 방정식'),
            CategoryNode(id: 'geo-2-2', name: '원/타원/쌍곡선'),
          ]),
        ];
    }
  }
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
}



