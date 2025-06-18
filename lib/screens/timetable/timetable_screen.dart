import 'package:flutter/material.dart';
import '../../models/class_info.dart';
import '../../models/operating_hours.dart';
import '../../services/data_manager.dart';
import 'components/timetable_header.dart';
import 'views/classes_view.dart';

enum TimetableViewType {
  classes,    // 수업
  schedule;   // 스케줄

  String get name {
    switch (this) {
      case TimetableViewType.classes:
        return '수업';
      case TimetableViewType.schedule:
        return '스케줄';
    }
  }
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
  final MenuController _menuController = MenuController();

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
          const Center(
            child: Text(
              '시간',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Container(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Primary Button
                    SizedBox(
                      width: 110,
                      height: 40,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1976D2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          minimumSize: const Size.fromHeight(40),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(20),
                              right: Radius.circular(4),
                            ),
                          ),
                        ),
                        onPressed: () {
                          // TODO: Implement registration
                        },
                        icon: const Icon(Icons.edit, size: 20),
                        label: const Text(
                          '등록',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    // Menu Button
                    MenuAnchor(
                      controller: _menuController,
                      menuChildren: [
                        MenuItemButton(
                          child: const Text(
                            '학생',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          onPressed: () {
                            // TODO: Implement student registration
                            _menuController.close();
                          },
                        ),
                        ..._classes.map((classInfo) => 
                          MenuItemButton(
                            child: Text(
                              classInfo.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                            onPressed: () {
                              // TODO: Implement class selection
                              _menuController.close();
                            },
                          ),
                        ).toList(),
                      ],
                      style: const MenuStyle(
                        backgroundColor: MaterialStatePropertyAll(Color(0xFF2A2A2A)),
                        padding: MaterialStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
                        shape: MaterialStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
                        ),
                      ),
                      builder: (context, controller, child) {
                        return SizedBox(
                          width: 40,
                          height: 40,
                          child: IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFF1976D2),
                              shape: controller.isOpen 
                                ? const CircleBorder()
                                : const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.horizontal(
                                      left: Radius.circular(4),
                                      right: Radius.circular(20),
                                    ),
                                  ),
                              padding: EdgeInsets.zero,
                            ),
                            icon: Icon(
                              controller.isOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                              color: Colors.white,
                              size: 20,
                            ),
                            onPressed: () {
                              if (controller.isOpen) {
                                controller.close();
                              } else {
                                controller.open();
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: 250,
                    child: SegmentedButton<TimetableViewType>(
                      segments: TimetableViewType.values.map((type) => ButtonSegment(
                        value: type,
                        label: Text(
                          type.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )).toList(),
                      selected: {_viewType},
                      onSelectionChanged: (Set<TimetableViewType> newSelection) {
                        setState(() {
                          _viewType = newSelection.first;
                        });
                      },
                      style: ButtonStyle(
                        backgroundColor: MaterialStateProperty.resolveWith<Color>(
                          (Set<MaterialState> states) {
                            if (states.contains(MaterialState.selected)) {
                              return const Color(0xFF78909C);
                            }
                            return Colors.transparent;
                          },
                        ),
                        foregroundColor: MaterialStateProperty.resolveWith<Color>(
                          (Set<MaterialState> states) {
                            if (states.contains(MaterialState.selected)) {
                              return Colors.white;
                            }
                            return Colors.white70;
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 140),
            ],
          ),
          const SizedBox(height: 24),
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
      case TimetableViewType.schedule:
        return Container(); // TODO: Implement ScheduleView
    }
  }
}