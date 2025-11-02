import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'widgets/section_list.dart';
import 'widgets/chapter_card.dart';

class CurriculumScreen extends StatefulWidget {
  const CurriculumScreen({super.key});

  @override
  State<CurriculumScreen> createState() => _CurriculumScreenState();
}

class _CurriculumScreenState extends State<CurriculumScreen> {
  final _supabase = Supabase.instance.client;
  
  // 학년 선택 상태
  String? _selectedCurriculumId;
  String? _selectedGradeId;
  String _schoolLevel = '중'; // '중' or '고'
  
  // 대단원별 확장 레벨: 0=닫힘, 1=소단원, 2=개념, 3=노트
  Map<String, int> _chapterExpandLevels = {};
  
  // 확장된 소단원 ID (개념 보기)
  String? _expandedSectionId;
  
  // 확장된 구분선 ID들 (노트 보기) - Set으로 여러 개 동시 확장 가능
  final Set<String> _expandedGroupIds = {};
  
  // 데이터 목록
  List<Map<String, dynamic>> _curriculums = [];
  List<Map<String, dynamic>> _grades = [];
  List<Map<String, dynamic>> _chapters = [];
  List<Map<String, dynamic>> _sections = [];
  List<Map<String, dynamic>> _conceptGroups = [];
  List<Map<String, dynamic>> _concepts = [];
  
  // 소단원 개수 캐시 (chapterId -> count)
  Map<String, int> _sectionCounts = {};
  
  // notes 필드 normalization: 다양한 형태(null, List<Map>, List<String> JSON, default wrapper 등)를
  // 일관된 List<Map{id,name,items:List<String>}> 형태로 변환
  List<Map<String, dynamic>> _normalizeNotes(dynamic notesData) {
    if (notesData == null) return <Map<String, dynamic>>[];
    if (notesData is! List || notesData.isEmpty) return <Map<String, dynamic>>[];

    final list = List<dynamic>.from(notesData);
    final first = list.first;

    // Case A: 이미 [{id,name,items:[...]}, ...] 형태
    if (first is Map) {
      return list.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        final rawItems = m['items'];
        List<String> items;
        if (rawItems is List) {
          // items 내부에 JSON 문자열이 있는 경우 파싱 시도 후, 실패하면 원본 문자열 유지
          items = rawItems.map((it) {
            if (it is String) {
              try {
                final parsed = jsonDecode(it);
                // 만약 잘못 저장된 group JSON 같은 경우 사람이 읽는 텍스트가 아니므로 무시
                // 파싱 성공했더라도 표시할 텍스트가 없으므로 원 문자열 반환
                return it;
              } catch (_) {
                return it;
              }
            }
            return it.toString();
          }).toList().cast<String>();
        } else {
          items = <String>[];
        }
        return {
          'id': m['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          'name': m['name']?.toString() ?? '',
          'items': items,
        };
      }).toList();
    }

    // Case B: ["{...}", "{...}"] 형태(과거 문자열 JSON 배열)
    if (first is String) {
      final decoded = <Map<String, dynamic>>[];
      bool allObjects = true;
      for (final s in list.cast<String>()) {
        try {
          final obj = jsonDecode(s);
          if (obj is Map && (obj.containsKey('id') || obj.containsKey('items') || obj.containsKey('name'))) {
            decoded.add({
              'id': obj['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
              'name': obj['name']?.toString() ?? '',
              'items': (obj['items'] is List)
                  ? List<String>.from((obj['items'] as List).map((e) => e.toString()))
                  : <String>[],
            });
          } else {
            allObjects = false;
            break;
          }
        } catch (_) {
          allObjects = false;
          break;
        }
      }
      if (allObjects) return decoded;

      // 문자열 일반 리스트였던 경우(default 그룹으로 감쌈)
      return [
        {
          'id': 'default',
          'name': '',
          'items': List<String>.from(list.map((e) => e.toString())),
        }
      ];
    }

    return <Map<String, dynamic>>[];
  }
  
  // 소단원 캐시 (chapterId -> sections)
  Map<String, List<Map<String, dynamic>>> _sectionsCache = {};
  
  // 개념 그룹 캐시 (sectionId -> groups)
  Map<String, List<Map<String, dynamic>>> _conceptGroupsCache = {};
  
  // 개념 캐시 (groupId -> concepts)
  Map<String, List<Map<String, dynamic>>> _conceptsCache = {};
  
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _loadCurriculums();
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
      // 캐시 초기화 (교육과정이나 학년이 변경됨)
      _sectionsCache.clear();
      _sectionCounts.clear();
      _chapterExpandLevels.clear();
      _sections = [];
      
      final data = await _supabase
          .from('grade')
          .select()
          .eq('curriculum_id', _selectedCurriculumId!)
          .eq('school_level', _schoolLevel)
          .order('display_order');
      
