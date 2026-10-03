from pathlib import Path
import re

MAIN = Path('lib/main.dart')
RULES = Path('firestore.rules')
PUBSPEC = Path('pubspec.yaml')

s = MAIN.read_text(encoding='utf-8')

# 1) Real network state, while keeping the existing Firebase/Firestore architecture.
if "import 'dart:io';" not in s:
    s = s.replace("import 'dart:convert';", "import 'dart:convert';\nimport 'dart:io';", 1)

if 'Timer? _connectivityTimer;' not in s:
    anchor = '  bool firebaseInitialized = false;\n'
    if anchor not in s:
        raise SystemExit('CONNECTIVITY_FIELD_ANCHOR_NOT_FOUND')
    s = s.replace(anchor, anchor + "  bool online = false;\n  Timer? _connectivityTimer;\n", 1)

start = s.find('  Future<void> connectFirebase() async {')
end = s.find('  CollectionReference', start)
if start < 0 or end < 0:
    raise SystemExit('CONNECTIVITY_METHOD_ANCHOR_NOT_FOUND')

new_connect = r'''  Future<bool> _hasInternet() async {
    try {
      final result = await InternetAddress.lookup('firebase.google.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshConnectivity({bool notify = true}) async {
    final connected = await _hasInternet();
    final changed = online != connected;
    online = connected;
    firebaseReady = firebaseInitialized && connected && uid.isNotEmpty;
    if (firebaseReady) {
      try {
        await pullCloud();
      } catch (_) {}
    }
    if (notify && (changed || firebaseReady)) safeNotify();
  }

  Future<void> connectFirebase() async {
    if (!firebaseInitialized) {
      firebaseReady = false;
      online = false;
      safeNotify();
      return;
    }

    try {
      var user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) {
        firebaseReady = false;
        online = false;
        safeNotify();
        return;
      }

      uid = user.uid;
      await _refreshConnectivity(notify: false);

      if (firebaseReady) {
        try {
          final profile = await FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .get();
          if (profile.data()?['activated'] == true) {
            activated = true;
            await _pref(() => prefs.setBool('activated', true));
          }
        } catch (_) {}
      }
    } catch (e) {
      firebaseReady = false;
      online = false;
      debugPrint('Firebase connection error: $e');
    }

    _connectivityTimer ??= Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_disposed) return;
      await _refreshConnectivity();
    });

    safeNotify();
  }

'''
s = s[:start] + new_connect + s[end:]

# 2) Stop the connectivity timer when the Store is disposed.
s = s.replace(
    '  void dispose() {\n    _disposed = true;',
    '  void dispose() {\n    _connectivityTimer?.cancel();\n    _connectivityTimer = null;\n    _disposed = true;',
    1,
)

# 3) Durable account recovery without changing the existing anonymous UID on upgrade.
activation_start = s.find('  Future<bool> activateCode(String code) async {')
class_app = s.find('class DainPayApp', activation_start)
if activation_start < 0 or class_app < 0:
    raise SystemExit('ACCOUNT_METHOD_ANCHOR_NOT_FOUND')

