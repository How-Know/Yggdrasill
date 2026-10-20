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
    '.xlsx': spreadsheetMime,
  };
  static const String spreadsheetMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  static const String attachmentTypesHint = '이미지(PNG·JPG·WEBP·GIF), PDF, 엑셀(.xlsx)만 첨부할 수 있습니다.';
  static const int maxAttachmentBytes = 20 * 1024 * 1024;

  /// 이 앱이 처리할 수 있는 기능과 버전. 서버가 Edge·DB 버전과 함께 보고 기능 상태를 정한다(권한은 서버가 따로 확인).
  static const Map<String, int> clientFeatures = {
    'conversation_split': 1,
    'think_roles': 1,
    'memory_proposals': 1,
    'department_work': 1,
    'auto_organize': 1,
  };

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
  Future<ThinkStatus> status() async => ThinkStatus.fromJson(await _invoke({
        'action': 'status',
        'client': {'features': clientFeatures},
      }));

  /// Supabase URL에서 프로젝트 식별(비밀값·전체 URL 없음).
  static String? supabaseProjectRef(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.host.isEmpty) return null;
    final host = u.host.toLowerCase();
    if (host.endsWith('.supabase.co')) {
      final ref = host.split('.').first;
      return ref.isEmpty ? null : ref;
    }
    return host;
  }

  static ThinkProbeOutcome _classifyProbeError(Object e) {
    final raw = e is PostgrestException ? '${e.message} ${e.code ?? ''} ${e.details ?? ''}' : e.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('permission') ||
        lower.contains('42501') ||
        lower.contains('forbidden') ||
        lower.contains('row-level security')) {
      return ThinkProbeOutcome.permissionDenied;
    }
    if (lower.contains('does not exist') ||
        lower.contains('42703') ||
        lower.contains('42883') ||
        lower.contains('could not find') ||
        lower.contains('ai_tree_get_document') && lower.contains('function')) {
      return ThinkProbeOutcome.missing;
    }
    if (lower.contains('document_not_found') || lower.contains('tree_node_not_found')) {
      return ThinkProbeOutcome.confirmed;
    }
    if (lower.contains('document_needs_messages') || lower.contains('excerpt_needs_messages')) {
      return ThinkProbeOutcome.confirmed;
    }
    return ThinkProbeOutcome.unknown;
  }

  /// 데이터 생성·수정 없이 종합 문서 관련 스키마·RPC 존재만 probe한다.
  Future<ThinkDocumentProbe> probeDocumentCapabilities({String? conversationIdForCreate}) async {
    final detail = <String, String>{};
    var bodyColumn = ThinkProbeOutcome.unknown;
    try {
      await _db.from('ai_tree_nodes').select('body').limit(0);
      bodyColumn = ThinkProbeOutcome.confirmed;
    } catch (e) {
      bodyColumn = _classifyProbeError(e);
      detail['body'] = e is PostgrestException ? e.message : e.toString();
    }

    var getRpc = ThinkProbeOutcome.notRun;
    try {
      await _db.rpc('ai_tree_get_document', params: {'p_node_id': '00000000-0000-0000-0000-000000000001'});
      getRpc = ThinkProbeOutcome.confirmed;
    } catch (e) {
      getRpc = _classifyProbeError(e);
      detail['get_document'] = e is PostgrestException ? e.message : e.toString();
    }

    var createRpc = ThinkProbeOutcome.notRun;
    if (conversationIdForCreate != null && conversationIdForCreate.isNotEmpty) {
      try {
        await _db.rpc('ai_tree_create_document', params: {
          'p_conversation_id': conversationIdForCreate,
          'p_parent_id': null,
          'p_title': 'probe',
          'p_body': '',
          'p_message_ids': <String>[],
        });
        createRpc = ThinkProbeOutcome.partial;
        detail['create'] = '빈 출처 없이 성공 — 생성 경로는 추가 확인 필요';
      } catch (e) {
        createRpc = _classifyProbeError(e);
        detail['create'] = e is PostgrestException ? e.message : e.toString();
      }
    }
    return ThinkDocumentProbe(bodyColumn: bodyColumn, getDocumentRpc: getRpc, createRpc: createRpc, detail: detail);
  }

  // ---------------------------------------------------------------- 대화
  /// origin 열은 커서 문의 마이그레이션 뒤에만 있다. 없으면 빼고 다시 읽어 모두 운영자 대화로 본다.
  Future<List<ThinkConversation>> listConversations({bool archived = false}) async {
    Future<List<Map<String, dynamic>>> load(String columns) => _db
        .from('ai_conversations')
        .select(columns)
        .eq('status', archived ? 'archived' : 'active')
        .order('last_message_at', ascending: false, nullsFirst: false)
        .order('created_at', ascending: false)
        .limit(300);
    const base = 'id,title,status,message_count,last_message_at,created_at';
    List<Map<String, dynamic>> rows;
    try {
      rows = await load('$base,origin,think_role_id');
    } on PostgrestException catch (e) {
      if (e.code != '42703' && !e.message.contains('think_role_id') && !e.message.contains('origin')) rethrow;
      try {
        rows = await load('$base,origin');
      } on PostgrestException catch (e2) {
        if (e2.code != '42703' && !e2.message.contains('origin')) rethrow;
        rows = await load(base);
      }
    }
    return rows.map(ThinkConversation.fromRow).toList();
  }

  Future<void> renameConversation(String id, String title) =>
      _db.from('ai_conversations').update({'title': title.trim()}).eq('id', id);

  Future<void> setConversationArchived(String id, bool archived) =>
      _db.from('ai_conversations').update({'status': archived ? 'archived' : 'active'}).eq('id', id);

  /// 대화와 메시지, 대화에 올린 첨부 파일을 지운다. 나눈 대화처럼 다른 대화가 같은 파일을 가리키면 파일은 남긴다.
  /// 호출 기록(ai_runs)은 남는다.
  Future<void> deleteConversation(String id) async {
    final rows = await _db.from('ai_messages').select('attachments').eq('conversation_id', id);
    final paths = <String>{
      for (final r in rows)
        for (final a in (r['attachments'] is List ? r['attachments'] as List : const []))
          if (a is Map && a['path'] is String) a['path'] as String,
    };
    final removable = paths.isEmpty ? const <String>[] : await _attachmentsOnlyIn(id, paths);
    if (removable.isNotEmpty) {
      try {
        await _db.storage.from(attachmentBucket).remove(removable);
      } catch (_) {}
    }
    await _db.from('ai_conversations').delete().eq('id', id);
  }

  /// [paths] 중 다른 대화가 가리키지 않는 파일. 확인하지 못하면 하나도 지우지 않는다(깨진 첨부보다 남은 파일이 낫다).
  Future<List<String>> _attachmentsOnlyIn(String conversationId, Set<String> paths) async {
    try {
      final res = await _db.rpc('ai_attachment_paths_in_use', params: {
        'p_paths': paths.toList(),
        'p_except_conversation_id': conversationId,
      });
      final inUse = {for (final p in (res is List ? res : const [])) p.toString()};
      return paths.where((p) => !inUse.contains(p)).toList();
    } on PostgrestException catch (e) {
      // 나누기 마이그레이션 전에는 복사한 메시지가 있을 수 없다.
      if (_isMissingFunction(e)) return paths.toList();
      return const [];
    } catch (_) {
      return const [];
    }
  }

  static bool _isMissingFunction(PostgrestException e) =>
      e.code == 'PGRST202' || e.code == '42883' || e.message.contains('Could not find the function');

  /// 열 이름을 고정하지 않는다. 나누기 마이그레이션 전 DB에는 source_message_id가 없다.
  Future<List<ThinkMessage>> listMessages(String conversationId) async {
    final rows = await _db
        .from('ai_messages')
        .select()
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .limit(1000);
    return rows.map(ThinkMessage.fromRow).toList();
  }

  /// 대화 하나(개념 탭 연결 확인). 지웠거나 볼 수 없으면 null. 열 이름을 고정하지 않는다.
  Future<ThinkConversation?> getConversation(String id) async {
    final row = await _db.from('ai_conversations').select().eq('id', id).maybeSingle();
    return row == null ? null : ThinkConversation.fromRow(row);
  }

  /// 나누기 출처·요약·제안 설정. 열 이름을 고정하지 않아 마이그레이션 전 DB에서는 기본값으로 읽힌다.
  Future<ThinkConversationDetail?> getConversationDetail(String id) async {
    final row = await _db.from('ai_conversations').select().eq('id', id).maybeSingle();
    return row == null ? null : ThinkConversationDetail.fromRow(row);
  }

  Future<ThinkConversationRoleSettings?> getConversationRoleSettings(String id) async {
    final row = await _db.from('ai_conversations').select().eq('id', id).maybeSingle();
    return row == null ? null : ThinkConversationRoleSettings.fromRow(row);
  }

  Future<void> setConversationThinkRole({
    required String conversationId,
    required ThinkRoleId role,
    required List<ThinkDepartmentId> extraRefs,
    String? roleProfileVersion,
  }) async {
    await _db.rpc('ai_conversation_set_think_role', params: {
      'p_conversation_id': conversationId,
      'p_think_role_id': role.db,
      'p_extra_ref_departments': extraRefs.map((e) => e.db).toList(),
      'p_role_profile_version': roleProfileVersion ?? kThinkRoleProfileVersion,
    });
  }

  Future<List<String>> listConversationMemoryLinks(String conversationId) async {
    try {
      final rows =
          await _db.from('ai_conversation_memory_links').select('memory_id').eq('conversation_id', conversationId);
      return rows.map((r) => r['memory_id']?.toString() ?? '').where((id) => id.isNotEmpty).toList();
    } on PostgrestException catch (e) {
      if (_isMissingFunction(e) || e.message.contains('ai_conversation_memory_links')) return [];
      rethrow;
    }
  }

  Future<List<String>> listConversationDocumentLinks(String conversationId) async {
    try {
      final rows = await _db
          .from('ai_conversation_document_links')
          .select('document_node_id')
          .eq('conversation_id', conversationId);
      return rows.map((r) => r['document_node_id']?.toString() ?? '').where((id) => id.isNotEmpty).toList();
    } on PostgrestException catch (e) {
      if (_isMissingFunction(e) || e.message.contains('ai_conversation_document_links')) return [];
      rethrow;
    }
  }

  Future<void> linkConversationMemory(String conversationId, String memoryId) async {
    await _db.rpc('ai_conversation_memory_link', params: {
      'p_conversation_id': conversationId,
      'p_memory_id': memoryId,
    });
  }

  Future<void> unlinkConversationMemory(String conversationId, String memoryId) async {
    await _db.rpc('ai_conversation_memory_unlink', params: {
      'p_conversation_id': conversationId,
      'p_memory_id': memoryId,
    });
  }

  Future<void> linkConversationDocument(String conversationId, String documentNodeId) async {
    await _db.rpc('ai_conversation_document_link', params: {
      'p_conversation_id': conversationId,
      'p_document_node_id': documentNodeId,
    });
  }

  Future<void> unlinkConversationDocument(String conversationId, String documentNodeId) async {
    await _db.rpc('ai_conversation_document_unlink', params: {
      'p_conversation_id': conversationId,
      'p_document_node_id': documentNodeId,
    });
  }

  Future<Map<String, ThinkMessageContextSnapshot>> listMessageSnapshots(Iterable<String> messageIds) async {
    final ids = messageIds.where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return {};
    try {
      final rows = await _db.from('ai_message_context_snapshots').select().inFilter('message_id', ids);
      return {
        for (final r in rows)
          (r['message_id']?.toString() ?? ''): ThinkMessageContextSnapshot.fromRow(Map<String, dynamic>.from(r)),
      };
    } on PostgrestException catch (e) {
      if (_isMissingFunction(e) || e.message.contains('ai_message_context_snapshots')) return {};
      rethrow;
    }
  }

  /// 거절로 꺼진 나누기 제안을 다시 켜거나 끈다. 서버는 꺼진 대화에서 Think에 나누기 도구를 주지 않는다.
  Future<void> setSplitSuggestions(String id, bool enabled) =>
      _db.from('ai_conversations').update({'auto_split_suggestions': enabled}).eq('id', id);

  Future<void> setMessagesExcluded(List<String> ids, bool excluded) async {
    if (ids.isEmpty) return;
    await _db.from('ai_messages').update({'context_excluded': excluded}).inFilter('id', ids);
  }

  /// 화면용 중요 표시. AI 맥락이나 원칙에는 영향이 없다.
  Future<void> setMessagesImportant(List<String> ids, bool important) async {
    if (ids.isEmpty) return;
    await _db.from('ai_messages').update({'marked_important': important}).inFilter('id', ids);
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
    'document_needs_messages': '종합 문서에 넣을 메시지를 하나 이상 고르세요.',
    'document_not_found': '종합 문서가 없어졌습니다. 새로고침한 뒤 다시 해 주세요.',
    'document_version_conflict': '다른 곳에서 먼저 수정되었습니다. 새로 불러온 뒤 다시 저장하세요.',
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
    Future<List<Map<String, dynamic>>> load(String extra) => _db
        .from('ai_tree_nodes')
        .select(
          'id,parent_id,kind,title,summary,body,sort_order,conversation_id,created_via,version,created_at,updated_at,$extra'
          'ai_tree_node_sources(message_id,sort_order)',
        )
        .order('sort_order', ascending: true)
        .limit(5000);
    List<Map<String, dynamic>> rows;
    try {
      rows = await load('department,');
    } on PostgrestException catch (e) {
      if (e.code != '42703' && !e.message.contains('department')) rethrow;
      rows = await load('');
    }
    return rows.map(ThinkTreeNode.fromRow).toList();
  }

  /// [department]는 최상위 폴더에만 쓴다(하위 폴더는 DB가 상위 폴더 부서로 정한다). 부서 마이그레이션 전에는 보내지 않는다.
  Future<void> createFolder({
    required String title,
    required String? parentId,
    required int sortOrder,
    ThinkRoleId? department,
  }) =>
      _db.from('ai_tree_nodes').insert({
        'kind': ThinkTreeKind.folder.db,
        'title': title.trim(),
        'parent_id': parentId,
        'sort_order': sortOrder,
        if (department != null && parentId == null) 'department': department.db,
      });

  /// 부서를 넘나드는 옮기기. 옮긴 대화(폴더면 안의 모든 대화)의 역할도 그 부서로 바뀐다. 바뀐 대화 수를 돌려준다.
  Future<int> moveTreeNodeDepartment({
    String? nodeId,
    String? conversationId,
    required String? parentId,
    required int index,
    required ThinkRoleId department,
  }) async {
    final res = await _db.rpc('ai_tree_move_department', params: {
      'p_node_id': nodeId,
      'p_conversation_id': conversationId,
      'p_parent_id': parentId,
      'p_index': index,
      'p_department': department.db,
    });
    return res is Map ? (res['roles_changed'] as num?)?.toInt() ?? 0 : 0;
  }

  /// 대화를 [department]의 미분류로 옮긴다(역할 변경 + 트리에서 빼기).
  Future<void> moveConversationDepartment(String conversationId, ThinkRoleId department) => _db.rpc(
        'ai_conversation_move_department',
        params: {'p_conversation_id': conversationId, 'p_department': department.db},
      );

  /// 대기 중인 제안이 있는 대화와 개수. 트리의 부서 캐릭터가 "승인 대기"를 보여 줄 때 쓴다.
  Future<Map<String, int>> pendingActionCounts() async {
    final rows = await _db.from('ai_actions').select('conversation_id').eq('status', 'proposed').limit(1000);
    final out = <String, int>{};
    for (final r in rows) {
      final id = r['conversation_id'];
      if (id is String) out[id] = (out[id] ?? 0) + 1;
    }
    return out;
  }

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

  Future<String> createDocument({
    required String conversationId,
    required String? parentId,
    required String title,
    required String body,
    required List<String> messageIds,
  }) async {
    final id = await _db.rpc('ai_tree_create_document', params: {
      'p_conversation_id': conversationId,
      'p_parent_id': parentId,
      'p_title': title.trim(),
      'p_body': body.trim(),
      'p_message_ids': messageIds,
    });
    return id?.toString() ?? '';
  }

  Future<ThinkDocumentDetail> getDocument(String nodeId) async {
    final rows = await _db.rpc('ai_tree_get_document', params: {'p_node_id': nodeId});
    if (rows is List && rows.isNotEmpty && rows.first is Map) {
      return ThinkDocumentDetail.fromRow(Map<String, dynamic>.from(rows.first as Map));
    }
    if (rows is Map) return ThinkDocumentDetail.fromRow(Map<String, dynamic>.from(rows));
    throw ThinkApiException('invalid_response', '종합 문서를 불러오지 못했습니다.');
  }

  Future<ThinkTreeNode> updateDocument({
    required String nodeId,
    required int expectedVersion,
    required String title,
    required String body,
  }) async {
    final row = await _db.rpc('ai_tree_update_document', params: {
      'p_node_id': nodeId,
      'p_title': title.trim(),
      'p_body': body.trim(),
      'p_expected_version': expectedVersion,
    });
    if (row is Map) return ThinkTreeNode.fromRow(Map<String, dynamic>.from(row));
    throw ThinkApiException('invalid_response', '종합 문서를 저장하지 못했습니다.');
  }

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
      throw ThinkApiException('attachment_type_invalid', attachmentTypesHint);
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

  /// downloadName을 주면 브라우저가 열지 않고 그 이름으로 내려받는다(Storage의 download 쿼리).
  Future<String> signedAttachmentUrl(String path, {String? downloadName}) async {
    final url = await _db.storage.from(attachmentBucket).createSignedUrl(path, 600);
    if (downloadName == null || downloadName.isEmpty) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}download=${Uri.encodeQueryComponent(downloadName)}';
  }

  // ---------------------------------------------------------------- 채팅(SSE)
  /// [conceptId]·[criterionId]는 개념 탭이 고른 개념·정리 기준의 id만 대화 id와 따로 보낸다. 본문·고치는 중인
  /// 내용은 보내지 않는다(서버가 보낼 때마다 저장본을 다시 읽는다).
  /// [statementId]는 그 개념에서 고른 서술의 id다. 없으면 기본 서술(개념 본문)이다.
  /// [draftId]는 개념 초안 검토 창의 초안 id. 새 대화(첫 질문)에도 보낸다(서버가 교육 부서·고정 제목으로 만든다).
  static Map<String, dynamic> chatRequestBody({
    required String? conversationId,
    required String message,
    required List<ThinkAttachment> attachments,
    required bool deep,
    required bool webSearch,
    ThinkRoleId? newConversationRole,
    List<ThinkDepartmentId> newConversationRefs = const [],
    String? conceptId,
    String? statementId,
    String? criterionId,
    String? draftId,
  }) =>
      {
        'action': 'chat',
        'conversation_id': conversationId,
        'message': message,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'options': {'deep': deep, 'web_search': webSearch},
        if (conversationId == null && newConversationRole != null)
          'role': {
            'think_role_id': newConversationRole.db,
            'extra_ref_departments': newConversationRefs.map((d) => d.db).toList(),
          },
        if (conversationId != null && conceptId != null) 'concept_id': conceptId,
        if (conversationId != null && conceptId != null && statementId != null) 'statement_id': statementId,
        if (conversationId != null && criterionId != null) 'criterion_id': criterionId,
        if (draftId != null) 'draft_id': draftId,
        'client': {'features': clientFeatures},
      };

  Future<ThinkChatStream> openChat({
    required String? conversationId,
    required String message,
    required List<ThinkAttachment> attachments,
    required bool deep,
    required bool webSearch,
    ThinkRoleId? newConversationRole,
    List<ThinkDepartmentId> newConversationRefs = const [],
    String? conceptId,
    String? statementId,
    String? criterionId,
    String? draftId,
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
      ..body = jsonEncode(chatRequestBody(
        conversationId: conversationId,
        message: message,
        attachments: attachments,
        deep: deep,
        webSearch: webSearch,
        newConversationRole: newConversationRole,
        newConversationRefs: newConversationRefs,
        conceptId: conceptId,
        statementId: statementId,
        criterionId: criterionId,
        draftId: draftId,
      ));

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
  Future<ThinkMemoryFeedbackDraftResult> memoryFeedbackDraft({
    required String conversationId,
    required String assistantMessageId,
    required List<String> userMessageIds,
    required String feedback,
    String? updateMemoryId,
  }) async {
    final res = await _invoke({
      'action': 'memory_feedback_draft',
      'conversation_id': conversationId,
      'assistant_message_id': assistantMessageId,
      'user_message_ids': userMessageIds,
      'feedback': feedback.trim(),
      if (updateMemoryId != null && updateMemoryId.isNotEmpty) 'update_memory_id': updateMemoryId,
    });
    final draft = res['draft'];
    if (draft is! Map) throw ThinkApiException('invalid_response', '초안 형식이 올바르지 않습니다.');
    final baselineRaw = res['update_baseline'];
    ThinkMemoryFeedbackUpdateBaseline? baseline;
    if (baselineRaw is Map) {
      final parsed = ThinkMemoryFeedbackUpdateBaseline.fromJson(Map<String, dynamic>.from(baselineRaw));
      if (parsed.isValid) baseline = parsed;
    }
    return ThinkMemoryFeedbackDraftResult(
      draft: ThinkMemoryFeedbackDraft.fromJson(Map<String, dynamic>.from(draft)),
      updateBaseline: baseline,
    );
  }

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

  Future<ThinkMemory> createMemory(ThinkMemoryDraft draft, {bool withScope = false}) async {
    final row = await _db.from('ai_memories').insert(draft.toRow(withScope: withScope)).select().single();
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
    'code_retry_not_allowed': '끝나지 못한 수정 요청만 다시 보낼 수 있습니다. 새로고침하세요.',
    'ai_code_requests_title_check': '제목을 1~200자로 입력하세요.',
    'ai_code_requests_request_check': '요청 내용이 너무 깁니다. 배경이나 질문을 줄이세요.',
    'code_request_title_required': '제목을 입력하세요.',
    'code_request_not_appliable': '적용할 수 있는 상태가 아닙니다. 새로고침하세요.',
    'code_request_parse_not_ok': '형식 확인이 끝나지 않았거나 확인 필요 상태입니다. diff만 보고 적용할 수 없습니다.',
    'code_request_diff_missing': '저장된 diff가 없습니다. 패치 전문을 확인한 뒤 재생성·재검증하세요.',
    'code_request_no_round': '완료 회차가 없습니다. 새로고침하세요.',
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
    'split_expired': '대화가 이어져 이 제안은 만료됐습니다.',
    'split_answer_pending': '답변 완료 후 나눌 수 있습니다.',
    'split_answer_incomplete': '답변이 끝까지 저장되지 않아(중단·오류) 나눌 수 없습니다.',
    'split_range_invalid': '나눌 메시지를 원본 대화에서 찾지 못했습니다. 새로고침하세요.',
    'split_title_required': '새 대화 제목을 입력하세요.',
    'split_summary_required': '요약의 "목적"을 입력하세요.',
    'action_kind_not_appliable': '승인해서 실행하는 제안이 아닙니다.',
    'action_kind_not_in_batch': '정리 패널에서 승인할 수 없는 제안입니다. 답변 아래 카드에서 처리하세요.',
    'batch_items_invalid': '승인할 항목을 1~20개 고르세요.',
    'handover_same_department': '이미 그 부서가 맡고 있습니다.',
    'place_department_mismatch': '대화가 아직 다른 부서에 있어 이 폴더로 옮길 수 없습니다. 부서 넘기기를 먼저 승인하세요.',
    'memory_card_not_pending': '기억 카드가 이미 처리됐습니다. 새로고침하세요.',
    'memory_supersede_not_active': '바꾸려던 기억이 이미 바뀌었거나 보관됐습니다. 새로고침하세요.',
    'organize_target_not_proposed': '제안에 없던 메시지는 더할 수 없습니다.',
    'organize_targets_invalid': '메시지를 하나 이상 고르세요.',
    'organize_target_missing': '대상 메시지가 없어졌습니다. 새로고침하세요.',
    'organize_too_many': '한 번에 고를 수 있는 메시지 수를 넘었습니다.',
    'summary_purpose_required': '요약의 "목적"을 입력하세요.',
    'progress_summary_changed': '그사이 진행 요약이 바뀌었습니다. 지금 요약을 확인한 뒤 다시 판단하세요.',
    'criteria_changed': '그사이 부서 기준이 바뀌었습니다. 새로고침한 뒤 다시 판단하세요.',
    'criteria_memory_not_allowed': '이 부서가 볼 수 없는 기억은 우선 참고로 넣을 수 없습니다.',
    'criteria_not_found': '부서 기준이 없습니다. 새로고침하세요.',
    'concept_draft_change_stale': '제안한 뒤 그 개념을 고쳤습니다. 지금 내용으로 다시 물어보세요.',
    'concept_draft_closed': '이미 닫힌 초안입니다(확정·버림·다시 정리).',
    'concept_draft_not_found': '초안을 찾지 못했습니다.',
    'concept_draft_review_not_saved': '검토를 한 번 저장해야 바꿀 수 있습니다.',
    'concept_draft_rerun_use_organize': '다시 정리 카드는 개념 초안 검토 창에서 승인하세요.',
    'concept_draft_change_': '지금 검토에 이 변경을 적용할 수 없습니다. 다시 물어보세요.',
    'concept_criteria_stale': '제안한 뒤 기준이 바뀌었습니다. 다시 물어보세요.',
    'concept_criteria_not_found': '기준을 찾지 못했습니다.',
  };

  static String codeErrorMessage(Object e) {
    if (e is ThinkApiException) return e.message;
    final raw = e is PostgrestException ? '${e.message} ${e.details ?? ''}' : e.toString();
    for (final entry in _codeErrors.entries) {
      if (raw.contains(entry.key)) return entry.value;
    }
    return '처리하지 못했습니다: ${e is PostgrestException ? e.message : e}';
  }

  /// 일괄 승인에서 실패한 항목 한 개의 안내.
  static String batchErrorMessage(ThinkBatchItemResult r) {
    final known = _codeErrors[r.code];
    if (known != null) return known;
    final raw = '${r.code ?? ''} ${r.message ?? ''}';
    for (final entry in _codeErrors.entries) {
      if (raw.contains(entry.key)) return entry.value;
    }
    return '처리하지 못했습니다: ${r.message ?? r.code ?? '알 수 없는 오류'}';
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

  Future<ThinkCodeRequest> retryCodeChange(String id) => _codeRpc('ai_code_change_retry', {'p_request_id': id});

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

  /// 승인. [overrides]: 코드 제안은 {title, spec}, 대화 분류는 {folder_id},
  /// 대화 나누기는 {title, summary, folder_id(null이면 미분류)}.
  Future<ThinkAction> applyAction(String id, {Map<String, dynamic> overrides = const {}}) =>
      _actionRpc('ai_action_apply', {'p_id': id, 'p_overrides': overrides});

  /// 개념 초안 변경·기준 고치기 카드 승인. 다시 정리 카드는 ConceptDraftService.rerun(Edge)으로 한다.
  Future<ThinkAction> applyConceptDraftAction(String id) => _actionRpc('concept_draft_action_apply', {'p_id': id});

  Future<ThinkAction> rejectAction(String id) => _actionRpc('ai_action_reject', {'p_id': id});

  /// 조율본 질문에 답하고 다시 조율한다. [answers]: [{id, option_id} 또는 {id, text}]. 새 code_plan 행이 돌아온다.
  Future<ThinkAction> revisePlan(String id, List<Map<String, String>> answers) =>
      _actionRpc('ai_code_plan_revise', {'p_action_id': id, 'p_answers': answers});

  /// 대화 분류·맥락 제외·중요 표시를 되돌릴 수 있다.
  Future<ThinkAction> undoAction(String id) => _actionRpc('ai_action_undo', {'p_id': id});

  /// 정리 패널의 일괄 승인. [items]: [{id, overrides}]. 서버가 정한 순서(부서 넘기기 → 분류 → … → 부서 기준)로
  /// 항목마다 따로 실행해, 실패한 항목만 대기 상태로 남는다. 이미 승인된 항목은 다시 실행하지 않는다.
  Future<List<ThinkBatchItemResult>> applyActionsBatch(List<Map<String, dynamic>> items) async {
    final res = await _db.rpc('ai_action_apply_batch', params: {'p_items': items});
    if (res is! List) throw ThinkApiException('invalid_response', '서버 응답을 해석하지 못했습니다.');
    return res.whereType<Map>().map((m) => ThinkBatchItemResult.fromJson(Map<String, dynamic>.from(m))).toList();
  }

  // ---------------------------------------------------------------- 부서 기준
  /// 자동 정리 마이그레이션 전 DB에서는 빈 목록.
  Future<List<ThinkDepartmentCriteria>> listDepartmentCriteria() async {
    try {
      final rows = await _db.from('ai_department_criteria').select();
      return rows.map(ThinkDepartmentCriteria.fromRow).toList();
    } on PostgrestException catch (e) {
      if (e.code == '42P01' || e.code == 'PGRST205' || e.message.contains('ai_department_criteria')) return const [];
      rethrow;
    }
  }

  /// 운영자가 직접 고친다. [baseVersion]이 지금 판과 다르면 criteria_changed로 막힌다.
  Future<ThinkDepartmentCriteria> saveDepartmentCriteria(
    ThinkRoleId department, {
    required List<String> questions,
    required List<String> risks,
    required List<String> priorityMemoryIds,
    required int baseVersion,
  }) async {
    final res = await _db.rpc('ai_department_criteria_save', params: {
      'p_department': department.db,
      'p_criteria': {'questions': questions, 'risks': risks, 'priority_memory_ids': priorityMemoryIds},
      'p_base_version': baseVersion,
    });
    final row = res is Map ? res : (res is List && res.isNotEmpty && res.first is Map ? res.first as Map : null);
    if (row == null) throw ThinkApiException('invalid_response', '서버 응답을 해석하지 못했습니다.');
    return ThinkDepartmentCriteria.fromRow(Map<String, dynamic>.from(row));
  }

  Future<List<ThinkCodeRound>> listCodeRounds(String requestId) async {
    Future<List<Map<String, dynamic>>> load(String columns) =>
        _db.from('ai_code_request_rounds').select(columns).eq('request_id', requestId).order('round', ascending: true);
    List<Map<String, dynamic>> rows;
    try {
      rows = await load('${ThinkCodeRound.columns},effort');
    } on PostgrestException catch (e) {
      if (e.code != '42703' && !e.message.contains('effort')) rethrow;
      rows = await load(ThinkCodeRound.columns);
    }
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

  /// 자동 정리 제안 켜기·끄기. 꺼도 사용자가 직접 정리를 요청한 답변에서는 Think가 제안한다.
  Future<ThinkSettings> setAutoOrganize(bool enabled) async {
    final row = await _db
        .from('ai_platform_settings')
        .update({'auto_organize_enabled': enabled})
        .eq('id', true)
        .select()
        .single();
    return ThinkSettings.fromRow(row);
  }
}
