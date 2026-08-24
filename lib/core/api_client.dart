import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Thrown for any non-2xx response or transport failure.
class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  /// HTTP status code, or `null` for network/timeout failures.
  final int? statusCode;

  final String message;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Minimal REST client for the Fastify backend.
///
/// Every request attaches `Authorization: Bearer <token>` (a Clerk JWT).
/// The token is fetched fresh on each request via [getToken], so Clerk
/// session refresh keeps working without recreating this client.
class ApiClient {  ApiClient({required this.getToken, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Returns the current Clerk JWT; called fresh on every request.
  final Future<String?> Function() getToken;

  final http.Client _http;

  static const Duration _timeout = Duration(seconds: 20);

  /// Performs a GET request and returns the decoded JSON (map or list).
  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  /// Performs a POST request with an optional JSON body.
  Future<dynamic> post(String path, {Object? body}) =>
      _send('POST', path, body: body);

  /// Performs a PUT request with an optional JSON body.
  Future<dynamic> put(String path, {Object? body}) =>
      _send('PUT', path, body: body);

  /// Performs a PATCH request with an optional JSON body.
  Future<dynamic> patch(String path, {Object? body}) =>
      _send('PATCH', path, body: body);

  /// Performs a DELETE request with an optional JSON body.
  Future<dynamic> delete(String path, {Object? body}) =>
      _send('DELETE', path, body: body);

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final token = await getToken();
    if (token == null || token.isEmpty) {
      throw ApiException(401, 'Not authenticated');
    }

    final uri = Uri.parse(AppConfig.api(path));
    final resolvedUri = (query != null && query.isNotEmpty)
        ? uri.replace(queryParameters: {...uri.queryParameters, ...query})
        : uri;
    final request = http.Request(method, resolvedUri);
    request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      final streamed = await _http.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed);
    } on Exception catch (e) {
      throw ApiException(null, 'Network error: $e');
    }

    final decoded = _decode(response.body);
    if (response.statusCode >= 400) {
      final message = switch (decoded) {
        {'error': final String e} => e,
        {'message': final String m} => m,
        _ => 'Request failed (${response.statusCode})',
      };
      throw ApiException(response.statusCode, message);
    }
    return decoded;
  }

  dynamic _decode(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  /// Uploads raw bytes as `multipart/form-data` to the backend's Cloudinary
  /// `POST /upload` route and returns the resulting `url`.
  Future<String> uploadBytes({
    required List<int> bytes,
    required String filename,
  }) async {
    final token = await getToken();
    if (token == null || token.isEmpty) {
      throw ApiException(401, 'Not authenticated');
    }

    final uri = Uri.parse(AppConfig.api('/upload'));
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );

    final http.Response response;
    try {
      final streamed = await _http.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed);
    } on Exception catch (e) {
      throw ApiException(null, 'Network error: $e');
    }

    final decoded = _decode(response.body);
    if (response.statusCode >= 400) {
      final message = switch (decoded) {
        {'error': final String e} => e,
        {'message': final String m} => m,
        _ => 'Upload failed (${response.statusCode})',
      };
      throw ApiException(response.statusCode, message);
    }
    if (decoded is Map<String, dynamic> && decoded['url'] is String) {
      return decoded['url'] as String;
    }
    throw ApiException(response.statusCode, 'Upload failed: no URL returned');
  }

  void dispose() => _http.close();
}