new_account_and_activation = r'''  bool get hasPermanentAccount {
    final user = FirebaseAuth.instance.currentUser;
    return user != null && !user.isAnonymous && user.email != null;
  }

  Future<String?> secureAccount(String email, String password) async {
    final cleanEmail = email.trim();
    if (cleanEmail.isEmpty || password.length < 6 || !firebaseReady) {
      return 'أدخل بريدًا صحيحًا وكلمة مرور من 6 أحرف على الأقل، مع توفر الإنترنت.';
    }
    try {
      final current = FirebaseAuth.instance.currentUser;
      if (current == null) return 'لم يتم العثور على حساب الجهاز.';
      if (!current.isAnonymous) return 'الحساب مؤمّن بالفعل.';

      final credential = EmailAuthProvider.credential(
        email: cleanEmail,
        password: password,
      );
      final linked = await current.linkWithCredential(credential);
      uid = linked.user?.uid ?? uid;
      await linked.user?.sendEmailVerification();
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'activated': activated,
        'accountEmail': cleanEmail,
        'accountUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await saveLocal();
      safeNotify();
      return null;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        return 'هذا البريد مرتبط بحساب DainPay آخر. استخدم استعادة الحساب بدل تأمين الحساب الحالي.';
      }
      if (e.code == 'weak-password') return 'كلمة المرور ضعيفة.';
      return 'تعذر تأمين الحساب: ${e.message ?? e.code}';
    } catch (e) {
      return 'تعذر تأمين الحساب: $e';
    }
  }

  Future<String?> restoreAccount(String email, String password) async {
    final cleanEmail = email.trim();
    if (cleanEmail.isEmpty || password.isEmpty || !firebaseInitialized) {
      return 'أدخل البريد وكلمة المرور مع توفر الإنترنت.';
    }
    try {
      await FirebaseAuth.instance.signOut();
      final result = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: cleanEmail,
        password: password,
      );
      final user = result.user;
      if (user == null) return 'تعذر تسجيل الدخول.';
      uid = user.uid;
      online = await _hasInternet();
      firebaseReady = online;
      if (!firebaseReady) return 'لا يوجد اتصال بالإنترنت.';

      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (profile.data()?['activated'] == true) {
        activated = true;
        await _pref(() => prefs.setBool('activated', true));
      }
      await pullCloud();
      await saveLocal();
      safeNotify();
      return null;
    } on FirebaseAuthException catch (e) {
      return 'تعذر الاستعادة: ${e.message ?? e.code}';
    } catch (e) {
      return 'تعذر الاستعادة: $e';
    }
  }

  Future<bool> deleteCustomerSafely(Customer customer) async {
    // Hard safety rule: any non-zero locally calculated balance blocks deletion.
    if (balance(customer.id) != 0) return false;
    if (!firebaseReady || uid.isEmpty) return false;

    try {
      // Recalculate from the authoritative cloud transaction set before deleting.
      final cloud = await transactionRef
          .where('customerId', isEqualTo: customer.id)
          .get();
      var cloudBalance = 0;
      for (final doc in cloud.docs) {
        final data = doc.data();
        final cents = data['amountCents'] is num
            ? (data['amountCents'] as num).toInt()
            : ((data['amount'] is num)
                ? ((data['amount'] as num).toDouble() * 100).round()
                : 0);
        cloudBalance += data['type'] == 'payment' ? -cents : cents;
      }
      if (cloudBalance != 0) return false;

      final batch = FirebaseFirestore.instance.batch();
      batch.delete(customerRef.doc(customer.id));
      for (final doc in cloud.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      customers.removeWhere((c) => c.id == customer.id);
      transactions.removeWhere((t) => t.customerId == customer.id);
      await saveLocal();
      safeNotify();
      return true;
    } catch (e) {
      debugPrint('Customer deletion failed: $e');
      return false;
    }
  }

  Future<bool> activateCode(String code) async {
    if (!firebaseReady || uid.isEmpty) return false;

    final clean = _digits(code).trim();
    if (!RegExp(r'^\d{6}$').hasMatch(clean)) return false;

    try {
      final ref = FirebaseFirestore.instance.collection('activation_codes').doc(clean);
      final ok = await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        if (!snap.exists || data == null || data['used'] == true) return false;
        tx.update(ref, {
          'used': true,
          'usedUid': uid,
          'usedDeviceId': deviceId,
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
      debugPrint('Activation error: $e');
      return false;
    }
  }

  Future<String?> generateCode([String? ignoredTargetDevice]) async {
    if (!firebaseReady || !isAdmin || uid.isEmpty) return null;
    final ref = FirebaseFirestore.instance.collection('activation_codes');

    try {
      for (var i = 0; i < 20; i++) {
        final candidate = '${100000 + Random.secure().nextInt(900000)}';
        final snap = await ref.doc(candidate).get();
        if (snap.exists) continue;
        await ref.doc(candidate).set({
          'deviceId': '',
          'used': false,
          'createdByUid': uid,
          'createdAt': FieldValue.serverTimestamp(),
        });
        final verify = await ref.doc(candidate).get();
        if (verify.exists && verify.data()?['used'] == false) return candidate;
      }
    } catch (e) {
      debugPrint('Activation-code generation error: $e');
    }
    return null;
  }
}

'''
s = s[:activation_start] + new_account_and_activation + s[class_app:]

