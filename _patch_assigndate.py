# -*- coding: utf-8 -*-
"""Fix: fallback assignedAt to now for newly assigned homework in todoEntries."""
import os

target = os.path.join('apps', 'yggdrasill', 'lib', 'widgets', 'homework_assign_dialog.dart')

with open(target, 'rb') as f:
    raw = f.read()

src = raw.decode('utf-8')
src = src.replace('\r\n', '\n')

count = 0
def rep(old, new, label=''):
    global src, count
    if old not in src:
        print(f'WARN: [{label}] not found')
        return False
    src = src.replace(old, new, 1)
    count += 1
    print(f'OK: [{label}]')
    return True

# Fix todoEntries: fallback assignedAt to classDateTime (today) when null
rep(
    "    final assignedAt = latestAssignmentByItem[id]?.assignedAt;\n    final assignedDateText =\n        assignedAt == null ? '--.--' : _formatMonthDay(assignedAt);",
    "    final assignedAt = latestAssignmentByItem[id]?.assignedAt ?? classDateTime;\n    final assignedDateText = _formatMonthDay(assignedAt);",
    'todoEntries assignedAt fallback'
)

# Fix classWorkEntries (donut/page2): fallback for group's earliestAssigned
# This is already handled since earliestAssigned can be null and we show '--.--'
# But for page2 학습내역 rows, we should also use classDateTime as fallback
rep(
    "      final tv = line.assignedAt == null ? '' : _formatTime(line.assignedAt);",
    "      final tv = _formatTime(line.assignedAt ?? classDateTime);",
    'classWorkEntries assignedAt fallback'
)

# Fix page2 checkRates: assignedAt fallback
rep(
    "    final dv = line.assignedAt == null ? '--.--' : _formatMonthDay(line.assignedAt!);",
    "    final dv = _formatMonthDay(line.assignedAt ?? classDateTime);",
    'checkRates assignedAt fallback'
)

with open(target, 'wb') as f:
    f.write(src.encode('utf-8'))

print(f'\nDONE: {count} fixes applied')
