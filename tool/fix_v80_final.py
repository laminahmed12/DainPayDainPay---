from pathlib import Path
import re

main = Path('lib/main.dart')
s = main.read_text(encoding='utf-8')

start_i = s.find('  Future<String?> generateCode(')
end_i = s.find('  Future<bool> activateCode', start_i)
if start_i < 0 or end_i < 0:
    raise SystemExit('GENERATE_CODE_NOT_FOUND')
replacement = '''  Future<String?> generateCode() async {
    if (!firebaseReady || !isAdmin || uid.isEmpty) return null;
    for (var attempt = 0; attempt < 50; attempt++) {
      final code = (100000 + Random.secure().nextInt(900000)).toString();
      final ref = activationCodesRef.doc(code);
      try {
        await ref.set({
          'used': false,
          'createdAt': FieldValue.serverTimestamp(),
          'createdByUid': uid,
          'deviceId': deviceId,
        });
        return code;
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied' || e.code == 'already-exists') {
          continue;
        }
        debugPrint('Generate activation code error: ' + e.code + ': ' + (e.message ?? ''));
        return null;
      } catch (e) {
        debugPrint('Generate activation code error: ' + e.toString());
        return null;
      }
    }
    return null;
  }

'''
s = s[:start_i] + replacement + s[end_i:]
tap = re.compile(r"  void hiddenAdmin\\(\\) \\{.*?\\n  \\}", re.S)
tap_repl = '''  void hiddenAdmin() {
    final now = DateTime.now();
    if (lastTap == null ||
        now.difference(lastTap!).inMilliseconds > 700) {
      taps = 0;
    }
    lastTap = now;
    taps++;
    if (taps == 3) {
      taps = 0;
      lastTap = null;
      showDialog(
        context: context,
        builder: (_) => AdminGate(store: widget.store),
      );
    }
  }'''
s,n=tap.subn(tap_repl,s,count=1)
if n!=1:
    raise SystemExit('HIDDEN_ADMIN_NOT_FOUND')
main.write_text(s, encoding='utf-8')

backup = Path('lib/backup_service.dart')
b = backup.read_text(encoding='utf-8')
if "package:flutter/services.dart" not in b:
    b = b.replace("import 'package:cryptography/cryptography.dart';",
                  "import 'package:cryptography/cryptography.dart';\nimport 'package:flutter/services.dart';",1)
old = """  Future<String?> _accessToken() async {
    GoogleSignInAccount? account = _google.currentUser;
    account ??= await _google.signIn();
    if (account == null) return null;
    final authentication = await account.authentication;
    return authentication.accessToken;
  }"""
new = """  Future<String?> _accessToken() async {
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
          'يجب تسجيل SHA-1 لشهادة إصدار التطبيق في Firebase '
          'وتفعيل Google Sign-In ثم تنزيل google-services.json الجديد.',
        );
      }
      rethrow;
    }
  }"""
if old not in b:
    raise SystemExit('ACCESS_TOKEN_BLOCK_NOT_FOUND')
b=b.replace(old,new,1)
backup.write_text(b,encoding='utf-8')
print("V80_FINAL_PATCH_READY")