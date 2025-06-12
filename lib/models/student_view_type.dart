enum StudentViewType {
  all('전체'),
  byClass('반별'),
  bySchool('학교별'),
  byDate('등록일별');

  final String label;
  const StudentViewType(this.label);
} 