# 4) Add account recovery UI before SettingsPage.
settings_idx = s.find('class SettingsPage')
if settings_idx < 0:
    raise SystemExit('SETTINGS_ANCHOR_NOT_FOUND')
account_ui = r'''
class AccountRecoveryPage extends StatefulWidget {
  const AccountRecoveryPage({super.key, required this.store});
  final Store store;
  @override State<AccountRecoveryPage> createState() => _AccountRecoveryPageState();
}

class _AccountRecoveryPageState extends State<AccountRecoveryPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> run(Future<String?> Function() action) async {
    setState(() => busy = true);
    final error = await action();
    if (mounted) setState(() => busy = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'تمت العملية بنجاح. احفظ بيانات الدخول في مكان آمن.')),
    );
    if (error == null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final permanent = widget.store.hasPermanentAccount;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('تأمين واستعادة بيانات المحل')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: Icon(permanent ? Icons.verified_user : Icons.cloud_upload),
                title: Text(permanent ? 'الحساب مؤمّن' : 'بياناتك تحتاج إلى تأمين'),
                subtitle: Text(permanent
                    ? 'يمكن استعادة البيانات بعد تغيير الهاتف.'
                    : 'أنشئ حسابًا دائمًا الآن حتى لا تعتمد بياناتك على هذا الهاتف.'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'البريد الإلكتروني')),
            TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور (6 أحرف أو أكثر)')),
            const SizedBox(height: 12),
            if (!permanent)
              FilledButton.icon(
                onPressed: busy ? null : () => run(() => widget.store.secureAccount(email.text, password.text)),
                icon: const Icon(Icons.lock_outline),
                label: Text(busy ? 'جارٍ التأمين...' : 'تأمين الحساب الحالي'),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : () => run(() => widget.store.restoreAccount(email.text, password.text)),
              icon: const Icon(Icons.restore),
              label: Text(busy ? 'جارٍ الاستعادة...' : 'استعادة بيانات حساب سابق'),
            ),
            const SizedBox(height: 12),
            const Text('مهم: لا تحذف البريد وكلمة المرور. هما مفتاح استعادة بيانات المحل على هاتف جديد.'),
          ],
        ),
      ),
    );
  }
}

'''
s = s[:settings_idx] + account_ui + s[settings_idx:]

# 5) Add a recovery icon to HomePage without replacing the existing UI.
home_start = s.find('class HomePage extends StatefulWidget')
home_end = s.find('class AddCustomerPage', home_start)
if home_start < 0 or home_end < 0:
    raise SystemExit('HOME_ANCHOR_NOT_FOUND')
home = s[home_start:home_end]
old_actions = "IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(store: s))))"
new_actions = old_actions + ", IconButton(icon: const Icon(Icons.cloud_sync), tooltip: 'استعادة وتأمين البيانات', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountRecoveryPage(store: s))))"
if old_actions not in home:
    raise SystemExit('HOME_ACTION_ANCHOR_NOT_FOUND')
home = home.replace(old_actions, new_actions, 1)
marker = 'body: ListView(padding: const EdgeInsets.all(12), children: ['
if marker in home and 'العمل المحلي' not in home:
    indicator = "body: ListView(padding: const EdgeInsets.all(12), children: [\n        Card(child: ListTile(leading: Icon(s.firebaseReady ? Icons.cloud_done : Icons.cloud_off), title: Text(s.firebaseReady ? 'متصل بالإنترنت' : 'غير متصل بالإنترنت'), subtitle: Text(s.firebaseReady ? 'المزامنة السحابية فعالة' : 'العمل المحلي مستمر، وستتم المزامنة عند عودة الإنترنت'))),"
    home = home.replace(marker, indicator, 1)
s = s[:home_start] + home + s[home_end:]

