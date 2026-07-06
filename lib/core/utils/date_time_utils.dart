/// Parses a UTC datetime string from the API and returns a local [DateTime].
///
/// ASP.NET Core + EF Core strips [DateTimeKind.Utc] when reading back from
/// SQL Server, so the API often returns strings without a 'Z' suffix
/// (e.g. "2026-03-07T19:48:05" instead of "2026-03-07T19:48:05Z").
/// [DateTime.parse] treats such strings as local time, which is wrong.
/// This helper always interprets the value as UTC before converting to local.
DateTime parseUtc(String s) {
  // A bare date like "2026-03-02Z" has no time component — Dart's DateTime.parse
  // rejects the Z suffix unless a time part is present (e.g. "…T00:00:00Z").
  // For date-only strings, append a midnight time so the Z is valid.
  if (!s.contains('T')) {
    final dateOnly = s.endsWith('Z') ? s.substring(0, s.length - 1) : s;
    return DateTime.parse('${dateOnly}T00:00:00Z').toLocal();
  }
  final normalized = (s.endsWith('Z') || s.contains('+')) ? s : '${s}Z';
  return DateTime.parse(normalized).toLocal();
}

/// Same as [parseUtc] but returns null for null/empty input.
DateTime? parseUtcOrNull(String? s) {
  if (s == null || s.isEmpty) return null;
  return parseUtc(s);
}
