from pathlib import Path

main = Path('lib/main.dart')
text = main.read_text()

# Keep a legacy deviceId field only for compatibility with already-deployed Firestore rules.
# The activation flow never compares this field, so a code remains transferable across phones.
needle = "          'createdByUid': uid,\n"
replacement = "          'createdByUid': uid,\n          'deviceId': deviceId,\n"
if needle not in text:
    raise SystemExit('activation code payload anchor not found')
if "'deviceId': deviceId," not in text:
    text = text.replace(needle, replacement, 1)

# The customer deletion guard must remain present and require exact zero balance.
required = [
    'Future<bool> deleteCustomer(Customer customer) async {',
    'if (balance(customer.id) != 0) return false;',
    "'حذف العميل'",
]
for item in required:
    if item not in text:
        raise SystemExit(f'missing required deletion feature: {item}')

main.write_text(text)
print('V76G_REPAIR_OK')
