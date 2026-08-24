/// Formats a date as `dd MMM yyyy` (e.g. `13 Aug 2026`).
String formatDate(DateTime time) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = time.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

/// Formats a timestamp for chat bubbles and list previews:
/// `HH:mm` for today, `dd/MM` otherwise.
String formatTime(DateTime time) {  final now = DateTime.now();
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');

  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return '${two(local.hour)}:${two(local.minute)}';
  }
  return '${two(local.day)}/${two(local.month)}';
}

/// Formats a duration as `m:ss`, e.g. `65 s` → `1:05`.
String formatDuration(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Formats a byte count, e.g. `1048576` → `1.0 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(1)} GB';
}
