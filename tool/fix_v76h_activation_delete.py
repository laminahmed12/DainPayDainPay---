from pathlib import Path

main = Path('lib/main.dart')
text = main.read_text()
old = "        await ref.create({"
new = "        final existing = await ref.get();\n        if (existing.exists) continue;\n        await ref.set({"
if old not in text:
    raise SystemExit('unsupported activation create call not found')
text = text.replace(old, new, 1)

for item in [
    'Future<bool> deleteCustomer(Customer customer) async {',
    'if (balance(customer.id) != 0) return false;',
    "'حذف العميل'",
]:
    if item not in text:
        raise SystemExit(f'missing required deletion feature: {item}')

main.write_text(text)
print('V76H_REPAIR_OK')
