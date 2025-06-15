import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class ClassInfo {
  final String id;
  final String name;
  final String description;
  final int capacity;
  final int duration; // 수업 시간 (분)
  final Color color;

  ClassInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.capacity,
    required this.duration,
    required this.color,
  });

  factory ClassInfo.fromJson(Map<String, dynamic> json) {
    return ClassInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      capacity: json['capacity'] as int,
      duration: json['duration'] as int,
      color: Color(json['color'] as int),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'capacity': capacity,
      'duration': duration,
      'color': color.value,
    };
  }

  ClassInfo copyWith({
    String? id,
    String? name,
    String? description,
    int? capacity,
    int? duration,
    Color? color,
  }) {
    return ClassInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      capacity: capacity ?? this.capacity,
      duration: duration ?? this.duration,
      color: color ?? this.color,
    );
  }
} 