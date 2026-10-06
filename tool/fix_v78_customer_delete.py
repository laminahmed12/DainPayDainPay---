from pathlib import Path
import re

main = Path('lib/main.dart')
text = main.read_text(encoding='utf-8')

# Add a precise deletion diagnostic without weakening the zero-balance safety rule.
marker = "  bool isAdmin = false;\n"
if marker in text and "String lastDeleteError" not in text:
    text = text.replace(marker, marker + "  String lastDeleteError = '';\n", 1)

method_pattern = re.compile(r"  Future<bool> deleteCustomer\(Customer customer\) async \{.*?\n  \}\n", re.S)
method_replacement = '''  Future<bool> deleteCustomer(Customer customer) async {
    lastDeleteError = '';
    if (balance(customer.id) != 0) {
      lastDeleteError = 'الرصيد المحلي ليس صفراً.';
      return false;
    }
    if (!firebaseReady || uid.isEmpty) {
      lastDeleteError = 'لا يوجد اتصال فعلي بقاعدة البيانات السحابية.';
      return false;
    }

    try {
      // Force a fresh server read. Firestore supports Source.server to bypass
      // the offline cache; this is required before an irreversible deletion.
      final txSnap = await transactionRef
          .where('customerId', isEqualTo: customer.id)
          .get(const GetOptions(source: Source.server));

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

      if (cloudBalance != 0) {
        lastDeleteError = 'الرصيد السحابي الحالي ${money(cloudBalance)} وليس صفراً.';
        return false;
      }

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
    } on FirebaseException catch (e) {
      lastDeleteError = 'خطأ Firebase (${e.code}): ${e.message ?? 'تعذر التحقق من الخادم'}';
      debugPrint('Delete customer Firebase error: ${e.code}: ${e.message}');
      return false;
    } catch (e) {
      lastDeleteError = 'تعذر الاتصال بالخادم للتحقق من الرصيد.';
      debugPrint('Delete customer error: $e');
      return false;
    }
  }
'''

text, n = method_pattern.subn(method_replacement, text, count=1)
if n != 1:
    raise SystemExit('V78_DELETE_METHOD_NOT_FOUND')

# Replace the generic failure snackbar with the actual safe diagnostic.
old = "const SnackBar(\n            content:\n                Text('تم رفض الحذف: الرصيد السحابي ليس صفراً أو تعذر التحقق.')),"
new = "SnackBar(content: Text(store.lastDeleteError.isEmpty ? 'تم رفض الحذف.' : store.lastDeleteError)),"
if old in text:
    text = text.replace(old, new, 1)
else:
    raise SystemExit('V78_DELETE_UI_ANCHOR_NOT_FOUND')

main.write_text(text, encoding='utf-8')
print('V78_DELETE_FIX_OK')
