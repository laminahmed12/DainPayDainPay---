from pathlib import Path

script = Path('tool/fix_v76b_activation_delete.py').read_text()

create_anchor = "      try:\n        await ref.create({"
create_replacement = "      try:\n        final existing = await ref.get();\n        if (existing.exists) continue;\n        await ref.set({"
if create_anchor not in script:
    raise SystemExit('activation create anchor not found')
script = script.replace(create_anchor, create_replacement, 1)

old_block = '''phone_button = ''' + "'''" + '''                      OutlinedButton.icon(
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
''' + "'''" + '''
delete_button = phone_button + ''' + "'''" + '''                      OutlinedButton.icon(
                        onPressed: () => deleteCustomer(context),
                        icon: const Icon(Icons.delete_forever_rounded, color: burgundy),
                        label: const Text('حذف العميل'),
                        style: OutlinedButton.styleFrom(foregroundColor: burgundy),
                      ),
''' + "'''" + '''
if phone_button not in customer_part:
    raise SystemExit('customer phone button anchor not found')
customer_part = customer_part.replace(phone_button, delete_button, 1)'''
new_block = '''delete_button = ''' + "'''" + '''                      OutlinedButton.icon(
                        onPressed: () => deleteCustomer(context),
                        icon: const Icon(Icons.delete_forever_rounded, color: burgundy),
                        label: const Text('حذف العميل'),
                        style: OutlinedButton.styleFrom(foregroundColor: burgundy),
                      ),
''' + "'''" + '''
phone_label_anchor = "                        label: const Text('اتصال'),\\n                      ),"
if phone_label_anchor not in customer_part:
    raise SystemExit('customer phone label anchor not found')
customer_part = customer_part.replace(
    phone_label_anchor,
    phone_label_anchor + "\\n" + delete_button,
    1,
)'''
if old_block not in script:
    raise SystemExit('v76b fragile UI block not found')
script = script.replace(old_block, new_block, 1)

exec(compile(script, 'tool/fix_v76b_activation_delete.py', 'exec'), {'__name__': '__main__'})
