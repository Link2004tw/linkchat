// Small helpers for parsing the backend's JSON without crashing on
// missing/renamed/null fields. The backend mixes shapes across endpoints
// (see PLAN.md "Model quirks"), so models stay defensive.

String? asString(dynamic value) => value is String ? value : value?.toString();

int? asInt(dynamic value) =>
    value is int ? value : (value is num ? value.toInt() : null);

bool asBool(dynamic value) => value == true;

/// Backend timestamps arrive as:
///   - epoch **milliseconds** (number) over WebSocket
///   - ISO-8601 strings over REST (the Firestore stores serialize dates)
DateTime? asDateTime(dynamic value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: false).toLocal();
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal();
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toLocal();
    final asMillis = int.tryParse(value);
    if (asMillis != null) {
      return DateTime.fromMillisecondsSinceEpoch(asMillis).toLocal();
    }
  }
  return null;
}
