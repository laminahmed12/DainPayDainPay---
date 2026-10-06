from pathlib import Path
import re

main = Path('lib/main.dart')
rules = Path('firestore.rules')
text = main.read_text()

# Activation codes: no device binding.
generate_pattern = re.compile(r"  Future<String\?> generateCode\(String targetDevice\) async \{.*?\n  \}\n", re.S)
generate_replacement = '''  Future<String?> generateCode() async {
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
text, count = generate_pattern.subn(generate_replacement, text, count=1)
if count != 1:
    raise SystemExit('generateCode block not found')

text = re.sub(r"\n        final boundDevice = .*?\n        if \(boundDevice\.isNotEmpty && boundDevice != deviceId\) return false;\n", "\n", text, count=1, flags=re.S)
text = text.replace("          'usedDeviceId': deviceId,\n", "")
text = text.replace("        'deviceId': deviceId,\n", "")

# Safe deletion: require online cloud verification and exact zero balance.
anchor = "  Future<void> deleteVoiceDraft(String id) async {\n"
method = '''  Future<bool> deleteCustomer(Customer customer) async {
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
        final raw = data['amountCents'];
        final amount = raw is num
            ? raw.toInt()
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
    raise SystemExit('delete anchor not found')
text = text.replace(anchor, method + anchor, 1)

# Activation screen no longer displays or sends device ID.
text = text.replace("                  SelectableText('رقم الجهاز: ${store.deviceId}'),\n", "")
request_block = re.compile(r"          FilledButton\.icon\(\n            onPressed: \(\) \{\n              launchWhatsApp\(\n                '\+218934951072',\n                'طلب تفعيل DainPay - رقم الجهاز: \$\{store\.deviceId\}',\n              \);\n            \},\n            icon: const Icon\(Icons\.chat\),\n            label: const Text\('طلب رمز عبر واتساب'\),\n          \),\n          const SizedBox\(height: 12\),\n")
text, _ = request_block.subn('', text, count=1)
text = text.replace("'الكود غير صحيح أو مستخدم أو مخصص لجهاز آخر'", "'الكود غير صحيح أو مستخدم'")

# Owner screen: no Device ID input.
text = text.replace("  final device = TextEditingController();\n", "")
text = text.replace("    device.dispose();\n", "")
old_generate = '''    final target = device.text.trim();
    if (target.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل Device ID للعميل')),
      );
      return;
    }

'''
text = text.replace(old_generate, '')
text = text.replace("    final generated = await widget.store.generateCode(target);", "    final generated = await widget.store.generateCode();")
old_field = '''          TextField(
            controller: device,
            decoration: const InputDecoration(
              labelText: 'Device ID للعميل',
              hintText: 'مثال: DP-...',
            ),
          ),
          const SizedBox(height: 12),
'''
text = text.replace(old_field, '''          const Card(
            child: ListTile(
              leading: Icon(Icons.vpn_key_rounded),
              title: Text('رمز دائم لمرة واحدة'),
              subtitle: Text('الرمز غير مرتبط بالهاتف ويمكن استخدامه مرة واحدة فقط.'),
            ),
          ),
''')

# Customer page: guarded delete action.
customer_anchor = '''  @override
  Widget build(BuildContext context) {
'''
delete_ui = '''  Future<void> deleteCustomer(BuildContext context) async {
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
        content: const Text('سيتم حذف العميل وجميع عملياته بعد التحقق من أن الرصيد السحابي يساوي صفرًا.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
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
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم رفض الحذف: الرصيد السحابي ليس صفراً أو تعذر التحقق.')),
      );
    }
  }

'''
# Only inject into CustomerPage, not the first build method elsewhere.
customer_start = text.index('class CustomerPage extends StatelessWidget')
customer_end = text.index('class AccountStatementPage', customer_start)
customer_part = text[customer_start:customer_end]
if customer_anchor not in customer_part:
    raise SystemExit('customer build anchor not found')
customer_part = customer_part.replace(customer_anchor, delete_ui + customer_anchor, 1)
phone_button = '''                      OutlinedButton.icon(
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
'''
delete_button = phone_button + '''                      OutlinedButton.icon(
                        onPressed: () => deleteCustomer(context),
                        icon: const Icon(Icons.delete_forever_rounded, color: burgundy),
                        label: const Text('حذف العميل'),
                        style: OutlinedButton.styleFrom(foregroundColor: burgundy),
                      ),
'''
if phone_button not in customer_part:
    raise SystemExit('customer phone button anchor not found')
customer_part = customer_part.replace(phone_button, delete_button, 1)
text = text[:customer_start] + customer_part + text[customer_end:]

main.write_text(text)

# Firestore rules: one-time activation codes are not device-bound.
rules.write_text('''rules_version = '2';
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

print('V76B_REPAIR_OK')
