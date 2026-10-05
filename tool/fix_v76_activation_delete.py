from pathlib import Path
import re

MAIN = Path('lib/main.dart')
RULES = Path('firestore.rules')
text = MAIN.read_text()

# 1) Activation codes: one-time codes are no longer bound to a device id.
pattern = re.compile(r"  Future<String\?> generateCode\(String targetDevice\) async \{.*?\n  \}\n", re.S)
replacement = '''  Future<String?> generateCode() async {
    if (!firebaseReady || !isAdmin || uid.isEmpty) return null;

    for (var attempt = 0; attempt < 50; attempt++) {
      final code = (100000 + Random.secure().nextInt(900000)).toString();
      final ref = activationCodesRef.doc(code);

      try {
        await ref.create({
          'used': false,
          'createdAt': FieldValue.serverTimestamp(),
          'createdByUid': uid,
        });
        return code;
      } on FirebaseException catch (e) {
        if (e.code == 'already-exists') continue;
        debugPrint('Generate activation code error: ${e.code}: ${e.message}');
        return null;
      } catch (e) {
        debugPrint('Generate activation code error: $e');
        return null;
      }
    }

    return null;
  }
'''
text, n = pattern.subn(replacement, text, count=1)
if n != 1:
    raise SystemExit('generateCode block not found')

# Remove the device binding check and device binding fields from activation.
text = re.sub(
    r"\n        final boundDevice = .*?\n        if \(boundDevice\.isNotEmpty && boundDevice != deviceId\) return false;\n",
    "\n",
    text,
    count=1,
    flags=re.S,
)
text = text.replace("          'usedDeviceId': deviceId,\n", "")
text = text.replace("        'deviceId': deviceId,\n", "")

# 2) Safe customer deletion: only online, only when local and cloud balance are exactly zero.
anchor = "  Future<void> deleteVoiceDraft(String id) async {\n"
delete_method = '''  Future<bool> deleteCustomer(Customer customer) async {
    if (balance(customer.id) != 0) return false;
    if (!firebaseReady || uid.isEmpty) return false;

    try {
      final txSnap = await transactionRef
          .where('customerId', isEqualTo: customer.id)
          .get();

      var cloudBalance = 0;
      for (final doc in txSnap.docs) {
        final data = doc.data();
        final type = '${data['type'] ?? ''}';
        final rawAmount = data['amountCents'];
        final amount = rawAmount is num
            ? rawAmount.toInt()
            : data['amount'] is num
                ? ((data['amount'] as num).toDouble() * 100).round()
                : 0;
        cloudBalance += type == 'debt' ? amount : -amount;
      }

      if (cloudBalance != 0) return false;

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in txSnap.docs) {
        batch.delete(doc.reference);
      }
      batch.delete(customerRef.doc(customer.id));
      await batch.commit();

      transactions.removeWhere((tx) => tx.customerId == customer.id);
      customers.removeWhere((item) => item.id == customer.id);
      await saveLocal();
      safeNotify();
      return true;
    } catch (e) {
      debugPrint('Delete customer error: $e');
      return false;
    }
  }

'''
if anchor not in text:
    raise SystemExit('deleteVoiceDraft anchor not found')
text = text.replace(anchor, delete_method + anchor, 1)

# 3) Activation UI: remove device-specific wording and controls.
text = text.replace("                  SelectableText('رقم الجهاز: ${store.deviceId}'),\n", "")
text = re.sub(
    r"          FilledButton\.icon\(\n            onPressed: \(\) \{\n              launchWhatsApp\(\n                '\+218934951072',\n                'طلب تفعيل DainPay - رقم الجهاز: \$\{store\.deviceId\}',\n              \);\n            \},\n            icon: const Icon\(Icons\.chat\),\n            label: const Text\('طلب رمز عبر واتساب'\),\n          \),\n          const SizedBox\(height: 12\),\n",
    "",
    text,
    count=1,
)
text = text.replace(
    "'الكود غير صحيح أو مستخدم أو مخصص لجهاز آخر'",
    "'الكود غير صحيح أو مستخدم'",
)

# 4) Owner panel: generate without asking for a Device ID.
admin_pattern = re.compile(r"class AdminPage extends StatefulWidget \{.*?\nclass AdminGate", re.S)
admin_replacement = '''class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.store});

  final Store store;

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  String result = '';
  bool busy = false;

  Future<void> generate() async {
    if (busy) return;

    if (!widget.store.firebaseReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Firebase غير متصل. اتصل بالإنترنت ثم حاول مرة أخرى.')),
      );
      return;
    }

    setState(() => busy = true);
    final generated = await widget.store.generateCode();

    if (!mounted) return;
    setState(() {
      busy = false;
      result = generated ?? 'تعذر توليد الرمز — تحقق من اتصال Firebase وقواعد Firestore';
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    return Scaffold(
      appBar: AppBar(title: const Text('إدارة التفعيل')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('وضع المالك'),
              subtitle: Text(store.firebaseReady ? 'متصل بـ Firebase' : 'غير متصل بـ Firebase'),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.vpn_key_rounded),
              title: Text('رمز دائم لمرة واحدة'),
              subtitle: Text('الرمز غير مرتبط بالهاتف، ويمكن للعميل استخدامه مرة واحدة فقط.'),
            ),
          ),
          FilledButton.icon(
            onPressed: busy ? null : generate,
            icon: const Icon(Icons.add_moderator_rounded),
            label: Text(busy ? 'جارٍ التوليد...' : 'توليد رمز تفعيل'),
          ),
          if (result.isNotEmpty)
            Card(
              child: ListTile(
                title: const Text('رمز التفعيل'),
                subtitle: SelectableText(
                  result,
                  style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
                ),
                trailing: result.length == 6
                    ? IconButton(
                        onPressed: () {
                          launchWhatsApp(
                            '+218934951072',
                            'رمز تفعيل DainPay: $result',
                          );
                        },
                        icon: const Icon(Icons.send),
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class AdminGate'''
text, n = admin_pattern.subn(admin_replacement, text, count=1)
if n != 1:
    raise SystemExit('AdminPage block not found')

