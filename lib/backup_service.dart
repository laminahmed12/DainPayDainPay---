import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

class DainPayBackupResult {
  const DainPayBackupResult({required this.success, this.message = '', this.recoveryCode});

  final bool success;
  final String message;
  final String? recoveryCode;
}

class DainPayBackupService {
  static const _scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const _fileName = 'DainPay_Backup.dpb';
  static const _mime = 'application/octet-stream';
  static const _schema = 1;

  final GoogleSignIn _google = GoogleSignIn(scopes: const [_scope]);
  final http.Client _client = http.Client();
  final AesGcm _aes = AesGcm.with256bits();

  Future<String?> _accessToken() async {
    try {
      GoogleSignInAccount? account = _google.currentUser;
      account ??= await _google.signIn();
      if (account == null) return null;
      final authentication = await account.authentication;
      return authentication.accessToken;
    } on PlatformException catch (e) {
      if (e.code == 'sign_in_failed' &&
          (e.message ?? '').contains('api: 10')) {
        throw StateError(
          'إعداد Google Sign-In غير مكتمل (API 10). '
          'أضف SHA-1 لشهادة إصدار التطبيق في Firebase، '
          'فعّل Google Sign-In، ثم نزّل google-services.json الجديد.',
        );
      }
      rethrow;
    }
  }

  String generateRecoveryCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(20, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  Future<List<int>> _deriveKey(String recoveryCode, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    );
    final key = await kdf.deriveKeyFromPassword(
      password: recoveryCode.trim().toUpperCase(),
      nonce: salt,
    );
    return key.extractBytes();
  }

  Future<String> encrypt(Map<String, dynamic> payload, String recoveryCode) async {
    final salt = _aes.newNonce();
    final keyBytes = await _deriveKey(recoveryCode, salt);
    final key = SecretKey(keyBytes);
    final clear = utf8.encode(jsonEncode(payload));
    final box = await _aes.encrypt(clear, secretKey: key);

    final envelope = <String, dynamic>{
      'format': 'DainPay encrypted backup',
      'version': _schema,
      'algorithm': 'AES-256-GCM',
      'kdf': 'PBKDF2-HMAC-SHA256-120000',
      'salt': base64Encode(salt),
      'secretBox': base64Encode(box.concatenation()),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    return jsonEncode(envelope);
  }

  Future<Map<String, dynamic>> decrypt(String text, String recoveryCode) async {
    final envelope = jsonDecode(text);
    if (envelope is! Map) throw const FormatException('INVALID_BACKUP');
    if (envelope['format'] != 'DainPay encrypted backup') {
      throw const FormatException('INVALID_BACKUP');
    }

    final salt = base64Decode('${envelope['salt']}');
    final raw = base64Decode('${envelope['secretBox']}');
    final keyBytes = await _deriveKey(recoveryCode, salt);
    final key = SecretKey(keyBytes);
    final box = SecretBox.fromConcatenation(
      raw,
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    final clear = await _aes.decrypt(box, secretKey: key);
    final payload = jsonDecode(utf8.decode(clear));
    if (payload is! Map) throw const FormatException('INVALID_BACKUP_DATA');
    return Map<String, dynamic>.from(payload);
  }

  Future<String?> _findFile(String token) async {
    final uri = Uri.parse(
      'https://www.googleapis.com/drive/v3/files'
      '?spaces=appDataFolder'
      '&q=${Uri.encodeQueryComponent("name = '$_fileName' and trashed = false")}'
      '&pageSize=10&fields=files(id,name,modifiedTime)',
    );
    final response = await _client.get(uri, headers: {'Authorization': 'Bearer $token'});
    if (response.statusCode != 200) {
      throw Exception('Drive list failed: ${response.statusCode}');
    }
    final data = jsonDecode(response.body);
    final files = data['files'];
    if (files is List && files.isNotEmpty) return '${files.first['id']}';
    return null;
  }

  Future<String> _upload(String token, String content, {String? fileId}) async {
    final bytes = utf8.encode(content);
    if (fileId == null) {
      final boundary = 'dainpay_${DateTime.now().microsecondsSinceEpoch}';
      final metadata = jsonEncode({'name': _fileName, 'parents': ['appDataFolder']});
      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(utf8.encode('Content-Type: application/json; charset=UTF-8\r\n\r\n'));
      body.addAll(utf8.encode(metadata));
      body.addAll(utf8.encode('\r\n--$boundary\r\n'));
      body.addAll(utf8.encode('Content-Type: $_mime\r\n\r\n'));
      body.addAll(bytes);
      body.addAll(utf8.encode('\r\n--$boundary--\r\n'));

      final response = await _client.post(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: Uint8List.fromList(body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Drive upload failed: ${response.statusCode} ${response.body}');
      }
      return '${jsonDecode(response.body)['id']}';
    }

    final response = await _client.patch(
      Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media&fields=id'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': _mime,
      },
      body: Uint8List.fromList(bytes),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Drive update failed: ${response.statusCode} ${response.body}');
    }
    return fileId;
  }

  Future<String> _download(String token, String fileId) async {
    final response = await _client.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw Exception('Drive download failed: ${response.statusCode}');
    }
    return response.body;
  }

  Future<DainPayBackupResult> backup({
    required Map<String, dynamic> payload,
    required String recoveryCode,
  }) async {
    try {
      final token = await _accessToken();
      if (token == null) {
        return const DainPayBackupResult(success: false, message: 'لم يتم تسجيل الدخول بحساب Google');
      }
      final encrypted = await encrypt(payload, recoveryCode);
      final existing = await _findFile(token);
      await _upload(token, encrypted, fileId: existing);
      return DainPayBackupResult(
        success: true,
        message: 'تم حفظ النسخة المشفرة في Google Drive',
        recoveryCode: recoveryCode,
      );
    } catch (e) {
      return DainPayBackupResult(success: false, message: 'فشل النسخ الاحتياطي: $e');
    }
  }

  Future<Map<String, dynamic>> restore({required String recoveryCode}) async {
    final token = await _accessToken();
    if (token == null) throw Exception('لم يتم تسجيل الدخول بحساب Google');
    final fileId = await _findFile(token);
    if (fileId == null) throw Exception('لم يتم العثور على نسخة DainPay الاحتياطية');
    final encrypted = await _download(token, fileId);
    return decrypt(encrypted, recoveryCode);
  }

  void dispose() => _client.close();
}
