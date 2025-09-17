import 'package:flutter/material.dart';
import '../models/group_info.dart';
import '../models/group_schedule.dart';
import '../services/data_manager.dart';
import 'package:uuid/uuid.dart';

class GroupScheduleDialog extends StatefulWidget {
  final GroupInfo groupInfo;
  final Function(GroupSchedule) onScheduleSelected;

  const GroupScheduleDialog({
    Key? key,
    required this.groupInfo,
    required this.onScheduleSelected,
  }) : super(key: key);

  @override
  State<GroupScheduleDialog> createState() => _GroupScheduleDialogState();
}

class _GroupScheduleDialogState extends State<GroupScheduleDialog> {
  List<GroupSchedule> _schedules = [];

  @override
  void initState() {
    super.initState();
    _loadSchedules();
  }

  Future<void> _loadSchedules() async {
    final schedules = await DataManager.instance.getGroupSchedules(widget.groupInfo.id);
    setState(() {
      _schedules = schedules;
    });
  }

  String _getDayName(int dayIndex) {
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    return days[dayIndex];
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(
        '${widget.groupInfo.name} 시간표',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          children: [
            if (_schedules.isEmpty)
              const Expanded(
                child: Center(
                  child: Text(
                    '등록된 시간이 없습니다.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _schedules.length,
                  itemBuilder: (context, index) {
                    final schedule = _schedules[index];
                    return Card(
                      color: const Color(0xFF2A2A2A),
                      child: ListTile(
                        title: Text(
                          '${_getDayName(schedule.dayIndex)} ${_formatTime(schedule.startTime)}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.white70),
                              onPressed: () {
                                widget.onScheduleSelected(schedule);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () async {
                                await DataManager.instance.deleteGroupSchedule(schedule.id);
                                await _loadSchedules();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              onPressed: () async {
                // 새 시간 추가
                final newSchedule = GroupSchedule(
                  id: const Uuid().v4(),
                  groupId: widget.groupInfo.id,
                  dayIndex: 0,
                  startTime: DateTime(2024, 1, 1, 14, 0),
                  duration: const Duration(hours: 1),
                  createdAt: DateTime.now(),
                );
                await DataManager.instance.addGroupSchedule(newSchedule);
                await _loadSchedules();
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.add),
              label: const Text('새 시간 추가'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            '닫기',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ],
    );
  }
} 