enum StudentViewType {
  all,
  byClass,
  bySchool,
  byDate;

  String get label {
    switch (this) {
      case StudentViewType.all:
        return '모든 학생';
      case StudentViewType.byClass:
        return '클래스';
      case StudentViewType.bySchool:
        return '학교별';
      case StudentViewType.byDate:
        return '수강 일자';
    }
  }
} 