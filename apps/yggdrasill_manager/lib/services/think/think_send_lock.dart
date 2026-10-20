import 'dart:async';

import 'package:flutter/foundation.dart';

class ThinkSendRelease {
  const ThinkSendRelease(this.conversationId, this.owner);

  final String conversationId;
  final String owner;
}

/// 한 대화에는 한 번에 답변 하나만 받는다. Think 화면과 개념 탭이 같은 대화로 동시에 보내지 않게 함께 쓴다.
/// 서버는 같은 대화의 동시 질문을 막지 않으므로 앱이 막는다(이 앱 안에서만 막는다).
class ThinkSendLock extends ChangeNotifier {
  ThinkSendLock._();
  static final ThinkSendLock instance = ThinkSendLock._();

  static const String thinkScreen = 'think';
  static const String conceptTab = 'concept';
  static const String conceptDraft = 'concept_draft';

  final Map<String, String> _owners = {};
  final StreamController<ThinkSendRelease> _released = StreamController<ThinkSendRelease>.broadcast();

  /// 답변을 다 받은(또는 끊긴) 대화. 다른 화면이 메시지·제안을 다시 읽는 데 쓴다.
  Stream<ThinkSendRelease> get released => _released.stream;

  Iterable<String> get busyConversations => _owners.keys;

  String? ownerOf(String? conversationId) => conversationId == null ? null : _owners[conversationId];

  bool busy(String? conversationId) => ownerOf(conversationId) != null;

  bool busyElsewhere(String? conversationId, String owner) {
    final o = ownerOf(conversationId);
    return o != null && o != owner;
  }

  /// 이미 누가 답변을 받는 중이면 false.
  bool acquire(String conversationId, String owner) {
    if (_owners.containsKey(conversationId)) return false;
    _owners[conversationId] = owner;
    notifyListeners();
    return true;
  }

  void release(String conversationId, String owner) {
    if (_owners[conversationId] != owner) return;
    _owners.remove(conversationId);
    notifyListeners();
    _released.add(ThinkSendRelease(conversationId, owner));
  }

  @visibleForTesting
  void resetForTest() => _owners.clear();
}
