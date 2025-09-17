import 'package:flutter/material.dart';

class ClassInfo {
  final String id;
  final String name;
  final int? capacity;
  final String description;
  final Color? color;
  ClassInfo({required this.id, required this.name, this.capacity, required this.description, this.color});

  factory ClassInfo.fromJson(Map<String, dynamic> json) {
    return ClassInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      capacity: json['capacity'] as int?,
      description: json['description'] as String,
      color: json['color'] != null ? Color(json['color'] as int) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'capacity': capacity,
      'description': description,
      'color': color?.value,
    };
  }

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