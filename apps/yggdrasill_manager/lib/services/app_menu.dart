import 'package:flutter/foundation.dart';

/// 메인 화면 왼쪽 메뉴를 다른 화면에서 바꿀 때 쓴다(개념 탭에서 Think 대화 열기).
class AppMenu extends ChangeNotifier {
  AppMenu._();
  static final AppMenu instance = AppMenu._();

  /// main.dart `_screens` 순서와 같다.
  static const int curriculum = 0;
  static const int think = 7;

  int? _requested;

  void open(int index) {
    _requested = index;
    notifyListeners();
  }

  int? takeRequest() {
    final index = _requested;
    _requested = null;
    return index;
  }
}
