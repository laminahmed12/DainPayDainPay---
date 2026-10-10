import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class DainPayBackupResult {
  const DainPayBackupResult({
    required this.success,
    this.message = '',
    this.accountEmail,
    this.localSaved = false,
    this.cloudSaved = false,
  });

  final bool success;
  final String message;
  final String? accountEmail;
  final bool localSaved;
  final bool cloudSaved;
}

class DainPayBackupService {
  static const _scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const _fileName = 'DainPay_Backup.dpb'; // legacy single-file backup
  static const _versionPrefix = 'DainPay_Backup_';
  static const _localA = 'DainPay_Backup_A.dpb';
  static const _localB = 'DainPay_Backup_B.dpb';
  static const _mime = 'application/octet-stream';
  static const _schema = 3;

  final GoogleSignIn _google = GoogleSignIn(scopes: const [_scope]);
  final http.Client _client = http.Client();
  final AesGcm _aes = AesGcm.with256bits();

  Future<void> _localWriteQueue = Future<void>.value();

  Future<Directory> _backupDirectory() async {
    return getApplicationDocumentsDirectory();
  }

  Future<File> _localFile(String name) async {
    final dir = await _backupDirectory();
    return File('${dir.path}/$name');
  }

  Future<bool> saveLocal({
    required Map<String, dynamic> payload,
    required String localKey,
  }) {
    final operation = _localWriteQueue.then(
      (_) => _saveLocalNow(payload: payload, localKey: localKey),
    );
    _localWriteQueue = operation.then<void>(
      (_) {},
      onError: (_) {},
    );
    return operation;
  }

  Future<bool> _saveLocalNow({
    required Map<String, dynamic> payload,
    required String localKey,
  }) async {
    final encrypted = await encrypt(payload, localKey);
    final fileA = await _localFile(_localA);
    final fileB = await _localFile(_localB);

    final aExists = await fileA.exists();
    final bExists = await fileB.exists();

    final File target;
    if (!aExists && bExists) {
      target = fileA;
    } else if (aExists && !bExists) {
      target = fileB;
    } else {
      target =
          DateTime.now().millisecondsSinceEpoch.isEven ? fileA : fileB;
    }

    final temp = File('${target.path}.tmp');
    await temp.writeAsString(encrypted, flush: true);

    // Verify the encrypted envelope before replacing the previous good copy.
    await decrypt(encrypted, localKey);

    if (await target.exists()) {
      await target.delete();
    }
    await temp.rename(target.path);

    // Verify the file after the atomic rename as well.
    final written = await target.readAsString();
    await decrypt(written, localKey);
    return true;
  }

  Future<Map<String, dynamic>> restoreLocal({
    required String localKey,
  }) async {
    return _restoreLocalWithKey(localKey);
  }

  Future<Map<String, dynamic>> _restoreLocalWithKey(String localKey) async {
    final files = <File>[await _localFile(_localA), await _localFile(_localB)];
    final candidates = <Map<String, dynamic>>[];

    for (final file in files) {
      if (!await file.exists()) continue;
      try {
        final text = await file.readAsString();
        final envelope = jsonDecode(text);
        final createdAt = DateTime.tryParse(
          '${envelope is Map ? envelope['createdAt'] : ''}',
        );
        final payload = await decrypt(text, localKey);
        candidates.add({
          'payload': payload,
          'createdAt': createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        });
      } catch (e) {
        debugPrint('Local backup candidate invalid: $e');
      }
    }

    if (candidates.isEmpty) {
      throw StateError('لا توجد نسخة محلية سليمة على هذا الجهاز');
    }

    candidates.sort(
      (a, b) => (b['createdAt'] as DateTime)
          .compareTo(a['createdAt'] as DateTime),
    );
    return Map<String, dynamic>.from(candidates.first['payload'] as Map);
  }

  Future<String?> _accessToken() async {
    try {
      GoogleSignInAccount? account = _google.currentUser;
      account ??= await _google.signInSilently();
      account ??= await _google.signIn();
      if (account == null) return null;
      final authentication = await account.authentication;
      return authentication.accessToken;
    } on PlatformException catch (e) {
      if (e.code == 'sign_in_failed' &&
          (e.message ?? '').contains('api: 10')) {
        throw StateError(
          'إعداد Google Drive غير مكتمل (API 10). '
          'يجب تسجيل SHA-1 لشهادة إصدار التطبيق في Firebase، '
          'تفعيل Google Sign-In وDrive API، ثم تنزيل google-services.json الجديد.',
        );
      }
      rethrow;
    }
  }

  String? get currentGoogleEmail => _google.currentUser?.email;

  Future<void> changeGoogleAccount() async {
    await _google.signOut();
  }

