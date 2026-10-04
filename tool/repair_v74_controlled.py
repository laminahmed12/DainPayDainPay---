from pathlib import Path
import re

MAIN = Path('lib/main.dart')
s = MAIN.read_text(encoding='utf-8')

# Real network state.
if "import 'dart:io';" not in s:
    s = s.replace("import 'dart:convert';", "import 'dart:convert';\nimport 'dart:io';", 1)

if 'bool online = false;' not in s:
    s = s.replace('  bool firebaseReady = false;\n', '  bool firebaseReady = false;\n  bool online = false;\n  Timer? _connectivityTimer;\n', 1)

connect_pattern = re.compile(r"  Future<void> connectFirebase\(\) async \{.*?\n  \}\n\n  CollectionReference", re.S)
connect_replacement = '''  Future<bool> _hasInternet() async {
    try {
      final result = await InternetAddress.lookup('firebase.google.com').timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshConnectivity() async {
    final state = await _hasInternet();
    online = state;
    firebaseReady = firebaseInitialized && online && uid.isNotEmpty;
    safeNotify();
  }

  Future<void> connectFirebase() async {
    if (!firebaseInitialized) {
      online = false;
      firebaseReady = false;
      safeNotify();
      return;
    }
    try {
      var user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) throw StateError('No Firebase user');
      uid = user.uid;
      await _refreshConnectivity();
    } catch (e) {
      online = false;
      firebaseReady = false;
      debugPrint('Firebase connection error: $e');
    }
    _connectivityTimer ??= Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_disposed) return;
      await _refreshConnectivity();
    });
    safeNotify();
  }

  CollectionReference'''
if connect_pattern.search(s):
    s = connect_pattern.sub(connect_replacement, s, count=1)
else:
    raise SystemExit('CONNECTIVITY_METHOD_NOT_FOUND')

if '    _connectivityTimer?.cancel();' not in s:
    s = s.replace('  void dispose() {\n    _disposed = true;', '  void dispose() {\n    _connectivityTimer?.cancel();\n    _connectivityTimer = null;\n    _disposed = true;', 1)

# Activation codes are one-time server records and are NOT bound to an installation/device id.
generate_pattern = re.compile(r"  Future<String\?> generateCode\(String targetDevice\) async \{.*?\n  \}\n\n  Future<bool> activateCode", re.S)
generate_replacement = '''  Future<String?> generateCode(String targetDevice) async {
    if (!firebaseReady || !isAdmin) return null;
    final ref = FirebaseFirestore.instance.collection('activation_codes');
    try {
      for (var i = 0; i < 25; i++) {
        final code = '${100000 + Random.secure().nextInt(900000)}';
        final existing = await ref.doc(code).get();
        if (existing.exists) continue;
        await ref.doc(code).set({
          'used': false,
          'createdAt': FieldValue.serverTimestamp(),
          'createdByUid': uid,
          'deviceId': '',
        });
        final verify = await ref.doc(code).get();
        if (verify.exists && verify.data()?['used'] == false) return code;
      }
    } catch (e) {
      debugPrint('generateCode error: $e');
    }
    return null;
  }

  Future<bool> activateCode'''
if generate_pattern.search(s):
    s = generate_pattern.sub(generate_replacement, s, count=1)
else:
    raise SystemExit('GENERATE_CODE_NOT_FOUND')

activate_pattern = re.compile(r"  Future<bool> activateCode\(String code\) async \{.*?\n  \}\n\n  Future", re.S)
activate_replacement = '''  Future<bool> activateCode(String code) async {
    if (!firebaseReady || uid.isEmpty) return false;
    final clean = _digits(code).trim();
    if (!RegExp(r'^\\d{6}$').hasMatch(clean)) return false;
    try {
      final ref = FirebaseFirestore.instance.collection('activation_codes').doc(clean);
      final ok = await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        if (!snap.exists || data == null || data['used'] == true) return false;
        tx.update(ref, {
          'used': true,
          'usedUid': uid,
          'usedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
      if (!ok) return false;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'activated': true,
        'activatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      activated = true;
      await _pref(() => prefs.setBool('activated', true));
      safeNotify();
      return true;
    } catch (e) {
      debugPrint('activateCode error: $e');
      return false;
    }
  }

  Future'''
if activate_pattern.search(s):
    s = activate_pattern.sub(activate_replacement, s, count=1)
else:
    raise SystemExit('ACTIVATE_CODE_NOT_FOUND')

MAIN.write_text(s, encoding='utf-8')
print('v74 controlled repair applied successfully')
# Trigger a fresh controlled validation run; no production branch changes are made here.