# 6) Add a guarded delete action to the existing CustomerPage AppBar.
customer_start = s.find('class CustomerPage')
customer_end = s.find('class AddTransactionPage', customer_start)
if customer_start < 0 or customer_end < 0:
    raise SystemExit('CUSTOMER_ANCHOR_NOT_FOUND')
customer = s[customer_start:customer_end]
appbar_old = 'appBar: AppBar(title: Text(customer.name)),'
if appbar_old not in customer:
    raise SystemExit('CUSTOMER_APPBAR_ANCHOR_NOT_FOUND')
helper = r'''
Future<void> confirmDeleteCustomer(BuildContext context, Store store, Customer customer) async {
  final current = store.balance(customer.id);
  if (current != 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('لا يمكن حذف الزبون. عليه رصيد قدره ${money(current)}. يجب تسوية الحساب بالكامل أولًا.')),
    );
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('حذف الزبون؟'),
      content: const Text('سيتم حذف بيانات الزبون وعملياته بعد التأكد من أن الرصيد صفر. لا يمكن التراجع عن الحذف.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف نهائي')),
      ],
    ),
  ) ?? false;
  if (!confirmed || !context.mounted) return;
  final ok = await store.deleteCustomerSafely(customer);
  if (!context.mounted) return;
  if (ok) {
    Navigator.pop(context);
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تعذر الحذف. تم رفض العملية لأن الرصيد السحابي ليس صفرًا أو لا يوجد اتصال للتحقق.')),
    );
  }
}

'''
if 'Future<void> confirmDeleteCustomer' not in s:
    s = s[:customer_start] + helper + s[customer_start:]
    customer_start = s.find('class CustomerPage')
    customer_end = s.find('class AddTransactionPage', customer_start)
    customer = s[customer_start:customer_end]
customer = customer.replace(appbar_old, "appBar: AppBar(title: Text(customer.name), actions: [IconButton(tooltip: 'حذف الزبون', icon: const Icon(Icons.delete_outline), onPressed: () => confirmDeleteCustomer(context, store, customer))]),", 1)
s = s[:customer_start] + customer + s[customer_end:]

# 7) Remove device-ID presentation from the customer-facing activation/owner UI.
s = re.sub(r"\s*Text\(['\"]رقم الجهاز: \$\{[^}]+\}['\"]\),", '', s)
s = re.sub(r"\s*Text\Field\([^\n]*labelText:\s*['\"]رقم جهاز العميل['\"][^\n]*\),", '', s)

# Replace AdminPage with an unbound one-time-code generator.
admin_start = s.find('class AdminPage extends StatefulWidget')
admin_end = s.find('class ReceiptPage', admin_start)
if admin_start >= 0 and admin_end >= 0:
    admin_ui = r'''class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.store});
  final Store store;
  @override State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  String result = '';
  bool busy = false;
  Future<void> generate() async {
    setState(() { busy = true; result = ''; });
    final code = await widget.store.generateCode();
    if (mounted) setState(() { busy = false; result = code ?? 'تعذر التوليد — تحقق من الإنترنت وصلاحيات Firebase.'; });
  }
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('Adreemk — المالك')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('توليد رمز تفعيل دائم لمرة واحدة لكل محل.'),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: busy ? null : generate, icon: const Icon(Icons.vpn_key), label: Text(busy ? 'جارٍ التوليد...' : 'توليد رمز التفعيل')),
        if (result.isNotEmpty) Card(child: ListTile(title: const Text('النتيجة'), subtitle: SelectableText(result, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)))),
      ]),
    ),
  );
}

'''
    s = s[:admin_start] + admin_ui + s[admin_end:]

# 8) Cleaner account statement: keep exact transaction date + time for camera reconciliation.
stmt_start = s.find('String buildAccountStatement(Store store, Customer customer) {')
stmt_end = s.find('// -----------------------------------------------------------------------------\n// Models', stmt_start)
if stmt_start < 0 or stmt_end < 0:
    raise SystemExit('STATEMENT_ANCHOR_NOT_FOUND')
