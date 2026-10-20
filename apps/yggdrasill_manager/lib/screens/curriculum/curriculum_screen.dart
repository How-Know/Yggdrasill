import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'widgets/category_tree.dart';
import 'widgets/concept_book_dialog.dart';
import 'widgets/concept_chat_panel.dart';
import 'widgets/concept_criteria_pane.dart';
import 'widgets/concept_draft_list_dialog.dart';
import 'widgets/concept_draft_review_dialog.dart';
import 'widgets/concept_anchor_dialogs.dart';
import 'widgets/concept_input_dialog.dart';
import 'widgets/concept_library_pane.dart';
import 'widgets/concept_relation_section.dart';
import 'widgets/concept_workspace.dart';
import '../../services/concept_draft_service.dart';
import '../../services/concept_library_controller.dart';
import '../../services/concept_service.dart';
import '../../services/concept_topic.dart';
import '../../services/think/think_concept_chat_controller.dart';
import '../../widgets/app_navigation_bar.dart';
import '../../services/concept_category_service.dart';
import '../think/think_style.dart';

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
  final ConceptDraftService _draftSvc = ConceptDraftService();

  /// 트리에 붙여 보는 유형·주제 묶음(트리를 다시 읽을 때 함께 읽는다).
  ConceptTreeMeta _treeMeta = ConceptTreeMeta.empty;

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

  bool _chatOpen = ConceptChatController.instance.panelOpen;

  /// 선택·저장 안 한 입력은 여기에 남는다(메뉴를 옮겨 화면이 다시 만들어져도).
  final ConceptLibraryController _lib = ConceptLibraryController.instance;

  @override
  void initState() {
    super.initState();
    _lib.ensureStarted();
    if (!_lib.loaded && !_lib.loading) unawaited(_lib.loadCriteria());
    _loadCurriculums();
    _reloadCategoryTree();
  }

  // 교육과정 목록 불러오기
  Future<void> _loadCurriculums() async {
    try {
      final data = await _supabase.from('curriculum').select().order('created_at');

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
          child: CircularProgressIndicator(color: kNavAccent),
        ),
      );
    }

    return Container(
      color: const Color(0xFF1F1F1F),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '개념',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '정리 기준(왼쪽)과 개념 라이브러리(오른쪽)를 함께 보며 정리합니다.',
              style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 16),
            ),
            const SizedBox(height: 20),
            _buildToolbarCard(),
            const SizedBox(height: 16),
            Expanded(
              child: ConceptWorkspace(
                controller: _lib,
                criteriaDetail: CriteriaDetailPane(
                  controller: _lib,
                  onOpenConcept: _openConceptById,
                  onChatPicked: _openChatForPick,
                ),
                criteriaSummary: CriteriaSummaryPane(controller: _lib),
                libraryDetail: _buildLibraryDetail(),
                librarySummary: LibrarySummaryPane(controller: _lib, onOpenConcept: _openConceptById),
                chat: _chatOpen ? ConceptChatPanel(onClose: () => _setChatOpen(false)) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _setChatOpen(bool open) {
    ConceptChatController.instance.panelOpen = open;
    setState(() => _chatOpen = open);
  }

  /// 대화 참고로 골랐을 때 대화 패널이 닫혀 있으면 연다(좁은 화면에서도 보던 칸은 그대로 둔다).
  void _openChatForPick() {
    if (!_chatOpen) _setChatOpen(true);
  }

  Future<void> _openDraftList() async {
    final id = await showConceptDraftListDialog(context, onConfirmed: () => unawaited(_reloadCategoryTree()));
    if (id != null && mounted) await _openDraft(id);
  }

  /// 초안 검토. 확정하면 라이브러리를 다시 읽는다.
  Future<void> _openDraft(String id) async {
    final confirmed = await showConceptDraftReviewDialog(context, draftId: id);
    if (!confirmed || !mounted) return;
    await _reloadCategoryTree();
    if (!mounted) return;
    showThinkSnack(context, '초안을 확정해 라이브러리에 넣었습니다. 다른 영역에 넣은 개념은 그 영역 탭에서 보입니다.');
  }

  Future<void> _openConceptBook() async {
    await showConceptBookDialog(
      context,
      library: _lib,
      onDraftReady: (id) => unawaited(_openDraft(id)),
      onDraftsConfirmed: () => unawaited(_reloadCategoryTree()),
      onAttached: (pages, problems) {
        if (!_chatOpen) _setChatOpen(true);
        _lib.showNarrowChat();
        if (!mounted) return;
        showThinkSnack(
          context,
          problems.isEmpty
              ? '쪽 이미지 $pages장을 Think 대화 입력창에 붙였습니다. 질문을 적고 보내세요.'
              : '쪽 이미지 $pages장을 붙였습니다. 붙이지 못한 것: ${problems.join(' / ')}',
          error: problems.isNotEmpty,
        );
      },
    );
  }

  Iterable<ConceptItem> _allConcepts(List<CategoryNode> nodes) sync* {
    for (final n in nodes) {
      yield* n.concepts;
      yield* _allConcepts(n.children);
    }
  }

  ConceptItem? _findConcept(String id) {
    for (final c in _allConcepts(_categoryTree)) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 요약·연결에서 개념을 눌렀을 때. 지금 도메인 트리에 없으면 서버에서 읽는다.
  Future<void> _openConceptById(String id) async {
    final local = _findConcept(id);
    if (local != null) {
      _lib.openConcept(local);
      return;
    }
    try {
      final fresh = await _conceptSvc.fetchConcept(id);
      if (!mounted) return;
      if (fresh == null) {
        _showError('개념을 찾지 못했습니다(지워졌거나 볼 수 없음).');
        return;
      }
      _lib.openConcept(fresh);
    } catch (e) {
      _showError('개념을 열지 못했습니다: $e');
    }
  }

  /// 저장된 개념만 고른다. 보낼 때마다 서버가 이 개념의 저장본을 다시 읽는다.
  void _pickForChat(ConceptItem concept) {
    final problem = ConceptChatController.instance.pickConcept(concept);
    if (problem != null) {
      _showError(problem);
      return;
    }
    if (!_chatOpen) _setChatOpen(true);
    final name = concept.name.isEmpty ? (concept.kind == ConceptKind.definition ? '정의' : '정리') : concept.name;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"$name"을(를) Think 대화의 참고 개념으로 골랐습니다.')),
    );
  }

  Widget _buildToolbarCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF18181A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 980;
          final filters = Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildLabeledControl('교육과정', _buildCurriculumDropdown()),
              _buildLabeledControl('도메인', _buildDomainTabs()),
            ],
          );
          final actions = _buildToolbarActions();
          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                filters,
                const SizedBox(height: 12),
                actions,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: filters),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _buildLibraryDetail() {
    final chat = ConceptChatController.instance;
    return LibraryDetailPane(
      badges: [_buildDomainBadge(_selectedDomain)],
      actions: [
        if (_treeBusy)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kNavAccent),
                ),
                SizedBox(width: 6),
                Text('동기화 중', style: TextStyle(color: Colors.white54, fontSize: 14)),
              ],
            ),
          ),
        TextButton.icon(
          key: const ValueKey('same-name-review-open'),
          onPressed: () => unawaited(showSameNameReviewDialog(
            context,
            store: _lib.relations,
            onOpenConcept: (id) {
              Navigator.of(context).pop();
              unawaited(_openConceptById(id));
            },
          )),
          icon: const Icon(Icons.join_inner, size: 16),
          label: const Text('같은 이름 검토'),
          style: TextButton.styleFrom(foregroundColor: kThinkAccent, visualDensity: VisualDensity.compact),
        ),
      ],
      tree: ListenableBuilder(
        listenable: Listenable.merge(
            [chat.pickedConcept, _lib.openedConceptId, _lib.statements.countsTick, _lib.relations.openTick]),
        builder: (context, _) => CategoryTree(
          roots: _categoryTree,
          meta: _treeMeta,
          forceExpandNodeId: _forceExpandNodeId,
          rootParentId: _domainRootId,
          onSelect: (node) {
            _lastSelectedCategoryId = node.id;
          },
          onAddChild: _onAddChildFolder,
          onRename: _onRenameFolder,
          onDelete: _onDeleteFolder,
          onReorderFolder: _onReorderFolder,
          onProposeAnchors: _onProposeAnchors,
          onTapConcept: _onTapConcept,
          onEditConcept: _onEditConcept,
          onDeleteConcept: _onDeleteConcept,
          onMoveConcept: _onMoveConcept,
          onMoveFolder: _onMoveFolder,
          selectedConceptId: chat.pickedConcept.value,
          openedConceptId: _lib.openedConceptId.value,
          statementCountOf: _lib.statements.statementCountOf,
          reviewOpenOf: _lib.relations.reviewOpen,
          onPickConcept: (_, concept) => _pickForChat(concept),
        ),
      ),
      detail: ConceptDetailView(
        controller: _lib,
        onEdit: (concept) => _onEditConcept(null, concept),
        onPickForChat: _pickForChat,
        topicOf: _topicOf,
        onChooseAnchor: _onChooseAnchor,
        onOpenConceptId: (id) => unawaited(_openConceptById(id)),
      ),
    );
  }

  Widget _buildLabeledControl(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFF8F8F8F), fontSize: 14),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _buildCurriculumDropdown() {
    if (_curriculums.isEmpty) {
      return Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF3A3A3A)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.school_outlined, color: Colors.white54, size: 18),
            SizedBox(width: 8),
            Text(
              '교육과정 없음',
              style: TextStyle(color: Colors.white54, fontSize: 15),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 44,
      constraints: const BoxConstraints(minWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedCurriculumId,
          dropdownColor: const Color(0xFF2A2A2A),
          style: const TextStyle(color: Colors.white, fontSize: 16),
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
    );
  }

  Widget _buildDomainTabs() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDomainChip('대수'),
          _buildDomainChip('해석'),
          _buildDomainChip('확률통계'),
          _buildDomainChip('기하'),
        ],
      ),
    );
  }

  Widget _buildToolbarActions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _openConceptBook,
          icon: const Icon(Icons.menu_book_outlined, size: 18),
          label: const Text('개념책 불러오기', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          style: OutlinedButton.styleFrom(
            foregroundColor: kNavAccent,
            side: BorderSide(color: kNavAccent.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _openDraftList,
          icon: const Icon(Icons.fact_check_outlined, size: 18),
          label: const Text('개념 초안', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          style: OutlinedButton.styleFrom(
            foregroundColor: kNavAccent,
            side: BorderSide(color: kNavAccent.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: () {
            final open = !_chatOpen;
            _setChatOpen(open);
            if (open) _lib.showNarrowChat();
          },
          icon: Icon(_chatOpen ? Icons.forum : Icons.forum_outlined, size: 18),
          label: Text(_chatOpen ? 'Think 대화 숨기기' : 'Think 대화',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          style: OutlinedButton.styleFrom(
            foregroundColor: kNavAccent,
            side: BorderSide(color: kNavAccent.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _onAddRootFolder,
          icon: const Icon(Icons.create_new_folder, size: 18),
          label: const Text('새 폴더', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          style: OutlinedButton.styleFrom(
            foregroundColor: kNavAccent,
            side: BorderSide(color: kNavAccent.withOpacity(0.5)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        FilledButton.icon(
          onPressed: _onAddConcept,
          icon: const Icon(Icons.add_circle_outline, size: 18),
          label: const Text('개념 추가', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          style: FilledButton.styleFrom(
            backgroundColor: kNavAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Widget _buildDomainBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? kNavAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? kNavAccent : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 16,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
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
      if (!mounted) return;
      setState(() {
        _domainRootId = tree.rootId;
        _categoryTree = tree.nodes;
      });
      final concepts = _allConcepts(tree.nodes);
      _lib.syncSelectedConcept(concepts);
      await _reloadTreeMeta(concepts);
    } catch (e) {
      _showError('카테고리 로드 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  Future<void> _reloadTreeMeta([Iterable<ConceptItem>? concepts]) async {
    final ids = [
      for (final c in concepts ?? _allConcepts(_categoryTree))
        if (_isUuid(c.id)) c.id
    ];
    try {
      final meta = await _draftSvc.treeMeta(ids);
      if (mounted) setState(() => _treeMeta = meta);
    } catch (e) {
      _showError('개념 유형·묶음을 읽지 못했습니다: $e');
    }
  }

  CategoryNode? _folderOfConcept(String conceptId) {
    CategoryNode? found;
    void visit(List<CategoryNode> list) {
      for (final n in list) {
        if (found != null) return;
        if (n.concepts.any((c) => c.id == conceptId)) {
          found = n;
          return;
        }
        visit(n.children);
      }
    }

    visit(_categoryTree);
    return found;
  }

  ConceptTopicInfo? _topicOf(ConceptItem concept) {
    final folder = _folderOfConcept(concept.id);
    if (folder == null) return null;
    final anchorId = _treeMeta.anchorOf[concept.id];
    final anchor = anchorId == null ? null : folder.concepts.where((c) => c.id == anchorId).firstOrNull;
    final dependents = [
      for (final c in folder.concepts)
        if (_treeMeta.anchorOf[c.id] == concept.id) c
    ];
    return ConceptTopicInfo(
      anchor: anchor,
      dependents: dependents,
      typeOf: _treeMeta.typeOf,
      unavailable: _treeMeta.anchorsUnavailable,
      canChoose: folder.concepts.length > 1,
    );
  }

  Future<void> _onChooseAnchor(ConceptItem concept) async {
    final folder = _folderOfConcept(concept.id);
    if (folder == null) return;
    final picked = await showConceptAnchorPicker(context, concept: concept, folder: folder, meta: _treeMeta);
    if (picked == null || !mounted) return;
    try {
      await _draftSvc.setAnchors({concept.id: picked.anchorId}, origin: 'manual');
      if (!mounted) return;
      setState(() => _treeMeta = _treeMeta.withAnchors({concept.id: picked.anchorId}));
      showThinkSnack(context, picked.anchorId == null ? '묶음에서 뺐습니다.' : '묶음을 바꿨습니다.');
    } on ConceptDraftException catch (e) {
      if (mounted) showThinkSnack(context, e.message, error: true);
      await _reloadTreeMeta();
    }
  }

  Future<void> _onProposeAnchors(CategoryNode folder) async {
    final applied = await showConceptAnchorProposalDialog(context, folder: folder, meta: _treeMeta, service: _draftSvc);
    if (applied == true) await _reloadTreeMeta();
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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('취소', style: TextStyle(color: Colors.white70))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, value.trim()),
              child: const Text('확인', style: TextStyle(color: kNavAccent))),
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소', style: TextStyle(color: Colors.white70))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제', style: TextStyle(color: Colors.redAccent))),
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
        return CategoryNode(
            id: n.id, name: newName, children: n.children, isShortcut: n.isShortcut, concepts: n.concepts);
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

  /// 트리에서 누르면 그 자리(라이브러리 쪽)에서 연다. 초점은 바꾸지 않는다.
  void _onTapConcept(CategoryNode parent, ConceptItem concept) {
    _lib.selectConcept(concept);
  }

  Future<void> _onEditConcept(CategoryNode? parent, ConceptItem concept) async {
    String? impact;
    if (_lib.isSavedConcept(concept)) {
      final id = concept.id;
      await Future.wait([
        if (_lib.sourcesOf(id) == null) _lib.loadSources(id),
        if (_lib.linkedCriteriaOf(id) == null) _lib.loadConceptLinks(id),
        if (!_lib.statements.loaded(id)) _lib.statements.load(id),
        if (!_lib.relations.loaded(id)) _lib.relations.load(id),
      ]).timeout(const Duration(seconds: 8), onTimeout: () => const []);
      if (!mounted) return;
      impact = conceptEditImpact(_lib, concept);
    }
    final edited = await showConceptInputDialog(context, initial: concept, impact: impact);
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
      ConceptChatController.instance.conceptSaved(concept.id, name: edited.name, kind: edited.kind);
      await _reloadCategoryTree();
      if (_lib.selectedConcept?.id == concept.id && _findConcept(concept.id) == null) {
        final fresh = await _conceptSvc.fetchConcept(concept.id);
        if (fresh != null) _lib.syncSelectedConcept([fresh]);
      }
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
      ConceptChatController.instance.conceptDeleted(concept.id);
      _lib.conceptRemoved(concept.id);
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
  }) async {
    if (fromParentId == toParentId) return;
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
      await _conceptSvc.moveConcept(conceptId: conceptId, toCategoryId: toParentId);
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

  Future<void> _onReorderFolder({
    required CategoryNode node,
    required String? parentId,
    required int direction,
  }) async {
    if (_treeBusy) return;
    if (parentId == null) return;
    final siblings = _childrenByParentId(parentId);
    if (siblings.length <= 1) return;
    final currentIndex = siblings.indexWhere((n) => n.id == node.id);
    if (currentIndex < 0) return;
    final targetIndex = currentIndex + direction;
    if (targetIndex < 0 || targetIndex >= siblings.length) return;
    final orderedIds = siblings.map((n) => n.id).toList();
    final moved = orderedIds.removeAt(currentIndex);
    orderedIds.insert(targetIndex, moved);
    try {
      setState(() => _treeBusy = true);
      await _cc.reorderCategories(parentId: parentId, orderedCategoryIds: orderedIds);
      await _reloadCategoryTree();
    } catch (e) {
      _showError('폴더 순서 변경 실패: $e');
    } finally {
      if (mounted) setState(() => _treeBusy = false);
    }
  }

  List<CategoryNode> _childrenByParentId(String parentId) {
    if (_domainRootId != null && parentId == _domainRootId) {
      return _categoryTree;
    }
    final parent = _findNodeById(_categoryTree, parentId);
    return parent?.children ?? const [];
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
