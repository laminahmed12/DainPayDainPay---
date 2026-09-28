from pathlib import Path
import re

p = Path('lib/main.dart')
s = p.read_text()

# Gate the app with a 10-day trial / permanent activation.
s = s.replace("home: HomePage(store: store)", "home: SubscriptionGate(store: store)", 1)

# Replace the settings title with a hidden three-tap owner entry point.
s = s.replace("appBar: AppBar(title: const Text('الإعدادات'))", "appBar: AppBar(title: GestureDetector(onTap: _ownerTap, child: const Text('الإعدادات')))", 1)
marker = "class _SettingsPageState extends State<SettingsPage> {"
if marker in s and "int _ownerTaps = 0;" not in s:
    s = s.replace(marker, marker + "\n  int _ownerTaps = 0;\n  void _ownerTap() { _ownerTaps++; if (_ownerTaps >= 3) { _ownerTaps = 0; _showOwnerLogin(); } }\n  Future<void> _showOwnerLogin() async { final c = TextEditingController(); final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('Adreemk'), content: TextField(controller: c, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'رمز الدخول')), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, c.text.trim() == '116936'), child: const Text('دخول'))])); if (ok == true && mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => OwnerPage(store: widget.store))); }\n")

# Inject the subscription and owner screens once.
if "class SubscriptionGate extends StatefulWidget" not in s:
    insert_at = s.rfind("class ReceiptPage")
    if insert_at < 0: insert_at = len(s)
    block = r'''
class SubscriptionGate extends StatefulWidget {
  const SubscriptionGate({super.key, required this.store});
  final Store store;
  @override State<SubscriptionGate> createState() => _SubscriptionGateState();
}

class _SubscriptionGateState extends State<SubscriptionGate> {
  String deviceId = '', code = '';
  bool loading = true, activated = false;
  int days = 10;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = widget.store.prefs;
    deviceId = p.getString('dainpay_device_id') ?? '';
    if (deviceId.isEmpty) { deviceId = '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(900000) + 100000}'; await p.setString('dainpay_device_id', deviceId); }
    activated = p.getBool('dainpay_activated') ?? false;
    final startedRaw = p.getString('dainpay_trial_started');
    if (startedRaw == null) await p.setString('dainpay_trial_started', DateTime.now().toIso8601String());
    final started = DateTime.tryParse(p.getString('dainpay_trial_started') ?? '') ?? DateTime.now();
    days = max(0, 10 - DateTime.now().difference(started).inDays);
    if (mounted) setState(() => loading = false);
  }
  Future<void> activate() async {
    if (code.trim().isEmpty || !widget.store.firebaseReady) return;
    setState(() => loading = true);
    try {
      final q = await FirebaseFirestore.instance.collection('activation_codes').where('code', isEqualTo: code.trim()).where('deviceId', isEqualTo: deviceId).where('used', isEqualTo: false).limit(1).get();
      if (q.docs.isEmpty) throw Exception('invalid');
      await FirebaseFirestore.instance.runTransaction((tx) async { final ref = q.docs.first.reference; final fresh = await tx.get(ref); if (!fresh.exists || (fresh.data()?['used'] == true)) throw Exception('used'); tx.update(ref, {'used': true, 'usedAt': FieldValue.serverTimestamp()}); tx.set(FirebaseFirestore.instance.collection('activations').doc(deviceId), {'deviceId': deviceId, 'code': code.trim(), 'activatedAt': FieldValue.serverTimestamp(), 'permanent': true}); });
      await widget.store.prefs.setBool('dainpay_activated', true);
      if (mounted) setState(() { activated = true; loading = false; });
    } catch (_) { if (mounted) { setState(() => loading = false); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('رمز التفعيل غير صحيح أو غير مخصص لهذا الجهاز.'))); } }
  }
  Future<void> contactSupport() async { final text = Uri.encodeComponent('السلام عليكم، أريد تفعيل DainPay. رقم الجهاز: $deviceId'); final u = Uri.parse('https://wa.me/218934951072?text=$text'); if (await canLaunchUrl(u)) await launchUrl(u, mode: LaunchMode.externalApplication); }
  @override Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (activated) return HomePage(store: widget.store);
    final expired = days <= 0;
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('تفعيل DainPay')), body: ListView(padding: const EdgeInsets.all(18), children: [
      Card(child: ListTile(leading: const Icon(Icons.timer_outlined), title: Text(expired ? 'انتهت الفترة التجريبية' : 'الفترة التجريبية'), subtitle: Text(expired ? 'يلزم التفعيل للاستمرار في إضافة العمليات.' : 'متبقي $days أيام من التجربة المجانية لمدة 10 أيام.'))),
      const SizedBox(height: 12), Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const Text('رقم الجهاز', style: TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 8), SelectableText(deviceId, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)), const SizedBox(height: 12), FilledButton.icon(onPressed: contactSupport, icon: const Icon(Icons.chat), label: const Text('طلب التفعيل عبر واتساب'))]))),
      const SizedBox(height: 12), TextField(onChanged: (v) => code = v, textAlign: TextAlign.center, decoration: const InputDecoration(labelText: 'كود التفعيل', hintText: 'أدخل الكود المخصص لجهازك')), const SizedBox(height: 12), FilledButton(onPressed: activate, child: const Text('تفعيل دائم')),
      const SizedBox(height: 16), const Text('الدفع نقداً فقط. لا توجد بطاقات أو تحويلات داخل التطبيق.', textAlign: TextAlign.center),
    ]));
  }
}

class OwnerPage extends StatefulWidget {
  const OwnerPage({super.key, required this.store}); final Store store;
  @override State<OwnerPage> createState() => _OwnerPageState();
}
class _OwnerPageState extends State<OwnerPage> {
  final device = TextEditingController(); String generated = '';
  String newCode() => '${Random().nextInt(90000000) + 10000000}${Random().nextInt(90) + 10}';
  Future<void> generate() async {
    final d = device.text.trim(); if (d.isEmpty || !widget.store.firebaseReady) return;
    generated = newCode();
    try { await FirebaseFirestore.instance.collection('activation_codes').doc(generated).set({'code': generated, 'deviceId': d, 'used': false, 'createdAt': FieldValue.serverTimestamp()}); if (mounted) setState(() {}); }
    catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر حفظ رمز التفعيل. تحقق من قواعد Firestore.'))); }
  }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('Adreemk — إدارة التفعيل')), body: ListView(padding: const EdgeInsets.all(16), children: [
    const Text('توليد رمز دائم لمرة واحدة لكل عميل', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 12), TextField(controller: device, decoration: const InputDecoration(labelText: 'رقم جهاز العميل')), const SizedBox(height: 10), FilledButton.icon(onPressed: generate, icon: const Icon(Icons.vpn_key), label: const Text('توليد رمز')), if (generated.isNotEmpty) Card(child: Padding(padding: const EdgeInsets.all(18), child: SelectableText(generated, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)))), const SizedBox(height: 18), const Divider(), const Text('الأكواد المسجلة', style: TextStyle(fontWeight: FontWeight.bold)), StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(stream: FirebaseFirestore.instance.collection('activation_codes').orderBy('createdAt', descending: true).limit(50).snapshots(), builder: (_, snap) { if (snap.hasError) return const Text('تعذر قراءة قائمة الأكواد.'); if (!snap.hasData) return const Center(child: CircularProgressIndicator()); return Column(children: snap.data!.docs.map((d) { final x = d.data(); return Card(child: ListTile(title: Text('${x['code'] ?? d.id}'), subtitle: Text('الجهاز: ${x['deviceId'] ?? ''}'), trailing: Text((x['used'] == true) ? 'مستخدم' : 'متاح')); }).toList()); }),
  ]));
}

'''
    s = s[:insert_at] + block + s[insert_at:]

p.write_text(s)
