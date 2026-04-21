import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/problem_bank/problem_bank_models.dart';

class ProblemBankSchemaMissingException implements Exception {
  ProblemBankSchemaMissingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AcademyIdNotFoundException implements Exception {
  AcademyIdNotFoundException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// AI(Gemini) 기반 5지선다 자동 생성 결과. 매니저 UI 는 이 결과만 있으면
/// 스낵바 문구(성공/폴백/이미 존재/실패) 와 로컬 상태 패치(보기+정답 라벨) 을 모두 수행할 수 있다.
class ProblemBankObjectiveGenerationResult {
  const ProblemBankObjectiveGenerationResult({
    required this.skipped,
    required this.success,
    required this.usedFallback,
    required this.choices,
    required this.answerKey,
    required this.allowObjective,
    required this.objectiveGenerated,
    this.reason,
    this.error,
  });

  /// 서버가 "이미 쓸만한 보기가 있으므로 건너뜀" 이라고 응답한 경우 true.
  final bool skipped;

  /// 실제로 생성에 성공했고 DB 가 업데이트된 경우 true. (skipped==true 일 때는 무조건 false)
  final bool success;

  /// Gemini 응답이 모자라 숫자/수식 폴백으로 보충된 경우 true.
  final bool usedFallback;

  /// 현재 문항에 적용되어야 할 5개 보기. skipped 의 경우 기존 보기가 그대로 담긴다.
  final List<ProblemBankChoice> choices;

  /// 현재 정답 라벨 (`①` ~ `⑤`).
  final String answerKey;

  final bool allowObjective;
  final bool objectiveGenerated;

  /// skipped 이유 ("choices_already_exist" 등) 또는 success=false 시 간단한 사유.
  final String? reason;
  final String? error;
}

class ProblemBankManualImportResult {
  const ProblemBankManualImportResult({
    required this.document,
    required this.extractJob,
    required this.questionCount,
  });

  final ProblemBankDocument document;
  final ProblemBankExtractJob extractJob;
  final int questionCount;
}

class ProblemBankResetResult {
  const ProblemBankResetResult({
    required this.documentCount,
    required this.extractJobCount,
    required this.questionCount,
    required this.exportCount,
    required this.storageObjectCount,
  });

  final int documentCount;
  final int extractJobCount;
  final int questionCount;
  final int exportCount;
  final int storageObjectCount;
}

class ProblemBankPdfPreviewArtifact {
  const ProblemBankPdfPreviewArtifact({
    required this.questionId,
    required this.questionUid,
    required this.status,
    required this.jobId,
    required this.pdfUrl,
    required this.thumbnailUrl,
    required this.error,
    required this.pollAfterMs,
  });

  final String questionId;
  final String questionUid;
  final String status;
  final String jobId;
  final String pdfUrl;
  final String thumbnailUrl;
  final String error;
  final int pollAfterMs;

  bool get isPending => status == 'queued' || status == 'running';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed' || status == 'cancelled';

  factory ProblemBankPdfPreviewArtifact.fromMap(
    Map<String, dynamic> map, {
    int defaultPollAfterMs = 0,
  }) {
    return ProblemBankPdfPreviewArtifact(
      questionId: '${map['questionId'] ?? ''}'.trim(),
      questionUid: '${map['questionUid'] ?? ''}'.trim(),
      status: '${map['status'] ?? ''}'.trim().toLowerCase(),
      jobId: '${map['jobId'] ?? ''}'.trim(),
      pdfUrl: '${map['pdfUrl'] ?? ''}'.trim(),
      thumbnailUrl: '${map['thumbnailUrl'] ?? ''}'.trim(),
      error: '${map['error'] ?? ''}'.trim(),
      pollAfterMs: int.tryParse('${map['pollAfterMs'] ?? defaultPollAfterMs}') ?? defaultPollAfterMs,
    );
  }
}

class ProblemBankService {
  ProblemBankService({
    SupabaseClient? client,
    http.Client? httpClient,
    String? gatewayBaseUrl,
    String? gatewayApiKey,
  })  : _client = client ?? Supabase.instance.client,
        _http = httpClient ?? http.Client(),
        _gatewayBaseUrl = _resolveGatewayUrl(gatewayBaseUrl),
        _gatewayApiKey = (gatewayApiKey ??
                const String.fromEnvironment('PB_GATEWAY_API_KEY',
                    defaultValue: ''))
            .trim();

  static String _resolveGatewayUrl(String? explicit) {
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    const dartDefine =
        String.fromEnvironment('PB_GATEWAY_URL', defaultValue: '');
    if (dartDefine.isNotEmpty) return dartDefine;
    try {
      final envValue = Platform.environment['PB_GATEWAY_URL'] ?? '';
      if (envValue.isNotEmpty) return envValue;
    } catch (_) {}
    return 'http://localhost:8787';
  }

  final SupabaseClient _client;
  final http.Client _http;
  final String _gatewayBaseUrl;
  final String _gatewayApiKey;

  bool get hasGateway => _gatewayBaseUrl.isNotEmpty;

  static const List<String> _curriculumCodes = <String>[
    'legacy_1to6',
    'k7_1997',
    'k7_2007',
    'rev_2009',
    'rev_2015',
    'rev_2022',
  ];
  static const List<String> _sourceTypeCodes = <String>[
    'market_book',
    'lecture_book',
    'ebs_book',
    'school_past',
    'mock_past',
    'original_item',
  ];

  String _normalizeCurriculumCode(String? value) {
    final code = (value ?? '').trim();
    if (_curriculumCodes.contains(code)) return code;
    return 'rev_2022';
  }

  String _normalizeSourceTypeCode(String? value) {
    final code = (value ?? '').trim();
    if (_sourceTypeCodes.contains(code)) return code;
    return 'school_past';
  }

  String _normalizeSemesterLabel(String? value) {
    final label = (value ?? '').trim();
    if (label == '1학기' || label == '2학기') return label;
    return '';
  }

  String _normalizeExamTermLabel(String? value) {
    final label = (value ?? '').trim();
    if (label == '중간' || label == '기말') return label;
    return '';
  }

  int? _normalizeExamYear(dynamic value) {
    if (value == null) return null;
    final digits = '$value'.replaceAll(RegExp(r'[^0-9]'), '').trim();
    if (digits.isEmpty) return null;
    return int.tryParse(digits);
  }

  Map<String, dynamic> _buildClassificationColumns({
    String? curriculumCode,
    String? sourceTypeCode,
    String? courseLabel,
    String? gradeLabel,
    dynamic examYear,
    String? semesterLabel,
    String? examTermLabel,
    String? schoolName,
    String? publisherName,
    String? materialName,
    Map<String, dynamic>? classificationDetail,
  }) {
    return <String, dynamic>{
      'curriculum_code': _normalizeCurriculumCode(curriculumCode),
      'source_type_code': _normalizeSourceTypeCode(sourceTypeCode),
      'course_label': (courseLabel ?? '').trim(),
      'grade_label': (gradeLabel ?? '').trim(),
      'exam_year': _normalizeExamYear(examYear),
      'semester_label': _normalizeSemesterLabel(semesterLabel),
      'exam_term_label': _normalizeExamTermLabel(examTermLabel),
      'school_name': (schoolName ?? '').trim(),
      'publisher_name': (publisherName ?? '').trim(),
      'material_name': (materialName ?? '').trim(),
      'classification_detail': classificationDetail ?? <String, dynamic>{},
    };
  }

  /// 추출 단계(draft)에서 pb_documents에 저장할 분류 컬럼.
  /// 분류는 아직 확정되지 않았으므로 모든 필드를 비워 둔다.
  /// 실제 분류는 검수 후 `_saveQuestionsToServer`가 `updateDocumentMeta`로
  /// status='ready' 전환과 함께 채워 넣는다.
  Map<String, dynamic> _buildDraftClassificationColumns() {
    return <String, dynamic>{
      'curriculum_code': '',
      'source_type_code': '',
      'course_label': '',
      'grade_label': '',
      'exam_year': null,
      'semester_label': '',
      'exam_term_label': '',
      'school_name': '',
      'publisher_name': '',
      'material_name': '',
      'classification_detail': <String, dynamic>{},
    };
  }

  Uri _gatewayUri(String path, [Map<String, String>? query]) {
    final base = _gatewayBaseUrl.endsWith('/')
        ? _gatewayBaseUrl.substring(0, _gatewayBaseUrl.length - 1)
        : _gatewayBaseUrl;
    final p = path.startsWith('/') ? path : '/$path';
    final u = Uri.parse('$base$p');
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: query);
  }

  Map<String, String> _gatewayHeaders() {
    final out = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_gatewayApiKey.isNotEmpty) {
      out['x-api-key'] = _gatewayApiKey;
    }
    return out;
  }

