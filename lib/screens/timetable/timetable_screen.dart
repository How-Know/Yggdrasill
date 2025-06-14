import 'package:flutter/material.dart';
import '../../models/class_info.dart';
import '../../models/operating_hours.dart';
import '../../services/data_manager.dart';
import 'components/timetable_header.dart';
import 'views/classes_view.dart';

enum TimetableViewType {
  classes,    // 수업
  classrooms, // 클래스
  makeup,     // 보강
  schedule,   // 스케줄
}

class TimetableScreen extends StatefulWidget {
  final List<ClassInfo> classes;
  
  const TimetableScreen({
    super.key,
    required this.classes,
  });

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  TimetableViewType _viewType = TimetableViewType.classes;
  List<OperatingHours> _operatingHours = [];

  @override
  void initState() {
    super.initState();
    _loadOperatingHours();
  }

  Future<void> _loadOperatingHours() async {
    final hours = await DataManager.instance.getOperatingHours();
    setState(() {
      _operatingHours = hours;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          TimetableHeader(
            viewType: _viewType,
            classes: widget.classes,
            onViewTypeChanged: (viewType) {
              setState(() {
                _viewType = viewType;
              });
            },
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              child: _buildContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_viewType) {
      case TimetableViewType.classes:
        return ClassesView(
          operatingHours: _operatingHours,
          breakTimeColor: const Color(0xFF424242),
        );
      case TimetableViewType.classrooms:
        return Container(); // TODO: Implement ClassroomsView
      case TimetableViewType.makeup:
        return Container(); // TODO: Implement MakeupView
      case TimetableViewType.schedule:
        return Container(); // TODO: Implement ScheduleView
    }
  }
} 