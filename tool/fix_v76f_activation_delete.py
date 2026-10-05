from pathlib import Path
import re

script = Path('tool/fix_v76b_activation_delete.py').read_text()

# Correct the Firestore API used by the generated activation-code patch.
create_anchor = "        await ref.create({"
create_replacement = "        final existing = await ref.get();\n        if (existing.exists) continue;\n        await ref.set({"
if create_anchor not in script:
    raise SystemExit('activation create call not found in repair script')
script = script.replace(create_anchor, create_replacement, 1)

# Let the base repair script finish writing the main source; the UI is patched below with a robust anchor.
script = script.replace(
    "    raise SystemExit('customer phone button anchor not found')",
    "    pass",
    1,
)

exec(compile(script, 'tool/fix_v76b_activation_delete.py', 'exec'), {'__name__': '__main__'})

main = Path('lib/main.dart')
text = main.read_text()
start = text.index('class CustomerPage extends StatelessWidget')
end = text.index('class AccountStatementPage', start)
customer = text[start:end]

if 'حذف العميل' not in customer:
    anchor = re.compile(r"(\s+label: const Text\('اتصال'\),\n\s+\),)")
    delete_button = '''\n                      OutlinedButton.icon(\n                        onPressed: () => deleteCustomer(context),\n                        icon: const Icon(Icons.delete_forever_rounded, color: burgundy),\n                        label: const Text('حذف العميل'),\n                        style: OutlinedButton.styleFrom(foregroundColor: burgundy),\n                      ),'''
    customer, count = anchor.subn(lambda m: m.group(1) + delete_button, customer, count=1)
    if count != 1:
        raise SystemExit('customer delete UI anchor not found')
    text = text[:start] + customer + text[end:]
    main.write_text(text)

print('V76F_REPAIR_OK')
