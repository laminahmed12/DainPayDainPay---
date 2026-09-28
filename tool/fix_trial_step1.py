from pathlib import Path
import re

p = Path('lib/main.dart')
s = p.read_text(encoding='utf-8')

# 1. Stable Android identifier used only for the trial record. The existing
# activation deviceId is intentionally left untouched so existing activations
# are not invalidated by this change.
if "package:device_info_plus/device_info_plus.dart" not in s:
    s = s.replace("import 'package:cloud_firestore/cloud_firestore.dart';", "import 'package:cloud_firestore/cloud_firestore.dart';\nimport 'package:device_info_plus/device_info_plus.dart';")

old_fields = "String uid='',deviceId='';bool firebaseReady=false,syncing=false,activated=false;DateTime? trialStart;"
new_fields = "String uid='',deviceId='',trialKey='';bool firebaseReady=false,syncing=false,activated=false;DateTime? trialStart;"
if old_fields in s:
    s = s.replace(old_fields, new_fields, 1)
elif "trialKey=''" not in s:
    raise SystemExit('trial fields anchor not found')

# Replace the local-only trial initialization with a stable trial key plus a
# local fallback. Server authority is established in connectFirebase below.
pattern = re.compile(r"s\.deviceId=s\.prefs\.getString\('device_id'\)\??'';if\(s\.deviceId\.isEmpty\)\{s\.deviceId='DP-.*?await s\.prefs\.setString\('device_id',s\.deviceId\);\}final ts=s\.prefs\.getString\('trial_start'\);if\(ts==null\)\{s\.trialStart=DateTime\.now\(\);await s\.prefs\.setString\('trial_start',s\.trialStart!\.toIso8601String\(\)\);\}else\{s\.trialStart=DateTime\.tryParse\(ts\);\}")
replacement = "s.deviceId=s.prefs.getString('device_id')??'';if(s.deviceId.isEmpty){s.deviceId='DP-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';await s.prefs.setString('device_id',s.deviceId);}s.trialKey=s.prefs.getString('trial_key')??'';if(s.trialKey.isEmpty){try{final ai=await DeviceInfoPlugin().androidInfo;final stable=ai.id.trim();if(stable.isNotEmpty&&stable!='unknown')s.trialKey='android:$stable';}catch(_){ }if(s.trialKey.isEmpty)s.trialKey='fallback:${s.deviceId}';await s.prefs.setString('trial_key',s.trialKey);}final ts=s.prefs.getString('trial_start');if(ts!=null)s.trialStart=DateTime.tryParse(ts);"
s, n = pattern.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit('trial initialization anchor not found')

# Server-backed trial record. It is created once per stable trial key and then
# reused after app deletion/reinstallation on the same Android device.
anchor = "Future<void> connectFirebase()async{try{var u=FirebaseAuth.instance.currentUser;u??=(await FirebaseAuth.instance.signInAnonymously()).user;if(u==null)return;uid=u.uid;firebaseReady=true;await pullCloud();await loadActivation();}catch(_){firebaseReady=false;}notifyListeners();}"
replacement_connect = "Future<void> ensureServerTrial()async{if(!firebaseReady||trialKey.isEmpty)return;try{final ref=FirebaseFirestore.instance.collection('trial_devices').doc(trialKey.replaceAll('/','_'));final snap=await ref.get();if(snap.exists&&snap.data()?['startedAt'] is Timestamp){trialStart=(snap.data()!['startedAt'] as Timestamp).toDate();await prefs.setString('trial_start',trialStart!.toIso8601String());}else{await ref.set({'startedAt':FieldValue.serverTimestamp(),'deviceId':deviceId,'createdBy':uid},SetOptions(merge:true));final fresh=await ref.get();final started=fresh.data()?['startedAt'];if(started is Timestamp){trialStart=started.toDate();await prefs.setString('trial_start',trialStart!.toIso8601String());}}}catch(_){}}\nFuture<void> connectFirebase()async{try{var u=FirebaseAuth.instance.currentUser;u??=(await FirebaseAuth.instance.signInAnonymously()).user;if(u==null)return;uid=u.uid;firebaseReady=true;await ensureServerTrial();await pullCloud();await loadActivation();}catch(_){firebaseReady=false;}notifyListeners();}"
if anchor not in s:
    raise SystemExit('connectFirebase anchor not found')
s=s.replace(anchor,replacement_connect,1)

# Make the 10-day calculation explicit and exact in whole calendar hours.
old_trial = "int get trialDaysLeft=>activated||trialStart==null?0:max(0,10-DateTime.now().difference(trialStart!).inDays);"
new_trial = "int get trialDaysLeft{if(activated||trialStart==null)return 0;final remaining=const Duration(days:10)-DateTime.now().difference(trialStart!);return remaining.isNegative?0:remaining.inDays+(remaining.inHours%24>0?1:0);}"
if old_trial in s:
    s=s.replace(old_trial,new_trial,1)

# If the source has already been patched, do not duplicate anything.
p.write_text(s,encoding='utf-8')

# Static verification for this step only.
checks = [
    "device_info_plus/device_info_plus.dart",
    "trialKey",
    "collection('trial_devices')",
    "FieldValue.serverTimestamp()",
    "const Duration(days:10)",
]
missing=[x for x in checks if x not in s]
if missing:
    raise SystemExit('STEP1_VERIFY_FAILED: '+', '.join(missing))
print('STEP1_VERIFY_OK: server-backed 10-day trial source patch applied')