  Future<Map<String, dynamic>> _gatewayGet(
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = _gatewayUri(path, query);
    final res = await _http.get(uri, headers: _gatewayHeaders());
    final decoded = _decodeJsonMap(res.body);
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        decoded['ok'] != true) {
      throw Exception(
        'gateway_get_failed(${res.statusCode}): ${decoded['error'] ?? decoded['message'] ?? res.body}',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _gatewayPost(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final uri = _gatewayUri(path);
    final res = await _http.post(
      uri,
      headers: _gatewayHeaders(),
      body: jsonEncode(body),
    );
    final decoded = _decodeJsonMap(res.body);
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        decoded['ok'] != true) {
      throw Exception(
        'gateway_post_failed(${res.statusCode}): ${decoded['error'] ?? decoded['message'] ?? res.body}',
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decodeJsonMap(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return v.map((k, dynamic val) => MapEntry('$k', val));
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 단일 문항에 대해 "객관식 허용" 상태가 새로 켜졌을 때 게이트웨이로 AI 생성 요청을 보낸다.
  ///
  /// - 서버는 기본적으로 `objective_choices.length >= 2` 이고 `objective_answer_key` 가
  ///   비어 있지 않으면 자동으로 건너뛴다. 덮어쓰려면 [force] 를 true 로 준다.
  /// - 생성 성공 시 DB 에는 이미 `allow_objective=true`, `objective_choices`,
  ///   `objective_answer_key`, `objective_generated` 가 반영된 상태로 응답이 내려온다.
  /// - 네트워크/서버 오류는 예외로 throw. 단순 "생성 실패(보기 부족)" 는 예외 없이
  ///   `success=false` 로 내려오며, UI 는 스낵바로만 알리면 된다.
  Future<ProblemBankObjectiveGenerationResult> generateObjectiveChoices({
    required String questionId,
    bool force = false,
  }) async {
    if (!hasGateway) {
      throw StateError(
        '게이트웨이 URL 이 설정되어 있지 않아 AI 객관식 보기 생성을 사용할 수 없습니다.',
      );
    }
    final json = await _gatewayPost(
      '/pb/questions/$questionId/generate-objective',
      body: <String, dynamic>{if (force) 'force': true},
    );
    final rawChoices = json['objective_choices'];
    final choices = <ProblemBankChoice>[];
    if (rawChoices is List) {
      for (final entry in rawChoices) {
        if (entry is Map) {
          choices.add(ProblemBankChoice.fromMap(
            entry.map((k, dynamic v) => MapEntry('$k', v)),
          ));
        }
      }
    }
    return ProblemBankObjectiveGenerationResult(
      skipped: json['skipped'] == true,
      success: json['success'] == true,
      usedFallback: json['used_fallback'] == true,
      choices: choices,
      answerKey: '${json['objective_answer_key'] ?? ''}',
      allowObjective: json['allow_objective'] == true,
      objectiveGenerated: json['objective_generated'] == true,
      reason: json['reason'] is String ? json['reason'] as String : null,
      error: json['error'] is String ? json['error'] as String : null,
    );
  }

  bool _isSchemaMissingMessage(String raw) {
    final msg = raw.toLowerCase();
    return msg.contains("could not find the table 'public.pb_documents'") ||
        msg.contains('relation "pb_documents" does not exist') ||
        msg.contains("table 'public.pb_documents'") ||
        msg.contains('schema cache') && msg.contains('pb_documents');
  }

  Future<void> ensurePipelineSchema() async {
    try {
      await _client.from('pb_documents').select('id').limit(1);
    } on PostgrestException catch (e) {
      if (_isSchemaMissingMessage(e.message)) {
        throw ProblemBankSchemaMissingException(
          '문제은행 파이프라인 테이블이 없습니다. '
          'Supabase 마이그레이션 `20260324193000_problem_bank_pipeline.sql`을 먼저 적용해주세요.',
        );
      }
      rethrow;
    } catch (e) {
      if (_isSchemaMissingMessage(e.toString())) {
        throw ProblemBankSchemaMissingException(
          '문제은행 파이프라인 테이블이 없습니다. '
          'Supabase 마이그레이션 `20260324193000_problem_bank_pipeline.sql`을 먼저 적용해주세요.',
        );
      }
      rethrow;
    }
  }

  String _pickAcademyIdFromRows(dynamic rows) {
    final list = (rows as List<dynamic>)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
    for (final row in list) {
      final id = '${row['academy_id'] ?? row['id'] ?? ''}'.trim();
      if (id.isNotEmpty) return id;
    }
    return '';
  }

  Future<String> _tryResolveFromMemberships(String userId) async {
    final rows = await _client
        .from('memberships')
        .select('academy_id, created_at')
        .eq('user_id', userId)
        .order('created_at', ascending: true)
        .limit(10);
    return _pickAcademyIdFromRows(rows);
  }

  Future<String> _tryResolveFromAcademySettings() async {
    final rows =
        await _client.from('academy_settings').select('academy_id').limit(10);
    return _pickAcademyIdFromRows(rows);
  }

  Future<String> _tryResolveFromResourceFiles() async {
    final rows =
        await _client.from('resource_files').select('academy_id').limit(20);
    return _pickAcademyIdFromRows(rows);
  }

  Future<String> _tryResolveFromAcademies() async {
    final rows = await _client.from('academies').select('id').limit(10);
    return _pickAcademyIdFromRows(rows);
  }

  Future<String> resolveAcademyId() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw Exception('로그인된 사용자가 없습니다.');
    }

    final fromMeta = '${user.userMetadata?['academy_id'] ?? ''}'.trim();
    if (fromMeta.isNotEmpty) {
      return fromMeta;
    }

    final candidates = <Future<String> Function()>[
      () => _tryResolveFromMemberships(user.id),
      _tryResolveFromAcademySettings,
      _tryResolveFromResourceFiles,
      _tryResolveFromAcademies,
    ];

    for (final resolver in candidates) {
      try {
        final id = (await resolver()).trim();
        if (id.isNotEmpty) return id;
      } catch (_) {
        // 다음 fallback 계속 시도
      }
    }

    throw AcademyIdNotFoundException(
      'academy_id를 찾을 수 없습니다. '
      'memberships에 사용자 소속 학원이 있는지 확인해주세요.',
    );
  }

  Future<ProblemBankDocument> uploadDocument({
    required Uint8List bytes,
    required String originalName,
    String curriculumCode = 'rev_2022',
    String sourceTypeCode = 'school_past',
    String courseLabel = '',
    String gradeLabel = '',
    int? examYear,
    String semesterLabel = '',
    String examTermLabel = '',
    String schoolName = '',
    String publisherName = '',
    String materialName = '',
    Map<String, dynamic> classificationDetail = const <String, dynamic>{},
    String? academyId,
  }) async {
    final aid = (academyId ?? await resolveAcademyId()).trim();
    if (aid.isEmpty) {
      throw Exception('academy_id가 없습니다.');
    }
    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();
    final sourceSha256 = sha256.convert(bytes).toString();
    final safeName = _safeFileName(originalName);
    final objectPath = '$aid/${now.millisecondsSinceEpoch}_$safeName';
    final reusableDraft = await _findReusableDraftDocumentByHash(
      academyId: aid,
      sourceSha256: sourceSha256,
    );

    final oldStorageBucket = reusableDraft?.sourceStorageBucket.trim() ?? '';
    final oldStoragePath = reusableDraft?.sourceStoragePath.trim() ?? '';

    await _client.storage.from('problem-documents').uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(
            cacheControl: '3600',
            contentType: 'application/octet-stream',
            upsert: false,
          ),
        );

    try {
      final uploadMeta = <String, dynamic>{
        'uploaded_from': 'manager',
        'uploaded_at': nowIso,
        'source_sha256': sourceSha256,
        'source_hash_algo': 'sha256',
        'reused_existing_draft': reusableDraft != null,
      };
      if (reusableDraft != null) {
        await _cancelActivePipelineJobsForDocument(
          academyId: aid,
          documentId: reusableDraft.id,
          nowIso: nowIso,
          reason: 'reupload_superseded',
        );
        await _client
            .from('pb_questions')
            .delete()
            .eq('academy_id', aid)
            .eq('document_id', reusableDraft.id);

        final mergedMeta = <String, dynamic>{
          ...reusableDraft.meta,
          ...uploadMeta,
        }..remove('extraction');

        // 추출 단계에서는 분류 정보를 DB에 저장하지 않는다.
        // 기존 draft가 남아있을 수 있으므로 분류는 빈 값으로 초기화한다.
        final row = await _client
            .from('pb_documents')
            .update({
              'source_filename': originalName,
              'source_storage_bucket': 'problem-documents',
              'source_storage_path': objectPath,
              'source_size_bytes': bytes.length,
              'status': 'uploaded',
              ..._buildDraftClassificationColumns(),
              'meta': mergedMeta,
              'updated_at': nowIso,
            })
            .eq('id', reusableDraft.id)
            .select('*')
            .single();

        if (oldStorageBucket.isNotEmpty &&
            oldStoragePath.isNotEmpty &&
            (oldStorageBucket != 'problem-documents' ||
                oldStoragePath != objectPath)) {
          try {
            await _client.storage
                .from(oldStorageBucket)
                .remove([oldStoragePath]);
          } catch (_) {
            // 이전 원본 삭제 실패는 업로드 성공을 막지 않는다.
          }
        }
        return ProblemBankDocument.fromMap(
          Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
        );
      }

      // 추출 단계(draft) insert에는 분류 정보를 넣지 않는다.
      final row = await _client
          .from('pb_documents')
          .insert({
            'academy_id': aid,
            'created_by': _client.auth.currentUser?.id,
            'source_filename': originalName,
            'source_storage_bucket': 'problem-documents',
            'source_storage_path': objectPath,
            'source_size_bytes': bytes.length,
            'status': 'uploaded',
            ..._buildDraftClassificationColumns(),
            'meta': uploadMeta,
          })
          .select('*')
          .single();
      return ProblemBankDocument.fromMap(
        Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
      );
    } catch (e) {
      try {
        await _client.storage.from('problem-documents').remove([objectPath]);
      } catch (_) {
        // 업로드 실패 정리 중 스토리지 삭제 실패는 무시한다.
      }
      rethrow;
    }
  }

  /// 이미 생성된 pb_document 에 VLM 추출용 PDF 원본을 첨부/교체한다.
  /// 같은 document 에 이전 PDF가 있다면 storage 에서 정리한다.
  Future<ProblemBankDocument> uploadPdfForDocument({
    required String documentId,
    required Uint8List bytes,
    required String originalName,
    String? academyId,
  }) async {
    final aid = (academyId ?? await resolveAcademyId()).trim();
    if (aid.isEmpty) {
      throw Exception('academy_id가 없습니다.');
    }
    if (documentId.trim().isEmpty) {
      throw Exception('documentId 가 필요합니다.');
    }
    if (bytes.isEmpty) {
      throw Exception('PDF 바이트가 비어 있습니다.');
    }

    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();
    final sourceSha256 = sha256.convert(bytes).toString();
    final safeName =
        _safeFileNameWithExt(originalName, '.pdf', fallback: 'document');
    final objectPath = '$aid/${now.millisecondsSinceEpoch}_$safeName';

    // 기존 문서 PDF 경로를 읽어둔다 (교체 시 정리용).
    final existing = await _client
        .from('pb_documents')
        .select(
          'source_pdf_storage_bucket, source_pdf_storage_path',
        )
        .eq('academy_id', aid)
        .eq('id', documentId)
        .maybeSingle();
    final existingMap = Map<String, dynamic>.from(
      (existing as Map<dynamic, dynamic>?) ?? const <String, dynamic>{},
    );
    final oldBucket =
        '${existingMap['source_pdf_storage_bucket'] ?? ''}'.trim();
    final oldPath = '${existingMap['source_pdf_storage_path'] ?? ''}'.trim();

    await _client.storage.from('problem-documents').uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(
            cacheControl: '3600',
            contentType: 'application/pdf',
            upsert: false,
          ),
        );

    try {
      final row = await _client
          .from('pb_documents')
          .update({
            'source_pdf_storage_bucket': 'problem-documents',
            'source_pdf_storage_path': objectPath,
            'source_pdf_filename': originalName,
            'source_pdf_sha256': sourceSha256,
            'source_pdf_size_bytes': bytes.length,
            'updated_at': nowIso,
          })
          .eq('academy_id', aid)
          .eq('id', documentId)
          .select('*')
          .single();

      if (oldBucket.isNotEmpty &&
          oldPath.isNotEmpty &&
          !(oldBucket == 'problem-documents' && oldPath == objectPath)) {
        try {
          await _client.storage.from(oldBucket).remove([oldPath]);
        } catch (_) {
          // 이전 PDF 정리 실패는 업로드 성공을 막지 않는다.
        }
      }

      return ProblemBankDocument.fromMap(
        Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
      );
    } catch (e) {
      try {
        await _client.storage.from('problem-documents').remove([objectPath]);
      } catch (_) {
        // 업로드 실패 정리 중 스토리지 삭제 실패는 무시한다.
      }
      rethrow;
    }
  }

  /// document 에 연결된 PDF 원본을 제거한다 (DB + Storage).
  Future<ProblemBankDocument> clearPdfForDocument({
    required String documentId,
    String? academyId,
  }) async {
    final aid = (academyId ?? await resolveAcademyId()).trim();
    if (aid.isEmpty) {
      throw Exception('academy_id가 없습니다.');
    }
    if (documentId.trim().isEmpty) {
      throw Exception('documentId 가 필요합니다.');
    }
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final existing = await _client
        .from('pb_documents')
        .select(
          'source_pdf_storage_bucket, source_pdf_storage_path',
        )
        .eq('academy_id', aid)
        .eq('id', documentId)
        .maybeSingle();
    final existingMap = Map<String, dynamic>.from(
      (existing as Map<dynamic, dynamic>?) ?? const <String, dynamic>{},
    );
    final oldBucket =
        '${existingMap['source_pdf_storage_bucket'] ?? ''}'.trim();
    final oldPath = '${existingMap['source_pdf_storage_path'] ?? ''}'.trim();

    final row = await _client
        .from('pb_documents')
        .update({
          'source_pdf_storage_bucket': '',
          'source_pdf_storage_path': '',
          'source_pdf_filename': '',
          'source_pdf_sha256': '',
          'source_pdf_size_bytes': 0,
          'updated_at': nowIso,
        })
        .eq('academy_id', aid)
        .eq('id', documentId)
        .select('*')
        .single();

    if (oldBucket.isNotEmpty && oldPath.isNotEmpty) {
      try {
        await _client.storage.from(oldBucket).remove([oldPath]);
      } catch (_) {
        // 이전 PDF 정리 실패는 무시한다.
      }
    }

    return ProblemBankDocument.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<ProblemBankManualImportResult> importPastedText({
    required String academyId,
    required String rawText,
    String sourceName = 'manual_paste.txt',
    String curriculumCode = 'rev_2022',
    String sourceTypeCode = 'school_past',
    String courseLabel = '',
    String gradeLabel = '',
    int? examYear,
    String semesterLabel = '',
    String examTermLabel = '',
    String schoolName = '',
    String publisherName = '',
    String materialName = '',
    Map<String, dynamic> classificationDetail = const <String, dynamic>{},
  }) async {
    final aid = academyId.trim();
    if (aid.isEmpty) {
      throw Exception('academy_id가 없습니다.');
    }

    final normalized = _normalizeManualText(rawText);
    if (normalized.isEmpty) {
      throw Exception('붙여넣은 텍스트가 비어 있습니다.');
    }
    final parsed = _parseManualQuestions(normalized);
    if (parsed.isEmpty) {
      throw Exception(
        '문항 시작 패턴을 찾지 못했습니다. '
        '예: "1.", "문항 1", "[... 1 [4.00점]]" 형태를 포함해 주세요.',
      );
    }

    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();
    final bytes = Uint8List.fromList(utf8.encode(normalized));
    final fileLabel =
        sourceName.trim().isEmpty ? 'manual_paste.txt' : sourceName.trim();
    final objectPath = '$aid/${now.millisecondsSinceEpoch}_manual_paste.txt';

    await _client.storage.from('problem-documents').uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(
            cacheControl: '3600',
            contentType: 'text/plain',
            upsert: false,
          ),
        );

    // 수동 붙여넣기 입력도 draft로 저장하며 분류는 확정 업로드 단계에서 채워진다.
    final docRow = await _client
        .from('pb_documents')
        .insert({
          'academy_id': aid,
          'created_by': _client.auth.currentUser?.id,
          'source_filename': fileLabel,
          'source_storage_bucket': 'problem-documents',
          'source_storage_path': objectPath,
          'source_size_bytes': bytes.length,
          'status': 'uploaded',
          ..._buildDraftClassificationColumns(),
          'meta': <String, dynamic>{
            'uploaded_from': 'manager_manual_paste',
            'uploaded_at': nowIso,
          },
        })
        .select('*')
        .single();
    final document = ProblemBankDocument.fromMap(
      Map<String, dynamic>.from(docRow as Map<dynamic, dynamic>),
    );

    final lowConfidenceCount = parsed.where((q) => q.confidence < 0.85).length;
    final extractStatus =
        lowConfidenceCount > 0 ? 'review_required' : 'completed';
    final resultSummary = <String, dynamic>{
      'totalQuestions': parsed.length,
      'lowConfidenceCount': lowConfidenceCount,
      'parseMode': 'manual_paste',
      'sourceLineCount': normalized.split('\n').length,
    };

    final jobRow = await _client
        .from('pb_extract_jobs')
        .insert({
          'academy_id': aid,
          'document_id': document.id,
          'created_by': _client.auth.currentUser?.id,
          'status': extractStatus,
          'retry_count': 0,
          'max_retries': 0,
          'worker_name': 'manual-paste',
          'source_version': 'manager_manual_paste_v1',
          'result_summary': resultSummary,
          'error_code': '',
          'error_message': '',
          'started_at': nowIso,
          'finished_at': nowIso,
        })
        .select('*')
        .single();
    final extractJob = ProblemBankExtractJob.fromMap(
      Map<String, dynamic>.from(jobRow as Map<dynamic, dynamic>),
    );

    final questionRows = parsed.asMap().entries.map((entry) {
      final idx = entry.key;
      final q = entry.value;
      final questionType = q.choices.length >= 2 ? '객관식' : '주관식';
      return <String, dynamic>{
        'academy_id': aid,
        'document_id': document.id,
        'extract_job_id': extractJob.id,
        'source_page': 1,
        'source_order': idx + 1,
        'question_number': q.questionNumber,
        'question_type': questionType,
        'stem': q.stem,
        'choices': q.choices
            .map((c) => <String, dynamic>{'label': c.label, 'text': c.text})
            .toList(growable: false),
        'allow_objective': true,
        'allow_subjective': true,
        'objective_choices': q.choices
            .map((c) => <String, dynamic>{'label': c.label, 'text': c.text})
            .toList(growable: false),
        'objective_answer_key': '',
        'subjective_answer': '',
        'objective_generated': false,
        ..._buildDraftClassificationColumns(),
        'figure_refs': const <String>[],
        'equations': const <Map<String, dynamic>>[],
        'source_anchors': <String, dynamic>{
          'mode': 'manual_paste',
          'line_start': q.lineStart,
          'line_end': q.lineEnd,
        },
        'confidence': q.confidence,
        'flags': <String>[
          'manual_paste',
          if (q.choices.length >= 2) 'choice_detected',
        ],
        'is_checked': false,
        'reviewer_notes': '',
        'meta': <String, dynamic>{
          'manual_input': true,
        },
      };
    }).toList(growable: false);

    if (questionRows.isNotEmpty) {
      await _client.from('pb_questions').insert(questionRows);
    }

    // draft 상태에서는 분류 정보를 저장하지 않는다. 확정 업로드 단계에서 채워진다.
    await _client.from('pb_documents').update({
      'status':
          lowConfidenceCount > 0 ? 'draft_review_required' : 'draft_ready',
      ..._buildDraftClassificationColumns(),
      'meta': <String, dynamic>{
        ...document.meta,
        'extraction': <String, dynamic>{
          ...resultSummary,
          'parser': 'manager_manual_paste_v1',
          'processed_at': nowIso,
          'file_name': fileLabel,
        },
      },
      'updated_at': nowIso,
    }).eq('id', document.id);

    return ProblemBankManualImportResult(
      document: document,
      extractJob: extractJob,
      questionCount: parsed.length,
    );
  }

  Future<List<ProblemBankDocument>> listRecentDocuments({
    required String academyId,
    int limit = 50,
  }) async {
    final rows = await _client
        .from('pb_documents')
        .select('*')
        .eq('academy_id', academyId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List<dynamic>)
        .map((e) => ProblemBankDocument.fromMap(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
            ))
        .toList(growable: false);
  }

  Future<List<ProblemBankDocument>> searchDocuments({
    required String academyId,
    String? curriculumCode,
    String? sourceTypeCode,
    String? gradeLabel,
    int? examYear,
    String? schoolName,
    int limit = 120,
  }) async {
    final safeLimit = limit.clamp(1, 400);
    var q =
        _client.from('pb_documents').select('*').eq('academy_id', academyId);
    final safeCurriculum = _normalizeCurriculumCode(curriculumCode);
    final safeSourceType = _normalizeSourceTypeCode(sourceTypeCode);
    final safeGrade = (gradeLabel ?? '').trim();
    final safeSchool = (schoolName ?? '').trim();
    final safeYear = _normalizeExamYear(examYear);
    if ((curriculumCode ?? '').trim().isNotEmpty) {
      q = q.eq('curriculum_code', safeCurriculum);
    }
    if ((sourceTypeCode ?? '').trim().isNotEmpty) {
      q = q.eq('source_type_code', safeSourceType);
    }
    if (safeGrade.isNotEmpty) {
      q = q.ilike('grade_label', '%$safeGrade%');
    }
    if (safeSchool.isNotEmpty) {
      q = q.ilike('school_name', '%$safeSchool%');
    }
    if (safeYear != null) {
      q = q.eq('exam_year', safeYear);
    }
    final rows = await q.order('created_at', ascending: false).limit(safeLimit);
    return (rows as List<dynamic>)
        .map((e) => ProblemBankDocument.fromMap(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
            ))
        .toList(growable: false);
  }

  /// 학습앱의 `listReadyDocuments`와 동일 규칙으로 문서를 조회한다.
  ///
  /// 필터: academy + curriculum + source_type(학습앱 UI 매핑) + status=ready +
  /// 레벨(`초/중/고`)과 세부 과정(`전체` 포함) 매칭 + `meta.saved_settings*` 제외.
  Future<List<ProblemBankDocument>> listSyncedReadyDocuments({
    required String academyId,
    required String curriculumCode,
    required String schoolLevel,
    required String detailedCourse,
    required String sourceTypeCode,
    int limit = 2000,
  }) async {
    final aid = academyId.trim();
    if (aid.isEmpty) return const <ProblemBankDocument>[];
    final dbCodes = _syncedSourceTypeCodesForUi(sourceTypeCode);
    if (dbCodes.isEmpty) return const <ProblemBankDocument>[];
    final safeLimit = limit.clamp(1, 4000);
    final rows = await _client
        .from('pb_documents')
        .select('*')
        .eq('academy_id', aid)
        .eq('curriculum_code', curriculumCode)
        .inFilter('source_type_code', dbCodes)
        .eq('status', 'ready')
        .order('updated_at', ascending: false)
        .limit(safeLimit);

    final out = <ProblemBankDocument>[];
    for (final item in (rows as List<dynamic>)) {
      final map = Map<String, dynamic>.from(item as Map<dynamic, dynamic>);
      if (_isSyncedSavedSettingsRow(map)) continue;
      final courseLabel = '${map['course_label'] ?? ''}'.trim();
      final gradeLabel = '${map['grade_label'] ?? ''}'.trim();
      if (!_syncedMatchesLevel(schoolLevel, courseLabel, gradeLabel)) continue;
      if (!_syncedMatchesDetailedCourse(
        detailedCourse,
        courseLabel,
        gradeLabel,
      )) {
        continue;
      }
      out.add(ProblemBankDocument.fromMap(map));
    }
    return out;
  }

  Future<ProblemBankResetResult> resetPipelineData({
    required String academyId,
  }) async {
    final aid = academyId.trim();
    if (aid.isEmpty) {
      throw Exception('academy_id가 없습니다.');
    }

    final docRows = await _client
        .from('pb_documents')
        .select('id,source_storage_bucket,source_storage_path')
        .eq('academy_id', aid);
    final exportRows = await _client
        .from('pb_exports')
        .select('id,output_storage_bucket,output_storage_path')
        .eq('academy_id', aid);
    final questionRows = await _client
        .from('pb_questions')
        .select('id,meta')
        .eq('academy_id', aid);
    final extractRows = await _client
        .from('pb_extract_jobs')
        .select('id')
        .eq('academy_id', aid);
    List<dynamic> figureJobRows = const <dynamic>[];
    try {
      figureJobRows = await _client
          .from('pb_figure_jobs')
          .select('id,output_storage_bucket,output_storage_path')
          .eq('academy_id', aid);
    } catch (_) {
      figureJobRows = const <dynamic>[];
    }

    final storageByBucket = <String, Set<String>>{};
    for (final row in (docRows as List<dynamic>)) {
      final map = _mapFromDynamic(row);
      _collectStoragePath(
        target: storageByBucket,
        bucket: '${map['source_storage_bucket'] ?? ''}',
        path: '${map['source_storage_path'] ?? ''}',
      );
    }
    for (final row in (exportRows as List<dynamic>)) {
      final map = _mapFromDynamic(row);
      _collectStoragePath(
        target: storageByBucket,
        bucket: '${map['output_storage_bucket'] ?? ''}',
        path: '${map['output_storage_path'] ?? ''}',
      );
    }
    for (final row in figureJobRows) {
      final map = _mapFromDynamic(row);
      _collectStoragePath(
        target: storageByBucket,
        bucket: '${map['output_storage_bucket'] ?? ''}',
        path: '${map['output_storage_path'] ?? ''}',
      );
    }
    for (final row in (questionRows as List<dynamic>)) {
      final map = _mapFromDynamic(row);
      final meta = _mapFromDynamic(map['meta']);
      final figureAssets = meta['figure_assets'];
      if (figureAssets is! List) continue;
      for (final item in figureAssets) {
        final asset = _mapFromDynamic(item);
        _collectStoragePath(
          target: storageByBucket,
          bucket: '${asset['bucket'] ?? ''}',
          path: '${asset['path'] ?? ''}',
        );
      }
    }

    var storageObjectCount = 0;
    for (final entry in storageByBucket.entries) {
      final bucket = entry.key.trim();
      if (bucket.isEmpty) continue;
      final paths = entry.value
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
      if (paths.isEmpty) continue;
      for (final chunk in _chunkStrings(paths, 100)) {
        try {
          await _client.storage.from(bucket).remove(chunk);
          storageObjectCount += chunk.length;
        } catch (_) {
          // 스토리지 오브젝트 삭제 실패는 DB 정리를 막지 않는다.
        }
      }
    }

    await _client.from('pb_questions').delete().eq('academy_id', aid);
    await _client.from('pb_extract_jobs').delete().eq('academy_id', aid);
    await _client.from('pb_exports').delete().eq('academy_id', aid);
    try {
      await _client.from('pb_figure_jobs').delete().eq('academy_id', aid);
    } catch (_) {
      // 신규 스키마 미적용 환경에서는 무시한다.
    }
    await _client.from('pb_documents').delete().eq('academy_id', aid);

    return ProblemBankResetResult(
      documentCount: (docRows as List<dynamic>).length,
      extractJobCount: (extractRows as List<dynamic>).length,
      questionCount: (questionRows as List<dynamic>).length,
      exportCount: (exportRows as List<dynamic>).length,
      storageObjectCount: storageObjectCount,
    );
  }

  Future<ProblemBankExtractJob> createExtractJob({
    required String academyId,
    required String documentId,
    List<String> targetQuestionIds = const <String>[],
  }) async {
    final safeTargetQuestionIds = targetQuestionIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final initialSummary = safeTargetQuestionIds.isEmpty
        ? const <String, dynamic>{}
        : <String, dynamic>{
            'partialReextract': true,
            'targetQuestionCount': safeTargetQuestionIds.length,
            'targetQuestionIds': safeTargetQuestionIds,
          };
    if (hasGateway) {
      try {
        final json = await _gatewayPost(
          '/pb/jobs/extract',
          body: {
            'academyId': academyId,
            'documentId': documentId,
            'createdBy': _client.auth.currentUser?.id,
            if (safeTargetQuestionIds.isNotEmpty)
              'targetQuestionIds': safeTargetQuestionIds,
          },
        );
        return ProblemBankExtractJob.fromMap(_mapFromDynamic(json['job']));
      } catch (_) {
        // gateway 실패 시 direct insert fallback
      }
    }

    final row = await _client
        .from('pb_extract_jobs')
        .insert({
          'academy_id': academyId,
          'document_id': documentId,
          'created_by': _client.auth.currentUser?.id,
          'status': 'queued',
          'retry_count': 0,
          'max_retries': 3,
          'worker_name': '',
          'source_version': safeTargetQuestionIds.isEmpty
              ? 'manager_fallback'
              : 'manager_partial_fallback',
          'result_summary': initialSummary,
          'error_code': '',
          'error_message': '',
        })
        .select('*')
        .single();
    await _client.from('pb_documents').update({
      'status': 'extract_queued',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', documentId);
    return ProblemBankExtractJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<ProblemBankExtractJob?> getExtractJob({
    required String academyId,
    required String jobId,
  }) async {
    if (hasGateway) {
      try {
        final json = await _gatewayGet(
          '/pb/jobs/extract/$jobId',
          query: {'academyId': academyId},
        );
        return ProblemBankExtractJob.fromMap(_mapFromDynamic(json['job']));
      } catch (_) {
        // fallback
      }
    }
    final row = await _client
        .from('pb_extract_jobs')
        .select('*')
        .eq('id', jobId)
        .eq('academy_id', academyId)
        .maybeSingle();
    if (row == null) return null;
    return ProblemBankExtractJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<ProblemBankExtractJob?> retryExtractJob({
    required String academyId,
    required String jobId,
  }) async {
    if (hasGateway) {
      final json = await _gatewayPost(
        '/pb/jobs/extract/$jobId/retry',
        body: {'academyId': academyId},
      );
      return ProblemBankExtractJob.fromMap(_mapFromDynamic(json['job']));
    }
    final row = await _client
        .from('pb_extract_jobs')
        .update({
          'status': 'queued',
          'error_code': '',
          'error_message': '',
          'result_summary': <String, dynamic>{},
          'started_at': null,
          'finished_at': null,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', jobId)
        .eq('academy_id', academyId)
        .select('*')
        .maybeSingle();
    if (row == null) return null;
    return ProblemBankExtractJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<ProblemBankFigureJob> createFigureJob({
    required String academyId,
    required String documentId,
    required String questionId,
    bool forceRegenerate = false,
    String? promptText,
    Map<String, dynamic>? options,
  }) async {
    final safePromptText = (promptText ?? '').trim();
    final safeOptions = options == null ? <String, dynamic>{} : {...options};
    if (hasGateway) {
      try {
        final json = await _gatewayPost(
          '/pb/jobs/figure',
          body: {
            'academyId': academyId,
            'documentId': documentId,
            'questionId': questionId,
            'createdBy': _client.auth.currentUser?.id,
            'forceRegenerate': forceRegenerate,
            if (safePromptText.isNotEmpty) 'promptText': safePromptText,
            if (safeOptions.isNotEmpty) 'options': safeOptions,
          },
        );
        return ProblemBankFigureJob.fromMap(_mapFromDynamic(json['job']));
      } catch (_) {
        // gateway 실패 시 fallback
      }
    }

    final row = await _client
        .from('pb_figure_jobs')
        .insert({
          'academy_id': academyId,
          'document_id': documentId,
          'question_id': questionId,
          'created_by': _client.auth.currentUser?.id,
          'status': 'queued',
          'provider': 'gemini',
          'model_name': '',
          'options': safeOptions,
          'prompt_text': safePromptText,
          'worker_name': '',
          'result_summary': <String, dynamic>{},
          'output_storage_bucket': 'problem-previews',
          'output_storage_path': '',
          'error_code': '',
          'error_message': '',
        })
        .select('*')
        .single();
    return ProblemBankFigureJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<ProblemBankFigureJob?> getFigureJob({
    required String academyId,
    required String jobId,
  }) async {
    if (hasGateway) {
      try {
        final json = await _gatewayGet(
          '/pb/jobs/figure/$jobId',
          query: {'academyId': academyId},
        );
        return ProblemBankFigureJob.fromMap(_mapFromDynamic(json['job']));
      } catch (_) {
        // fallback
      }
    }
    final row = await _client
        .from('pb_figure_jobs')
        .select('*')
        .eq('id', jobId)
        .eq('academy_id', academyId)
        .maybeSingle();
    if (row == null) return null;
    return ProblemBankFigureJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<List<ProblemBankFigureJob>> listFigureJobs({
    required String academyId,
    String? documentId,
    String? questionId,
    String? status,
    int limit = 40,
  }) async {
    final safeDocId = (documentId ?? '').trim();
    final safeQuestionId = (questionId ?? '').trim();
    final safeStatus = (status ?? '').trim();
    if (hasGateway) {
      try {
        final query = <String, String>{
          'academyId': academyId,
          'limit': '$limit',
          if (safeDocId.isNotEmpty) 'documentId': safeDocId,
          if (safeQuestionId.isNotEmpty) 'questionId': safeQuestionId,
          if (safeStatus.isNotEmpty) 'status': safeStatus,
        };
        final json = await _gatewayGet('/pb/jobs/figure', query: query);
        final jobs = (json['jobs'] as List<dynamic>? ?? const <dynamic>[])
            .map((e) => ProblemBankFigureJob.fromMap(_mapFromDynamic(e)))
            .toList(growable: false);
        return jobs;
      } catch (_) {
        // fallback
      }
    }

    var q =
        _client.from('pb_figure_jobs').select('*').eq('academy_id', academyId);
    if (safeDocId.isNotEmpty) {
      q = q.eq('document_id', safeDocId);
    }
    if (safeQuestionId.isNotEmpty) {
      q = q.eq('question_id', safeQuestionId);
    }
    if (safeStatus.isNotEmpty) {
      q = q.eq('status', safeStatus);
    }
    final rows = await q.order('created_at', ascending: false).limit(limit);
    return (rows as List<dynamic>)
        .map((e) => ProblemBankFigureJob.fromMap(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
            ))
        .toList(growable: false);
  }

  Future<String> createStorageSignedUrl({
    required String bucket,
    required String path,
    int expiresInSeconds = 3600,
  }) async {
    final safeBucket = bucket.trim();
    final safePath = path.trim();
    if (safeBucket.isEmpty || safePath.isEmpty) return '';
    final signed = await _client.storage
        .from(safeBucket)
        .createSignedUrl(safePath, expiresInSeconds);
    return signed.trim();
  }

  Future<List<ProblemBankQuestion>> listQuestions({
    required String academyId,
    required String documentId,
  }) async {
    final rows = await _client
        .from('pb_questions')
        .select('*')
        .eq('academy_id', academyId)
        .eq('document_id', documentId)
        .order('source_page', ascending: true)
        .order('source_order', ascending: true);
    return (rows as List<dynamic>)
        .map((e) => ProblemBankQuestion.fromMap(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
            ))
        .toList(growable: false);
  }

  Future<List<ProblemBankQuestion>> searchQuestions({
    required String academyId,
    String? documentId,
    String? curriculumCode,
    String? sourceTypeCode,
    String? gradeLabel,
    int? examYear,
    String? schoolName,
    String? questionType,
    int limit = 200,
    int offset = 0,
  }) async {
    final safeLimit = limit.clamp(1, 400);
    final safeOffset = offset < 0 ? 0 : offset;
    final safeDocumentId = (documentId ?? '').trim();
    final safeGrade = (gradeLabel ?? '').trim();
    final safeSchool = (schoolName ?? '').trim();
    final safeQuestionType = (questionType ?? '').trim();
    final safeCurriculum = (curriculumCode ?? '').trim().isEmpty
        ? ''
        : _normalizeCurriculumCode(curriculumCode);
    final safeSourceType = (sourceTypeCode ?? '').trim().isEmpty
        ? ''
        : _normalizeSourceTypeCode(sourceTypeCode);
    final safeYear = _normalizeExamYear(examYear);

    if (hasGateway) {
      try {
        final query = <String, String>{
          'academyId': academyId,
          'limit': '$safeLimit',
          'offset': '$safeOffset',
          if (safeDocumentId.isNotEmpty) 'documentId': safeDocumentId,
          if (safeCurriculum.isNotEmpty) 'curriculumCode': safeCurriculum,
          if (safeSourceType.isNotEmpty) 'sourceTypeCode': safeSourceType,
          if (safeGrade.isNotEmpty) 'gradeLabel': safeGrade,
          if (safeSchool.isNotEmpty) 'schoolName': safeSchool,
          if (safeQuestionType.isNotEmpty) 'questionType': safeQuestionType,
          if (safeYear != null) 'examYear': '$safeYear',
        };
        final json = await _gatewayGet('/pb/questions', query: query);
        final rows = (json['questions'] as List<dynamic>? ?? const <dynamic>[])
            .map((e) => ProblemBankQuestion.fromMap(_mapFromDynamic(e)))
            .toList(growable: false);
        return rows;
      } catch (_) {
        // gateway 실패 시 direct query fallback
      }
    }

    var q =
        _client.from('pb_questions').select('*').eq('academy_id', academyId);
    if (safeDocumentId.isNotEmpty) q = q.eq('document_id', safeDocumentId);
    if (safeCurriculum.isNotEmpty) q = q.eq('curriculum_code', safeCurriculum);
    if (safeSourceType.isNotEmpty) q = q.eq('source_type_code', safeSourceType);
    if (safeGrade.isNotEmpty) q = q.ilike('grade_label', '%$safeGrade%');
    if (safeSchool.isNotEmpty) q = q.ilike('school_name', '%$safeSchool%');
    if (safeQuestionType.isNotEmpty) {
      q = q.eq('question_type', safeQuestionType);
    }
    if (safeYear != null) q = q.eq('exam_year', safeYear);
    final rows = await q
        .order('created_at', ascending: false)
        .range(safeOffset, safeOffset + safeLimit - 1);
    return (rows as List<dynamic>)
        .map((e) => ProblemBankQuestion.fromMap(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
            ))
        .toList(growable: false);
  }

  Future<void> updateDocumentMeta({
    required String documentId,
    required Map<String, dynamic> meta,
    String? status,
    String? curriculumCode,
    String? sourceTypeCode,
    String? courseLabel,
    String? gradeLabel,
    int? examYear,
    String? semesterLabel,
    String? examTermLabel,
    String? schoolName,
    String? publisherName,
    String? materialName,
    Map<String, dynamic>? classificationDetail,
  }) async {
    final payload = <String, dynamic>{
      'meta': meta,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      if (status != null && status.trim().isNotEmpty) 'status': status.trim(),
    };
    if (curriculumCode != null ||
        sourceTypeCode != null ||
        courseLabel != null ||
        gradeLabel != null ||
        examYear != null ||
        semesterLabel != null ||
        examTermLabel != null ||
        schoolName != null ||
        publisherName != null ||
        materialName != null ||
        classificationDetail != null) {
      payload.addAll(
        _buildClassificationColumns(
          curriculumCode: curriculumCode,
          sourceTypeCode: sourceTypeCode,
          courseLabel: courseLabel,
          gradeLabel: gradeLabel,
          examYear: examYear,
          semesterLabel: semesterLabel,
          examTermLabel: examTermLabel,
          schoolName: schoolName,
          publisherName: publisherName,
          materialName: materialName,
          classificationDetail: classificationDetail,
        ),
      );
    }
    await _client.from('pb_documents').update(payload).eq('id', documentId);
  }

  Future<void> updateQuestionsClassificationForDocument({
    required String academyId,
    required String documentId,
    required String curriculumCode,
    required String sourceTypeCode,
    String courseLabel = '',
    String gradeLabel = '',
    int? examYear,
    String semesterLabel = '',
    String examTermLabel = '',
    String schoolName = '',
    String publisherName = '',
    String materialName = '',
    Map<String, dynamic> classificationDetail = const <String, dynamic>{},
  }) async {
    await _client
        .from('pb_questions')
        .update({
          ..._buildClassificationColumns(
            curriculumCode: curriculumCode,
            sourceTypeCode: sourceTypeCode,
            courseLabel: courseLabel,
            gradeLabel: gradeLabel,
            examYear: examYear,
            semesterLabel: semesterLabel,
            examTermLabel: examTermLabel,
            schoolName: schoolName,
            publisherName: publisherName,
            materialName: materialName,
            classificationDetail: classificationDetail,
          ),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('academy_id', academyId)
        .eq('document_id', documentId);
  }

  Future<void> deleteQuestionsForDocument({
    required String academyId,
    required String documentId,
  }) async {
    await _client
        .from('pb_questions')
        .delete()
        .eq('academy_id', academyId)
        .eq('document_id', documentId);
  }

  Future<void> deleteDocument({
    required String academyId,
    required ProblemBankDocument document,
  }) async {
    final sourceBucket = document.sourceStorageBucket.trim();
    final sourcePath = document.sourceStoragePath.trim();
    if (sourceBucket.isNotEmpty && sourcePath.isNotEmpty) {
      try {
        await _client.storage.from(sourceBucket).remove([sourcePath]);
      } catch (_) {
        // 스토리지 삭제 실패는 문서 삭제를 막지 않는다.
      }
    }
    await _client
        .from('pb_documents')
        .delete()
        .eq('academy_id', academyId)
        .eq('id', document.id);
  }

  Future<void> updateQuestionReview({
    required String questionId,
    required bool isChecked,
    String? reviewerNotes,
    String? questionType,
    String? stem,
    List<ProblemBankChoice>? choices,
    bool? allowObjective,
    bool? allowSubjective,
    List<ProblemBankChoice>? objectiveChoices,
    String? objectiveAnswerKey,
    String? subjectiveAnswer,
    bool? objectiveGenerated,
    List<ProblemBankEquation>? equations,
    Map<String, dynamic>? meta,
    String? curriculumCode,
    String? sourceTypeCode,
    String? courseLabel,
    String? gradeLabel,
    int? examYear,
    String? semesterLabel,
    String? examTermLabel,
    String? schoolName,
    String? publisherName,
    String? materialName,
    Map<String, dynamic>? classificationDetail,
  }) async {
    final payload = <String, dynamic>{
      'is_checked': isChecked,
      'reviewed_by': _client.auth.currentUser?.id,
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
      if (reviewerNotes != null) 'reviewer_notes': reviewerNotes,
      if (questionType != null) 'question_type': questionType,
      if (stem != null) 'stem': stem,
      if (choices != null)
        'choices': choices.map((e) => e.toMap()).toList(growable: false),
      if (allowObjective != null) 'allow_objective': allowObjective,
      if (allowSubjective != null) 'allow_subjective': allowSubjective,
      if (objectiveChoices != null)
        'objective_choices':
            objectiveChoices.map((e) => e.toMap()).toList(growable: false),
      if (objectiveAnswerKey != null)
        'objective_answer_key': objectiveAnswerKey,
      if (subjectiveAnswer != null) 'subjective_answer': subjectiveAnswer,
      if (objectiveGenerated != null) 'objective_generated': objectiveGenerated,
      if (equations != null)
        'equations': equations.map((e) => e.toMap()).toList(growable: false),
      if (meta != null) 'meta': meta,
    };
    if (curriculumCode != null ||
        sourceTypeCode != null ||
        courseLabel != null ||
        gradeLabel != null ||
        examYear != null ||
        semesterLabel != null ||
        examTermLabel != null ||
        schoolName != null ||
        publisherName != null ||
        materialName != null ||
        classificationDetail != null) {
      payload.addAll(
        _buildClassificationColumns(
          curriculumCode: curriculumCode,
          sourceTypeCode: sourceTypeCode,
          courseLabel: courseLabel,
          gradeLabel: gradeLabel,
          examYear: examYear,
          semesterLabel: semesterLabel,
          examTermLabel: examTermLabel,
          schoolName: schoolName,
          publisherName: publisherName,
          materialName: materialName,
          classificationDetail: classificationDetail,
        ),
      );
    }
    await _client.from('pb_questions').update(payload).eq('id', questionId);
  }

  /// 특정 문항에 대해 가장 최근 revision 한 건을 조회.
  ///
  /// `pb_questions` UPDATE 직후 DB trigger 가 revision 을 찍기 때문에, 저장 후
  /// 바로 호출하면 방금 적립된 revision 이 반환된다. 의미 있는 필드 변경이 없는
  /// UPDATE 였다면 (예: is_checked 토글만) trigger 가 적립을 건너뛰므로 null 이
  /// 반환될 수 있다 — 호출 측은 null 케이스를 자연스레 허용하면 됨.
  Future<ProblemBankQuestionRevision?> fetchLatestQuestionRevision({
    required String academyId,
    required String questionId,
  }) async {
    final rows = await _client
        .from('pb_question_revisions')
        .select(
            'id,academy_id,document_id,question_id,engine,engine_model,'
            'revised_at,edited_fields,reason_tags,reason_note,diff')
        .eq('academy_id', academyId)
        .eq('question_id', questionId)
        .order('revised_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    return ProblemBankQuestionRevision.fromMap(
      Map<String, dynamic>.from(rows.first),
    );
  }

  /// 이미 적립된 revision 에 수정 의도 태그와 메모를 덧붙인다.
  ///
  /// DB 의 immutable guard trigger 가 before/after 스냅샷·diff·엔진 정보는
  /// 변경되지 않도록 보호하므로, 이 호출은 안전하게 `reason_tags` / `reason_note`
  /// 두 필드만 업데이트한다.
  Future<void> attachRevisionReason({
    required String revisionId,
    required List<ProblemBankRevisionReasonTag> tags,
    String note = '',
  }) async {
    await _client
        .from('pb_question_revisions')
        .update({
          'reason_tags': tags.map((t) => t.key).toList(growable: false),
          'reason_note': note,
        })
        .eq('id', revisionId);
  }

  Future<void> updateQuestionMeta({
    required String questionId,
    required Map<String, dynamic> meta,
  }) async {
    await _client
        .from('pb_questions')
        .update({'meta': meta}).eq('id', questionId);
  }

  Future<void> bulkSetChecked({
    required String academyId,
    required String documentId,
    required bool isChecked,
  }) async {
    await _client
        .from('pb_questions')
        .update({
          'is_checked': isChecked,
          'reviewed_by': _client.auth.currentUser?.id,
          'reviewed_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('academy_id', academyId)
        .eq('document_id', documentId);
  }

  Future<ProblemBankDocumentSummary?> loadDocumentSummary({
    required String academyId,
    required String documentId,
  }) async {
    if (hasGateway) {
      try {
        final json = await _gatewayGet(
          '/pb/documents/summary',
          query: {
            'academyId': academyId,
            'documentId': documentId,
          },
        );
        final summary = _mapFromDynamic(json['summary']);
        final docMap = _mapFromDynamic(summary['document']);
        if (docMap.isEmpty) return null;
        return ProblemBankDocumentSummary(
          document: ProblemBankDocument.fromMap(docMap),
          latestExtractJob: summary['latestExtractJob'] == null
              ? null
              : ProblemBankExtractJob.fromMap(
                  _mapFromDynamic(summary['latestExtractJob']),
                ),
          latestExportJob: summary['latestExportJob'] == null
              ? null
              : ProblemBankExportJob.fromMap(
                  _mapFromDynamic(summary['latestExportJob']),
                ),
          questionCount: _intOrZero(summary['questionCount']),
        );
      } catch (_) {
        // fallback
      }
    }

    final docs = await _client
        .from('pb_documents')
        .select('*')
        .eq('academy_id', academyId)
        .eq('id', documentId)
        .limit(1);
    if ((docs as List).isEmpty) return null;
    final doc = ProblemBankDocument.fromMap(
      Map<String, dynamic>.from(docs.first as Map<dynamic, dynamic>),
    );
    final extractRows = await _client
        .from('pb_extract_jobs')
        .select('*')
        .eq('academy_id', academyId)
        .eq('document_id', documentId)
        .order('created_at', ascending: false)
        .limit(1);
    final exportRows = await _client
        .from('pb_exports')
        .select('*')
        .eq('academy_id', academyId)
        .eq('document_id', documentId)
        .order('created_at', ascending: false)
        .limit(1);
    final questionRows = await _client
        .from('pb_questions')
        .select('id')
        .eq('academy_id', academyId)
        .eq('document_id', documentId);
    return ProblemBankDocumentSummary(
      document: doc,
      latestExtractJob: (extractRows as List).isEmpty
          ? null
          : ProblemBankExtractJob.fromMap(
              Map<String, dynamic>.from(
                extractRows.first as Map<dynamic, dynamic>,
              ),
            ),
      latestExportJob: (exportRows as List).isEmpty
          ? null
          : ProblemBankExportJob.fromMap(
              Map<String, dynamic>.from(
                exportRows.first as Map<dynamic, dynamic>,
              ),
            ),
      questionCount: (questionRows as List).length,
    );
  }

  String _normalizeManualText(String value) {
    return value
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u3000', ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  List<_ManualQuestionDraft> _parseManualQuestions(String raw) {
    final lines = _normalizeManualText(raw)
        .split('\n')
        .map(_normalizeManualText)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final out = <_ManualQuestionDraft>[];
    _ManualQuestionDraftBuilder? current;

    void flush() {
      final q = current;
      if (q == null) return;
      final stem = _normalizeManualText(q.stemLines.join('\n'));
      if (stem.isEmpty) {
        current = null;
        return;
      }
      final hasChoices = q.choices.length >= 2;
      var confidence = hasChoices ? 0.88 : 0.74;
      if (stem.length < 12) confidence -= 0.14;
      out.add(
        _ManualQuestionDraft(
          questionNumber: q.questionNumber,
          stem: stem,
          choices: q.choices,
          confidence: (confidence.clamp(0.05, 0.99) as num).toDouble(),
          lineStart: q.lineStart,
          lineEnd: q.lineEnd,
        ),
      );
      current = null;
    }

    for (var i = 0; i < lines.length; i += 1) {
      final line = lines[i];
      final start = _parseManualQuestionStart(line);
      if (start != null) {
        flush();
        current = _ManualQuestionDraftBuilder(
          questionNumber: start.number,
          stemLines: <String>[
            if (start.rest.isNotEmpty) start.rest,
          ],
          choices: <_ManualChoice>[],
          lineStart: i,
          lineEnd: i,
        );
        continue;
      }
      final currentQ = current;
      if (currentQ == null) continue;
      currentQ.lineEnd = i;

      final inlineChoices = _parseManualInlineChoices(line);
      if (inlineChoices.length >= 2) {
        currentQ.choices.addAll(inlineChoices);
        continue;
      }

      final choice = _parseManualChoiceLine(line);
      if (choice != null) {
        currentQ.choices.add(choice);
        continue;
      }

      currentQ.stemLines.add(line);
    }

    flush();
    return out;
  }

  _ManualQuestionStart? _parseManualQuestionStart(String line) {
    final input = _normalizeManualText(
      line
          .replaceAll('．', '.')
          .replaceAll('。', '.')
          .replaceAll('﹒', '.')
          .replaceAll('︒', '.'),
    );
    if (input.isEmpty) return null;

    final m1 = RegExp(r'^(\d{1,3})\s*[\.\)]\s*(.+)?$').firstMatch(input);
    if (m1 != null) {
      return _ManualQuestionStart(
        number: m1.group(1) ?? '',
        rest: _normalizeManualText(m1.group(2) ?? ''),
      );
    }

    final m2 = RegExp(r'^문항\s*(\d{1,3})\s*[:.]?\s*(.+)?$').firstMatch(input);
    if (m2 != null) {
      return _ManualQuestionStart(
        number: m2.group(1) ?? '',
        rest: _normalizeManualText(m2.group(2) ?? ''),
      );
    }

    final m3 =
        RegExp(r'(\d{1,3})\s*\[\s*\d+(?:\.\d+)?\s*점\s*\]').firstMatch(input);
    if (m3 != null) {
      return _ManualQuestionStart(
        number: m3.group(1) ?? '',
        rest: '',
      );
    }

    return null;
  }

  _ManualChoice? _parseManualChoiceLine(String line) {
    final input = _normalizeManualText(line);
    if (input.isEmpty) return null;

    final circled = RegExp(r'^([①②③④⑤⑥⑦⑧⑨⑩])\s*(.+)?$').firstMatch(input);
    if (circled != null) {
      return _ManualChoice(
        label: circled.group(1) ?? '',
        text: _normalizeManualText(circled.group(2) ?? ''),
      );
    }

    final numeric =
        RegExp(r'^\(?([1-5])\)?\s*[\.\)]\s*(.+)?$').firstMatch(input);
    if (numeric != null) {
      return _ManualChoice(
        label: numeric.group(1) ?? '',
        text: _normalizeManualText(numeric.group(2) ?? ''),
      );
    }
    return null;
  }

  List<_ManualChoice> _parseManualInlineChoices(String line) {
    final input = _normalizeManualText(line);
    if (input.isEmpty) return const <_ManualChoice>[];
    final regex =
        RegExp(r'([①②③④⑤⑥⑦⑧⑨⑩])\s*([^①②③④⑤⑥⑦⑧⑨⑩]*)(?=[①②③④⑤⑥⑦⑧⑨⑩]|$)');
    final out = <_ManualChoice>[];
    for (final match in regex.allMatches(input)) {
      out.add(
        _ManualChoice(
          label: match.group(1) ?? '',
          text: _normalizeManualText(match.group(2) ?? ''),
        ),
      );
    }
    return out;
  }

  Future<ProblemBankDocument?> _findReusableDraftDocumentByHash({
    required String academyId,
    required String sourceSha256,
  }) async {
    final safeHash = sourceSha256.trim().toLowerCase();
    if (academyId.trim().isEmpty || safeHash.isEmpty) return null;
    final rows = await _client
        .from('pb_documents')
        .select('*')
        .eq('academy_id', academyId)
        .contains('meta', <String, dynamic>{'source_sha256': safeHash})
        .order('updated_at', ascending: false)
        .limit(40);
    for (final row in (rows as List<dynamic>)) {
      final doc = ProblemBankDocument.fromMap(_mapFromDynamic(row));
      if (!_isPublishedDocumentStatus(doc.status)) {
        return doc;
      }
    }
    return null;
  }

  bool _isPublishedDocumentStatus(String status) {
    return status.trim().toLowerCase() == 'ready';
  }

  Future<void> _cancelActivePipelineJobsForDocument({
    required String academyId,
    required String documentId,
    required String nowIso,
    String reason = 'cancelled',
  }) async {
    final safeReason = reason.trim().isEmpty ? 'cancelled' : reason.trim();
    final safeMessage = safeReason == 'reupload_superseded'
        ? '동일 파일 재업로드로 기존 작업이 취소되었습니다.'
        : safeReason;
    try {
      await _client
          .from('pb_extract_jobs')
          .update({
            'status': 'cancelled',
            'error_code': safeReason,
            'error_message': safeMessage,
            'finished_at': nowIso,
            'updated_at': nowIso,
          })
          .eq('academy_id', academyId)
          .eq('document_id', documentId)
          .inFilter('status', const <String>['queued', 'extracting']);
    } catch (_) {
      // 권한/스키마 차이로 실패할 수 있어 업로드는 계속 진행한다.
    }
    try {
      await _client
          .from('pb_exports')
          .update({
            'status': 'cancelled',
            'error_code': safeReason,
            'error_message': safeMessage,
            'finished_at': nowIso,
            'updated_at': nowIso,
          })
          .eq('academy_id', academyId)
          .eq('document_id', documentId)
          .inFilter('status', const <String>['queued', 'rendering']);
    } catch (_) {
      // 권한/스키마 차이로 실패할 수 있어 업로드는 계속 진행한다.
    }
    try {
      await _client
          .from('pb_figure_jobs')
          .update({
            'status': 'cancelled',
            'error_code': safeReason,
            'error_message': safeMessage,
            'finished_at': nowIso,
            'updated_at': nowIso,
          })
          .eq('academy_id', academyId)
          .eq('document_id', documentId)
          .inFilter('status', const <String>['queued', 'rendering']);
    } catch (_) {
      // 신규 스키마 미적용 환경에서는 무시한다.
    }
  }

  String _safeFileName(String input) {
    return _safeFileNameWithExt(input, '.hwpx', fallback: 'document');
  }

  String _safeFileNameWithExt(
    String input,
    String requiredExtension, {
    String fallback = 'document',
  }) {
    final ext = requiredExtension.toLowerCase();
    var sanitized = input.trim();
    if (sanitized.isEmpty) {
      return '$fallback$ext';
    }

    // Supabase Storage object key는 안전한 ASCII 문자만 사용한다.
    sanitized = sanitized
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^[._-]+'), '');

    if (sanitized.isEmpty) {
      sanitized = fallback;
    }
    if (!sanitized.toLowerCase().endsWith(ext)) {
      sanitized = '$sanitized$ext';
    }
    return sanitized;
  }

  void _collectStoragePath({
    required Map<String, Set<String>> target,
    required String bucket,
    required String path,
  }) {
    final b = bucket.trim();
    final p = path.trim();
    if (b.isEmpty || p.isEmpty) return;
    target.putIfAbsent(b, () => <String>{}).add(p);
  }

  Iterable<List<String>> _chunkStrings(List<String> items, int size) sync* {
    if (size <= 0) {
      yield items;
      return;
    }
    for (var i = 0; i < items.length; i += size) {
      final end = (i + size < items.length) ? i + size : items.length;
      yield items.sublist(i, end);
    }
  }

  Map<String, dynamic> _mapFromDynamic(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((k, dynamic v) => MapEntry('$k', v));
    }
    return <String, dynamic>{};
  }

  int _intOrZero(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  Future<Map<String, String>> triggerPreviewScreenshots({
    required String academyId,
    required List<String> questionIds,
    bool force = false,
  }) async {
    if (!hasGateway || questionIds.isEmpty) return {};
    try {
      final result = await _gatewayPost(
        '/pb/preview/questions',
        body: <String, dynamic>{
          'academyId': academyId,
          'questionIds': questionIds,
          if (force) 'force': true,
        },
      );
      final map = <String, String>{};
      final previews = result['previews'];
      if (previews is List) {
        for (final entry in previews) {
          if (entry is! Map) continue;
          final qId = '${entry['questionId'] ?? ''}'.trim();
          final url = '${entry['imageUrl'] ?? ''}'.trim();
          if (qId.isNotEmpty && url.isNotEmpty) map[qId] = url;
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, String>> batchRenderThumbnails({
    required String academyId,
    required List<String> questionIds,
    String documentId = '',
    Map<String, dynamic>? renderConfig,
    String templateProfile = '',
    String paperSize = '',
  }) async {
    if (!hasGateway || questionIds.isEmpty) return {};
    try {
      final body = <String, dynamic>{
        'academyId': academyId,
        'questionIds': questionIds,
        'mathEngine': 'xelatex',
      };
      if (documentId.trim().isNotEmpty) body['documentId'] = documentId.trim();
      if (templateProfile.trim().isNotEmpty) {
        body['templateProfile'] = templateProfile.trim();
      }
      if (paperSize.trim().isNotEmpty) body['paperSize'] = paperSize.trim();
      if (renderConfig != null && renderConfig.isNotEmpty) {
        body['renderConfig'] = renderConfig;
      }

      final result = await _gatewayPost('/pb/preview/batch-render', body: body);
      final thumbnails = result['thumbnails'];
      if (thumbnails is! Map) return {};

      final out = <String, String>{};
      for (final entry in thumbnails.entries) {
        final qid = '${entry.key}'.trim();
        final value = entry.value;
        if (value is Map) {
          final url = '${value['url'] ?? ''}'.trim();
          if (qid.isNotEmpty && url.isNotEmpty) out[qid] = url;
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, ProblemBankPdfPreviewArtifact>>
      fetchQuestionPdfPreviewArtifacts({
    required String academyId,
    required List<String> questionIds,
    String documentId = '',
    Map<String, dynamic>? renderConfig,
    String templateProfile = '',
    String paperSize = '',
    bool createJobs = true,
  }) async {
    if (!hasGateway || questionIds.isEmpty) {
      return <String, ProblemBankPdfPreviewArtifact>{};
    }
    try {
      final body = <String, dynamic>{
        'academyId': academyId,
        'questionIds': questionIds,
        'createJobs': createJobs,
        'mathEngine': 'xelatex',
      };
      if (documentId.trim().isNotEmpty) body['documentId'] = documentId.trim();
      if (templateProfile.trim().isNotEmpty) {
        body['templateProfile'] = templateProfile.trim();
      }
      if (paperSize.trim().isNotEmpty) body['paperSize'] = paperSize.trim();
      if (renderConfig != null && renderConfig.isNotEmpty) {
        body['renderConfig'] = renderConfig;
      }

      final result = await _gatewayPost(
        '/pb/preview/pdf-artifacts',
        body: body,
      );
      final defaultPollAfterMs = _intOrZero(result['pollAfterMs']);
      final artifacts = result['artifacts'];
      if (artifacts is! List) {
        return <String, ProblemBankPdfPreviewArtifact>{};
      }

      final out = <String, ProblemBankPdfPreviewArtifact>{};
      for (final one in artifacts) {
        if (one is! Map) continue;
        final mapped = _mapFromDynamic(one);
        final artifact = ProblemBankPdfPreviewArtifact.fromMap(
          mapped,
          defaultPollAfterMs: defaultPollAfterMs,
        );
        if (artifact.questionId.isEmpty) continue;
        out[artifact.questionId] = artifact;
      }
      return out;
    } catch (_) {
      return <String, ProblemBankPdfPreviewArtifact>{};
    }
  }

  Future<Map<String, String>> fetchQuestionPreviews({
    required String academyId,
    required List<String> questionIds,
    Map<String, dynamic>? layout,
  }) async {
    if (!hasGateway || questionIds.isEmpty) return {};
    try {
      final urlResult = await _gatewayPost(
        '/pb/preview/urls',
        body: <String, dynamic>{
          'academyId': academyId,
          'questionIds': questionIds,
        },
      );

      final map = <String, String>{};
      final missing = <String>[];
      final previews = urlResult['previews'];
      if (previews is List) {
        for (final entry in previews) {
          if (entry is! Map) continue;
          final qId = '${entry['questionId'] ?? ''}'.trim();
          final url = '${entry['imageUrl'] ?? ''}'.trim();
          if (qId.isNotEmpty && url.isNotEmpty) {
            map[qId] = url;
          } else if (qId.isNotEmpty) {
            missing.add(qId);
          }
        }
      }

      if (missing.isNotEmpty) {
        final body = <String, dynamic>{
          'academyId': academyId,
          'questionIds': missing,
        };
        if (layout != null && layout.isNotEmpty) body['layout'] = layout;
        final generated = await _gatewayPost(
          '/pb/preview/questions',
          body: body,
        );
        final generatedPreviews = generated['previews'];
        if (generatedPreviews is List) {
          for (final entry in generatedPreviews) {
            if (entry is! Map) continue;
            final qId = '${entry['questionId'] ?? ''}'.trim();
            final url = '${entry['imageUrl'] ?? ''}'.trim();
            if (qId.isNotEmpty && url.isNotEmpty) {
              map[qId] = url;
            }
          }
        }
      }

      return map;
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, String>> fetchPreviewHtmlBatch({
    required String academyId,
    required List<String> questionIds,
    Map<String, dynamic>? layout,
  }) async {
    if (!hasGateway || questionIds.isEmpty) return {};
    try {
      final body = <String, dynamic>{
        'academyId': academyId,
        'questionIds': questionIds,
      };
      if (layout != null && layout.isNotEmpty) body['layout'] = layout;

      final result = await _gatewayPost('/pb/preview/html', body: body);
      final questions = result['questions'];
      if (questions is! List) return {};

      final map = <String, String>{};
      for (final entry in questions) {
        if (entry is! Map) continue;
        final qId = '${entry['questionId'] ?? ''}'.trim();
        final html = '${entry['html'] ?? ''}'.trim();
        if (qId.isNotEmpty && html.isNotEmpty) map[qId] = html;
      }
      return map;
    } catch (_) {
      return {};
    }
  }
}

/// 학습앱 `pbSourceTypeCodesForLearningUi`와 동일한 매핑.
List<String> _syncedSourceTypeCodesForUi(String uiSourceTypeCode) {
  switch (uiSourceTypeCode.trim()) {
    case 'private_material':
      return const <String>['market_book', 'lecture_book', 'ebs_book'];
    case 'self_made':
      return const <String>['original_item'];
    case '':
      return const <String>[];
    default:
      return <String>[uiSourceTypeCode.trim()];
  }
}

bool _syncedMatchesLevel(String level, String courseLabel, String gradeLabel) {
  final safeLevel = level.trim();
  if (safeLevel.isEmpty || safeLevel == '전체') return true;
  final merged = '$courseLabel $gradeLabel'.replaceAll(' ', '');
  if (merged.isEmpty) return true;
  final hasExplicitLevel =
      merged.contains('초') || merged.contains('중') || merged.contains('고');
  if (!hasExplicitLevel) return true;
  if (safeLevel == '초') return merged.contains('초');
  if (safeLevel == '중') return merged.contains('중');
  if (safeLevel == '고') return merged.contains('고');
  return true;
}

bool _syncedMatchesDetailedCourse(
  String detailedCourse,
  String courseLabel,
  String gradeLabel,
) {
  final selected = detailedCourse.trim();
  if (selected.isEmpty || selected == '전체') return true;
  final merged = '$courseLabel $gradeLabel';
  if (merged.contains(selected)) return true;
  final compactMerged = merged.replaceAll(' ', '');
  final compactSelected = selected.replaceAll(' ', '');
  if (compactMerged.contains(compactSelected)) return true;
  final normalizedSelected =
      compactSelected.replaceAll(RegExp(r'^(초|중|고)'), '');
  if (normalizedSelected.isNotEmpty &&
      compactMerged.contains(normalizedSelected)) {
    return true;
  }
  return false;
}

bool _isSyncedSavedSettingsRow(Map<String, dynamic> row) {
  final raw = row['meta'];
  if (raw is! Map) return false;
  if (raw.isEmpty) return false;
  return raw.containsKey('saved_settings') ||
      raw.containsKey('savedSettings');
}

/// 초/중/고 단계와 학년 숫자를 혼합한 정렬 rank (학습앱 `pbDocumentGradeSortRank`와 동일).
int pbManagerDocumentGradeSortRank(String gradeLabel, String courseLabel) {
  final merged = '$gradeLabel$courseLabel'.replaceAll(RegExp(r'\s'), '');
  var levelBase = 500;
  if (merged.contains('초')) {
    levelBase = 0;
  } else if (merged.contains('중')) {
    levelBase = 100;
  } else if (merged.contains('고')) {
    levelBase = 200;
  }
  final m = RegExp(r'(\d+)').firstMatch(merged);
  final n = m != null ? int.tryParse(m.group(1) ?? '') ?? 50 : 50;
  return levelBase + n;
}

/// 매니저 내부 커리큘럼 키(legacy_1_6 등)를 학습앱 키(legacy_1to6 등)로 맞춤.
String normalizePbCurriculumCodeForSync(String code) {
  final safe = code.trim();
  if (safe.isEmpty) return safe;
  switch (safe) {
    case 'legacy_1_6':
      return 'legacy_1to6';
    case 'curr_7th_1997':
      return 'k7_1997';
    default:
      return safe;
  }
}

class _ManualQuestionStart {
  const _ManualQuestionStart({
    required this.number,
    required this.rest,
  });

  final String number;
  final String rest;
}

class _ManualChoice {
  const _ManualChoice({
    required this.label,
    required this.text,
  });

  final String label;
  final String text;
}

class _ManualQuestionDraftBuilder {
  _ManualQuestionDraftBuilder({
    required this.questionNumber,
    required this.stemLines,
    required this.choices,
    required this.lineStart,
    required this.lineEnd,
  });

  final String questionNumber;
  final List<String> stemLines;
  final List<_ManualChoice> choices;
  final int lineStart;
  int lineEnd;
}

class _ManualQuestionDraft {
  const _ManualQuestionDraft({
    required this.questionNumber,
    required this.stem,
    required this.choices,
    required this.confidence,
    required this.lineStart,
    required this.lineEnd,
  });

  final String questionNumber;
  final String stem;
  final List<_ManualChoice> choices;
  final double confidence;
  final int lineStart;
  final int lineEnd;
}
