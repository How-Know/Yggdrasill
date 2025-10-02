enum TeacherRole { all, part, assistant }

String getTeacherRoleLabel(TeacherRole role) {
  switch (role) {
    case TeacherRole.all:
      return '전체';
    case TeacherRole.part:
      return '일부';
    case TeacherRole.assistant:
      return '보조';
  }
}

class Teacher {
  final String name;
  final TeacherRole role;
  final String contact;
  final String email;
  final String description;
  final int? displayOrder;

  Teacher({
    required this.name,
    required this.role,
    required this.contact,
    required this.email,
    required this.description,
    this.displayOrder,
  });
}