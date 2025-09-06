import 'package:flutter/foundation.dart';

class ExamModeService {
  ExamModeService._();
  static final ExamModeService instance = ExamModeService._();

  /// 전역 시험기간 모드 상태
  final ValueNotifier<bool> isOn = ValueNotifier<bool>(false);
}


