from pathlib import Path

p = Path('lib/main.dart')
s = p.read_text(encoding='utf-8')

if "package:device_info_plus/device_info_plus.dart" not in s:
    s = s.replace("import 'package:cloud_firestore/cloud_firestore.dart';", "import 'package:cloud_firestore/cloud_firestore.dart';\nimport 'package:device_info_plus/device_info_plus.dart';", 1)

s = s.replace("String uid='',deviceId='';bool firebaseReady=false,syncing=false,activated=false;DateTime? trialStart;", "String uid='',deviceId='',trialKey='';bool firebaseReady=false,syncing=false,activated=false;DateTime? trialStart;", 1)

start = s.find("s.deviceId=s.prefs.getString('device_id')")
end = s.find("s.activated=s.prefs.getBool('activated')", start)
if start < 0 or end < 0:
    raise SystemExit('STEP1_INIT_ANCHOR_NOT_FOUND')
new_init = "s.deviceId=s.prefs.getString('device_id')??'';if(s.deviceId.isEmpty){s.deviceId='DP-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';await s.prefs.setString('device_id',s.deviceId);}s.trialKey=s.prefs.getString('trial_key')??'';if(s.trialKey.isEmpty){try{final ai=await DeviceInfoPlugin().androidInfo;final stable=ai.id.trim();if(stable.isNotEmpty&&stable!='unknown')s.trialKey='android:$stable';}catch(_){ }if(s.trialKey.isEmpty)s.trialKey='fallback:${s.deviceId}';await s.prefs.setString('trial_key',s.trialKey);}final ts=s.prefs.getString('trial_start');if(ts!=null)s.trialStart=DateTime.tryParse(ts);"
s = s[:start] + new_init + s[end:]

start = s.find("Future<void> connectFirebase()")
end = s.find("CollectionReference", start)
if start < 0 or end < 0:
    raise SystemExit('STEP1_FIREBASE_ANCHOR_NOT_FOUND')
new_firebase = "Future<void> ensureServerTrial()async{if(!firebaseReady||trialKey.isEmpty)return;try{final ref=FirebaseFirestore.instance.collection('trial_devices').doc(trialKey.replaceAll('/','_'));final snap=await ref.get();if(snap.exists&&snap.data()?['startedAt'] is Timestamp){trialStart=(snap.data()!['startedAt'] as Timestamp).toDate();await prefs.setString('trial_start',trialStart!.toIso8601String());}else{await ref.set({'startedAt':FieldValue.serverTimestamp(),'deviceId':deviceId,'createdBy':uid},SetOptions(merge:true));final fresh=await ref.get();final started=fresh.data()?['startedAt'];if(started is Timestamp){trialStart=started.toDate();await prefs.setString('trial_start',trialStart!.toIso8601String());}}}catch(_){}}\nFuture<void> connectFirebase()async{try{var u=FirebaseAuth.instance.currentUser;u??=(await FirebaseAuth.instance.signInAnonymously()).user;if(u==null)return;uid=u.uid;firebaseReady=true;await ensureServerTrial();await pullCloud();await loadActivation();}catch(_){firebaseReady=false;}notifyListeners();}"
s = s[:start] + new_firebase + s[end:]

start = s.find("int get trialDaysLeft")
end = s.find("bool get locked", start)
if start < 0 or end < 0:
    raise SystemExit('STEP1_TRIAL_GETTER_ANCHOR_NOT_FOUND')
new_trial = "int get trialDaysLeft{if(activated||trialStart==null)return 0;final remaining=const Duration(days:10)-DateTime.now().difference(trialStart!);return remaining.isNegative?0:remaining.inDays+(remaining.inHours%24>0?1:0);}"
s = s[:start] + new_trial + s[end:]

p.write_text(s, encoding='utf-8')

required = [
    "device_info_plus/device_info_plus.dart",
    "trialKey",
    "collection('trial_devices')",
    "FieldValue.serverTimestamp()",
    "const Duration(days:10)",
]
missing = [x for x in required if x not in s]
if missing:
    raise SystemExit('STEP1_VERIFY_FAILED: ' + ', '.join(missing))
print('STEP1_VERIFY_OK')
