class StudentFlow {
  final String id;
  final String name;
  final bool enabled;

  const StudentFlow({
    required this.id,
    required this.name,
    required this.enabled,
  });

  StudentFlow copyWith({String? id, String? name, bool? enabled}) {
    return StudentFlow(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
    );
  }
}
