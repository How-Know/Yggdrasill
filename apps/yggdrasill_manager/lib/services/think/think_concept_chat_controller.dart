import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_menu.dart';
import '../auth_service.dart';
import '../concept_library_service.dart';
import '../concept_service.dart';
import '../concept_statement_store.dart';
import 'think_action_models.dart';
import 'think_api.dart';
import 'think_controller.dart';
import 'think_models.dart';
import 'think_send_lock.dart';

/// 개념 탭이 연결한 대화를 확인한 결과.
enum ConceptChatLink { none, checking, ready, missing, failed }

/// 서버가 이번 답변에서 고른 개념을 어떻게 읽었는지(SSE conversation.context.concept). 본문은 들어 있지 않다.
class ConceptReadInfo {
  const ConceptReadInfo({
    required this.status,
    this.updatedAt,
    this.contentChars,
    this.deliveredChars,
    this.pathComplete,
    this.linksReported = false,
    this.linkedCriteria,
    this.sources,
    this.statementStatus,
    this.statementVersion,
    this.statementHasDraft,
    this.statementDraftSavedAt,
    this.statements,
    this.appearances,
  });

  /// ok · truncated · not_found · error. 옛 Edge라 키가 없으면 unsupported, 서버가 이번 요청에서 읽지 않았으면 skipped.
  final String status;
  final DateTime? updatedAt;
  final int? contentChars;
  final int? deliveredChars;
  final bool? pathComplete;

  /// 서버가 이은 기준·출처 수를 알려 주는 버전이다(옛 Edge는 키가 없다).
  final bool linksReported;

  /// 함께 읽은 이은 기준·출처 수. null = 읽지 못함.
  final int? linkedCriteria;
  final int? sources;

  /// 고른 서술을 읽은 결과: base(기본 서술) · ok · truncated · not_found · unread. 옛 Edge는 null.
  final String? statementStatus;
  final int? statementVersion;
  final bool? statementHasDraft;
  final DateTime? statementDraftSavedAt;

  /// 기본 서술 말고 더 있는 서술 수, 등장 위치 수. null = 읽지 못함(또는 옛 Edge).
  final int? statements;
  final int? appearances;

  static ConceptReadInfo parse(Map<String, dynamic>? context) {
    if (context == null || !context.containsKey('concept')) return const ConceptReadInfo(status: 'unsupported');
    final raw = context['concept'];
    if (raw == null) return const ConceptReadInfo(status: 'skipped');
    if (raw is! Map) return const ConceptReadInfo(status: 'error');
    final m = Map<String, dynamic>.from(raw);
    int? n(String k) => (m[k] as num?)?.toInt();
    final st = m['statement'] is Map ? Map<String, dynamic>.from(m['statement'] as Map) : null;
    return ConceptReadInfo(
      status: m['status']?.toString() ?? 'error',
      updatedAt: DateTime.tryParse(m['updated_at']?.toString() ?? '')?.toLocal(),
      contentChars: n('content_chars'),
      deliveredChars: n('delivered_chars'),
      pathComplete: m['path_complete'] is bool ? m['path_complete'] as bool : null,
      linksReported: m.containsKey('linked_criteria') || m.containsKey('sources'),
      linkedCriteria: n('linked_criteria'),
      sources: n('sources'),
      statementStatus: st?['status']?.toString(),
      statementVersion: (st?['version'] as num?)?.toInt(),
      statementHasDraft: st?['has_draft'] is bool ? st!['has_draft'] as bool : null,
      statementDraftSavedAt: DateTime.tryParse(st?['draft_saved_at']?.toString() ?? '')?.toLocal(),
      statements: n('statements'),
      appearances: n('appearances'),
    );
  }
}

/// 서버가 이번 답변에서 고른 정리 기준을 어떻게 읽었는지(SSE conversation.context.criterion). 제목·본문은 없다.
class CriterionReadInfo {
  const CriterionReadInfo({
    required this.status,
    this.version,
    this.confirmedAt,
    this.hasDraft,
    this.draftSavedAt,
    this.linkedConcepts,
  });

  /// ok · truncated · not_found · error · skipped · unsupported(옛 Edge).
  final String status;
  final int? version;
  final DateTime? confirmedAt;
  final bool? hasDraft;
  final DateTime? draftSavedAt;
  final int? linkedConcepts;

  static CriterionReadInfo parse(Map<String, dynamic>? context) {
    if (context == null || !context.containsKey('criterion')) return const CriterionReadInfo(status: 'unsupported');
    final raw = context['criterion'];
    if (raw == null) return const CriterionReadInfo(status: 'skipped');
    if (raw is! Map) return const CriterionReadInfo(status: 'error');
    final m = Map<String, dynamic>.from(raw);
    DateTime? t(String k) => DateTime.tryParse(m[k]?.toString() ?? '')?.toLocal();
    return CriterionReadInfo(
      status: m['status']?.toString() ?? 'error',
      version: (m['version'] as num?)?.toInt(),
      confirmedAt: t('confirmed_at'),
      hasDraft: m['has_draft'] is bool ? m['has_draft'] as bool : null,
      draftSavedAt: t('draft_saved_at'),
      linkedConcepts: (m['linked_concepts'] as num?)?.toInt(),
    );
  }
}

