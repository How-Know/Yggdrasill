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
  const TimetableScreen({Key? key}) : super(key: key);

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  DateTime _selectedDate = DateTime.now();
  List<ClassInfo> _classes = [];
  TimetableViewType _viewType = TimetableViewType.classes;
  List<OperatingHours> _operatingHours = [];

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadOperatingHours();
  }

  Future<void> _loadData() async {
    await DataManager.instance.loadClasses();
    setState(() {
      _classes = List.from(DataManager.instance.classes);
    });
  }

  Future<void> _loadOperatingHours() async {
    final hours = await DataManager.instance.getOperatingHours();
    setState(() {
      _operatingHours = hours;
    });
  }

  void _handleDateChanged(DateTime date) {
    setState(() {
      _selectedDate = date;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          TimetableHeader(
            selectedDate: _selectedDate,
            onDateChanged: _handleDateChanged,
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