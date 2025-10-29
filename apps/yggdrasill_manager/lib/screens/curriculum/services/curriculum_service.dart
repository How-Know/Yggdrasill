import 'package:supabase_flutter/supabase_flutter.dart';

class CurriculumService {
  final _supabase = Supabase.instance.client;
  
  // 교육과정 목록
  Future<List<Map<String, dynamic>>> loadCurriculums() async {
    final data = await _supabase
        .from('curriculum')
        .select()
        .order('created_at');
    return List<Map<String, dynamic>>.from(data);
  }
  
  // 학년 목록
  Future<List<Map<String, dynamic>>> loadGrades(String curriculumId, String schoolLevel) async {
    final data = await _supabase
        .from('grade')
        .select()
        .eq('curriculum_id', curriculumId)
        .eq('school_level', schoolLevel)
        .order('display_order');
    return List<Map<String, dynamic>>.from(data);
  }
  
  // 대단원 목록
  Future<List<Map<String, dynamic>>> loadChapters(String gradeId) async {
    final data = await _supabase
        .from('chapter')
        .select()
        .eq('grade_id', gradeId)
        .order('display_order', ascending: true);
    
    final groups = (data as List).map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      if (map.containsKey('notes') && map['notes'] != null) {
        print('원본 notes: ${map['notes']}');
      }
      return map;
    }).toList();
    
    return groups;
  }
  
  // 대단원 추가
  Future<Map<String, dynamic>> addChapter(String gradeId, String name, int displayOrder) async {
    final result = await _supabase.from('chapter').insert({
      'grade_id': gradeId,
      'name': name,
      'display_order': displayOrder,
    }).select();
    
    return result.isNotEmpty ? Map<String, dynamic>.from(result[0]) : {};
  }
  
  // 대단원 수정
  Future<void> updateChapter(String chapterId, String name) async {
    await _supabase.from('chapter').update({
      'name': name,
    }).eq('id', chapterId);
  }
  
  // 대단원 삭제
  Future<void> deleteChapter(String chapterId) async {
    await _supabase.from('chapter').delete().eq('id', chapterId);
  }
  
  // 소단원 목록
  Future<List<Map<String, dynamic>>> loadSections(String chapterId) async {
    final data = await _supabase
        .from('section')
        .select()
        .eq('chapter_id', chapterId)
        .order('display_order', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }
  
  // 소단원 추가
  Future<void> addSection(String chapterId, String name, int displayOrder) async {
    await _supabase.from('section').insert({
      'chapter_id': chapterId,
      'name': name,
      'display_order': displayOrder,
    }).select();
  }
  
  // 소단원 수정
  Future<void> updateSection(String sectionId, String name) async {
    await _supabase.from('section').update({
      'name': name,
    }).eq('id', sectionId);
  }
  
  // 소단원 삭제
  Future<void> deleteSection(String sectionId) async {
    await _supabase.from('section').delete().eq('id', sectionId);
  }
  
  // 소단원 순서 변경
  Future<void> reorderSections(List<Map<String, dynamic>> sections) async {
    for (int i = 0; i < sections.length; i++) {
      final sectionId = sections[i]['id'] as String;
      await _supabase.from('section').update({
        'display_order': i + 1,
      }).eq('id', sectionId);
    }
  }
  
  // 개념 그룹 목록
  Future<List<Map<String, dynamic>>> loadConceptGroups(String sectionId) async {
    final data = await _supabase
        .from('concept_group')
        .select()
        .eq('section_id', sectionId)
        .order('display_order', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }
  
  // 개념 그룹 추가
  Future<void> addConceptGroup(String sectionId, String? name, int displayOrder) async {
    await _supabase.from('concept_group').insert({
      'section_id': sectionId,
      'name': name,
      'display_order': displayOrder,
    });
  }
  
  // 개념 그룹 삭제
  Future<void> deleteConceptGroup(String groupId) async {
    await _supabase.from('concept_group').delete().eq('id', groupId);
  }
  
  // 개념 그룹 노트 업데이트
  Future<void> updateConceptGroupNotes(String groupId, dynamic notes) async {
    await _supabase.from('concept_group').update({
      'notes': notes,
    }).eq('id', groupId);
  }
  
  // 개념 목록
  Future<List<Map<String, dynamic>>> loadConcepts(String groupId) async {
    final data = await _supabase
        .from('concept')
        .select()
        .eq('group_id', groupId)
        .order('display_order', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }
  
  // 개념 추가
  Future<void> addConcept(String groupId, String name, String color, List<String> tags, int displayOrder) async {
    await _supabase.from('concept').insert({
      'group_id': groupId,
      'name': name,
      'color': color,
      'tags': tags,
      'display_order': displayOrder,
    });
  }
  
  // 개념 수정
  Future<void> updateConcept(String conceptId, String name, String color, List<String> tags) async {
    await _supabase.from('concept').update({
      'name': name,
      'color': color,
      'tags': tags,
    }).eq('id', conceptId);
  }
  
  // 개념 삭제
  Future<void> deleteConcept(String conceptId) async {
    await _supabase.from('concept').delete().eq('id', conceptId);
  }
  
  // 소단원 개수 조회 (여러 대단원)
  Future<Map<String, int>> loadSectionCounts(List<String> chapterIds) async {
    final counts = <String, int>{};
    
    for (var chapterId in chapterIds) {
      final countData = await _supabase
          .from('section')
          .select()
          .eq('chapter_id', chapterId);
      counts[chapterId] = countData.length;
    }
    
    return counts;
  }
}

