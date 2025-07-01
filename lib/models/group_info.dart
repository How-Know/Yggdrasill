import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class GroupInfo {
  final String id;
  final String name;
  final String description;
  final int capacity;
  final int duration; // 그룹의 기본 수업 시간(분)
  final Color color;

  GroupInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.capacity,
    required this.duration,
    required this.color,
  });

  factory GroupInfo.fromJson(Map<String, dynamic> json) {
    return GroupInfo(
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

  GroupInfo copyWith({
    String? id,
    String? name,
    String? description,
    int? capacity,
    int? duration,
    Color? color,
  }) {
    return GroupInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      capacity: capacity ?? this.capacity,
      duration: duration ?? this.duration,
      color: color ?? this.color,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
} 