/// 서버가 이번 답변에서 검토 창의 초안을 어떻게 읽었는지(SSE conversation.context.draft). 이름·본문은 없다.
class DraftReadInfo {
  const DraftReadInfo({required this.status, this.draftStatus, this.reviewSavedAt, this.items, this.blocksCut});

  /// ok · truncated · not_found · error · skipped · unsupported(옛 Edge).
  final String status;
  final String? draftStatus;
  final DateTime? reviewSavedAt;
  final int? items;
  final bool? blocksCut;

  static DraftReadInfo parse(Map<String, dynamic>? context) {
    if (context == null || !context.containsKey('draft')) return const DraftReadInfo(status: 'unsupported');
    final raw = context['draft'];
    if (raw == null) return const DraftReadInfo(status: 'skipped');
    if (raw is! Map) return const DraftReadInfo(status: 'error');
    final m = Map<String, dynamic>.from(raw);
    return DraftReadInfo(
      status: m['status']?.toString() ?? 'error',
      draftStatus: m['draft_status']?.toString(),
      reviewSavedAt: DateTime.tryParse(m['review_saved_at']?.toString() ?? '')?.toLocal(),
      items: (m['items'] as num?)?.toInt(),
      blocksCut: m['blocks_cut'] is bool ? m['blocks_cut'] as bool : null,
    );
  }
}

class _Part {
  _Part(this.phase);
  String phase;
  final StringBuffer text = StringBuffer();
}

/// 개념 탭의 Think 대화. 선택·입력·스트림을 Think 화면과 따로 갖고, 같은 대화로 동시에 보내지 않게
/// [ThinkSendLock]을 함께 쓴다. 제안 카드는 Think 화면과 같은 곳([ThinkController])에 모은다.
/// 기기에는 계정별로 연결한 대화 id와 고른 개념·정리 기준 id만 저장한다. 본문은 저장하지도 보내지도 않는다.
///
/// [draftReview]는 개념 초안 검토 창의 대화다. 초안이 바뀌어도 같은 대화를 잇고('새 대화'로 바꿀 수 있다),
/// 연결한 대화가 없으면 첫 질문에서 서버가 교육 부서의 '개념 초안 검토' 대화를 만든다. 초안 id만 보낸다.
class ConceptChatController extends ChangeNotifier {
  ConceptChatController._({this.draftMode = false}) {
    ThinkSendLock.instance.addListener(notifyListeners);
    ThinkSendLock.instance.released.listen(_onSendReleased);
  }

  static final ConceptChatController instance = ConceptChatController._();
  static final ConceptChatController draftReview = ConceptChatController._(draftMode: true);

  /// 로그인 상태를 구독하지 않는다. 계정은 [switchAccountForTest]로 바꾼다.
  @visibleForTesting
  factory ConceptChatController.forTest({bool draftMode = false}) =>
      ConceptChatController._(draftMode: draftMode).._started = true;

  /// 개념 초안 검토 창의 대화.
  final bool draftMode;

  String get _owner => draftMode ? ThinkSendLock.conceptDraft : ThinkSendLock.conceptTab;
  static String prefsKey(String userId) => 'concept_chat_link.v1.$userId';
  static String draftPrefsKey(String userId) => 'concept_draft_chat.v1.$userId';
  String _prefsKey(String userId) => draftMode ? draftPrefsKey(userId) : prefsKey(userId);

  static final RegExp _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  /// 임시(저장 전) 개념은 서버에 없어 고를 수 없다.
  static bool isSavedConceptId(String id) => _uuid.hasMatch(id);

  final ThinkApi _api = ThinkApi.instance;
  bool _started = false;
  bool _accountLoaded = false;
  String? _userId;

