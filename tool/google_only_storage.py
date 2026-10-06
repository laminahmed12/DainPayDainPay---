from pathlib import Path

p = Path('lib/main.dart')
s = p.read_text(encoding='utf-8')

# Customer/transaction data must never be read from or written to Firestore.
# Firebase remains available for activation/account administration only.

pull_start = s.find('  Future<void> pullCloud() async {')
pull_end = s.find('\n  Future<void> saveLocal() async {', pull_start)
if pull_start < 0 or pull_end < 0:
    raise SystemExit('PULL_CLOUD_ANCHOR_NOT_FOUND')
s = s[:pull_start] + '''  Future<void> pullCloud() async {\n    // Customer and transaction data are local-first. Google Drive is the\n    // encrypted backup/restore layer; Firestore is not used for customer data.\n    return;\n  }\n''' + s[pull_end:]

old_save = '''  Future<void> save() async {\n    await saveLocal();\n    safeNotify();\n    await syncAll();\n  }'''
new_save = '''  Future<void> save() async {\n    // Primary customer data store: local device.\n    // Backup is explicitly encrypted and stored in the shop's Google Drive.\n    await saveLocal();\n    safeNotify();\n  }'''
if old_save not in s:
    raise SystemExit('SAVE_ANCHOR_NOT_FOUND')
s = s.replace(old_save, new_save, 1)

del_start = s.find('  Future<bool> deleteCustomer(Customer customer) async {')
del_end = s.find('\n  Future<void> deleteVoiceDraft', del_start)
if del_start < 0 or del_end < 0:
    raise SystemExit('DELETE_ANCHOR_NOT_FOUND')
new_delete = '''  Future<bool> deleteCustomer(Customer customer) async {\n    // Deletion is intentionally local because customer data is no longer\n    // stored in Firestore. A customer can only be deleted when the local\n    // authoritative balance is exactly zero.\n    if (balance(customer.id) != 0) return false;\n\n    transactions.removeWhere((tx) => tx.customerId == customer.id);\n    customers.removeWhere((item) => item.id == customer.id);\n    await saveLocal();\n    safeNotify();\n    return true;\n  }\n'''
s = s[:del_start] + new_delete + s[del_end:]

# Keep syncAll harmless if older UI/code still calls it, but never touch Firestore data.
sync_start = s.find('  Future<void> syncAll() async {')
sync_end = s.find('\n  int balance(String customerId)', sync_start)
if sync_start >= 0 and sync_end >= 0:
    s = s[:sync_start] + '''  Future<void> syncAll() async {\n    // Deprecated: customer/transaction cloud sync has been removed in v79.\n    return;\n  }\n''' + s[sync_end:]

p.write_text(s, encoding='utf-8')
print('GOOGLE_ONLY_STORAGE_PATCH_OK')