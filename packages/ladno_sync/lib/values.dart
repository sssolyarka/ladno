/// Calendar dates have no timezone and are never converted through UTC.
DateTime? parseDay(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final date = DateTime.tryParse(value);
  return date != null &&
          dayKey(date) == value &&
          date.year >= 2000 &&
          date.year <= 2199
      ? date
      : null;
}

String dayKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
DateTime nextDay(DateTime due, String repeat, int anchorDay) =>
    switch (repeat) {
      'daily' => DateTime(due.year, due.month, due.day + 1),
      'weekly' => DateTime(due.year, due.month, due.day + 7),
      'monthly' => DateTime(
        due.year,
        due.month + 1,
        anchorDay.clamp(1, DateTime(due.year, due.month + 2, 0).day),
      ),
      _ => throw const FormatException('Неизвестное правило повтора.'),
    };
