import 'dart:convert';
import 'dart:typed_data';

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

class ProblemBankService {
  ProblemBankService({
    SupabaseClient? client,
    http.Client? httpClient,
    String? gatewayBaseUrl,
    String? gatewayApiKey,
  })  : _client = client ?? Supabase.instance.client,
        _http = httpClient ?? http.Client(),
        _gatewayBaseUrl = (gatewayBaseUrl ??
                const String.fromEnvironment('PB_GATEWAY_URL',
                    defaultValue: ''))
            .trim(),
        _gatewayApiKey = (gatewayApiKey ??
                const String.fromEnvironment('PB_GATEWAY_API_KEY',
                    defaultValue: ''))
            .trim();

  final SupabaseClient _client;
  final http.Client _http;
  final String _gatewayBaseUrl;
  final String _gatewayApiKey;

  bool get hasGateway => _gatewayBaseUrl.isNotEmpty;

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
    String examProfile = 'naesin',
    String? academyId,
  }) async {
    final aid = (academyId ?? await resolveAcademyId()).trim();
    if (aid.isEmpty) {
      throw Exception('academy_id가 없습니다.');
    }
    final safeName = _safeFileName(originalName);
    final objectPath =
        '$aid/${DateTime.now().millisecondsSinceEpoch}_$safeName';
    await _client.storage.from('problem-documents').uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(
            cacheControl: '3600',
            contentType: 'application/octet-stream',
            upsert: false,
          ),
        );

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
          'exam_profile': examProfile,
          'meta': <String, dynamic>{
            'uploaded_from': 'manager',
            'uploaded_at': DateTime.now().toUtc().toIso8601String(),
          },
        })
        .select('*')
        .single();
    return ProblemBankDocument.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<ProblemBankManualImportResult> importPastedText({
    required String academyId,
    required String rawText,
    String sourceName = 'manual_paste.txt',
    String examProfile = 'naesin',
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
          'exam_profile': examProfile,
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

    await _client.from('pb_documents').update({
      'status': lowConfidenceCount > 0 ? 'review_required' : 'ready',
      'exam_profile': examProfile,
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
  }) async {
    if (hasGateway) {
      try {
        final json = await _gatewayPost(
          '/pb/jobs/extract',
          body: {
            'academyId': academyId,
            'documentId': documentId,
            'createdBy': _client.auth.currentUser?.id,
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
          'source_version': 'manager_fallback',
          'result_summary': <String, dynamic>{},
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
  }) async {
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

  Future<void> updateQuestionReview({
    required String questionId,
    required bool isChecked,
    String? reviewerNotes,
    String? questionType,
    String? stem,
    List<ProblemBankChoice>? choices,
    List<ProblemBankEquation>? equations,
    Map<String, dynamic>? meta,
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
      if (equations != null)
        'equations': equations.map((e) => e.toMap()).toList(growable: false),
      if (meta != null) 'meta': meta,
    };
    await _client.from('pb_questions').update(payload).eq('id', questionId);
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

  Future<ProblemBankExportJob> createExportJob({
    required String academyId,
    required String documentId,
    required String templateProfile,
    required String paperSize,
    required bool includeAnswerSheet,
    required bool includeExplanation,
    required List<String> selectedQuestionIds,
    Map<String, dynamic> options = const <String, dynamic>{},
  }) async {
    if (hasGateway) {
      final json = await _gatewayPost(
        '/pb/jobs/export',
        body: {
          'academyId': academyId,
          'documentId': documentId,
          'requestedBy': _client.auth.currentUser?.id,
          'templateProfile': templateProfile,
          'paperSize': paperSize,
          'includeAnswerSheet': includeAnswerSheet,
          'includeExplanation': includeExplanation,
          'selectedQuestionIds': selectedQuestionIds,
          'options': options,
        },
      );
      return ProblemBankExportJob.fromMap(_mapFromDynamic(json['job']));
    }

    final row = await _client
        .from('pb_exports')
        .insert({
          'academy_id': academyId,
          'document_id': documentId,
          'requested_by': _client.auth.currentUser?.id,
          'status': 'queued',
          'template_profile': templateProfile,
          'paper_size': paperSize,
          'include_answer_sheet': includeAnswerSheet,
          'include_explanation': includeExplanation,
          'selected_question_ids': selectedQuestionIds,
          'options': options,
          'output_storage_bucket': 'problem-exports',
          'output_storage_path': '',
          'output_url': '',
          'page_count': 0,
          'worker_name': '',
          'error_code': '',
          'error_message': '',
        })
        .select('*')
        .single();
    return ProblemBankExportJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<ProblemBankExportJob?> getExportJob({
    required String academyId,
    required String jobId,
  }) async {
    if (hasGateway) {
      try {
        final json = await _gatewayGet(
          '/pb/jobs/export/$jobId',
          query: {'academyId': academyId},
        );
        return ProblemBankExportJob.fromMap(_mapFromDynamic(json['job']));
      } catch (_) {
        // fallback
      }
    }
    final row = await _client
        .from('pb_exports')
        .select('*')
        .eq('id', jobId)
        .eq('academy_id', academyId)
        .maybeSingle();
    if (row == null) return null;
    return ProblemBankExportJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
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

  String _safeFileName(String input) {
    var sanitized = input.trim();
    if (sanitized.isEmpty) {
      return 'document.hwpx';
    }

    // Supabase Storage object key는 안전한 ASCII 문자만 사용한다.
    sanitized = sanitized
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^[._-]+'), '');

    if (sanitized.isEmpty) {
      sanitized = 'document';
    }
    if (!sanitized.toLowerCase().endsWith('.hwpx')) {
      sanitized = '$sanitized.hwpx';
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
