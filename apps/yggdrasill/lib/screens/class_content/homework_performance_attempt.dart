/// 수행 기준 차수: 대기(1)·확인(4)은 끝난 시도 수, 수행(2)·제출(3)은 지금 차수.
/// 생성 직후 대기는 0, 첫 수행부터 1.
int homeworkPerformanceAttemptIndex({
  required int checkCount,
  required int phase,
}) {
  final checks = checkCount < 0 ? 0 : checkCount;
  if (phase == 2 || phase == 3) return checks + 1;
  return checks;
}
