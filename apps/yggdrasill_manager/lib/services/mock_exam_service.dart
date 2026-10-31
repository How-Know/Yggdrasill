import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/problem_bank/mock_exam/mock_exam_models.dart';

/// 모의고사 기출 테이블(mock_exams 등) 접근. 추출은 gateway mock_exam_worker 가 한다.
class MockExamService {
  MockExamService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;
  static const String _bucket = 'problem-documents';

  Future<List<MockExam>> listExams(String academyId) async {
    final rows = await _client
        .from('mock_exams')
        .select('*')
        .eq('academy_id', academyId)
        .order('exam_year', ascending: false)
        .order('exam_month', ascending: true);
    return (rows as List<dynamic>)
        .map((r) => MockExam.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  Future<List<MockExamPaper>> listPapers(String examId) async {
    final rows =
        await _client.from('mock_exam_papers').select('*').eq('exam_id', examId);
    return (rows as List<dynamic>)
        .map((r) => MockExamPaper.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  /// 학원의 모든 구간 문서 연결. exam_id 별로 묶는다.
  Future<Map<String, List<MockExamSectionLink>>> listSectionLinks(
    String academyId,
  ) async {
    final rows = await _client
        .from('mock_exam_sections')
        .select('exam_id, section, pb_document_id, extract_job_id')
        .eq('academy_id', academyId);
    final links = (rows as List<dynamic>)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    String? id(dynamic v) {
      final s = '${v ?? ''}'.trim();
      return s.isEmpty ? null : s;
    }

    Future<Map<String, String>> statusById(String table, String column) async {
      final ids = links.map((r) => id(r[column])).whereType<String>().toList();
      if (ids.isEmpty) return const <String, String>{};
      final found =
          await _client.from(table).select('id, status').inFilter('id', ids);
      return {
        for (final r in found as List<dynamic>)
          '${(r as Map)['id']}': '${r['status'] ?? ''}',
      };
    }

    final jobStatus = await statusById('pb_extract_jobs', 'extract_job_id');
    final docStatus = await statusById('pb_documents', 'pb_document_id');
    final out = <String, List<MockExamSectionLink>>{};
    for (final r in links) {
      out.putIfAbsent('${r['exam_id']}', () => <MockExamSectionLink>[]).add(
            MockExamSectionLink(
              section: '${r['section']}',
              pbDocumentId: id(r['pb_document_id']),
              extractJobId: id(r['extract_job_id']),
              extractStatus: jobStatus['${r['extract_job_id']}'] ?? '',
              documentStatus: docStatus['${r['pb_document_id']}'] ?? '',
            ),
          );
    }
    return out;
  }

  /// 파일명으로 읽은 PDF 묶음을 시험 단위로 올리고 추출 대기열에 넣는다.
  /// 같은 시험·종류·선택과목의 기존 PDF 는 교체한다.
  Future<List<String>> uploadBatch({
    required String academyId,
    required List<MockExamFileName> files,
    void Function(String message)? onProgress,
  }) async {
    final userId = _client.auth.currentUser?.id;
    final byExam = <String, List<MockExamFileName>>{};
    for (final f in files) {
      byExam.putIfAbsent(f.examKey, () => <MockExamFileName>[]).add(f);
    }
    final examIds = <String>[];
    var index = 0;
    for (final group in byExam.values) {
      index += 1;
      final head = group.first;
      onProgress?.call('[$index/${byExam.length}] ${head.title} 등록 중');
      final exam = await _client
          .from('mock_exams')
          .upsert(
            <String, dynamic>{
              'academy_id': academyId,
              'grade': head.grade,
              'exam_year': head.examYear,
              'school_year': mockExamSchoolYear(head.grade, head.examYear),
              'exam_month': head.month,
              'org': head.org,
              'title': head.title,
              if (userId != null) 'created_by': userId,
            },
            onConflict: 'academy_id,grade,exam_year,exam_month,org',
          )
          .select('id, status')
          .single();
      final examId = '${exam['id']}';
      final status = '${exam['status'] ?? ''}';
      if (status == 'queued' || status == 'running') {
        throw Exception('${head.title} 은(는) 추출 중이라 교체할 수 없습니다.');
      }
      final existing = {
        for (final paper in await listPapers(examId))
          '${paper.kind}|${paper.elective}': paper,
      };
      for (final f in group) {
        onProgress?.call('[$index/${byExam.length}] ${p.basename(f.path)} 업로드');
        final bytes = await File(f.path).readAsBytes();
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final elective = f.elective.isEmpty ? 'common' : f.elective;
        final objectPath =
            '$academyId/mock-exams/$examId/${f.kind}_${elective}_$stamp.pdf';
        await _client.storage.from(_bucket).uploadBinary(
              objectPath,
              bytes,
              fileOptions: const FileOptions(
                cacheControl: '3600',
                contentType: 'application/pdf',
                upsert: false,
              ),
            );
        await _client.from('mock_exam_papers').upsert(
          <String, dynamic>{
            'academy_id': academyId,
            'exam_id': examId,
            'kind': f.kind,
            'elective': f.elective,
            'storage_bucket': _bucket,
            'storage_path': objectPath,
            'file_name': p.basename(f.path),
            'sha256': sha256.convert(bytes).toString(),
            'size_bytes': bytes.length,
            'page_count': null,
          },
          onConflict: 'exam_id,kind,elective',
        );
        final old = existing['${f.kind}|${f.elective}'];
        if (old != null && old.storagePath != objectPath) {
          try {
            await _client.storage.from(old.storageBucket).remove([old.storagePath]);
          } catch (_) {
            // 이전 PDF 정리 실패는 등록을 막지 않는다.
          }
        }
      }
      await requestExtraction(examId, 'all');
      examIds.add(examId);
    }
    return examIds;
  }

  /// request: 'all' | 'crops' | 'solutions' | 'problem_bank'
  Future<void> requestExtraction(String examId, String request) async {
    await _client.from('mock_exams').update(<String, dynamic>{
      'status': 'queued',
      'stage': '',
      'last_error': '',
      'progress': <String, dynamic>{'request': request},
    }).eq('id', examId).neq('status', 'running');
  }
}