# 5) Customer page: add an explicit, guarded delete action.
customer_pattern = re.compile(r"class CustomerPage extends StatelessWidget \{.*?\nclass AccountStatementPage", re.S)
customer_replacement = '''class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer});

  final Store store;
  final Customer customer;

  Future<void> openWhatsApp(BuildContext context) async {
    final text = store.whatsappMessage
        .replaceAll('[الاسم]', customer.name)
        .replaceAll('[المبلغ]', money(store.balance(customer.id)));

    final ok = await launchWhatsApp(customer.phone, text);

    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب')),
      );
    }
  }

  Future<void> delete(BuildContext context) async {
    final balance = store.balance(customer.id);

    if (balance != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('لا يمكن حذف العميل. المتبقي عليه ${money(balance)}')),
      );
      return;
    }

    if (!store.firebaseReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الحذف الآمن يحتاج اتصالاً بالإنترنت للتحقق من الرصيد السحابي.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف العميل؟'),
        content: const Text('سيتم حذف العميل وجميع عملياته بعد التحقق من أن رصيده يساوي صفرًا. لا يمكن التراجع عن العملية.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: burgundy),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف نهائي'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final ok = await store.deleteCustomer(customer);
    if (!context.mounted) return;

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف العميل بعد التحقق من أن رصيده صفر.')),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم رفض الحذف: الرصيد السحابي ليس صفراً أو تعذر التحقق.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = store.transactions
        .where((t) => t.customerId == customer.id)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final currentBalance = store.balance(customer.id);

    return Scaffold(
      appBar: AppBar(title: Text(customer.name)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  const Icon(Icons.account_balance_wallet_rounded, size: 36, color: emerald),
                  Text(
                    money(currentBalance),
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900),
                  ),
                  Text(
                    'الدَين ${money(store.debts(customer.id))} • '
                    'المسدد ${money(store.paid(customer.id))}',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => openWhatsApp(context),
                        icon: const Icon(Icons.chat_rounded),
                        label: const Text('واتساب'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AccountStatementPage(
                                store: store,
                                customer: customer,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.receipt_long_rounded),
                        label: const Text('كشف الحساب'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final ok = await makePhoneCall(customer.phone);
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('تعذر إجراء الاتصال')),
                            );
                          }
                        },
                        icon: const Icon(Icons.phone_rounded),
                        label: const Text('اتصال'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => delete(context),
                        icon: const Icon(Icons.delete_forever_rounded, color: burgundy),
                        label: const Text('حذف العميل'),
                        style: OutlinedButton.styleFrom(foregroundColor: burgundy),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (rows.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('لا توجد عمليات بعد')),
              ),
            ),
          ...rows.map(
            (transaction) => Card(
              child: ListTile(
                leading: Icon(
                  transaction.type == 'debt' ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                  color: transaction.type == 'debt' ? burgundy : mint,
                ),
                title: Text(transaction.type == 'debt' ? 'دَين' : 'تسديد'),
                subtitle: Text(
                  '${dateText(transaction.date)} ${timeText(transaction.date)}'
                  '${transaction.note.isEmpty ? '' : ' • ${transaction.note}'}',
                ),
                trailing: Text(
                  money(transaction.amountCents),
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: transaction.type == 'debt' ? burgundy : mint,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: store.locked
            ? () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ActivationPage(store: store)),
                );
              }
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AddTransactionPage(store: store, customer: customer),
                  ),
                );
              },
        icon: Icon(store.locked ? Icons.lock : Icons.swap_horiz_rounded),
        label: Text(store.locked ? 'التفعيل' : 'عملية جديدة'),
      ),
    );
  }
}

class AccountStatementPage'''
text, n = customer_pattern.subn(customer_replacement, text, count=1)
if n != 1:
    raise SystemExit('CustomerPage block not found')

MAIN.write_text(text)

# Firestore rules: activation codes are one-time records, never device-bound.
RULES.write_text('''rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    function signedIn() {
      return request.auth != null;
    }

    match /users/{userId} {
      allow read, write: if signedIn() && request.auth.uid == userId;

      match /customers/{customerId} {
        allow read, write: if signedIn() && request.auth.uid == userId;
      }

      match /transactions/{txId} {
        allow read, write: if signedIn() && request.auth.uid == userId;
      }
    }

    match /activation_codes/{codeId} {
      allow get: if signedIn() && resource.data.used != true;

      allow create: if signedIn()
        && request.resource.data.used == false
        && request.resource.data.createdByUid == request.auth.uid;

      allow update: if signedIn()
        && resource.data.used == false
        && request.resource.data.used == true
        && request.resource.data.usedUid == request.auth.uid
        && request.resource.data.usedAt is timestamp;

      allow delete: if false;
    }
  }
}
''')

print('v76 activation/delete repair applied')