      setState(() {
        _grades = List<Map<String, dynamic>>.from(data);
        if (_grades.isNotEmpty) {
          _selectedGradeId = _grades[0]['id'];
          _loadChapters();
        } else {
          _chapters = [];
          _isLoading = false;
        }
      });
    } catch (e) {
      _showError('학년 로드 실패: $e');
    }
  }
  
  // 대단원 목록 불러오기
  Future<void> _loadChapters() async {
    if (_selectedGradeId == null) return;
    
    try {
      final data = await _supabase
          .from('chapter')
          .select()
          .eq('grade_id', _selectedGradeId!)
          .order('display_order', ascending: true); // 오름차순 명시
      
      setState(() {
        _chapters = List<Map<String, dynamic>>.from(data);
        _isLoading = false;
      });
      
      // 각 대단원의 소단원 개수 미리 로드
      await _loadAllSectionCounts();
    } catch (e) {
      _showError('대단원 로드 실패: $e');
      setState(() => _isLoading = false);
    }
  }
  
  // 모든 대단원의 소단원 개수 로드
  Future<void> _loadAllSectionCounts() async {
    try {
      for (var chapter in _chapters) {
        final chapterId = chapter['id'] as String;
        final countData = await _supabase
            .from('section')
            .select()
            .eq('chapter_id', chapterId);
        
        setState(() {
          _sectionCounts[chapterId] = countData.length;
        });
      }
    } catch (e) {
      // 개수 로드 실패는 무시 (치명적이지 않음)
    }
  }
  
  // 소단원 목록 불러오기 (특정 대단원)
  Future<void> _loadSections(String chapterId, {bool forceRefresh = false}) async {
    // 강제 새로고침이 아니고 캐시에 있으면 즉시 표시
    if (!forceRefresh && _sectionsCache.containsKey(chapterId)) {
      setState(() {
        _sections = _sectionsCache[chapterId]!;
      });
      return;
    }
    
    try {
      final data = await _supabase
          .from('section')
          .select()
          .eq('chapter_id', chapterId)
          .order('display_order', ascending: true); // 오름차순 명시
      
      final sections = List<Map<String, dynamic>>.from(data);
      
      setState(() {
        _sections = sections;
        _sectionsCache[chapterId] = sections; // 캐시에 저장
        _sectionCounts[chapterId] = sections.length; // 개수 업데이트
      });
    } catch (e) {
      _showError('소단원 로드 실패: $e');
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
      child: Row(
        children: [
          // 왼쪽 80%: 커리큘럼 영역
          Expanded(
            flex: 8,
            child: Container(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 학년 선택 UI (상단)
                  _buildGradeSelector(),
                  
                  const SizedBox(height: 32),
                  
                  // 대단원 카드 리스트 (왼쪽 정렬)
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _buildChapterList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
        ],
      ),
    );
  }
  
  // 학년 선택 UI (교육과정 + 중/고 토글 + 드롭다운)
  Widget _buildGradeSelector() {
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
        
        // 중/고 토글 버튼
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF3A3A3A)),
          ),
          child: Row(
            children: [
              _buildToggleButton('중'),
              _buildToggleButton('고'),
            ],
          ),
        ),
        
        const SizedBox(width: 12),
        
        // 학기/과목 드롭다운
        if (_grades.isNotEmpty)
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF3A3A3A)),
            ),
            child: DropdownButton<String>(
              value: _selectedGradeId,
              dropdownColor: const Color(0xFF2A2A2A),
              underline: const SizedBox(),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              icon: const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 20),
              items: _grades
                  .map((grade) => DropdownMenuItem(
                        value: grade['id'] as String,
                        child: Text(grade['name'] as String),
                      ))
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _selectedGradeId = value;
                  _loadChapters();
                });
              },
            ),
          ),
      ],
    );
  }
  
  // 중/고 토글 버튼
  Widget _buildToggleButton(String level) {
    final isSelected = _schoolLevel == level;
    return GestureDetector(
      onTap: () {
        setState(() {
          _schoolLevel = level;
          _chapterExpandLevels.clear(); // 확장 상태 초기화
          _loadGrades(); // 학년 목록 다시 로드
        });
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF4A9EFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          level,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 15,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
  
  // 대단원 카드 리스트 (가로 스크롤)
  Widget _buildChapterList() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center, // 카드들 세로 중앙 정렬
        children: [
          ..._chapters.map((chapter) => _buildChapterCard(chapter)),
          
          // 대단원 추가 버튼
          _buildAddChapterButton(),
        ],
      ),
    );
  }
  
  // 모든 소단원 ID를 담는 Set
  final Set<String> _allExpandedSections = {};
  
  // 확장 레벨 증가 (>, 다음 단계로)
  void _expandChapterMore(String chapterId) async {
    final currentLevel = _chapterExpandLevels[chapterId] ?? 0;
    if (currentLevel < 3) {
      // 레벨에 따라 필요한 데이터 로드 및 체크
      if (currentLevel == 0) {
        // 0 → 1: 소단원 로드
        await _loadSections(chapterId);
        
        // 소단원이 있으면 레벨 증가
        if (_sections.isNotEmpty) {
          setState(() {
            _chapterExpandLevels[chapterId] = 1;
          });
        }
      } else if (currentLevel == 1) {
        // 1 → 2: 모든 소단원 펼치고 각 소단원의 개념 그룹 로드
        if (_sections.isNotEmpty) {
          // 모든 소단원을 확장 상태로
          _allExpandedSections.clear();
          bool hasAnyConcepts = false;
          
          for (final section in _sections) {
            final sectionId = section['id'] as String;
            _allExpandedSections.add(sectionId);
            await _loadConceptGroups(sectionId);
            
            // 개념 그룹이 하나라도 있는지 확인
            final groups = _conceptGroupsCache[sectionId] ?? [];
            if (groups.isNotEmpty) {
              hasAnyConcepts = true;
            }
          }
          
          // 개념이 하나라도 있으면 레벨 증가
          if (hasAnyConcepts) {
            final firstSectionId = _sections.first['id'] as String;
            setState(() {
              _chapterExpandLevels[chapterId] = 2;
              _expandedSectionId = firstSectionId;
            });
          }
        }
      } else if (currentLevel == 2) {
        // 2 → 3: 모든 개념 그룹의 노트 자동 확장 (노트가 있는 것만)
        _expandedGroupIds.clear();
        bool hasAnyNotes = false;
        
        for (final section in _sections) {
          final sectionId = section['id'] as String;
          final groups = _conceptGroupsCache[sectionId] ?? [];
          for (final group in groups) {
            final groupId = group['id'] as String;
            final notes = group['notes'];
            
            // 노트가 있는 그룹만 확장
            if (notes != null && notes is List && notes.isNotEmpty) {
              _expandedGroupIds.add(groupId);
              hasAnyNotes = true;
            }
          }
        }
        
        // 노트가 하나라도 있으면 레벨 증가
        if (hasAnyNotes) {
          setState(() {
            _chapterExpandLevels[chapterId] = 3;
          });
        }
      }
    }
  }
  
  // 확장 레벨 감소 (<, 이전 단계로)
  void _expandChapterLess(String chapterId) {
    final currentLevel = _chapterExpandLevels[chapterId] ?? 0;
    if (currentLevel > 0) {
      setState(() {
        _chapterExpandLevels[chapterId] = currentLevel - 1;
        
        // 레벨에 따라 상태 초기화
        if (currentLevel == 1) {
          // 1 → 0: 소단원 닫기
          _sections = [];
          _allExpandedSections.clear();
        } else if (currentLevel == 2) {
          // 2 → 1: 모든 개념 닫기
          _expandedSectionId = null;
          _conceptGroups = [];
          _allExpandedSections.clear();
        } else if (currentLevel == 3) {
          // 3 → 2: 모든 노트 닫기
          _expandedGroupIds.clear();
        }
      });
    }
  }
  
  // 대단원 카드
  Widget _buildChapterCard(Map<String, dynamic> chapter) {
    final chapterId = chapter['id'] as String;
    final expandLevel = _chapterExpandLevels[chapterId] ?? 0;
    final isExpanded = expandLevel > 0;
    
    // 소단원 개수 계산 (캐시에서 가져오기)
    final sectionCount = _sectionCounts[chapterId] ?? 0;
    
    return Container(
      margin: const EdgeInsets.only(right: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center, // 중앙 정렬
        children: [
          // 대단원 카드
          ChapterCard(
            chapter: chapter,
            isExpanded: isExpanded,
            expandLevel: expandLevel,
            sectionCount: sectionCount,
            onTap: () {
              // 카드 클릭 시 레벨 1로 토글
              if (expandLevel == 0) {
                _expandChapterMore(chapterId);
              } else {
                setState(() {
                  _chapterExpandLevels[chapterId] = 0;
                  _sections = [];
                  _allExpandedSections.clear();
                  _expandedGroupIds.clear();
                });
              }
            },
            onDoubleTap: () => _showAddSectionDialog(chapterId),
            onSecondaryTap: () => _showChapterContextMenu(chapter),
            onExpandMore: () => _expandChapterMore(chapterId),
            onExpandLess: () => _expandChapterLess(chapterId),
          ),
          
          // 확장 시 소단원 트리뷰 공간 (오른쪽에 표시)
          if (expandLevel >= 1) ...[
            const SizedBox(width: 20),
            SectionList(
              chapterId: chapterId,
              sections: _sections,
              expandedSectionId: _expandedSectionId,
              allExpandedSections: expandLevel >= 2 ? _allExpandedSections : const {},
              showConcepts: expandLevel >= 1, // 레벨 1부터 개념 표시 가능
              conceptGroupsCache: _conceptGroupsCache,
              conceptsCache: _conceptsCache,
              expandedGroupIds: _expandedGroupIds, // 모든 레벨에서 노트 토글 가능
              onReorderSections: (oldIndex, newIndex) => _reorderSections(chapterId, oldIndex, newIndex),
              onTapSection: (sectionId) {
                setState(() {
                  if (_expandedSectionId == sectionId) {
                    _expandedSectionId = null;
                    _conceptGroups = [];
                  } else {
                    _expandedSectionId = sectionId;
                    _loadConceptGroups(sectionId);
                  }
                });
              },
              onAddConceptGroup: (sectionId) => _addConceptGroup(sectionId),
              onSectionContextMenu: (section, chapId) => _showSectionContextMenu(section, chapId),
              onAddConcept: (groupId) => _addConcept(groupId),
              onGroupContextMenu: (group, secId) => _showGroupContextMenu(group, secId),
              onReorderConcepts: (groupId, oldIndex, newIndex) => _reorderConcepts(groupId, oldIndex, newIndex),
              onConceptContextMenu: (concept, groupId) => _showConceptContextMenu(concept, groupId),
              onToggleNotes: (groupId) {
                setState(() {
                  if (_expandedGroupIds.contains(groupId)) {
                    _expandedGroupIds.remove(groupId);
                  } else {
                    _expandedGroupIds.add(groupId);
                  }
                });
              },
              onArrowPositionMeasured: null, // 더 이상 사용하지 않음
              onAddNoteGroup: (group) => _addNoteGroup(group),
              onAddNote: (group, noteGroup) => _addNoteToGroup(group, noteGroup),
              onDeleteNoteGroup: (group, idx) => _deleteNoteGroup(group, idx),
              onDeleteNote: (group, gi, ii) => _deleteNoteItem(group, gi, ii),
            ),
          ],
        ],
      ),
    );
  }
  
  // 소단원 추가 다이얼로그
  Future<void> _showAddSectionDialog(String chapterId) async {
    String inputText = '';
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('소단원 추가', style: TextStyle(color: Colors.white)),
            content: TextField(
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                hintText: '소단원 이름',
                hintStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white54),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF4A9EFF)),
                ),
              ),
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              onChanged: (value) {
                setDialogState(() {
                  inputText = value;
                });
              },
              onSubmitted: (value) async {
                if (value.trim().isNotEmpty) {
                  Navigator.pop(context);
                  await _addSection(chapterId, value.trim());
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () async {
                  if (inputText.trim().isNotEmpty) {
                    Navigator.pop(context);
                    await _addSection(chapterId, inputText.trim());
                  }
                },
                child: const Text('추가', style: TextStyle(color: Color(0xFF4A9EFF))),
              ),
            ],
          );
        },
      ),
    );
  }
  
  // 소단원 추가
  Future<void> _addSection(String chapterId, String name) async {
    try {
      // 현재 최대 순서 찾기
      int maxOrder = 0;
      if (_sections.isNotEmpty) {
        for (var section in _sections) {
          final order = section['display_order'];
          if (order != null && order is int && order > maxOrder) {
            maxOrder = order;
          }
        }
      }
      
      // 소단원 추가
      final result = await _supabase.from('section').insert({
        'chapter_id': chapterId,
        'name': name,
        'display_order': maxOrder + 1,
      }).select();
      
      if (result.isEmpty) {
        _showError('소단원 추가 실패: 응답이 비어있습니다');
        return;
      }
      
      // 강제 새로고침
      await _loadSections(chapterId, forceRefresh: true);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('소단원 "$name" 추가됨')),
        );
      }
    } catch (e) {
      _showError('소단원 추가 실패: $e');
    }
  }
  
  // 소단원 삭제
  Future<void> _deleteSection(String sectionId) async {
    try {
      await _supabase.from('section').delete().eq('id', sectionId);
      
      // 확장된 대단원이 있으면 새로고침
      for (final chapterId in _chapterExpandLevels.keys) {
        if (_chapterExpandLevels[chapterId]! >= 1) {
          _sectionsCache.remove(chapterId);
          await _loadSections(chapterId);
        }
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('소단원 삭제됨')),
        );
      }
    } catch (e) {
      _showError('소단원 삭제 실패: $e');
    }
  }
  
  // 소단원 우클릭 메뉴
  void _showSectionContextMenu(Map<String, dynamic> section, String chapterId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(
          section['name'] as String,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: Color(0xFF4A9EFF)),
              title: const Text('편집', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showEditSectionDialog(section, chapterId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('삭제', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteSection(section, chapterId);
              },
            ),
          ],
        ),
      ),
    );
  }
  
  // 소단원 편집 다이얼로그
  Future<void> _showEditSectionDialog(Map<String, dynamic> section, String chapterId) async {
    String inputText = section['name'] as String;
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('소단원 편집', style: TextStyle(color: Colors.white)),
            content: TextField(
              autofocus: true,
              controller: TextEditingController(text: inputText)
                ..selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: inputText.length,
                ),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                hintText: '소단원 이름',
                hintStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white54),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF4A9EFF)),
                ),
              ),
              onChanged: (value) {
                setDialogState(() {
                  inputText = value;
                });
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () async {
                  if (inputText.trim().isNotEmpty) {
                    Navigator.pop(context);
                    await _updateSection(section['id'] as String, inputText.trim(), chapterId);
                  }
                },
                child: const Text('저장', style: TextStyle(color: Color(0xFF4A9EFF))),
              ),
            ],
          );
        },
      ),
    );
  }
  
  // 소단원 업데이트
  Future<void> _updateSection(String sectionId, String name, String chapterId) async {
    try {
      await _supabase.from('section').update({
        'name': name,
      }).eq('id', sectionId);
      
      // 강제 새로고침
      await _loadSections(chapterId, forceRefresh: true);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('소단원 "$name"(으)로 수정됨')),
        );
      }
    } catch (e) {
      _showError('소단원 수정 실패: $e');
    }
  }
  
  // 소단원 삭제 확인
  void _confirmDeleteSection(Map<String, dynamic> section, String chapterId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('소단원 삭제', style: TextStyle(color: Colors.white)),
        content: Text(
          '"${section['name']}" 소단원을 삭제하시겠습니까?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _deleteSection(section['id'] as String);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
  
  // 소단원 순서 변경
  Future<void> _reorderSections(String chapterId, int oldIndex, int newIndex) async {
    try {
      // UI 먼저 업데이트 (즉각 반응)
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      
      final List<Map<String, dynamic>> reorderedSections = List.from(_sections);
      final item = reorderedSections.removeAt(oldIndex);
      reorderedSections.insert(newIndex, item);
      
      setState(() {
        _sections = reorderedSections;
      });
      
      // 데이터베이스 업데이트 (순서대로)
      for (int i = 0; i < reorderedSections.length; i++) {
        final section = reorderedSections[i];
        final sectionId = section['id'] as String;
        
        await _supabase.from('section').update({
          'display_order': i + 1,
        }).eq('id', sectionId);
      }
      
      // 데이터베이스 업데이트 완료 후 강제 새로고침
      await _loadSections(chapterId, forceRefresh: true);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('순서 변경됨'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      _showError('순서 변경 실패: $e');
      // 오류 발생 시 강제 새로고침
      await _loadSections(chapterId, forceRefresh: true);
    }
  }
  
  // 대단원 추가 버튼
  Widget _buildAddChapterButton() {
    return GestureDetector(
      onTap: () {
        _showAddChapterDialog();
      },
      child: Container(
        width: 288, // 추가 20% 증가 (240 → 288)
        height: 172, // 추가 20% 증가 (144 → 172)
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFF3A3A3A),
            style: BorderStyle.solid,
          ),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.add_circle_outline,
              color: Color(0xFF4A9EFF),
              size: 50, // 추가 20% 증가 (42 → 50)
            ),
            SizedBox(height: 16),
            Text(
              '대단원 추가',
              style: TextStyle(
                color: Color(0xFF4A9EFF),
                fontSize: 19, // 3 증가 (16 → 19)
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  // 대단원 추가 다이얼로그
  Future<void> _showAddChapterDialog() async {
    if (_selectedGradeId == null) return;
    
    String inputText = '';
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('대단원 추가', style: TextStyle(color: Colors.white)),
            content: TextField(
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                hintText: '대단원 이름',
                hintStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white54),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF4A9EFF)),
                ),
              ),
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              onChanged: (value) {
                setDialogState(() {
                  inputText = value;
                });
              },
              onSubmitted: (value) async {
                if (value.trim().isNotEmpty) {
                  Navigator.pop(context);
                  await _addChapter(value.trim());
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () async {
                  if (inputText.trim().isNotEmpty) {
                    Navigator.pop(context);
                    await _addChapter(inputText.trim());
                  }
                },
                child: const Text('추가', style: TextStyle(color: Color(0xFF4A9EFF))),
              ),
            ],
          );
        },
      ),
    );
  }
  
  // 대단원 추가
  Future<void> _addChapter(String name) async {
    if (_selectedGradeId == null) return;
    
    try {
      // 현재 최대 순서 찾기
      int maxOrder = 0;
      if (_chapters.isNotEmpty) {
        for (var chapter in _chapters) {
          final order = chapter['display_order'];
          if (order != null && order is int && order > maxOrder) {
            maxOrder = order;
          }
        }
      }
      
      // 대단원 추가
      final result = await _supabase.from('chapter').insert({
        'grade_id': _selectedGradeId,
        'name': name,
        'display_order': maxOrder + 1,
      }).select();
      
      // 추가된 대단원의 소단원 개수는 0
      if (result.isNotEmpty) {
        final newChapterId = result[0]['id'] as String;
        _sectionCounts[newChapterId] = 0;
      }
      
      // 목록 새로고침
      await _loadChapters();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('대단원 "$name" 추가됨')),
        );
      }
    } catch (e) {
      _showError('대단원 추가 실패: $e');
    }
  }
  
  // 대단원 우클릭 메뉴
  void _showChapterContextMenu(Map<String, dynamic> chapter) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(
          chapter['name'] as String,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: Color(0xFF4A9EFF)),
              title: const Text('편집', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showEditChapterDialog(chapter);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('삭제', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteChapter(chapter);
              },
            ),
          ],
        ),
      ),
    );
  }
  
  // 대단원 편집 다이얼로그
  Future<void> _showEditChapterDialog(Map<String, dynamic> chapter) async {
    String inputText = chapter['name'] as String;
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('대단원 편집', style: TextStyle(color: Colors.white)),
            content: TextField(
              autofocus: true,
              controller: TextEditingController(text: inputText)
                ..selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: inputText.length,
                ),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                hintText: '대단원 이름',
                hintStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white54),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF4A9EFF)),
                ),
              ),
              onChanged: (value) {
                setDialogState(() {
                  inputText = value;
                });
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () async {
                  if (inputText.trim().isNotEmpty) {
                    Navigator.pop(context);
                    await _updateChapter(chapter['id'] as String, inputText.trim());
                  }
                },
                child: const Text('저장', style: TextStyle(color: Color(0xFF4A9EFF))),
              ),
            ],
          );
        },
      ),
    );
  }
  
  // 대단원 업데이트
  Future<void> _updateChapter(String chapterId, String name) async {
    try {
      await _supabase.from('chapter').update({
        'name': name,
      }).eq('id', chapterId);
      
      await _loadChapters();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('대단원 "$name"(으)로 수정됨')),
        );
      }
    } catch (e) {
      _showError('대단원 수정 실패: $e');
    }
  }
  
  // 대단원 삭제 확인
  void _confirmDeleteChapter(Map<String, dynamic> chapter) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('대단원 삭제', style: TextStyle(color: Colors.white)),
        content: Text(
          '"${chapter['name']}" 대단원을 삭제하시겠습니까?\n\n소단원도 모두 삭제됩니다.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _deleteChapter(chapter['id'] as String);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
  
  // 대단원 삭제
  Future<void> _deleteChapter(String chapterId) async {
    try {
      await _supabase.from('chapter').delete().eq('id', chapterId);
      
      // 확장된 대단원이 삭제되면 상태 초기화
      if (_chapterExpandLevels.containsKey(chapterId)) {
        setState(() {
          _chapterExpandLevels.remove(chapterId);
          _sections = [];
        });
      }
      
      // 캐시에서 제거
      _sectionsCache.remove(chapterId);
      _sectionCounts.remove(chapterId);
      
      await _loadChapters();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('대단원 삭제됨')),
        );
      }
    } catch (e) {
      _showError('대단원 삭제 실패: $e');
    }
  }
  
  // 개념 그룹 로드
  Future<void> _loadConceptGroups(String sectionId) async {
    try {
      final data = await _supabase
          .from('concept_group')
          .select()
          .eq('section_id', sectionId)
          .order('display_order', ascending: true);
      
      // 데이터 파싱 시 notes 필드도 명시적으로 처리
      final groups = (data as List).map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        // notes 필드가 JSONB라서 이미 파싱된 상태로 올 수 있음
        if (map.containsKey('notes') && map['notes'] != null) {
          print('원본 notes: ${map['notes']}'); // 디버그
        }
        return map;
      }).toList();
      
      setState(() {
        _conceptGroups = groups;
        _conceptGroupsCache[sectionId] = _conceptGroups;
      });
      
      // 각 그룹의 개념도 미리 로드
      for (var group in _conceptGroups) {
        await _loadConcepts(group['id'] as String);
      }
    } catch (e) {
      _showError('개념 그룹 로드 실패: $e');
    }
  }
  
  // 개념 로드
  Future<void> _loadConcepts(String groupId) async {
    try {
      final data = await _supabase
          .from('concept')
          .select()
          .eq('group_id', groupId)
          .order('display_order', ascending: true);
      
      var concepts = List<Map<String, dynamic>>.from(data);
      
      // SharedPreferences에서 로컬 순서 불러오기
      final prefs = await SharedPreferences.getInstance();
      final localOrderJson = prefs.getString('concept_order_$groupId');
      if (localOrderJson != null) {
        try {
          final localOrder = List<String>.from(jsonDecode(localOrderJson));
          // 로컬 순서대로 재정렬
          final orderedConcepts = <Map<String, dynamic>>[];
          for (var conceptId in localOrder) {
            final concept = concepts.firstWhere(
              (c) => c['id'] == conceptId,
              orElse: () => {},
            );
            if (concept.isNotEmpty) {
              orderedConcepts.add(concept);
            }
          }
          // 로컬에 없는 새 개념은 뒤에 추가
          for (var concept in concepts) {
            if (!localOrder.contains(concept['id'])) {
              orderedConcepts.add(concept);
            }
          }
          concepts = orderedConcepts;
        } catch (_) {}
      }
      
      setState(() {
        _conceptsCache[groupId] = concepts;
      });
    } catch (e) {
      _showError('개념 로드 실패: $e');
    }
  }
  
  
  
  
  
  
  
  
  
  // 노트 구분선 추가
  Future<void> _addNoteGroup(Map<String, dynamic> group) async {
    final controller = TextEditingController();
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('노트 구분선 추가', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          decoration: const InputDecoration(
            hintText: '구분선 이름 (예: 중요 정리)',
            hintStyle: TextStyle(color: Colors.white54),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white54),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF4A9EFF)),
            ),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(context, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(context, name);
              }
            },
            child: const Text('추가', style: TextStyle(color: Color(0xFF4A9EFF))),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      await _saveNoteGroup(group, result);
    }
  }
  
  Future<void> _saveNoteGroup(Map<String, dynamic> group, String name) async {
    try {
      final groupId = group['id'] as String;
      final notesData = group['notes'];
      // 현재 notes를 일관된 구조로 정규화
      List<Map<String, dynamic>> noteGroups = _normalizeNotes(notesData);
      
      // 새 구분선 추가
      final newGroup = {
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'name': name,
        'items': <String>[],
      };
      
      noteGroups.add(newGroup);
      
      print('저장할 노트 데이터: $noteGroups'); // 디버그
      
      await _supabase.from('concept_group').update({
        'notes': noteGroups,
      }).eq('id', groupId);
      
      if (_expandedSectionId != null) {
        await _loadConceptGroups(_expandedSectionId!);
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('구분선 "$name" 추가됨')),
        );
      }
    } catch (e) {
      _showError('노트 구분선 추가 실패: $e');
      print('노트 구분선 추가 오류 상세: $e');
    }
  }
  
  // 노트 그룹에 항목 추가
  Future<void> _addNoteToGroup(Map<String, dynamic> group, Map<String, dynamic> noteGroup) async {
    String noteText = '';
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('정리/명제/공식 추가', style: TextStyle(color: Colors.white)),
            content: TextField(
              autofocus: true,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                hintText: '예: 피타고라스 정리의 역\n직각삼각형에서 a²+b²=c²',
                hintStyle: TextStyle(color: Colors.white54),
              ),
              onChanged: (value) {
                setDialogState(() {
                  noteText = value;
                });
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () async {
                  if (noteText.trim().isNotEmpty) {
                    Navigator.pop(context);
                    await _saveNoteToGroup(group, noteGroup, noteText.trim());
                  }
                },
                child: const Text('추가', style: TextStyle(color: Color(0xFF4A9EFF))),
              ),
            ],
          );
        },
      ),
    );
  }
  
  Future<void> _saveNoteToGroup(Map<String, dynamic> group, Map<String, dynamic> noteGroup, String noteText) async {
    try {
      final groupId = group['id'] as String;
      final notesData = group['notes'];
      // 일관된 그룹 구조로 변환
      List<Map<String, dynamic>> noteGroups = _normalizeNotes(notesData);
      
      // 해당 구분선 찾아서 항목 추가
      for (var ng in noteGroups) {
        if (ng['id'] == noteGroup['id']) {
          final items = List<String>.from(ng['items'] as List<dynamic>? ?? []);
          items.add(noteText);
          ng['items'] = items;
          break;
        }
      }
      
      await _supabase.from('concept_group').update({
        'notes': noteGroups,
      }).eq('id', groupId);
      
      if (_expandedSectionId != null) {
        await _loadConceptGroups(_expandedSectionId!);
      }
    } catch (e) {
      _showError('노트 추가 실패: $e');
    }
  }
  
  Future<void> _deleteNoteGroup(Map<String, dynamic> group, int groupIndex) async {
    try {
      final groupId = group['id'] as String;
      final notesData = group['notes'];
      List<Map<String, dynamic>> noteGroups = _normalizeNotes(notesData);
      
      if (groupIndex < noteGroups.length) {
        noteGroups.removeAt(groupIndex);
      }
      
      await _supabase.from('concept_group').update({
        'notes': noteGroups,
      }).eq('id', groupId);
      
      if (_expandedSectionId != null) {
        await _loadConceptGroups(_expandedSectionId!);
      }
    } catch (e) {
      _showError('노트 구분선 삭제 실패: $e');
    }
  }
  
  Future<void> _deleteNoteItem(Map<String, dynamic> group, int groupIndex, int itemIndex) async {
    try {
      final groupId = group['id'] as String;
      final notesData = group['notes'];
      List<Map<String, dynamic>> noteGroups = _normalizeNotes(notesData);
      
      if (groupIndex < noteGroups.length) {
        final items = List<String>.from(noteGroups[groupIndex]['items'] as List<dynamic>? ?? []);
        if (itemIndex < items.length) {
          items.removeAt(itemIndex);
          noteGroups[groupIndex]['items'] = items;
        }
      }
      
      await _supabase.from('concept_group').update({
        'notes': noteGroups,
      }).eq('id', groupId);
      
      if (_expandedSectionId != null) {
        await _loadConceptGroups(_expandedSectionId!);
      }
    } catch (e) {
      _showError('노트 삭제 실패: $e');
    }
  }
  
  
  
  
  
  // 개념 순서 변경 (로컬만)
  Future<void> _reorderConcepts(String groupId, int oldIndex, int newIndex) async {
    print('드래그앤드롭: $oldIndex → $newIndex (groupId: $groupId)');
    
    if (oldIndex == newIndex) return;
    
    final concepts = List<Map<String, dynamic>>.from(_conceptsCache[groupId] ?? []);
    if (oldIndex >= concepts.length || newIndex >= concepts.length) return;
    
    print('이전 순서: ${concepts.map((c) => c['name']).toList()}');
    
    // UI 업데이트
    final item = concepts.removeAt(oldIndex);
    concepts.insert(newIndex, item);
    
    print('새 순서: ${concepts.map((c) => c['name']).toList()}');
    
    // SharedPreferences에 순서 저장
    try {
      final prefs = await SharedPreferences.getInstance();
      final conceptIds = concepts.map((c) => c['id'] as String).toList();
      await prefs.setString('concept_order_$groupId', jsonEncode(conceptIds));
      print('순서 저장 완료: $conceptIds');
    } catch (e) {
      _showError('순서 저장 실패: $e');
    }
    
    // 캐시 업데이트 및 강제 리렌더링
    setState(() {
      _conceptsCache[groupId] = concepts;
    });
  }
  
  // 구분선 추가
  Future<void> _addConceptGroup(String sectionId) async {
    String groupName = '';
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('구분선 추가', style: TextStyle(color: Colors.white)),
            content: TextField(
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                hintText: '구분선 이름 (예: 기본 개념)',
                hintStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white54),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF4A9EFF)),
                ),
              ),
              onChanged: (value) {
                setDialogState(() {
                  groupName = value;
                });
              },
              onSubmitted: (value) async {
                if (value.trim().isNotEmpty) {
                  Navigator.pop(context);
                  await _saveConceptGroup(sectionId, value.trim());
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () async {
                  if (groupName.trim().isNotEmpty) {
                    Navigator.pop(context);
                    await _saveConceptGroup(sectionId, groupName.trim());
                  }
                },
                child: const Text('추가', style: TextStyle(color: Color(0xFF4A9EFF))),
              ),
            ],
          );
        },
      ),
    );
  }
  
  Future<void> _saveConceptGroup(String sectionId, String name) async {
    try {
      final maxOrder = _conceptGroups.isEmpty
          ? 0
          : _conceptGroups.map((g) => g['display_order'] as int? ?? 0).reduce((a, b) => a > b ? a : b);
      
      await _supabase.from('concept_group').insert({
        'section_id': sectionId,
        'name': name,
        'display_order': maxOrder + 1,
      });
      
      await _loadConceptGroups(sectionId);
    } catch (e) {
      _showError('구분선 추가 실패: $e');
    }
  }
  
  // 개념 추가
  Future<void> _addConcept(String groupId) async {
    String name = '';
    String selectedTag = ''; // '', '정의', '정리', '방법'
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('개념 추가', style: TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: const InputDecoration(
                    hintText: '개념 이름',
                    hintStyle: TextStyle(color: Colors.white54),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white54),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF4A9EFF)),
                    ),
                  ),
                  onChanged: (value) => name = value,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('태그: ', style: TextStyle(color: Colors.white70)),
                    const SizedBox(width: 12),
                    // 정의 태그
                    GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedTag = selectedTag == '정의' ? '' : '정의';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selectedTag == '정의'
                              ? const Color(0xFFFF5252).withOpacity(0.2) 
                              : Colors.transparent,
                          border: Border.all(
                            color: selectedTag == '정의'
                                ? const Color(0xFFFF5252) 
                                : const Color(0xFF666666),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '정의',
                          style: TextStyle(
                            color: selectedTag == '정의'
                                ? const Color(0xFFFF5252) 
                                : const Color(0xFF999999),
                            fontSize: 13,
                            fontWeight: selectedTag == '정의' ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 정리 태그
                    GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedTag = selectedTag == '정리' ? '' : '정리';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selectedTag == '정리'
                              ? const Color(0xFF4A9EFF).withOpacity(0.2) 
                              : Colors.transparent,
                          border: Border.all(
                            color: selectedTag == '정리'
                                ? const Color(0xFF4A9EFF) 
                                : const Color(0xFF666666),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '정리',
                          style: TextStyle(
                            color: selectedTag == '정리'
                                ? const Color(0xFF4A9EFF) 
                                : const Color(0xFF999999),
                            fontSize: 13,
                            fontWeight: selectedTag == '정리' ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 방법 태그
                    GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedTag = selectedTag == '방법' ? '' : '방법';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selectedTag == '방법'
                              ? const Color(0xFF999999).withOpacity(0.2) 
                              : Colors.transparent,
                          border: Border.all(
                            color: selectedTag == '방법'
                                ? const Color(0xFF999999) 
                                : const Color(0xFF666666),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '방법',
                          style: TextStyle(
                            color: selectedTag == '방법'
                                ? const Color(0xFF999999) 
                                : const Color(0xFF666666),
                            fontSize: 13,
                            fontWeight: selectedTag == '방법' ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () async {
                  if (name.trim().isNotEmpty) {
                    Navigator.pop(context);
                    await _saveNewConcept(groupId, name.trim(), selectedTag);
                  }
                },
                child: const Text('추가', style: TextStyle(color: Color(0xFF4A9EFF))),
              ),
            ],
          );
        },
      ),
    );
  }
  
  Future<void> _saveNewConcept(String groupId, String name, String tag) async {
    try {
      final concepts = _conceptsCache[groupId] ?? [];
      final maxOrder = concepts.isEmpty
          ? 0
          : concepts.map((c) => c['display_order'] as int? ?? 0).reduce((a, b) => a > b ? a : b);
      
      final tags = tag.isNotEmpty ? [tag] : [];
      final color = tag == '정의' ? '#FF5252' : (tag == '정리' ? '#4A9EFF' : '#999999');
      
      await _supabase.from('concept').insert({
        'group_id': groupId,
        'name': name,
        'color': color,
        'tags': tags,
        'display_order': maxOrder + 1,
      });
      
      await _loadConcepts(groupId);
    } catch (e) {
      _showError('개념 추가 실패: $e');
    }
  }
  
  // 구분선 컨텍스트 메뉴
  void _showGroupContextMenu(Map<String, dynamic> group, String sectionId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('구분선', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('삭제', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _deleteConceptGroup(group['id'] as String, sectionId);
              },
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _deleteConceptGroup(String groupId, String sectionId) async {
    try {
      await _supabase.from('concept_group').delete().eq('id', groupId);
      _conceptsCache.remove(groupId);
      await _loadConceptGroups(sectionId);
    } catch (e) {
      _showError('구분선 삭제 실패: $e');
    }
  }
  
  // 개념 컨텍스트 메뉴
  void _showConceptContextMenu(Map<String, dynamic> concept, String groupId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(concept['name'] as String, style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: Color(0xFF4A9EFF)),
              title: const Text('편집', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _editConcept(concept, groupId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('삭제', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _deleteConcept(concept['id'] as String, groupId);
              },
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _editConcept(Map<String, dynamic> concept, String groupId) async {
    String name = concept['name'] as String;
    final tags = List<String>.from(concept['tags'] as List<dynamic>? ?? []);
    String selectedTag = tags.isEmpty ? '' : tags[0]; // '정의', '정리', '방법', ''
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('개념 편집', style: TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: TextEditingController(text: name)
                    ..selection = TextSelection(baseOffset: 0, extentOffset: name.length),
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: const InputDecoration(
                    hintText: '개념 이름',
                    hintStyle: TextStyle(color: Colors.white54),
                  ),
                  onChanged: (value) => name = value,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('태그: ', style: TextStyle(color: Colors.white70)),
                    const SizedBox(width: 12),
                    // 정의 태그
                    GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedTag = selectedTag == '정의' ? '' : '정의';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selectedTag == '정의'
                              ? const Color(0xFFFF5252).withOpacity(0.2) 
                              : Colors.transparent,
                          border: Border.all(
                            color: selectedTag == '정의'
                                ? const Color(0xFFFF5252) 
                                : const Color(0xFF666666),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '정의',
                          style: TextStyle(
                            color: selectedTag == '정의'
                                ? const Color(0xFFFF5252) 
                                : const Color(0xFF999999),
                            fontSize: 13,
                            fontWeight: selectedTag == '정의' ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 정리 태그
                    GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedTag = selectedTag == '정리' ? '' : '정리';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selectedTag == '정리'
                              ? const Color(0xFF4A9EFF).withOpacity(0.2) 
                              : Colors.transparent,
                          border: Border.all(
                            color: selectedTag == '정리'
                                ? const Color(0xFF4A9EFF) 
                                : const Color(0xFF666666),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '정리',
                          style: TextStyle(
                            color: selectedTag == '정리'
                                ? const Color(0xFF4A9EFF) 
                                : const Color(0xFF999999),
                            fontSize: 13,
                            fontWeight: selectedTag == '정리' ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 방법 태그
                    GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedTag = selectedTag == '방법' ? '' : '방법';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selectedTag == '방법'
                              ? const Color(0xFF999999).withOpacity(0.2) 
                              : Colors.transparent,
                          border: Border.all(
                            color: selectedTag == '방법'
                                ? const Color(0xFF999999) 
                                : const Color(0xFF666666),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '방법',
                          style: TextStyle(
                            color: selectedTag == '방법'
                                ? const Color(0xFF999999) 
                                : const Color(0xFF666666),
                            fontSize: 13,
                            fontWeight: selectedTag == '방법' ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () async {
                  if (name.trim().isNotEmpty) {
                    Navigator.pop(context);
                    await _updateConcept(concept['id'] as String, name.trim(), selectedTag, groupId);
                  }
                },
                child: const Text('저장', style: TextStyle(color: Color(0xFF4A9EFF))),
              ),
            ],
          );
        },
      ),
    );
  }
  
  Future<void> _updateConcept(String conceptId, String name, String tag, String groupId) async {
    try {
      final tags = tag.isNotEmpty ? [tag] : [];
      final color = tag == '정의' ? '#FF5252' : (tag == '정리' ? '#4A9EFF' : '#999999');
      
      await _supabase.from('concept').update({
        'name': name,
        'color': color,
        'tags': tags,
      }).eq('id', conceptId);
      
      await _loadConcepts(groupId);
    } catch (e) {
      _showError('개념 수정 실패: $e');
    }
  }
  
  Future<void> _deleteConcept(String conceptId, String groupId) async {
    try {
      await _supabase.from('concept').delete().eq('id', conceptId);
      await _loadConcepts(groupId);
    } catch (e) {
      _showError('개념 삭제 실패: $e');
    }
  }
}



