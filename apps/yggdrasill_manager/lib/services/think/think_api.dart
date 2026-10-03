import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../auth_service.dart';
import 'think_action_models.dart';
import 'think_code_models.dart';
import 'think_models.dart';

class ThinkApiException implements Exception {
  ThinkApiException(this.code, this.message, {this.status});

  final String code;
  final String message;
  final int? status;

  static const Map<String, String> _messages = {
    'unauthorized': '로그인이 필요합니다.',
    'forbidden': '슈퍼관리자 계정만 사용할 수 있습니다. (app_users.platform_role = superadmin)',
    'ai_not_configured': '서버에 OPENAI_API_KEY 비밀값이 없습니다.',
    'budget_exceeded': '이번 달 AI 사용 한도를 넘었습니다. 사용량 탭에서 한도를 조정하세요.',
    'conflict': '다른 곳에서 먼저 수정되었습니다. 새로 불러온 뒤 다시 저장하세요.',
  };

  factory ThinkApiException.fromBody(int status, dynamic body) {
    Map<String, dynamic>? map;
    if (body is Map) {
      map = Map<String, dynamic>.from(body);
    } else if (body is String && body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) map = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    final code = map?['error']?.toString() ?? 'http_$status';
    final message = _messages[code] ?? map?['message']?.toString() ?? '요청 실패 ($status)';
    return ThinkApiException(code, message, status: status);
  }

  @override
  String toString() => message;
}

class ThinkSseEvent {
  const ThinkSseEvent(this.event, this.data);

  final String event;
  final Map<String, dynamic> data;
}

/// ai_think 채팅 스트림. [cancel]을 부르면 연결을 끊고 서버는 받은 부분까지 '중단됨'으로 저장한다.
class ThinkChatStream {
  ThinkChatStream._(this._client, this.events);

  final http.Client _client;
  final Stream<ThinkSseEvent> events;

  void cancel() => _client.close();
}

class ThinkSseDecoder extends StreamTransformerBase<String, ThinkSseEvent> {
  const ThinkSseDecoder();

  @override
  Stream<ThinkSseEvent> bind(Stream<String> lines) async* {
    String? event;
    final data = StringBuffer();
    await for (final raw in lines) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          try {
            final decoded = jsonDecode(data.toString());
            if (decoded is Map) {
              yield ThinkSseEvent(event ?? 'message', Map<String, dynamic>.from(decoded));
            }
          } catch (_) {}
        }
        event = null;
        data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon == -1 ? line : line.substring(0, colon);
      var value = colon == -1 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') {
        event = value;
      } else if (field == 'data') {
        if (data.isNotEmpty) data.write('\n');
        data.write(value);
      }
    }
  }
}

class ThinkApi {
  ThinkApi._();
  static final ThinkApi instance = ThinkApi._();

  static const String functionName = 'ai_think';
  static const String attachmentBucket = 'ai-attachments';
  static const Map<String, String> attachmentMimeByExt = {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.webp': 'image/webp',
    '.gif': 'image/gif',
    '.pdf': 'application/pdf',
  };
  static const int maxAttachmentBytes = 20 * 1024 * 1024;

