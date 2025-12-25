import 'package:flutter/foundation.dart';

/// 상담 노트 화면과 오른쪽 슬라이드(메모 패널) 사이의 "노트 전환" 브릿지.
///
/// - 오른쪽 슬라이드에서 노트를 탭하면 [requestOpen]으로 ID를 전달
/// - 상담 노트 화면은 이를 listen하여 노트를 로드/전환
class ConsultNoteController {
  ConsultNoteController._internal();
  static final ConsultNoteController instance = ConsultNoteController._internal();

  final ValueNotifier<String?> requestedNoteId = ValueNotifier<String?>(null);

  /// 상담 노트 화면이 현재 열려있는지(중복 push 방지용)
  bool isScreenOpen = false;

  void requestOpen(String id) {
    if (id.trim().isEmpty) return;
    requestedNoteId.value = id;
  }

  /// 한 번 소비하고 초기화 (동일 id 재선택 시에도 이벤트가 발생하도록)
  String? consumeRequested() {
    final v = requestedNoteId.value;
    requestedNoteId.value = null;
    return v;
  }
}


