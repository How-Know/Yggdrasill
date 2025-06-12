import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class ClassInfo {
  final String id;
  final String name;
  final int capacity;
  final String description;
  final Color color;

  ClassInfo({
    String? id,
    required this.name,
    required this.capacity,
    required this.description,
    required this.color,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'capacity': capacity,
    'description': description,
    'color': color.value,
  };

  factory ClassInfo.fromJson(Map<String, dynamic> json) => ClassInfo(
    id: json['id'],
    name: json['name'],
    capacity: json['capacity'],
    description: json['description'],
    color: Color(json['color']),
  );

  ClassInfo copyWith({
    String? id,
    String? name,
    int? capacity,
    String? description,
    Color? color,
  }) {
    return ClassInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      capacity: capacity ?? this.capacity,
      description: description ?? this.description,
      color: color ?? this.color,
    );
  }
} 