/// Converts decoded JSON (a List, or null) into a list of object maps.
/// Used by repositories for list-returning endpoints.
List<Map<String, dynamic>> asJsonList(dynamic data) {
  if (data is! List) return const [];
  return data.whereType<Map<String, dynamic>>().toList();
}
