import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class AnalysisApi {
  final SupabaseClient auth;
  final http.Client client;
  final String baseUrl;
  AnalysisApi(this.auth, this.baseUrl, {http.Client? client})
    : client = client ?? http.Client();

  Future<Map<String, String>> headers() async {
    var session = auth.auth.currentSession;
    if (session == null) throw ApiException('Sign in to continue.');
    if (session.isExpired) session = (await auth.auth.refreshSession()).session;
    if (session == null) throw ApiException('Sign in again to continue.');
    return {'Authorization': 'Bearer ${session.accessToken}'};
  }

  dynamic decode(int status, String body) {
    if (status >= 400) {
      String message = 'The request failed. Please retry.';
      try {
        final detail = jsonDecode(body)['detail'];
        if (detail is String) message = detail;
        if (detail is List && detail.isNotEmpty) {
          message = detail
              .map(
                (item) => item is Map
                    ? '${(item['loc'] as List? ?? []).skip(1).join('.')}: ${item['msg']}'
                    : 'Invalid input',
              )
              .join('\n');
        }
      } catch (_) {}
      throw ApiException(message);
    }
    return jsonDecode(body);
  }

  Future<dynamic> get(String path) async {
    final response = await client
        .get(Uri.parse('$baseUrl$path'), headers: await headers())
        .timeout(const Duration(seconds: 30));
    return decode(response.statusCode, response.body);
  }

  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? data,
  ]) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    request.headers.addAll(await headers());
    request.headers['Content-Type'] = 'application/json';
    if (data != null) request.body = jsonEncode(data);
    final response = await http.Response.fromStream(await client.send(request))
        .timeout(const Duration(seconds: 30));
    return decode(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> submit(Uint8List image, String key) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/v1/analyses'),
    );
    request.headers.addAll(await headers());
    request.headers['Idempotency-Key'] = key;
    request.fields['consent_version'] = 'skin-analysis-v1';
    request.files.add(
      http.MultipartFile.fromBytes('image', image, filename: 'selfie'),
    );
    final response = await http.Response.fromStream(await client.send(request))
        .timeout(const Duration(seconds: 60));
    return Map<String, dynamic>.from(
      decode(response.statusCode, response.body),
    );
  }

  Future<dynamic> converse(Map<String, dynamic> data) async {
    final response = await client
        .post(
          Uri.parse('$baseUrl/v1/looks/conversation'),
          headers: {...await headers(), 'Content-Type': 'application/json'},
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 110));
    return decode(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> submitVto(
    Uint8List image,
    String key,
    Map<String, dynamic> options,
  ) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/v1/vto/jobs'),
    );
    request.headers.addAll(await headers());
    request.headers['Idempotency-Key'] = key;
    request.fields.addAll({
      'consent_version': 'makeup-vto-v1',
      'options': jsonEncode(options),
    });
    request.files.add(
      http.MultipartFile.fromBytes('image', image, filename: 'source.jpg'),
    );
    final response = await http.Response.fromStream(await client.send(request))
        .timeout(const Duration(seconds: 60));
    return Map<String, dynamic>.from(
      decode(response.statusCode, response.body),
    );
  }

  Future<Uint8List> vtoPreview(String jobId) async {
    final response = await client
        .get(
          Uri.parse('$baseUrl/v1/vto/jobs/$jobId/preview'),
          headers: await headers(),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode >= 400) decode(response.statusCode, response.body);
    if (response.bodyBytes.length >= 10000000 ||
        !response.headers['content-type'].toString().startsWith('image/jpeg')) {
      throw ApiException('Invalid preview image. Refresh the job and retry.');
    }
    return response.bodyBytes;
  }

  void close() => client.close();
}
