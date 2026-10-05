from pathlib import Path
import re

main = Path('lib/main.dart')
text = main.read_text()

method_pattern = re.compile(r"  Future<bool> deleteCustomer\(Customer customer\) async \{.*?\n  \}\n", re.S)
method_replacement = '''  Future<bool> deleteCustomer(Customer customer) async {
    if (!firebaseReady || uid.isEmpty) return false;

    try {
      await pullCloud();
      if (balance(customer.id) != 0) return false;

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

text, n = method_pattern.subn(method_replacement, text, count=1)
if n != 1:
    raise SystemExit('deleteCustomer method not found')

main.write_text(text)
print('V77_DELETE_FIX_OK')
