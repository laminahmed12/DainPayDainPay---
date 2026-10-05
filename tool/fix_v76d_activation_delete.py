from pathlib import Path

script = Path('tool/fix_v76c_activation_delete.py').read_text()
old = "      try:\n        await ref.create({"
new = "      try:\n        final existing = await ref.get();\n        if (existing.exists) continue;\n        await ref.set({"
if old not in script:
    raise SystemExit('activation create anchor not found')
script = script.replace(old, new, 1)
exec(compile(script, 'tool/fix_v76c_activation_delete.py', 'exec'), {'__name__': '__main__'})
