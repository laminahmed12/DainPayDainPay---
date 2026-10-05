from pathlib import Path
import re

main = Path('lib/main.dart')
text = main.read_text()

# Replace the deletion implementation with an authoritative server-checked flow.
method_pattern = re.compile(r"  Future<bool> deleteCustomer\(Customer customer\) async \{.*?\n  \}\n\n  Future<void> deleteVoiceDraft", re.S)
method_replacement = '''  Future<bool> deleteCustomer(Customer customer) async {
    if (!firebaseReady || uid.isEmpty) return false;

    try {
      // Refresh the customer's data from Firestore before making the decision.
      // This prevents a stale local zero balance from bypassing a real cloud debt.
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

      // The customer may only be deleted when the authoritative cloud ledger is zero.
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

  Future<void> deleteVoiceDraft'''

text, n = method_pattern.subn(method_replacement, text, count=1)
if n != 1:
    raise SystemExit('deleteCustomer method not found')

# Ensure the UI always refreshes before evaluating the visible balance.
ui_pattern = re.compile(r"  Future<void> delete\(BuildContext context\) async \{.*?\n  \}\n\n  @override\n  Widget build", re.S)
ui_replacement = '''  Future<void> delete(BuildContext context) async {
    if (!store.firebaseReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الحذف الآمن يحتاج اتصالاً بالإنترنت للتحقق من الرصيد.')),
      );
      return;
    }

    await store.pullCloud();
    if (!context.mounted) return;

    final balance = store.balance(customer.id);
    if (balance != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('لا يمكن حذف العميل. المتبقي عليه ${money(balance)}')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف العميل؟'),
        content: const Text('تم التحقق من الرصيد. سيتم حذف العميل وجميع عملياته نهائياً.'),
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
        const SnackBar(content: Text('تم حذف العميل بنجاح.')),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم رفض الحذف: الرصيد السحابي ليس صفراً أو تعذر الاتصال بالخادم.')),
      );
    }
  }

  @override
  Widget build'''
text, n = ui_pattern.subn(ui_replacement, text, count=1)
if n != 1:
    raise SystemExit('CustomerPage delete UI method not found')

main.write_text(text)
print('V77_DELETE_FIX_OK')
