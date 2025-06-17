enum StudentViewType {
  all,
  byClass,
  bySchool,
  byDate,
}

final StudentViewType all = StudentViewType.all;
final StudentViewType byClass = StudentViewType.byClass;
final StudentViewType bySchool = StudentViewType.bySchool;
final StudentViewType byDate = StudentViewType.byDate;

final List<StudentViewType> allStudentViewTypes = [all, byClass, bySchool, byDate]; 