  /// 계정이 바뀔 때마다 오른다. 앞 계정의 늦은 응답이 새 계정 화면을 덮지 않게 한다.
  int _epoch = 0;

  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    AuthService.authStateChanges.listen((s) => unawaited(_switchAccount(s.session?.user.id)));
    await _switchAccount(AuthService.currentUser?.id);
  }

  @visibleForTesting
  Future<void> switchAccountForTest(String? userId) => _switchAccount(userId);

  Future<void> _switchAccount(String? uid) async {
    if (_accountLoaded && uid == _userId) return;
    _accountLoaded = true;
    _userId = uid;
    _epoch += 1;
    final epoch = _epoch;
    if (isStreaming) stop();
    conversationId = null;
    conversation = null;
    link = ConceptChatLink.none;
    linkError = null;
    pickedConcept.value = null;
    conceptName = null;
    conceptKind = null;
    conceptMissing = false;
    pickedCriterion.value = null;
    _criterionHeader(null);
    criterionMissing = false;
    lastCriterionRead = null;
    lastDraftRead = null;
    messages = const [];
    messagesLoading = false;
    messagesError = null;
    composer.clear();
    pendingAttachments.clear();
    sendError = null;
    notice = null;
    lastRead = null;
    status = null;
    statusError = null;
    statusLoading = false;
    _forbidden = false;
    notifyListeners();
    if (uid == null) return;
    final saved = await _readSaved(uid);
    if (epoch != _epoch) return;
    conversationId = saved.conversationId;
    pickedConcept.value = saved.conceptId;
    pickedCriterion.value = saved.criterionId;
    notifyListeners();
    await Future.wait([
      refreshStatus(),
      if (conversationId != null) refreshLink(),
      if (conceptId != null) _loadConceptHeader(),
      if (criterionId != null) _loadCriterionHeader(),
    ]);
  }

  Future<({String? conversationId, String? conceptId, String? criterionId})> _readSaved(String uid) async {
    const none = (conversationId: null, conceptId: null, criterionId: null);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey(uid));
      final j = raw == null ? null : jsonDecode(raw);
      String? id(Object? v) => v is String && _uuid.hasMatch(v) ? v : null;
      if (j is! Map) return none;
      return (
        conversationId: id(j['conversation_id']),
        conceptId: id(j['concept_id']),
        criterionId: id(j['criterion_id']),
      );
    } catch (_) {
      return none;
    }
  }

  Future<void> _save() async {
    final uid = _userId;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (conversationId == null && conceptId == null && criterionId == null) {
        await prefs.remove(_prefsKey(uid));
      } else {
        await prefs.setString(
          _prefsKey(uid),
          jsonEncode({
            'conversation_id': conversationId,
            'concept_id': conceptId,
            if (criterionId != null) 'criterion_id': criterionId,
          }),
        );
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------------ 서버 상태
  ThinkStatus? status;
  String? statusError;
  bool statusLoading = false;
  bool _forbidden = false;

  bool get forbidden => _forbidden;

  /// 서버(ai_think)가 개념 참고를 안다. 옛 Edge는 concept_id를 말없이 버리므로, 모르면 개념을 붙여 보내지 않는다.
  bool get serverReady => status?.conceptReference ?? false;

  /// 서버가 고른 서술(statement_id)을 읽는다. 모르면 기본 서술이 아닌 서술을 고른 채 보내지 않는다.
  bool get statementServerReady => status?.conceptStatementReference ?? false;

  /// 서버가 정리 기준 참고(criterion_id)를 안다. 모르면 기준을 붙여 보내지 않는다.
  bool get criterionServerReady => status?.criterionReference ?? false;

  /// 서버가 검토 창 초안 참고(draft_id)를 안다. 옛 Edge는 draft_id를 버리므로 보내지 않는다.
  bool get draftServerReady => status?.conceptDraftReference ?? false;

  // ------------------------------------------------------------------ 검토 창의 초안(draftMode)
  /// 검토 창이 연 초안. 보낼 때 id만 보낸다.
  String? draftId;

  /// 열린(검토 중) 초안인지. 닫힌 초안에는 보내지 않는다.
  bool draftOpen = true;

  /// 마지막 답변에서 서버가 초안을 어떻게 읽었는지.
  DraftReadInfo? lastDraftRead;

  /// 검토 창이 초안을 열거나 바꿀 때 부른다. 대화는 그대로 잇는다.
  void setDraft(String? id, {bool open = true}) {
    if (draftId == id && draftOpen == open) return;
    if (draftId != id) lastDraftRead = null;
    draftId = id;
    draftOpen = open;
    notifyListeners();
  }

  /// 검토 대화를 끊고, 다음 질문에서 새 '개념 초안 검토' 대화를 만든다.
  Future<void> startNewConversation() async {
    if (isStreaming) return;
    conversationId = null;
    conversation = null;
    link = ConceptChatLink.none;
    linkError = null;
    messages = const [];
    messagesError = null;
    lastDraftRead = null;
    sendError = null;
    notice = null;
    notifyListeners();
    await _save();
  }

  Future<void> refreshStatus() async {
    final epoch = _epoch;
    statusLoading = true;
    notifyListeners();
    try {
      final s = await _api.status();
      if (epoch != _epoch) return;
      status = s;
      statusError = null;
      _forbidden = false;
    } on ThinkApiException catch (e) {
      if (epoch != _epoch) return;
      statusError = e.message;
      _forbidden = e.code == 'forbidden';
    } catch (e) {
      if (epoch != _epoch) return;
      statusError = '서버 상태를 확인하지 못했습니다: $e';
    } finally {
      if (epoch == _epoch) {
        statusLoading = false;
        notifyListeners();
      }
    }
  }

  /// 개념 화면 오른쪽 패널을 펼쳐 둘지. 메뉴를 옮겨 다녀도 유지한다(알림 없음, 화면이 직접 읽고 쓴다).
  bool panelOpen = true;

  // ------------------------------------------------------------------ 연결한 대화
  String? conversationId;
  ThinkConversation? conversation;
  ConceptChatLink link = ConceptChatLink.none;
  String? linkError;

  /// 사용자가 고를 수 있는 기존 대화. 새 대화는 만들지 않는다.
  Future<List<ThinkConversation>> loadPickable() => _api.listConversations();

  /// 사용자가 고른 기존 대화를 잇는다. 대화를 만들거나 그 대화의 부서·폴더를 바꾸지 않는다.
  Future<void> linkConversation(ThinkConversation c) async {
    if (isStreaming) return;
    conversationId = c.id;
    conversation = c;
    messages = const [];
    messagesError = null;
    lastRead = null;
    lastCriterionRead = null;
    sendError = null;
    notice = null;
    notifyListeners();
    await _save();
    await refreshLink();
  }

  Future<void> unlinkConversation() async {
    if (isStreaming) return;
    conversationId = null;
    conversation = null;
    link = ConceptChatLink.none;
    linkError = null;
    messages = const [];
    messagesError = null;
    lastRead = null;
    lastCriterionRead = null;
    notifyListeners();
    await _save();
  }

  /// 연결한 대화가 아직 있고 볼 수 있는지 다시 확인한다. 화면을 열 때와 보내기 실패 뒤에 부른다.
  Future<void> refreshLink() async {
    final id = conversationId;
    if (id == null) {
      link = ConceptChatLink.none;
      notifyListeners();
      return;
    }
    final epoch = _epoch;
    link = ConceptChatLink.checking;
    linkError = null;
    notifyListeners();
    try {
      final c = await _api.getConversation(id);
      if (epoch != _epoch || conversationId != id) return;
      if (c == null) {
        link = ConceptChatLink.missing;
        conversation = null;
        messages = const [];
        notifyListeners();
        return;
      }
      conversation = c;
      link = ConceptChatLink.ready;
      notifyListeners();
      unawaited(ThinkController.instance.loadActions(id));
      await _loadMessages(id, epoch);
    } catch (e) {
      if (epoch != _epoch || conversationId != id) return;
      link = ConceptChatLink.failed;
      linkError = '연결한 대화를 확인하지 못했습니다: $e';
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ 고른 개념
  /// 고른 개념 id. 개념 트리는 이 값만 듣는다(답변을 받는 동안 트리 전체를 다시 그리지 않게).
  final ValueNotifier<String?> pickedConcept = ValueNotifier<String?>(null);

  String? get conceptId => pickedConcept.value;
  String? conceptName;
  ConceptKind? conceptKind;
  bool conceptMissing = false;

  /// 반환값: 고르지 못한 이유(없으면 null).
  String? pickConcept(ConceptItem c) {
    if (!isSavedConceptId(c.id)) return '저장된 개념만 고를 수 있습니다. 먼저 저장해 주세요.';
    pickedConcept.value = c.id;
    conceptName = c.name;
    conceptKind = c.kind;
    conceptMissing = false;
    lastRead = null;
    notifyListeners();
    unawaited(_save());
    return null;
  }

  void clearConcept() {
    if (conceptId == null) return;
    pickedConcept.value = null;
    conceptName = null;
    conceptKind = null;
    conceptMissing = false;
    lastRead = null;
    notifyListeners();
    unawaited(_save());
  }

  /// 개념 화면에서 고친 이름·종류를 표시에 반영한다(본문은 들고 있지 않는다).
  void conceptSaved(String id, {required String name, required ConceptKind kind}) {
    if (id != conceptId) return;
    conceptName = name;
    conceptKind = kind;
    conceptMissing = false;
    notifyListeners();
  }

  void conceptDeleted(String id) {
    if (id == conceptId) clearConcept();
  }

  /// 개념 상세의 서술 선택. 개념 라이브러리가 붙인다. 고른 개념의 고른 서술을 Think에 같이 보낸다.
  ConceptStatementStore? _statements;
  String? _shownStatement;

  void attachStatements(ConceptStatementStore store) {
    if (identical(_statements, store)) return;
    _statements?.removeListener(_onStatements);
    _statements = store;
    store.addListener(_onStatements);
    _shownStatement = _statementKey;
  }

  String get _statementKey => '${statementId ?? ''}|${statementLabel ?? ''}';

  void _onStatements() {
    final key = _statementKey;
    if (key == _shownStatement) return;
    _shownStatement = key;
    notifyListeners();
  }

  /// 고른 개념에서 고른 서술. null이면 기본 서술(개념 본문)이다(서술을 읽기 전도 기본 서술).
  String? get statementId {
    final id = conceptId;
    return id == null ? null : _statements?.selectedOf(id);
  }

  /// 표시용 "서술 i · 제목". 기본 서술이면 null.
  String? get statementLabel {
    final id = conceptId;
    final sid = statementId;
    if (id == null || sid == null) return null;
    final list = _statements!.statementsOf(id);
    final i = list.indexWhere((s) => s.id == sid);
    if (i < 0) return null;
    final t = (list[i].content ?? list[i].draft)?.title.trim() ?? '';
    return '서술 ${i + 1} · ${t.isEmpty ? '(제목 없음)' : t}';
  }

  // ------------------------------------------------------------------ 고른 정리 기준
  /// 고른 정리 기준 id. 화면은 이 값만 듣는다.
  final ValueNotifier<String?> pickedCriterion = ValueNotifier<String?>(null);

  String? get criterionId => pickedCriterion.value;

  /// 표시용(제목·판). 본문은 들고 있지 않다.
  String? criterionTitle;
  int criterionVersion = 0;
  bool criterionHasDraft = false;
  bool criterionMissing = false;

  /// 마지막 답변에서 서버가 기준을 어떻게 읽었는지.
  CriterionReadInfo? lastCriterionRead;

  void _criterionHeader(ConceptCriterion? c) {
    criterionTitle = c == null ? null : (c.confirmed ? c.title : c.draftTitle);
    criterionVersion = c?.version ?? 0;
    criterionHasDraft = c?.hasDraft ?? false;
  }

  /// 반환값: 고르지 못한 이유(없으면 null). 저장한 기준만 고를 수 있다.
  String? pickCriterion(ConceptCriterion c) {
    if (!isSavedConceptId(c.id)) return '저장한 기준만 고를 수 있습니다. 먼저 초안을 저장해 주세요.';
    pickedCriterion.value = c.id;
    _criterionHeader(c);
    criterionMissing = false;
    lastCriterionRead = null;
    notifyListeners();
    unawaited(_save());
    return null;
  }

  void clearCriterion() {
    if (criterionId == null) return;
    pickedCriterion.value = null;
    _criterionHeader(null);
    criterionMissing = false;
    lastCriterionRead = null;
    notifyListeners();
    unawaited(_save());
  }

  /// 기준 화면에서 저장·확정한 뒤 제목·판 표시를 맞춘다.
  void criterionSaved(ConceptCriterion c) {
    if (c.id != criterionId) return;
    _criterionHeader(c);
    criterionMissing = false;
    notifyListeners();
  }

  void criterionRemoved(String id) {
    if (id == criterionId) clearCriterion();
  }

  Future<void> _loadCriterionHeader() async {
    final id = criterionId;
    if (id == null) return;
    final epoch = _epoch;
    try {
      final row = await Supabase.instance.client
          .from('concept_criteria')
          .select('id,title,version,draft_title,draft_saved_at')
          .eq('id', id)
          .maybeSingle();
      if (epoch != _epoch || criterionId != id) return;
      criterionMissing = row == null;
      if (row != null) _criterionHeader(ConceptCriterion.fromRow(Map<String, dynamic>.from(row)));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _loadConceptHeader() async {
    final id = conceptId;
    if (id == null) return;
    final epoch = _epoch;
    try {
      final c = await ConceptService(Supabase.instance.client).fetchConceptHeader(id);
      if (epoch != _epoch || conceptId != id) return;
      conceptMissing = c == null;
      if (c != null) {
        conceptName = c.name;
        conceptKind = c.kind;
      }
      notifyListeners();
    } catch (_) {}
  }

  // ------------------------------------------------------------------ 메시지
  List<ThinkMessage> messages = const [];
  bool messagesLoading = false;
  String? messagesError;

  Future<void> _loadMessages(String id, int epoch) async {
    if (ThinkSendLock.instance.ownerOf(id) == _owner) return;
    messagesLoading = messages.isEmpty;
    messagesError = null;
    notifyListeners();
    try {
      final loaded = await _api.listMessages(id);
      if (epoch != _epoch || conversationId != id || ThinkSendLock.instance.ownerOf(id) == _owner) return;
      messages = loaded;
    } catch (e) {
      if (epoch == _epoch && conversationId == id) messagesError = '메시지를 불러오지 못했습니다: $e';
    } finally {
      if (epoch == _epoch) {
        messagesLoading = false;
        notifyListeners();
      }
    }
  }

  /// Think 화면이 같은 대화에서 답변을 다 받으면 다시 읽는다.
  void _onSendReleased(ThinkSendRelease r) {
    if (r.owner == _owner || r.conversationId != conversationId || link != ConceptChatLink.ready) return;
    unawaited(_loadMessages(r.conversationId, _epoch));
  }

  // ------------------------------------------------------------------ Think 화면으로
  /// Think 메뉴로 옮겨 연결한 대화를 연다(사용자가 누를 때만 Think 화면의 선택이 바뀐다).
  Future<void> openInThink({bool organize = false, String? messageId}) async {
    final id = conversationId;
    if (id == null) return;
    await openConversationInThink(id);
    if (organize) ThinkController.instance.openOrganizePanel(messageId: messageId);
  }

  Future<void> openConversationInThink(String id) async {
    AppMenu.instance.open(AppMenu.think);
    await ThinkController.instance.openConversation(id);
  }

  // ------------------------------------------------------------------ 입력창
  final TextEditingController composer = TextEditingController();
  final List<ThinkAttachment> pendingAttachments = [];
  int uploadingCount = 0;
  bool deep = false;
  bool webSearch = true;
  String? sendError;
  String? notice;

  /// 마지막 답변에서 서버가 개념을 어떻게 읽었는지. 이번 실행 중 마지막 답변 하나만 보여 준다.
  ConceptReadInfo? lastRead;

  void setDeep(bool v) {
    deep = v;
    notifyListeners();
  }

  void setWebSearch(bool v) {
    webSearch = v;
    notifyListeners();
  }

  void clearSendError() {
    if (sendError == null) return;
    sendError = null;
    notifyListeners();
  }

  void clearNotice() {
    if (notice == null) return;
    notice = null;
    notifyListeners();
  }

  /// 반환값: 첨부하지 못한 파일에 대한 안내 문구들.
  Future<List<String>> addFiles(Iterable<String> paths) async {
    final epoch = _epoch;
    final problems = <String>[];
    final room = 6 - pendingAttachments.length - uploadingCount;
    var accepted = 0;
    final uploads = <Future<void>>[];
    for (final path in paths) {
      final name = path.split(RegExp(r'[\\/]')).last;
      if (ThinkApi.mimeForPath(path) == null) {
        problems.add('$name: ${ThinkApi.attachmentTypesHint}');
        continue;
      }
      if (accepted >= room) {
        problems.add('$name: 한 번에 6개까지 첨부할 수 있습니다.');
        continue;
      }
      accepted += 1;
      uploadingCount += 1;
      uploads.add(() async {
        try {
          final a = await _api.uploadAttachment(File(path));
          if (epoch == _epoch) {
            pendingAttachments.add(a);
          } else {
            await _api.removeAttachment(a.path);
          }
        } catch (e) {
          problems.add('$name: ${e is ThinkApiException ? e.message : '업로드 실패 ($e)'}');
        } finally {
          uploadingCount -= 1;
          notifyListeners();
        }
      }());
    }
    notifyListeners();
    await Future.wait(uploads);
    return problems;
  }

  Future<void> removePending(ThinkAttachment a) async {
    pendingAttachments.remove(a);
    notifyListeners();
    await _api.removeAttachment(a.path);
  }

  /// 보낼 수 없는 이유. null이면 보낼 수 있다(입력 여부는 [canSend]가 따로 본다).
  String? get blockedReason {
    if (forbidden) return 'Think는 최고 관리자만 쓸 수 있습니다.';
    if (draftMode) return _draftBlockedReason;
    switch (link) {
      case ConceptChatLink.none:
        return '먼저 이어 갈 Think 대화를 연결하세요.';
      case ConceptChatLink.checking:
        return '연결한 대화를 확인하는 중입니다.';
      case ConceptChatLink.missing:
        return '연결한 대화를 찾을 수 없습니다(지워졌거나 볼 수 없음). 다른 대화를 연결하세요.';
      case ConceptChatLink.failed:
        return linkError ?? '연결한 대화를 확인하지 못했습니다. 다시 확인하거나 다른 대화를 연결하세요.';
      case ConceptChatLink.ready:
        break;
    }
    if (conceptId != null && !serverReady) {
      if (statusLoading) return '서버 상태를 확인하는 중입니다.';
      if (statusError != null) return '서버 상태를 확인하지 못해 개념을 붙여 보낼 수 없습니다. 다시 확인해 주세요.';
      return '서버(ai_think)가 아직 개념 참고를 모르는 버전입니다. 배포한 뒤에 개념을 붙여 보낼 수 있습니다. '
          '개념 없이 이야기하려면 참고 개념을 해제하세요.';
    }
    if (statementId != null && !statementServerReady) {
      if (statusLoading) return '서버 상태를 확인하는 중입니다.';
      if (statusError != null) return '서버 상태를 확인하지 못해 고른 서술을 붙여 보낼 수 없습니다. 다시 확인해 주세요.';
      return '서버(ai_think)가 아직 고른 서술을 읽지 못하는 버전입니다. 배포한 뒤에 서술을 붙여 보낼 수 있습니다. '
          '개념 본문으로 물으려면 개념 상세에서 기본 서술을 고르세요.';
    }
    if (criterionId != null && !criterionServerReady) {
      if (statusLoading) return '서버 상태를 확인하는 중입니다.';
      if (statusError != null) return '서버 상태를 확인하지 못해 정리 기준을 붙여 보낼 수 없습니다. 다시 확인해 주세요.';
      return '서버(ai_think)가 아직 정리 기준 참고를 모르는 버전입니다. 배포한 뒤에 기준을 붙여 보낼 수 있습니다. '
          '기준 없이 이야기하려면 참고 기준을 해제하세요.';
    }
    if (ThinkSendLock.instance.busyElsewhere(conversationId, _owner)) {
      return 'Think 화면에서 이 대화의 답변을 받는 중입니다. 끝나면 보낼 수 있습니다.';
    }
    return null;
  }

  String? get _draftBlockedReason {
    if (draftId == null) return '초안을 연 뒤 물어볼 수 있습니다.';
    if (!draftOpen) return '닫힌 초안입니다(확정·버림·다시 정리). 검토 중인 초안에서 물어보세요.';
    if (!draftServerReady) {
      if (statusLoading) return '서버 상태를 확인하는 중입니다.';
      if (statusError != null) return '서버 상태를 확인하지 못했습니다. 다시 확인해 주세요.';
      return '서버(ai_think)가 아직 초안 검토 대화를 모르는 버전입니다. 배포한 뒤에 쓸 수 있습니다.';
    }
    switch (link) {
      case ConceptChatLink.none:
      case ConceptChatLink.ready:
        break;
      case ConceptChatLink.checking:
        return '이어 갈 대화를 확인하는 중입니다.';
      case ConceptChatLink.missing:
        return '이어 가던 대화를 찾을 수 없습니다(지워졌거나 볼 수 없음). 새 대화로 시작하세요.';
      case ConceptChatLink.failed:
        return linkError ?? '이어 가던 대화를 확인하지 못했습니다. 다시 확인하거나 새 대화로 시작하세요.';
    }
    if (ThinkSendLock.instance.busyElsewhere(conversationId, _owner)) {
      return 'Think 화면에서 이 대화의 답변을 받는 중입니다. 끝나면 보낼 수 있습니다.';
    }
    return null;
  }

  bool get canSend => !isStreaming && uploadingCount == 0 && composer.text.trim().isNotEmpty && blockedReason == null;

  // ------------------------------------------------------------------ 스트리밍
  ThinkChatStream? _stream;
  bool _opening = false;
  bool _stopRequested = false;
  Timer? _notifyTimer;

  bool get isStreaming => _stream != null || _opening;

  void _notifySoon() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 50), notifyListeners);
  }

  void stop() {
    if (!isStreaming) return;
    _stopRequested = true;
    _stream?.cancel();
  }

  Future<void> send() async {
    // 검토 창은 이어 갈 대화가 없으면 첫 질문으로 새 대화를 만든다(대화 id는 서버가 알려 준다).
    String? convId = conversationId;
    if (!canSend || (convId == null && !draftMode)) return;
    if (convId != null && !ThinkSendLock.instance.acquire(convId, _owner)) return;
    final epoch = _epoch;
    final text = composer.text.trim();
    final attachments = [...pendingAttachments];
    final concept = draftMode ? null : conceptId;
    final statement = concept == null ? null : statementId;
    final criterion = draftMode ? null : criterionId;
    final draft = draftMode ? draftId : null;
    var created = false;
    final user = ThinkMessage(
      role: 'user',
      content: text,
      status: ThinkMessageStatus.complete,
      attachments: attachments,
      createdAt: DateTime.now(),
    );
    final assistant = ThinkMessage(
      role: 'assistant',
      content: '',
      status: ThinkMessageStatus.streaming,
      createdAt: DateTime.now(),
    );
    messages = [...messages, user, assistant];
    composer.clear();
    pendingAttachments.clear();
    sendError = null;
    notice = null;
    lastRead = null;
    lastCriterionRead = null;
    lastDraftRead = null;
    _stopRequested = false;
    _opening = true;
    notifyListeners();

    final ThinkChatStream stream;
    try {
      stream = await _api.openChat(
        conversationId: convId,
        conceptId: concept,
        statementId: statement,
        criterionId: criterion,
        draftId: draft,
        message: text,
        attachments: attachments,
        deep: deep,
        webSearch: webSearch && (status?.webSearchEnabled ?? true),
      );
    } catch (e) {
      _opening = false;
      if (convId != null) ThinkSendLock.instance.release(convId, _owner);
      if (epoch == _epoch) {
        messages = [
          for (final m in messages)
            if (!identical(m, user) && !identical(m, assistant)) m
        ];
        composer.text = text;
        pendingAttachments.addAll(attachments);
        sendError = e is ThinkApiException ? e.message : '보내지 못했습니다: $e';
        if (e is ThinkApiException && e.code == 'forbidden') _forbidden = true;
      }
      notifyListeners();
      return;
    }
    _stream = stream;
    _opening = false;
    if (_stopRequested) stream.cancel();
    notifyListeners();

    final think = ThinkController.instance;
    var finished = false;
    final parts = <String, _Part>{};

    void rebuildText() {
      String join(bool commentary) => parts.values
          .where((p) => (p.phase == 'commentary') == commentary)
          .map((p) => p.text.toString().trim())
          .where((t) => t.isNotEmpty)
          .join('\n\n');
      assistant.content = join(false);
      final c = join(true);
      assistant.commentary = c.isEmpty ? null : c;
    }

    List<ThinkToolTrace> settledTools() => [
          for (final t in assistant.toolCalls)
            if (!t.running) t
        ];

    try {
      await for (final ev in stream.events) {
        if (epoch != _epoch) continue;
        final d = ev.data;
        switch (ev.event) {
          case 'notice':
            notice = ThinkController.noticeText(d);
            notifyListeners();
          case 'conversation':
            user.id = d['user_message_id']?.toString();
            final serverId = d['conversation_id']?.toString();
            if (convId == null && serverId != null && serverId.isNotEmpty) {
              convId = serverId;
              created = true;
              ThinkSendLock.instance.acquire(serverId, _owner);
              conversationId = serverId;
              link = ConceptChatLink.ready;
              unawaited(_save());
            }
            if (convId != null) think.beginExternalTurn(convId);
            final context = d['context'] is Map ? Map<String, dynamic>.from(d['context'] as Map) : null;
            if (concept != null) lastRead = ConceptReadInfo.parse(context);
            if (criterion != null) lastCriterionRead = CriterionReadInfo.parse(context);
            if (draft != null) lastDraftRead = DraftReadInfo.parse(context);
            notifyListeners();
          case 'message_start':
            final itemId = d['item_id']?.toString() ?? 'item_${parts.length}';
            parts[itemId] = _Part(d['phase']?.toString() ?? 'final');
          case 'delta':
            final itemId = d['item_id']?.toString() ?? 'item_${parts.length}';
            parts.putIfAbsent(itemId, () => _Part('final')).text.write(d['text']?.toString() ?? '');
            rebuildText();
            _notifySoon();
          case 'message_done':
            final part = parts[d['item_id']?.toString()];
            if (part != null) {
              part.phase = d['phase']?.toString() ?? part.phase;
              rebuildText();
              _notifySoon();
            }
          case 'tool':
            final trace = ThinkToolTrace.fromJson(d);
            final tools = [...assistant.toolCalls];
            final idx = tools.indexWhere((t) => t.callId != null && t.callId == trace.callId);
            if (idx >= 0) {
              tools[idx] = trace;
            } else {
              tools.add(trace);
            }
            assistant.toolCalls = tools;
            notifyListeners();
          case 'action':
            final raw = d['action'];
            final action = raw is Map ? ThinkAction.fromRow(Map<String, dynamic>.from(raw)) : null;
            if (action != null) think.putStreamedAction(action);
          case 'done':
            finished = true;
            assistant.id = d['assistant_message_id']?.toString();
            assistant.status = d['status'] == 'stopped' ? ThinkMessageStatus.stopped : ThinkMessageStatus.complete;
            assistant.model = d['model']?.toString();
            assistant.sources = (d['sources'] is List ? d['sources'] as List : const [])
                .whereType<Map>()
                .map((s) => ThinkSource.fromJson(Map<String, dynamic>.from(s)))
                .toList();
            assistant.attachments = _answerFiles(d);
            assistant.toolCalls = settledTools();
            if (convId != null) think.attachStreamedActions(convId, d['action_ids'], assistant.id);
            notifyListeners();
          case 'error':
            finished = true;
            assistant.id = d['assistant_message_id']?.toString();
            assistant.status = ThinkMessageStatus.error;
            assistant.errorText = d['message']?.toString() ?? '답변을 만들지 못했습니다.';
            assistant.attachments = _answerFiles(d);
            assistant.toolCalls = settledTools();
            if (convId != null) think.attachStreamedActions(convId, d['action_ids'], assistant.id);
            if (d['code'] == 'conversation_not_found' && epoch == _epoch && conversationId == convId) {
              link = ConceptChatLink.missing;
            }
            notifyListeners();
        }
      }
    } catch (e) {
      if (!finished && !_stopRequested) assistant.errorText = '연결이 끊겼습니다: $e';
    } finally {
      _notifyTimer?.cancel();
      if (!finished) {
        assistant.status = _stopRequested ? ThinkMessageStatus.stopped : ThinkMessageStatus.error;
        if (!_stopRequested) assistant.errorText ??= '답변이 끝나기 전에 연결이 끊겼습니다.';
        assistant.toolCalls = settledTools();
      }
      stream.cancel();
      _stream = null;
      if (convId != null) ThinkSendLock.instance.release(convId, _owner);
      notifyListeners();
    }

    final sent = convId;
    if (sent == null) return;
    if (created && epoch == _epoch && conversationId == sent) {
      // 새로 만든 대화의 제목·부서를 읽고 Think 화면 목록에도 보이게 한다.
      unawaited(refreshLink());
      unawaited(think.refreshTree());
      return;
    }
    if (!finished) {
      // 서버는 연결이 끊긴 뒤에 부분 답변을 저장하므로 조금 기다렸다가 다시 읽는다.
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
        if (epoch == _epoch && conversationId == sent) await _loadMessages(sent, epoch);
      }));
    }
  }

  static List<ThinkAttachment> _answerFiles(Map<String, dynamic> d) =>
      (d['attachments'] is List ? d['attachments'] as List : const [])
          .whereType<Map>()
          .map((a) => ThinkAttachment.fromJson(Map<String, dynamic>.from(a)))
          .where((a) => a.path.isNotEmpty)
          .toList();
}
