import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/cupertino.dart';
import 'package:mneme_flutter/models/student_time_block.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/group_info.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/widgets/app_snackbar.dart';
import 'package:mneme_flutter/widgets/class_student_card.dart';
import 'package:mneme_flutter/services/data_manager.dart';

class TimetableCell extends StatelessWidget {
  final int dayIdx;
  final int blockIdx;
  final String cellKey;
  final DateTime startTime;
  final DateTime endTime;
  final List<StudentTimeBlock> students;
  final bool isBreakTime;
  final bool isExpanded;
  final bool isDragHighlight;
  final VoidCallback? onTap;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final Color? countColor;
  final int activeStudentCount;
  final List<StudentWithInfo> cellStudentWithInfos;
  final List<GroupInfo> groups;
  final double cellWidth;

  const TimetableCell({
    super.key,
    required this.dayIdx,
    required this.blockIdx,
    required this.cellKey,
    required this.startTime,
    required this.endTime,
    required this.students,
    required this.isBreakTime,
    required this.isExpanded,
    required this.isDragHighlight,
    this.onTap,
    this.onDragStart,
    this.onDragEnd,
    this.countColor,
    this.activeStudentCount = 0,
    this.cellStudentWithInfos = const [],
    this.groups = const [],
    this.cellWidth = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: isBreakTime
                  ? const Color(0xFF1F1F1F)
                  : isDragHighlight
                      ? const Color(0xFF1976D2).withOpacity(0.18)
                      : Colors.transparent,
              border: Border(
                left: BorderSide(
                  color: Colors.white.withOpacity(0.1),
                ),
              ),
            ),
          ),
          if (isBreakTime)
            Center(
              child: Text(
                '휴식',
                style: TextStyle(
                  color: Colors.grey.shade400,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (activeStudentCount > 0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 28,
                color: countColor ?? Colors.green,
                child: Center(
                  child: Text('$activeStudentCount명', style: TextStyle(color: Colors.white)),
                ),
              ),
            ),
          if (isExpanded && students.isNotEmpty)
            // 학생 카드(간단 버전)
            Positioned.fill(
              child: Wrap(
                spacing: 5,
                runSpacing: 10,
                children: cellStudentWithInfos.map((s) => Container(
                  width: 109,
                  height: 39,
                  margin: EdgeInsets.all(2),
                  color: Colors.grey.shade300,
                  child: Center(child: Text(s.student.name, style: TextStyle(color: Colors.black))),
                )).toList(),
              ),
            ),
        ],
      ),
    );
  }
} 