statement = r'''String buildAccountStatement(Store store, Customer customer) {
  final items = store.transactions.where((t) => t.customerId == customer.id).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final debt = store.debts(customer.id);
  final paid = store.paid(customer.id);
  final balance = store.balance(customer.id);
  final lines = <String>[
    '*${store.shop}*',
    '📋 *كشف حساب*',
    '━━━━━━━━━━━━━━━━━━',
    '👤 *العميل:* ${customer.name}',
    if (customer.phone.trim().isNotEmpty) '📱 *الهاتف:* ${customer.phone.trim()}',
    '📅 *تاريخ الكشف:* ${dateText(DateTime.now())}',
    '',
    '💰 *إجمالي الديون:* ${money(debt)}',
    '💵 *إجمالي المسدد:* ${money(paid)}',
    '🔴 *المتبقي:* ${money(balance)}',
    '📌 *حالة الحساب:* ${balance <= 0 ? 'مسدد' : 'عليه رصيد'}',
    '━━━━━━━━━━━━━━━━━━',
    '🧾 *تفاصيل العمليات:*',
  ];
  if (items.isEmpty) {
    lines.add('لا توجد عمليات مسجلة.');
  } else {
    for (final item in items) {
      final kind = item.type == 'debt' ? 'دَين' : 'تسديد';
      final note = item.note.trim();
      lines.add('• ${dateText(item.date)} — ${timeText(item.date)} — $kind — ${money(item.amountCents)}${note.isEmpty ? '' : ' — $note'}');
    }
  }
  lines.addAll([
    '━━━━━━━━━━━━━━━━━━',
    '🔴 *المبلغ المطلوب حاليًا: ${money(balance)}*',
    '',
    'وقت العملية مسجل تلقائيًا ويمكن استخدامه كمرجع لمراجعة كاميرات المراقبة عند الحاجة.',
  ]);
  return lines.join('\\n');
}

'''
s = s[:stmt_start] + statement + s[stmt_end:]

# 9) Version bump only on this controlled branch.
if 'version: 1.5.3+10' in PUBSPEC.read_text(encoding='utf-8'):
    PUBSPEC.write_text(PUBSPEC.read_text(encoding='utf-8').replace('version: 1.5.3+10', 'version: 1.5.4+11', 1), encoding='utf-8')

# 10) Firestore rules: activation codes are unbound to device; UID records who consumed them.
rules = RULES.read_text(encoding='utf-8')
rules = rules.replace(
"""      allow create: if signedIn()\n        && request.resource.data.used == false\n        && request.resource.data.deviceId is string\n        && request.resource.data.deviceId.size() > 0\n        && request.resource.data.createdByUid == request.auth.uid;""",
"""      allow create: if signedIn()\n        && request.resource.data.used == false\n        && request.resource.data.deviceId is string\n        && request.resource.data.createdByUid == request.auth.uid;""", 1)
rules = rules.replace(
"""      allow update: if signedIn()\n        && resource.data.used == false\n        && request.resource.data.used == true\n        && request.resource.data.usedUid == request.auth.uid\n        && request.resource.data.usedDeviceId == resource.data.deviceId\n        && request.resource.data.usedAt is timestamp;""",
"""      allow update: if signedIn()\n        && resource.data.used == false\n        && request.resource.data.used == true\n        && request.resource.data.usedUid == request.auth.uid\n        && request.resource.data.usedAt is timestamp;""", 1)
RULES.write_text(rules, encoding='utf-8')

# 11) Verification anchors. Fail closed rather than producing a questionable build.
required = [
    "import 'dart:io';",
    'Timer? _connectivityTimer;',
    'Future<bool> _hasInternet() async',
    'Future<String?> secureAccount',
    'Future<String?> restoreAccount',
    'Future<bool> deleteCustomerSafely',
    'Future<String?> generateCode([String? ignoredTargetDevice])',
    'استعادة بيانات حساب سابق',
    'confirmDeleteCustomer',
    'متصل بالإنترنت',
    'وقت العملية مسجل تلقائيًا',
]
missing = [x for x in required if x not in s]
if missing:
    raise SystemExit('V74_VERIFY_FAILED: ' + ', '.join(missing))
MAIN.write_text(s, encoding='utf-8')
print('V74_SOURCE_PATCH_OK')
