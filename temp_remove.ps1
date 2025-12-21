$path = "apps/yggdrasill/lib/screens/student/student_course_detail_screen.dart"
$text = [IO.File]::ReadAllText($path)
$start = $text.IndexOf("  Widget _buildHomeworkCard(")
if ($start -ge 0) {
  $end = $text.IndexOf("  _MonthlyDotInfo", $start)
  if ($end -ge 0) {
    $text = $text.Substring(0, $start) + $text.Substring($end)
    [IO.File]::WriteAllText($path, $text)
  }
}

























