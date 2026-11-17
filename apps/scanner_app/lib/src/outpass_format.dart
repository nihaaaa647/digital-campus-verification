String _two(int n) => n.toString().padLeft(2, '0');

String formatDate(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';
String formatTime(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