  SupabaseClient get _db => Supabase.instance.client;

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    try {
      final res = await _db.functions.invoke(functionName, body: body);
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw ThinkApiException('invalid_response', '서버 응답을 해석하지 못했습니다.');
    } on FunctionException catch (e) {
      throw ThinkApiException.fromBody(e.status, e.details);
    }
  }

  // ---------------------------------------------------------------- 상태
  Future<ThinkStatus> status() async => ThinkStatus.fromJson(await _invoke({'action': 'status'}));

  // ---------------------------------------------------------------- 대화
  Future<List<ThinkConversation>> listConversations({bool archived = false}) async {
    final rows = await _db
        .from('ai_conversations')
        .select('id,title,status,message_count,last_message_at,created_at')
        .eq('status', archived ? 'archived' : 'active')
        .order('last_message_at', ascending: false, nullsFirst: false)
        .order('created_at', ascending: false)
        .limit(300);
    return rows.map(ThinkConversation.fromRow).toList();
  }

  Future<void> renameConversation(String id, String title) =>
      _db.from('ai_conversations').update({'title': title.trim()}).eq('id', id);

  Future<void> setConversationArchived(String id, bool archived) =>
      _db.from('ai_conversations').update({'status': archived ? 'archived' : 'active'}).eq('id', id);

  /// 대화와 메시지, 대화에 올린 첨부 파일을 지운다. 호출 기록(ai_runs)은 남는다.
  Future<void> deleteConversation(String id) async {
    final rows = await _db.from('ai_messages').select('attachments').eq('conversation_id', id);
    final paths = <String>[
      for (final r in rows)
        for (final a in (r['attachments'] is List ? r['attachments'] as List : const []))
          if (a is Map && a['path'] is String) a['path'] as String,
    ];
    if (paths.isNotEmpty) {
      try {
        await _db.storage.from(attachmentBucket).remove(paths);
      } catch (_) {}
    }
    await _db.from('ai_conversations').delete().eq('id', id);
  }

  Future<List<ThinkMessage>> listMessages(String conversationId) async {
    final rows = await _db
        .from('ai_messages')
        .select('id,role,content,status,attachments,sources,tool_calls,commentary,model,created_at,context_excluded')
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .limit(1000);
    return rows.map(ThinkMessage.fromRow).toList();
  }

  Future<void> setMessagesExcluded(List<String> ids, bool excluded) async {
    if (ids.isEmpty) return;
    await _db.from('ai_messages').update({'context_excluded': excluded}).inFilter('id', ids);
  }

  // ---------------------------------------------------------------- 정리 트리
  static const Map<String, String> _treeErrors = {
    'tree_cycle': '폴더를 자기 자신이나 그 안쪽으로 옮길 수 없습니다.',
    'tree_too_deep': '폴더는 12단계까지만 만들 수 있습니다.',
    'tree_parent_not_folder': '폴더 안에만 넣을 수 있습니다.',
    'tree_parent_not_found': '옮길 폴더가 없어졌습니다. 새로고침한 뒤 다시 해 주세요.',
    'tree_node_not_found': '항목이 없어졌습니다. 새로고침한 뒤 다시 해 주세요.',
    'tree_source_invalid': '발췌에는 같은 대화의 메시지만 넣을 수 있습니다.',
    'excerpt_needs_messages': '발췌할 메시지를 하나 이상 고르세요.',
    'ai_tree_nodes_shape': '이름을 입력하세요.',
    'uq_ai_tree_nodes_conversation': '이미 트리에 있는 대화입니다. 새로고침한 뒤 다시 해 주세요.',
  };

  static String treeErrorMessage(Object e) {
    final raw = e is PostgrestException ? e.message : e.toString();
    for (final entry in _treeErrors.entries) {
      if (raw.contains(entry.key)) return entry.value;
    }
    return '처리하지 못했습니다: $raw';
  }

  Future<List<ThinkTreeNode>> listTreeNodes() async {
    final rows = await _db
        .from('ai_tree_nodes')
        .select(
          'id,parent_id,kind,title,summary,sort_order,conversation_id,created_via,version,created_at,updated_at,'
          'ai_tree_node_sources(message_id)',
        )
        .order('sort_order', ascending: true)
        .limit(5000);
    return rows.map(ThinkTreeNode.fromRow).toList();
  }

  Future<void> createFolder({required String title, required String? parentId, required int sortOrder}) =>
      _db.from('ai_tree_nodes').insert({
        'kind': ThinkTreeKind.folder.db,
        'title': title.trim(),
        'parent_id': parentId,
        'sort_order': sortOrder,
      });

  Future<void> updateTreeNode(String id, Map<String, dynamic> patch) =>
      _db.from('ai_tree_nodes').update(patch).eq('id', id);

  /// 폴더가 아닌 노드(대화 배치, 발췌)만 직접 지운다. 폴더는 [deleteFolder].
  Future<void> deleteTreeNode(String id) => _db.from('ai_tree_nodes').delete().eq('id', id);

  Future<void> deleteFolder(String id) => _db.rpc('ai_tree_delete_folder', params: {'p_folder_id': id});

  Future<void> moveTreeNode(String id, String? parentId, int index) =>
      _db.rpc('ai_tree_move', params: {'p_node_id': id, 'p_parent_id': parentId, 'p_index': index});

  Future<void> placeConversation(String conversationId, String? parentId, int index) => _db.rpc(
        'ai_tree_place_conversation',
        params: {'p_conversation_id': conversationId, 'p_parent_id': parentId, 'p_index': index},
      );

  Future<void> createExcerpt({
    required String conversationId,
    required String? parentId,
    required String title,
    required String? summary,
    required List<String> messageIds,
  }) =>
      _db.rpc('ai_tree_create_excerpt', params: {
        'p_conversation_id': conversationId,
        'p_parent_id': parentId,
        'p_title': title.trim(),
        'p_summary': summary,
        'p_message_ids': messageIds,
      });

  Future<double?> conversationCost(String conversationId) async {
    final rows = await _db.from('ai_runs').select('cost_usd').eq('conversation_id', conversationId);
    var sum = 0.0;
    var known = false;
    for (final r in rows) {
      final v = r['cost_usd'];
      if (v is num) {
        sum += v.toDouble();
        known = true;
      }
    }
    return known ? sum : null;
  }

  // ---------------------------------------------------------------- 첨부
  static String? mimeForPath(String path) => attachmentMimeByExt[p.extension(path).toLowerCase()];

  Future<ThinkAttachment> uploadAttachment(File file) async {
    final user = _db.auth.currentUser;
    if (user == null) throw ThinkApiException('unauthorized', '로그인이 필요합니다.');
    final mime = mimeForPath(file.path);
    if (mime == null) {
      throw ThinkApiException('attachment_type_invalid', '이미지(PNG·JPG·WEBP·GIF)와 PDF만 첨부할 수 있습니다.');
    }
    final size = await file.length();
    if (size > maxAttachmentBytes) {
      throw ThinkApiException('attachment_too_large', '파일은 20MB 이하만 첨부할 수 있습니다.');
    }
    final name = p.basename(file.path);
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final now = DateTime.now();
    final month = '${now.year}${now.month.toString().padLeft(2, '0')}';
    final path = '${user.id}/$month/${const Uuid().v4()}-$safe';
    await _db.storage.from(attachmentBucket).upload(path, file, fileOptions: FileOptions(contentType: mime));
    return ThinkAttachment(path: path, name: name, mime: mime, size: size);
  }

  Future<void> removeAttachment(String path) async {
    try {
      await _db.storage.from(attachmentBucket).remove([path]);
    } catch (_) {}
  }

  Future<String> signedAttachmentUrl(String path) => _db.storage.from(attachmentBucket).createSignedUrl(path, 600);

  // ---------------------------------------------------------------- 채팅(SSE)
  Future<ThinkChatStream> openChat({
    required String? conversationId,
    required String message,
    required List<ThinkAttachment> attachments,
    required bool deep,
    required bool webSearch,
  }) async {
    var session = _db.auth.currentSession;
    if (session == null) throw ThinkApiException('unauthorized', '로그인이 필요합니다.');
    final expiresAt = session.expiresAt;
    if (expiresAt != null &&
        DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000).difference(DateTime.now()).inSeconds < 60) {
      session = (await _db.auth.refreshSession()).session ?? session;
    }

    final client = http.Client();
    final request = http.Request('POST', Uri.parse('${AuthService.supabaseUrl}/functions/v1/$functionName'))
      ..headers.addAll({
        'Authorization': 'Bearer ${session.accessToken}',
        'apikey': AuthService.supabaseAnonKey,
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'action': 'chat',
        'conversation_id': conversationId,
        'message': message,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'options': {'deep': deep, 'web_search': webSearch},
      });

    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } catch (e) {
      client.close();
      throw ThinkApiException('network', '서버에 연결하지 못했습니다: $e');
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      client.close();
      throw ThinkApiException.fromBody(response.statusCode, body);
    }
    final events =
        response.stream.transform(utf8.decoder).transform(const LineSplitter()).transform(const ThinkSseDecoder());
    return ThinkChatStream._(client, events);
  }

  // ---------------------------------------------------------------- 결정 초안 / 스펙
  Future<ThinkDecisionDraft> decisionDraft(String conversationId) async {
    final res = await _invoke({'action': 'decision_draft', 'conversation_id': conversationId});
    final draft = res['draft'];
    if (draft is! Map) throw ThinkApiException('invalid_response', '초안 형식이 올바르지 않습니다.');
    return ThinkDecisionDraft.fromJson(Map<String, dynamic>.from(draft));
  }

  Future<({String markdown, String suggestedPath})> specExport(String memoryId) async {
    final res = await _invoke({'action': 'spec_export', 'memory_id': memoryId});
    return (
      markdown: res['markdown']?.toString() ?? '',
      suggestedPath: res['suggested_path']?.toString() ?? 'docs/specs/decision.md',
    );
  }

  // ---------------------------------------------------------------- 기억
  Future<List<ThinkMemory>> listMemories() async {
    final rows = await _db
        .from('ai_memories')
        .select()
        .order('kind', ascending: true)
        .order('sort_order', ascending: true)
        .order('updated_at', ascending: false)
        .limit(1000);
    return rows.map(ThinkMemory.fromRow).toList();
  }

  Future<ThinkMemory> createMemory(ThinkMemoryDraft draft) async {
    final row = await _db.from('ai_memories').insert(draft.toRow()).select().single();
    return ThinkMemory.fromRow(row);
  }

  /// [expectedVersion]이 DB와 다르면(다른 곳에서 먼저 수정) conflict 예외.
  Future<ThinkMemory> updateMemory(String id, int expectedVersion, Map<String, dynamic> patch) async {
    final rows = await _db.from('ai_memories').update(patch).eq('id', id).eq('version', expectedVersion).select();
    if (rows.isEmpty) throw ThinkApiException('conflict', ThinkApiException._messages['conflict']!);
    return ThinkMemory.fromRow(rows.first);
  }

  Future<void> deleteMemory(String id) => _db.from('ai_memories').delete().eq('id', id);

  Future<List<ThinkMemoryRevision>> listRevisions(String memoryId) async {
    final rows = await _db
        .from('ai_memory_revisions')
        .select('version,changed_at,snapshot')
        .eq('memory_id', memoryId)
        .order('version', ascending: false)
        .limit(50);
    return rows.map(ThinkMemoryRevision.fromRow).toList();
  }

  // ---------------------------------------------------------------- 코드 조사 (Think ↔ Cursor)
  static const Map<String, String> _codeErrors = {
    'code_request_daily_limit': '오늘 보낼 수 있는 코드 조사 요청 수를 넘었습니다. 사용량 탭에서 하루 한도를 바꿀 수 있습니다.',
    'code_request_goal_required': '목표를 입력하세요.',
    'code_request_not_draft': '이미 보낸 요청입니다. 새로고침하세요.',
    'code_request_not_cancellable': '이미 끝난 요청이라 취소할 수 없습니다.',
    'code_request_not_decidable': '결과가 도착한 요청에만 판단을 남길 수 있습니다.',
    'code_request_not_found': '요청이 없어졌습니다. 새로고침하세요.',
    'ai_code_requests_title_check': '제목을 1~200자로 입력하세요.',
    'ai_code_requests_request_check': '요청 내용이 너무 깁니다. 배경이나 질문을 줄이세요.',
    'code_request_title_required': '제목을 입력하세요.',
    'code_request_not_appliable': '적용할 수 있는 상태가 아닙니다. 새로고침하세요.',
    'code_request_not_revertable': '되돌릴 수 있는 상태가 아닙니다. 새로고침하세요.',
    'code_request_not_deletable': '진행 중인 요청은 지울 수 없습니다. 먼저 취소하세요.',
    'action_not_pending': '이미 처리된 제안입니다. 새로고침하세요.',
    'action_not_found': '제안이 없어졌습니다. 새로고침하세요.',
    'action_not_undoable': '되돌릴 수 없는 제안입니다.',
    'tree_folder_not_found': '폴더가 없어졌습니다. 다른 폴더를 고르세요.',
    'tree_parent_not_folder': '새 폴더를 만들 상위 폴더가 없어졌습니다.',
    'conversation_not_found': '대화가 이미 없습니다.',
    'plan_answer_missing': '모든 질문에 답해야 반영할 수 있습니다. 직접 입력은 내용을 적어 주세요.',
    'plan_answer_invalid': '보기가 바뀌었습니다. 새로고침한 뒤 다시 골라 주세요.',
    'plan_no_decisions': '이 조율본에는 정할 질문이 없습니다.',
  };

  static String codeErrorMessage(Object e) {
    if (e is ThinkApiException) return e.message;
    final raw = e is PostgrestException ? '${e.message} ${e.details ?? ''}' : e.toString();
    for (final entry in _codeErrors.entries) {
      if (raw.contains(entry.key)) return entry.value;
    }
    return '처리하지 못했습니다: ${e is PostgrestException ? e.message : e}';
  }

  Future<List<ThinkCodeRequest>> listCodeRequests() async {
    final rows = await _db
        .from('ai_code_requests')
        .select(ThinkCodeRequest.columns)
        .order('created_at', ascending: false)
        .limit(200);
    return rows.map(ThinkCodeRequest.fromRow).toList();
  }

  Future<ThinkCodeRequest> createCodeRequest({
    required String title,
    required ThinkCodeSpec spec,
    String? conversationId,
    List<String> sourceMessageIds = const [],
  }) async {
    final row = await _db
        .from('ai_code_requests')
        .insert({
          'title': title.trim(),
          'request': spec.toJson(),
          'conversation_id': conversationId,
          'source_message_ids': sourceMessageIds,
        })
        .select(ThinkCodeRequest.columns)
        .single();
    return ThinkCodeRequest.fromRow(row);
  }

  /// 초안만 고칠 수 있다(RLS). 보낸 요청이면 빈 결과가 돌아온다.
  Future<ThinkCodeRequest> updateCodeDraft(String id, {required String title, required ThinkCodeSpec spec}) async {
    final rows = await _db
        .from('ai_code_requests')
        .update({'title': title.trim(), 'request': spec.toJson()})
        .eq('id', id)
        .select(ThinkCodeRequest.columns);
    if (rows.isEmpty) throw ThinkApiException('code_request_not_draft', _codeErrors['code_request_not_draft']!);
    return ThinkCodeRequest.fromRow(rows.first);
  }

  Future<ThinkCodeRequest> _codeRpc(String fn, Map<String, dynamic> params) async {
    final res = await _db.rpc(fn, params: params);
    if (res is Map) return ThinkCodeRequest.fromRow(Map<String, dynamic>.from(res));
    if (res is List && res.isNotEmpty && res.first is Map) {
      return ThinkCodeRequest.fromRow(Map<String, dynamic>.from(res.first as Map));
    }
    throw ThinkApiException('invalid_response', '서버 응답을 해석하지 못했습니다.');
  }

  Future<ThinkCodeRequest> submitCodeRequest(String id) => _codeRpc('ai_code_request_submit', {'p_id': id});

  Future<ThinkCodeRequest> cancelCodeRequest(String id) => _codeRpc('ai_code_request_cancel', {'p_id': id});

  Future<ThinkCodeRequest> decideCodeRequest(String id, ThinkCodeOutcome? outcome, String? note) =>
      _codeRpc('ai_code_request_decide', {'p_id': id, 'p_outcome': outcome?.db, 'p_note': note});

  Future<void> deleteCodeRequest(String id) => _db.from('ai_code_requests').delete().eq('id', id);

  /// 수정 모드 결과를 작업 폴더에 적용해 달라고 작업자에게 맡긴다. `git apply --check`가 통과해야 적용된다.
  Future<ThinkCodeRequest> applyCodeChange(String id) => _codeRpc('ai_code_request_apply', {'p_id': id});

  Future<ThinkCodeRequest> revertCodeChange(String id) => _codeRpc('ai_code_request_revert', {'p_id': id});

  // ---------------------------------------------------------------- 작업 제안 (AI 제안 → 사람 승인)
  Future<List<ThinkAction>> listActions(String conversationId) async {
    final rows = await _db
        .from('ai_actions')
        .select(ThinkAction.columns)
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .limit(200);
    return rows.map(ThinkAction.fromRow).whereType<ThinkAction>().toList();
  }

  Future<ThinkAction> _actionRpc(String fn, Map<String, dynamic> params) async {
    final res = await _db.rpc(fn, params: params);
    final row = res is Map ? res : (res is List && res.isNotEmpty && res.first is Map ? res.first as Map : null);
    final action = row == null ? null : ThinkAction.fromRow(Map<String, dynamic>.from(row));
    if (action == null) throw ThinkApiException('invalid_response', '서버 응답을 해석하지 못했습니다.');
    return action;
  }

  /// 승인. [overrides]: 코드 제안은 {title, spec}, 대화 분류는 {folder_id}.
  Future<ThinkAction> applyAction(String id, {Map<String, dynamic> overrides = const {}}) =>
      _actionRpc('ai_action_apply', {'p_id': id, 'p_overrides': overrides});

  Future<ThinkAction> rejectAction(String id) => _actionRpc('ai_action_reject', {'p_id': id});

  /// 조율본 질문에 답하고 다시 조율한다. [answers]: [{id, option_id} 또는 {id, text}]. 새 code_plan 행이 돌아온다.
  Future<ThinkAction> revisePlan(String id, List<Map<String, String>> answers) =>
      _actionRpc('ai_code_plan_revise', {'p_action_id': id, 'p_answers': answers});

  /// 대화 분류만 되돌릴 수 있다.
  Future<ThinkAction> undoAction(String id) => _actionRpc('ai_action_undo', {'p_id': id});

  Future<List<ThinkCodeRound>> listCodeRounds(String requestId) async {
    final rows = await _db
        .from('ai_code_request_rounds')
        .select(ThinkCodeRound.columns)
        .eq('request_id', requestId)
        .order('round', ascending: true);
    return rows.map(ThinkCodeRound.fromRow).toList();
  }

  Future<List<ThinkCodeWorker>> listCodeWorkers() async {
    final rows = await _db
        .from('ai_code_workers')
        .select('worker_id,version,model,current_request_id,last_seen_at')
        .order('last_seen_at', ascending: false)
        .limit(10);
    return rows.map(ThinkCodeWorker.fromRow).toList();
  }

  // ---------------------------------------------------------------- 사용량 / 설정
  Future<List<ThinkUsageRow>> usageSummary(DateTime from, DateTime to) async {
    final res = await _db.rpc('ai_usage_summary', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    });
    if (res is! List) return const [];
    return res.whereType<Map>().map((r) => ThinkUsageRow.fromRow(Map<String, dynamic>.from(r))).toList();
  }

  Future<ThinkSettings> settings() async {
    final row = await _db.from('ai_platform_settings').select().eq('id', true).maybeSingle();
    return ThinkSettings.fromRow(row);
  }

  Future<ThinkSettings> updateSettings({
    required double? monthlyBudgetUsd,
    required String budgetMode,
    required bool webSearchEnabled,
    required int codeRequestDailyLimit,
  }) async {
    final row = await _db
        .from('ai_platform_settings')
        .update({
          'monthly_budget_usd': monthlyBudgetUsd,
          'budget_mode': budgetMode,
          'web_search_enabled': webSearchEnabled,
          'code_request_daily_limit': codeRequestDailyLimit,
        })
        .eq('id', true)
        .select()
        .single();
    return ThinkSettings.fromRow(row);
  }
}
