import 'package:flutter/foundation.dart';

/// 하단 크롬(탭바·미니바·검색) 스크롤 축소 상태.
class StudentShellChrome extends ChangeNotifier {
  StudentShellChrome._();
  static final StudentShellChrome instance = StudentShellChrome._();

  bool _scrollCollapsed = false;
  /// 스크롤 축소 중에도 탭 전환을 위해 일시적으로 탭바를 펼침.
  bool _tabsPinnedOpen = false;
  bool _searchExpanded = false;

  bool get scrollCollapsed => _scrollCollapsed;
  bool get tabsPinnedOpen => _tabsPinnedOpen;
  bool get searchExpanded => _searchExpanded;

  /// 스크롤로 줄어든 1줄 모드 (현재 탭 원 + 미니바 + 검색).
  bool get compact => _scrollCollapsed && !_tabsPinnedOpen;

  /// 스크롤 축소 크롬 (본문 하단 여백 계산용).
  /// - 미니바 있음: 1줄 배치 (검색 펼침 시 미니바를 위로 올림)
  /// - 미니바 없음: 탭바 구조 유지 + 크기만 축소
  bool get oneLineChrome => compact && !_searchExpanded;

  void setScrollCollapsed(bool value) {
    if (_scrollCollapsed == value) return;
    _scrollCollapsed = value;
    if (!value) _tabsPinnedOpen = false;
    notifyListeners();
  }

  void setSearchExpanded(bool value) {
    if (_searchExpanded == value) return;
    _searchExpanded = value;
    notifyListeners();
  }

  void pinTabsOpen() {
    if (!_scrollCollapsed || _tabsPinnedOpen) return;
    _tabsPinnedOpen = true;
    notifyListeners();
  }

  void clearTabsPin() {
    if (!_tabsPinnedOpen) return;
    _tabsPinnedOpen = false;
    notifyListeners();
  }
}
