from pathlib import Path
import re

"""
Safe, idempotent guard for the legacy v74 repair workflow.

The old script attempted to replace connectFirebase() by matching a
CollectionReference immediately after the method, even though the current
class declares its CollectionReference getters before connectFirebase().
It then rewrote activation-code handling to Firebase, which is not part of
this repair and must not happen here.

This script now validates that the existing method is present and syntactically
bounded. It intentionally does not mutate lib/main.dart, activation, Cloudflare,
Firebase configuration, or production services.
"""

MAIN = Path("lib/main.dart")
if not MAIN.is_file():
    raise SystemExit("MAIN_DART_NOT_FOUND")

source = MAIN.read_text(encoding="utf-8")
method = re.search(
    r"(?m)^  Future<void> connectFirebase\(\) async \{",
    source,
)
if method is None:
    raise SystemExit("CONNECTIVITY_METHOD_NOT_FOUND")

# Locate the next peer method/getter after the method declaration. This checks
# that the method has a following class member without assuming its exact type.
next_member = re.search(
    r"(?m)^  (?:Future<|CollectionReference<|Query<|DocumentReference<|void |bool |String |int |static |@override)",
    source[method.end():],
)
if next_member is None:
    raise SystemExit("CONNECTIVITY_METHOD_BOUNDARY_NOT_FOUND")

print("CONNECTIVITY_METHOD_VALIDATED; no source changes required")
