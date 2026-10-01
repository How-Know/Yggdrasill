// Think 채팅의 작업 제안(ai_actions). AI는 제안만 남기고, 실행은 사람이 승인할 때 서버 RPC가 한다.
// 설계: docs/architecture/ai-think-actions.md

enum ThinkActionKind {
  codeRequest('code_request', '코드 조사'),
  codeChange('code_change', '코드 수정'),
  placeConversation('place_conversation', '대화 분류'),
  deleteCodeRequest('delete_code_request', '코드 요청 삭제'),
  deleteFolder('delete_folder', '폴더 삭제'),
  deleteConversation('delete_conversation', '대화 삭제');

  const ThinkActionKind(this.db, this.label);
  final String db;
  final String label;

  static ThinkActionKind? parse(String? raw) {
    for (final k in values) {
      if (k.db == raw) return k;
    }
    return null;
  }

  bool get isCode => this == codeRequest || this == codeChange;
  bool get isDelete => this == deleteCodeRequest || this == deleteFolder || this == deleteConversation;
}

enum ThinkActionStatus {
  proposed('proposed', '승인 대기'),
  applied('applied', '실행함'),
  rejected('rejected', '거절함'),
  failed('failed', '실패'),
  undone('undone', '되돌림');

  const ThinkActionStatus(this.db, this.label);
  final String db;
  final String label;

  static ThinkActionStatus parse(String? raw) =>
      values.firstWhere((s) => s.db == raw, orElse: () => ThinkActionStatus.proposed);
}

String _str(dynamic v) => v == null ? '' : v.toString().trim();

Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

DateTime? _date(dynamic v) => v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;

class ThinkAction {
  const ThinkAction({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.messageId,
    this.payload = const {},
    this.preview = const {},
    this.result,
    this.error,
    this.superseded = false,
    this.decidedAt,
  });

  final String id;
  final String conversationId;

  /// 제안을 낸 답변. 답변이 저장되기 전(스트리밍 중)에는 null이다.
  final String? messageId;
  final ThinkActionKind kind;
  final ThinkActionStatus status;
  final Map<String, dynamic> payload;

  /// 서버가 제안 때 만든 요약. 카드는 이것만 보여 준다(원본 대상은 승인 시 서버가 다시 확인한다).
  final Map<String, dynamic> preview;
  final Map<String, dynamic>? result;
  final String? error;

  /// 같은 대화에서 같은 종류의 새 제안이 나와 닫혔다.
  final bool superseded;
  final DateTime createdAt;
  final DateTime? decidedAt;

  static const String columns =
      'id,conversation_id,message_id,kind,status,payload,preview,result,error,superseded,decided_at,created_at';

  /// 알 수 없는 kind(서버가 먼저 배포된 경우)는 null.
  static ThinkAction? fromRow(Map<String, dynamic> r) {
    final kind = ThinkActionKind.parse(r['kind']?.toString());
    if (kind == null) return null;
    final message = _str(r['message_id']);
    final error = _str(r['error']);
    return ThinkAction(
      id: _str(r['id']),
      conversationId: _str(r['conversation_id']),
      messageId: message.isEmpty ? null : message,
      kind: kind,
      status: ThinkActionStatus.parse(r['status']?.toString()),
      payload: _map(r['payload']),
      preview: _map(r['preview']),
      result: r['result'] is Map ? Map<String, dynamic>.from(r['result'] as Map) : null,
      error: error.isEmpty ? null : error,
      superseded: r['superseded'] == true,
      createdAt: _date(r['created_at']) ?? DateTime.now(),
      decidedAt: _date(r['decided_at']),
    );
  }

  ThinkAction copyWith({String? messageId, ThinkActionStatus? status, bool? superseded}) => ThinkAction(
        id: id,
        conversationId: conversationId,
        messageId: messageId ?? this.messageId,
        kind: kind,
        status: status ?? this.status,
        payload: payload,
        preview: preview,
        result: result,
        error: error,
        superseded: superseded ?? this.superseded,
        createdAt: createdAt,
        decidedAt: decidedAt,
      );

  bool get pending => status == ThinkActionStatus.proposed;

  String get title => _str(preview['title'] ?? payload['title']);

  /// 코드 제안을 승인하면 만들어진 요청.
  String? get codeRequestId {
    final id = _str(result?['code_request_id']);
    return id.isEmpty ? null : id;
  }

  // ---- 대화 분류
  String? get folderId {
    final id = _str(payload['folder_id']);
    return id.isEmpty ? null : id;
  }

  String? get newFolderTitle {
    final t = _str(payload['new_folder_title']);
    return t.isEmpty ? null : t;
  }

  String? get newFolderParentId {
    final id = _str(payload['new_folder_parent_id']);
    return id.isEmpty ? null : id;
  }

  /// 승인 뒤 실제로 넣은 폴더(다른 폴더를 고른 경우 포함).
  String? get placedFolderId {
    final id = _str(result?['folder_id']);
    return id.isEmpty ? null : id;
  }

  // ---- 삭제
  String? get targetId {
    final id = _str(payload['target_id']);
    return id.isEmpty ? null : id;
  }

  bool get deletedSelf => result?['deleted_self'] == true;
}