  String driveKeyForAccountId(String accountId) {
    return 'DainPay-Drive-Key-v4-2026-Account-Bound:$accountId';
  }

  Future<List<int>> _deriveKey(String secret, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    );
    final key = await kdf.deriveKeyFromPassword(
      password: secret.trim().toUpperCase(),
      nonce: salt,
    );
    return key.extractBytes();
  }

  Future<String> encrypt(
    Map<String, dynamic> payload,
    String secret,
  ) async {
    final salt = _aes.newNonce();
    final keyBytes = await _deriveKey(secret, salt);
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

  Future<Map<String, dynamic>> decrypt(
    String text,
    String secret,
  ) async {
    final envelope = jsonDecode(text);
    if (envelope is! Map ||
        envelope['format'] != 'DainPay encrypted backup') {
      throw const FormatException('INVALID_BACKUP');
    }

    final salt = base64Decode('${envelope['salt']}');
    final raw = base64Decode('${envelope['secretBox']}');
    final keyBytes = await _deriveKey(secret, salt);
    final key = SecretKey(keyBytes);
    final box = SecretBox.fromConcatenation(
      raw,
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    final clear = await _aes.decrypt(box, secretKey: key);
    final payload = jsonDecode(utf8.decode(clear));
    if (payload is! Map) {
      throw const FormatException('INVALID_BACKUP_DATA');
    }
    return Map<String, dynamic>.from(payload);
  }

  Future<String?> _findFile(String token) async {
    final query = Uri.encodeQueryComponent(
      "(name contains '$_versionPrefix' or name = '$_fileName') "
      "and trashed = false and 'appDataFolder' in parents",
    );
    final uri = Uri.parse(
      'https://www.googleapis.com/drive/v3/files'
      '?spaces=appDataFolder'
      '&q=$query'
      '&pageSize=10&orderBy=modifiedTime desc'
      '&fields=files(id,name,modifiedTime)',
    );
    final response = await _client.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw Exception('Drive list failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final files = data['files'];
    if (files is List && files.isNotEmpty) {
      return '${files.first['id']}';
    }
    return null;
  }

  Future<String> _upload(
    String token,
    String content, {
    String? fileId,
    String fileName = _fileName,
  }) async {
    final bytes = utf8.encode(content);

    if (fileId == null) {
      final boundary = 'dainpay_${DateTime.now().microsecondsSinceEpoch}';
      final metadata = jsonEncode({
        'name': fileName,
        'parents': ['appDataFolder'],
      });
      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(utf8.encode(
        'Content-Type: application/json; charset=UTF-8\r\n\r\n',
      ));
      body.addAll(utf8.encode(metadata));
      body.addAll(utf8.encode('\r\n--$boundary\r\n'));
      body.addAll(utf8.encode('Content-Type: $_mime\r\n\r\n'));
      body.addAll(bytes);
      body.addAll(utf8.encode('\r\n--$boundary--\r\n'));

      final response = await _client.post(
        Uri.parse(
          'https://www.googleapis.com/upload/drive/v3/files'
          '?uploadType=multipart&fields=id',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: Uint8List.fromList(body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Drive upload failed: ${response.statusCode} ${response.body}',
        );
      }
      return '${jsonDecode(response.body)['id']}';
    }

    final response = await _client.patch(
      Uri.parse(
        'https://www.googleapis.com/upload/drive/v3/files/$fileId'
        '?uploadType=media&fields=id',
      ),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': _mime,
      },
      body: Uint8List.fromList(bytes),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Drive update failed: ${response.statusCode} ${response.body}',
      );
    }
    return fileId;
  }

  Future<String> _download(String token, String fileId) async {
    final response = await _client.get(
      Uri.parse(
        'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
      ),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw Exception('Drive download failed: ${response.statusCode}');
    }
    return response.body;
  }

  Future<DainPayBackupResult> backup({
    required Map<String, dynamic> payload,
    required String localKey,
  }) async {
    var localSaved = false;
    var cloudSaved = false;
    String? email;
    Object? cloudError;

    try {
      localSaved = await saveLocal(
        payload: payload,
        localKey: localKey,
      );
    } catch (e) {
      debugPrint('Local backup failed: $e');
    }

    try {
      final token = await _accessToken();
      final account = _google.currentUser;
      email = account?.email;

      if (token != null && account != null) {
        final driveKey = driveKeyForAccountId(account.id);
        final encrypted = await encrypt(payload, driveKey);
        final now = DateTime.now().toUtc();
        final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
            '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
        // Create a new cloud generation every time. Never overwrite the last
        // known-good backup with a possibly incomplete or invalid generation.
        await _upload(
          token,
          encrypted,
          fileName: '$_versionPrefix$stamp.dpb',
        );
        cloudSaved = true;
      }
    } catch (e) {
      cloudError = e;
      debugPrint('Google Drive backup unavailable: $e');
    }

    if (cloudSaved) {
      return DainPayBackupResult(
        success: true,
        message: email == null
            ? 'تم حفظ النسخة محلياً وفي Google Drive.'
            : 'تم حفظ النسخة المشفرة محلياً وفي Google Drive لحساب: $email',
        accountEmail: email,
        localSaved: localSaved,
        cloudSaved: true,
      );
    }

    if (localSaved) {
      return DainPayBackupResult(
        success: true,
        message: cloudError == null
            ? 'تم حفظ النسخة المشفرة محلياً.'
            : 'تم حفظ النسخة محلياً، لكن فشل Google Drive: '
                '${_friendlyCloudError(cloudError)}',
        accountEmail: email,
        localSaved: true,
        cloudSaved: false,
      );
    }

    return DainPayBackupResult(
      success: false,
      message: 'فشل النسخ الاحتياطي المحلي والسحابي: $cloudError',
      accountEmail: email,
    );
  }

  String _friendlyCloudError(Object error) {
    final details = error.toString();
    final normalized = details.toLowerCase();

    if (details.contains('API 10') ||
        normalized.contains('developer_error') ||
        normalized.contains('sign_in_failed')) {
      return 'إعداد تسجيل الدخول من Google غير مكتمل (API 10). '
          'يلزم تسجيل SHA-1 لشهادة توقيع APK في إعدادات تطبيق Android داخل Firebase، '
          'وتفعيل Google Sign-In وGoogle Drive API، ثم تحديث google-services.json.';
    }
    if (details.contains('Drive list failed: 401') ||
        details.contains('Drive upload failed: 401')) {
      return 'انتهت صلاحية تفويض Google. أعد اختيار حساب Google ثم حاول مجدداً.';
    }
    if (details.contains('403')) {
      final lower = details.toLowerCase();
      if (lower.contains('accessnotconfigured') ||
          lower.contains('drive api has not been used') ||
          lower.contains('drive api is disabled')) {
        return 'Google Drive API غير مفعّلة في مشروع Google Cloud المرتبط بالتطبيق. '
            'فعّل Google Drive API في المشروع dainpay-a29fc ثم انتظر بضع دقائق وأعد المحاولة.';
      }
      if (lower.contains('insufficientpermissions') ||
          lower.contains('insufficient permissions') ||
          lower.contains('appnotauthorizedtofile')) {
        return 'Google رفض صلاحية الوصول إلى ملفات Drive. أعد اختيار حساب Google ووافق على صلاحية Drive، '
            'وتحقق من إعداد OAuth ونشر شاشة الموافقة.';
      }
      if (lower.contains('daily limit') || lower.contains('quota')) {
        return 'تجاوز مشروع Google حصة Drive API. راجع الحصص في Google Cloud Console.';
      }
      return 'رفض Google Drive الطلب (403). تفاصيل الخطأ: '
          '${_extractGoogleError(details)}. راجع تفعيل Drive API وصلاحيات OAuth.';
    }
    if (details.contains('Drive list failed: 404') ||
        details.contains('Drive upload failed: 404')) {
      return 'لم يتم العثور على مورد Google Drive المطلوب (404).';
    }
    if (normalized.contains('socketexception') ||
        normalized.contains('failed host lookup') ||
        normalized.contains('network is unreachable')) {
      return 'تعذر الاتصال بالإنترنت أثناء الوصول إلى Google Drive.';
    }
    return details.replaceFirst('Bad state: ', '');
  }

  String _extractGoogleError(String details) {
    final start = details.indexOf('{');
    if (start < 0) return details;
    try {
      final decoded = jsonDecode(details.substring(start));
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final message = error['message'];
          final errors = error['errors'];
          final reason = errors is List && errors.isNotEmpty && errors.first is Map
              ? errors.first['reason']
              : null;
          return [if (reason != null) '$reason', if (message != null) '$message']
              .join(': ');
        }
      }
    } catch (_) {}
    return details;
  }

  Future<Map<String, dynamic>> restore() async {
    final token = await _accessToken();
    final account = _google.currentUser;

    if (token == null || account == null) {
      throw StateError('اختر حساب Google أولاً');
    }

    final fileId = await _findFile(token);
    if (fileId == null) {
      throw StateError('لا توجد نسخة احتياطية لهذا الحساب');
    }

    final encrypted = await _download(token, fileId);
    return decrypt(
      encrypted,
      driveKeyForAccountId(account.id),
    );
  }

  void dispose() => _client.close();
}
