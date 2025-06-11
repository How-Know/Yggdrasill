import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class ClassInfo {
  final String id;
  final String name;
  final String description;
  final int capacity;
  final Color color;

  ClassInfo({
    String? id,
    required this.name,
    required this.description,
    required this.capacity,
    required this.color,
  }) : id = id ?? const Uuid().v4();

  ClassInfo copyWith({
    String? name,
    String? description,
    int? capacity,
    Color? color,
  }) {
    return ClassInfo(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      capacity: capacity ?? this.capacity,
      color: color ?? this.color,
    );
  }
} 