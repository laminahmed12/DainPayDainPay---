import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (_) {}
  final store = await Store.load();
  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
String money(double v) => '${v.toStringAsFixed(2)} د.ل';
String dateText(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
String timeText(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String phone218(String value) { var p = value.replaceAll(RegExp(r'[^0-9]'), ''); if (p.startsWith('00')) p = p.substring(2); if (p.startsWith('218')) return p; if (p.startsWith('0')) return '218${p.substring(1)}'; return p; }

Future<bool> openWhatsApp(String phone, String message) async {
  final n = phone218(phone);
  if (n.isEmpty) return false;
  try { return await launchUrl(Uri.https('wa.me', '/$n', {'text': message}), mode: LaunchMode.externalApplication); } catch (_) { return false; }
}

class Customer {
  Customer({required this.id, required this.name, required this.phone, this.limit = 0});
  String id, name, phone; double limit;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'limit': limit};
  factory Customer.fromJson(Map<String, dynamic> j) => Customer(id: '${j['id'] ?? ''}', name: '${j['name'] ?? ''}', phone: '${j['phone'] ?? ''}', limit: (j['limit'] as num?)?.toDouble() ?? 0);
}

class Tx {
  Tx({required this.id, required this.customerId, required this.type, required this.amount, required this.date, required this.note});
  String id, customerId, type, note; double amount; DateTime date;
  Map<String, dynamic> toJson() => {'id': id, 'customerId': customerId, 'type': type, 'amount': amount, 'date': date.toIso8601String(), 'note': note};
  factory Tx.fromJson(Map<String, dynamic> j) => Tx(id: '${j['id'] ?? ''}', customerId: '${j['customerId'] ?? ''}', type: '${j['type'] ?? 'debt'}', amount: (j['amount'] as num?)?.toDouble() ?? 0, date: DateTime.tryParse('${j['date']}') ?? DateTime.now(), note: '${j['note'] ?? ''}');
}

class VoiceDraft {
  VoiceDraft({required this.id, required this.text, required this.date, this.customerId = '', this.amount = 0, this.note = ''});
  String id, text, customerId, note; DateTime date; double amount;
  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'date': date.toIso8601String(), 'customerId': customerId, 'amount': amount, 'note': note};
  factory VoiceDraft.fromJson(Map<String, dynamic> j) => VoiceDraft(id: '${j['id'] ?? ''}', text: '${j['text'] ?? ''}', date: DateTime.tryParse('${j['date']}') ?? DateTime.now(), customerId: '${j['customerId'] ?? ''}', amount: (j['amount'] as num?)?.toDouble() ?? 0, note: '${j['note'] ?? ''}');
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  final customers = <Customer>[];
  final transactions = <Tx>[];
  final voiceDrafts = <VoiceDraft>[];
  String shop = 'DainPay — دَيْن';
  String whatsappMessage = 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  String uid = '', deviceId = '';
  bool firebaseReady = false, syncing = false, activated = false;
  DateTime? trialStart;
  Timer? syncTimer;

  static Future<Store> load() async {
    final s = Store(); s.prefs = await SharedPreferences.getInstance();
    s.shop = s.prefs.getString('shop') ?? s.shop;
    s.whatsappMessage = s.prefs.getString('whatsappMessage') ?? s.whatsappMessage;
    s.deviceId = s.prefs.getString('device_id') ?? '';
    if (s.deviceId.isEmpty) { s.deviceId = 'DP-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}'; await s.prefs.setString('device_id', s.deviceId); }
    final ts = s.prefs.getString('trial_start');
    if (ts == null) { s.trialStart = DateTime.now(); await s.prefs.setString('trial_start', s.trialStart!.toIso8601String()); } else { s.trialStart = DateTime.tryParse(ts); }
    s.activated = s.prefs.getBool('activated') ?? false;
    try { final a = jsonDecode(s.prefs.getString('customers') ?? '[]') as List; s.customers.addAll(a.map((e) => Customer.fromJson(Map<String, dynamic>.from(e)))); } catch (_) {}
    try { final a = jsonDecode(s.prefs.getString('transactions') ?? '[]') as List; s.transactions.addAll(a.map((e) => Tx.fromJson(Map<String, dynamic>.from(e)))); } catch (_) {}
    try { final a = jsonDecode(s.prefs.getString('voice_drafts') ?? '[]') as List; s.voiceDrafts.addAll(a.map((e) => VoiceDraft.fromJson(Map<String, dynamic>.from(e)))); } catch (_) {}
    return s;
  }

  int get trialDaysLeft => activated || trialStart == null ? 0 : max(0, 10 - DateTime.now().difference(trialStart!).inDays);
  bool get locked => !activated && trialDaysLeft <= 0;
  CollectionReference<Map<String, dynamic>> get customersRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('customers');
  CollectionReference<Map<String, dynamic>> get transactionsRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('transactions');

  Future<void> connectFirebase() async {
    try {
      var u = FirebaseAuth.instance.currentUser;
      u ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (u == null) return;
      uid = u.uid; firebaseReady = true;
      await pullCloud();
      await loadActivation();
      syncTimer?.cancel();
      syncTimer = Timer.periodic(const Duration(seconds: 60), (_) => saveCloud());
    } catch (_) { firebaseReady = false; }
    notifyListeners();
  }

  Future<void> loadActivation() async {
    if (!firebaseReady) return;
    try { final d = await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).get(); if (d.data()?['activated'] == true) { activated = true; await prefs.setBool('activated', true); } } catch (_) {}
  }

  Future<void> pullCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      for (final d in (await customersRef.get()).docs) { final c = Customer.fromJson(d.data()); final i = customers.indexWhere((x) => x.id == c.id); if (i < 0) customers.add(c); else customers[i] = c; }
      for (final d in (await transactionsRef.get()).docs) { final x = d.data(); final raw = x['date']; final dt = raw is Timestamp ? raw.toDate() : DateTime.tryParse('$raw') ?? DateTime.now(); final t = Tx(id: '${x['id'] ?? d.id}', customerId: '${x['customerId'] ?? ''}', type: '${x['type'] ?? 'debt'}', amount: (x['amount'] as num?)?.toDouble() ?? 0, date: dt, note: '${x['note'] ?? ''}'); final i = transactions.indexWhere((z) => z.id == t.id); if (i < 0) transactions.add(t); else transactions[i] = t; }
      await saveLocal();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try { final b = FirebaseFirestore.instance.batch(); for (final c in customers) b.set(customersRef.doc(c.id), c.toJson()); for (final t in transactions) b.set(transactionsRef.doc(t.id), {...t.toJson(), 'date': Timestamp.fromDate(t.date)}); await b.commit(); } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveLocal() async {
    await prefs.setString('customers', jsonEncode(customers.map((e) => e.toJson()).toList()));
    await prefs.setString('transactions', jsonEncode(transactions.map((e) => e.toJson()).toList()));
    await prefs.setString('voice_drafts', jsonEncode(voiceDrafts.map((e) => e.toJson()).toList()));
    await prefs.setString('shop', shop); await prefs.setString('whatsappMessage', whatsappMessage);
  }
  Future<void> save() async { await saveLocal(); notifyListeners(); await saveCloud(); }
  double balance(String id) => transactions.where((t) => t.customerId == id).fold(0.0, (a, t) => a + (t.type == 'debt' ? t.amount : -t.amount));
  double debts(String id) => transactions.where((t) => t.customerId == id && t.type == 'debt').fold(0.0, (a, t) => a + t.amount);
  double paid(String id) => transactions.where((t) => t.customerId == id && t.type == 'payment').fold(0.0, (a, t) => a + t.amount);
  String risk(String id) { final b = balance(id); if (b <= 0) return 'مسدد'; final ds = transactions.where((t) => t.customerId == id && t.type == 'debt').toList()..sort((a, b) => a.date.compareTo(b.date)); if (ds.isEmpty) return 'حديث'; final days = DateTime.now().difference(ds.first.date).inDays; if (days > 90) return 'خطر'; if (days > 30) return 'متأخر'; return 'حديث'; }

  Future<bool> activateCode(String code) async {
    if (!firebaseReady || code.trim().isEmpty) return false;
    final ref = FirebaseFirestore.instance.collection('activation_codes').doc(code.trim());
    try {
      final ok = await FirebaseFirestore.instance.runTransaction<bool>((tx) async { final snap = await tx.get(ref); final d = snap.data(); if (!snap.exists || d == null || d['used'] == true) return false; final bound = '${d['deviceId'] ?? ''}'; if (bound.isNotEmpty && bound != deviceId) return false; tx.update(ref, {'used': true, 'usedAt': FieldValue.serverTimestamp(), 'usedDeviceId': deviceId}); return true; });
      if (!ok) return false;
      await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).set({'activated': true, 'activatedAt': FieldValue.serverTimestamp(), 'uid': uid});
      activated = true; await prefs.setBool('activated', true); notifyListeners(); return true;
    } catch (_) { return false; }
  }

  Future<String?> generateCode(String targetDevice) async {
    if (!firebaseReady || targetDevice.trim().isEmpty) return null;
    try {
      String code;
      do { code = (100000 + Random().nextInt(900000)).toString(); } while ((await FirebaseFirestore.instance.collection('activation_codes').doc(code).get()).exists);
      await FirebaseFirestore.instance.collection('activation_codes').doc(code).set({'deviceId': targetDevice.trim(), 'used': false, 'createdAt': FieldValue.serverTimestamp()}).timeout(const Duration(seconds: 12));
      return code;
    } catch (_) { return null; }
  }

  Future<void> clearLocal() async { customers.clear(); transactions.clear(); voiceDrafts.clear(); await prefs.remove('customers'); await prefs.remove('transactions'); await prefs.remove('voice_drafts'); notifyListeners(); }
  @override void dispose() { syncTimer?.cancel(); super.dispose(); }
}

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store}); final Store store;
  ThemeData theme(Brightness b) => ThemeData(useMaterial3: true, brightness: b, colorSchemeSeed: const Color(0xFF0F5C6E), fontFamily: 'Cairo');
  @override Widget build(BuildContext c) => AnimatedBuilder(animation: store, builder: (_, __) => MaterialApp(debugShowCheckedModeBanner: false, theme: theme(Brightness.light), darkTheme: theme(Brightness.dark), themeMode: ThemeMode.system, home: HomePage(store: store)));
}

class HomePage extends StatefulWidget { const HomePage({super.key, required this.store}); final Store store; @override State<HomePage> createState() => _HomePageState(); }
class _HomePageState extends State<HomePage> {
  String query = '', filter = 'all'; int taps = 0; DateTime? lastTap;
  void hidden() { final n = DateTime.now(); if (lastTap == null || n.difference(lastTap!).inSeconds > 2) taps = 0; lastTap = n; taps++; if (taps == 3) { taps = 0; showDialog(context: context, builder: (_) => AdminGate(store: widget.store)); } }
  @override Widget build(BuildContext c) {
    final s = widget.store;
    final list = s.customers.where((x) { final b = s.balance(x.id); return (query.isEmpty || x.name.contains(query) || x.phone.contains(query)) && (filter == 'all' || (filter == 'debt' && b > 0) || (filter == 'paid' && b <= 0)); }).toList()..sort((a, b) => s.balance(b.id).compareTo(s.balance(a.id)));
    final old = list.where((x) { final ds = s.transactions.where((t) => t.customerId == x.id && t.type == 'debt').toList()..sort((a, b) => a.date.compareTo(b.date)); return s.balance(x.id) > 0 && ds.isNotEmpty && DateTime.now().difference(ds.first.date).inDays > 90; }).length;
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: GestureDetector(onTap: hidden, child: Text(s.shop, style: const TextStyle(fontWeight: FontWeight.bold))), actions: [IconButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => SettingsPage(store: s))), icon: const Icon(Icons.settings_outlined))]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (!s.activated) Card(child: ListTile(title: Text(s.locked ? 'انتهت الفترة التجريبية' : 'التجربة المجانية 10 أيام'), subtitle: Text(s.locked ? 'يلزم التفعيل' : 'متبقٍ ${s.trialDaysLeft} أيام'), trailing: FilledButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ActivationPage(store: s))), child: const Text('تفعيل')))),
        if (old > 0) Card(color: Colors.red.shade50, child: ListTile(leading: const Icon(Icons.warning_amber), title: const Text('ديون قديمة معلّقة'), subtitle: Text('$old عميل لديه دين أقدم من 90 يومًا'))),
        Card(child: ListTile(leading: const Icon(Icons.mic), title: const Text('التسجيل الصوتي'), subtitle: Text(s.voiceDrafts.isEmpty ? 'سجل ملاحظة صوتية وحوّلها لمسودة للمراجعة' : '${s.voiceDrafts.length} مسودة بانتظار المراجعة'), onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => VoiceDraftsPage(store: s))))),
        TextField(decoration: const InputDecoration(hintText: 'بحث بالاسم أو الهاتف', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => query = v)),
        Wrap(spacing: 8, children: [ChoiceChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) => setState(() => filter = 'all')), ChoiceChip(label: const Text('عليهم دين'), selected: filter == 'debt', onSelected: (_) => setState(() => filter = 'debt')), ChoiceChip(label: const Text('مسدد'), selected: filter == 'paid', onSelected: (_) => setState(() => filter = 'paid'))]),
        ...list.map((x) => Card(child: ListTile(onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CustomerPage(store: s, customer: x))), title: Text(x.name), subtitle: Text('${x.phone}\n${s.risk(x.id)} • دين ${money(s.debts(x.id))} • مسدد ${money(s.paid(x.id))}'), isThreeLine: true, trailing: Text(money(s.balance(x.id)), style: const TextStyle(fontWeight: FontWeight.bold)))))
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: s.locked ? () => Navigator.push(c, MaterialPageRoute(builder: (_) => ActivationPage(store: s))) : () => Navigator.push(c, MaterialPageRoute(builder: (_) => AddCustomerPage(store: s))), icon: Icon(s.locked ? Icons.lock : Icons.person_add), label: Text(s.locked ? 'التفعيل' : 'عميل')),
    ));
  }
}

class AddCustomerPage extends StatefulWidget { const AddCustomerPage({super.key, required this.store}); final Store store; @override State<AddCustomerPage> createState() => _AddCustomerPageState(); }
class _AddCustomerPageState extends State<AddCustomerPage> {
  final name = TextEditingController(), phone = TextEditingController(), limit = TextEditingController();
  @override void dispose() { name.dispose(); phone.dispose(); limit.dispose(); super.dispose(); }
  Future<void> save() async { if (name.text.trim().isEmpty) return; widget.store.customers.add(Customer(id: makeId(), name: name.text.trim(), phone: phone.text.trim(), limit: double.tryParse(limit.text.replaceAll(',', '.')) ?? 0)); await widget.store.save(); if (mounted) Navigator.pop(context); }
  @override Widget build(BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('إضافة عميل')), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل')), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')), TextField(controller: limit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'السقف الائتماني اختياري')), FilledButton(onPressed: save, child: const Text('حفظ'))])));
}

String statementFor(Store s, Customer c) {
  final rows = s.transactions.where((t) => t.customerId == c.id).toList()..sort((a, b) => a.date.compareTo(b.date));
  var running = 0.0;
  final b = StringBuffer();
  b.writeln('كشف حساب — ${s.shop}'); b.writeln('الزبون: ${c.name}'); b.writeln('الهاتف: ${c.phone}'); b.writeln('────────────────');
  b.writeln('التاريخ | البيان | دَين | تسديد | الرصيد');
  for (final t in rows) { running += t.type == 'debt' ? t.amount : -t.amount; b.writeln('${dateText(t.date)} | ${t.note.isEmpty ? (t.type == 'debt' ? 'دَين' : 'تسديد') : t.note} | ${t.type == 'debt' ? t.amount.toStringAsFixed(2) : '-'} | ${t.type == 'payment' ? t.amount.toStringAsFixed(2) : '-'} | ${running.toStringAsFixed(2)}'); }
  b.writeln('────────────────'); b.writeln('إجمالي الدين: ${money(s.debts(c.id))}'); b.writeln('إجمالي التسديد: ${money(s.paid(c.id))}'); b.writeln('المتبقي: ${money(s.balance(c.id))}');
  return b.toString();
}

String paymentReceipt(Store s, Customer c, double amount, DateTime date) => 'وصل استلام — ${s.shop}\nالزبون: ${c.name}\nالمبلغ المستلم: ${money(amount)}\nالتاريخ: ${dateText(date)} ${timeText(date)}\nالمتبقي بعد التسديد: ${money(s.balance(c.id))}\nشكرًا لكم.';

class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer}); final Store store; final Customer customer;
  Future<void> wa(BuildContext c) async { if (!await openWhatsApp(customer.phone, store.whatsappMessage.replaceAll('[الاسم]', customer.name).replaceAll('[المبلغ]', money(store.balance(customer.id)))) && c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب'))); }
  Future<void> statement(BuildContext c) async { if (!await openWhatsApp(customer.phone, statementFor(store, customer)) && c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب'))); }
  Future<void> call(BuildContext c) async { if (!await launchUrl(Uri.parse('tel:${customer.phone}'), mode: LaunchMode.externalApplication) && c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('تعذر فتح الاتصال'))); }
  @override Widget build(BuildContext c) { final a = store.transactions.where((t) => t.customerId == customer.id).toList()..sort((a, b) => b.date.compareTo(a.date)); return Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text(customer.name)), body: ListView(padding: const EdgeInsets.all(12), children: [Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [Text(money(store.balance(customer.id)), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'), Text('السقف الائتماني: ${customer.limit <= 0 ? 'غير محدد' : money(customer.limit)}'), Wrap(spacing: 8, children: [FilledButton.icon(onPressed: () => wa(c), icon: const Icon(Icons.chat), label: const Text('تذكير')), OutlinedButton.icon(onPressed: () => statement(c), icon: const Icon(Icons.receipt_long), label: const Text('كشف حساب')), OutlinedButton.icon(onPressed: () => call(c), icon: const Icon(Icons.phone), label: const Text('اتصال'))])]))), ...a.map((t) => ListTile(title: Text(t.type == 'debt' ? 'دَين' : 'تسديد'), subtitle: Text('${dateText(t.date)} ${timeText(t.date)}${t.note.isEmpty ? '' : ' • ${t.note}'}'), trailing: Text(money(t.amount))))]), floatingActionButton: FloatingActionButton.extended(onPressed: store.locked ? () => Navigator.push(c, MaterialPageRoute(builder: (_) => ActivationPage(store: store))) : () => Navigator.push(c, MaterialPageRoute(builder: (_) => AddTransactionPage(store: store, customer: customer))), icon: Icon(store.locked ? Icons.lock : Icons.add), label: Text(store.locked ? 'التفعيل' : 'عملية')))); }
}

class AddTransactionPage extends StatefulWidget { const AddTransactionPage({super.key, required this.store, required this.customer}); final Store store; final Customer customer; @override State<AddTransactionPage> createState() => _AddTransactionPageState(); }
class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount = TextEditingController(), note = TextEditingController(); String type = 'debt';
  @override void dispose() { amount.dispose(); note.dispose(); super.dispose(); }
  double? spokenAmount(String text) { final m = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(text); if (m != null) return double.tryParse(m.group(1)!.replaceAll(',', '.')); const words = {'صفر':0,'واحد':1,'واحدة':1,'اثنين':2,'ثلاثة':3,'أربعة':4,'اربعة':4,'خمسة':5,'ستة':6,'سبعة':7,'ثمانية':8,'تسعة':9,'عشرة':10,'عشرين':20,'ثلاثين':30,'أربعين':40,'خمسين':50,'ستين':60,'سبعين':70,'ثمانين':80,'تسعين':90,'مية':100,'مائة':100,'مئة':100,'ألف':1000}; for (final e in words.entries) { if (text.contains(e.key)) return e.value.toDouble(); } return null; }
  Future<void> saveTx({String? spokenText}) async { final v = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0; if (v <= 0) return; final current = widget.store.balance(widget.customer.id); if (type == 'debt' && widget.customer.limit > 0 && current + v > widget.customer.limit) { if (mounted) await showDialog(context: context, builder: (_) => AlertDialog(title: const Text('تجاوز السقف الائتماني'), content: Text('السقف ${money(widget.customer.limit)} والمتاح ${money(max(0, widget.customer.limit - current))}.'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('حسنًا'))])); return; } final now = DateTime.now(); widget.store.transactions.add(Tx(id: makeId(), customerId: widget.customer.id, type: type, amount: v, date: now, note: spokenText ?? note.text.trim())); await widget.store.save(); if (!mounted) return; Navigator.pop(context, type == 'payment' ? paymentReceipt(widget.store, widget.customer, v, now) : null); }
  @override Widget build(BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text(type == 'debt' ? 'إضافة دَين' : 'تسجيل تسديد')), body: ListView(padding: const EdgeInsets.all(16), children: [SegmentedButton<String>(segments: const [ButtonSegment(value:'debt', label:Text('دَين')), ButtonSegment(value:'payment', label:Text('تسديد'))], selected:{type}, onSelectionChanged:(v)=>setState(()=>type=v.first)), TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal:true), decoration: const InputDecoration(labelText:'المبلغ بالدينار الليبي')), TextField(controller: note, decoration: const InputDecoration(labelText:'ملاحظات')), FilledButton(onPressed:()=>saveTx(), child: const Text('حفظ العملية'))])));
}

class VoiceDraftsPage extends StatefulWidget { const VoiceDraftsPage({super.key, required this.store}); final Store store; @override State<VoiceDraftsPage> createState()=>_VoiceDraftsPageState(); }
class _VoiceDraftsPageState extends State<VoiceDraftsPage> {
  final speech = stt.SpeechToText(); bool listening=false; String live='';
  @override void dispose(){ speech.stop(); super.dispose(); }
  double? parseAmount(String text){ final m=RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(text); if(m!=null)return double.tryParse(m.group(1)!.replaceAll(',','.')); const w={'مية':100,'مائة':100,'مئة':100,'ألف':1000,'الف':1000,'عشرة':10,'عشرين':20,'ثلاثين':30,'أربعين':40,'خمسين':50,'ستين':60,'سبعين':70,'ثمانين':80,'تسعين':90}; for(final e in w.entries){if(text.contains(e.key))return e.value.toDouble();} return null; }
  String matchCustomer(String text){ for(final c in widget.store.customers){if(text.contains(c.name))return c.id;} return ''; }
  Future<void> record() async { if(listening){await speech.stop();if(mounted)setState(()=>listening=false);return;} final ok=await speech.initialize(onStatus:(x){if(mounted&&x=='notListening')setState(()=>listening=false);},onError:(_){if(mounted)setState(()=>listening=false);}); if(!ok){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('لم يتم السماح بالميكروفون أو لم يتوفر محرك التعرف على الكلام')));return;} setState(()=>listening=true); await speech.listen(localeId:'ar-LY',partialResults:true,onResult:(r){if(mounted)setState(()=>live=r.recognizedWords); if(r.finalResult){final text=r.recognizedWords.trim(); if(text.isNotEmpty){final d=VoiceDraft(id:makeId(),text:text,date:DateTime.now(),customerId:matchCustomer(text),amount:parseAmount(text)??0,note:text); widget.store.voiceDrafts.insert(0,d); widget.store.save();} if(mounted)setState(()=>listening=false);}}); }
  @override Widget build(BuildContext c){final drafts=widget.store.voiceDrafts;return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('المسودات الصوتية')),body:ListView(padding:const EdgeInsets.all(12),children:[Card(child:ListTile(leading:Icon(listening?Icons.stop:Icons.mic),title:Text(listening?'جارٍ التسجيل...':'اضغط للتسجيل'),subtitle:Text(live.isEmpty?'مثال: محمد 100 دينار بضاعة':'$live'),onTap:record)),if(drafts.isEmpty)const Padding(padding:EdgeInsets.all(24),child:Center(child:Text('لا توجد مسودات'))),...drafts.map((d)=>Card(child:ListTile(title:Text(d.customerId.isEmpty?'عميل غير محدد':widget.store.customers.firstWhere((x)=>x.id==d.customerId,orElse:()=>Customer(id:'',name:'غير معروف',phone:'')).name),subtitle:Text('${d.text}\nالمبلغ: ${money(d.amount)}'),isThreeLine:true,onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>VoiceReviewPage(store:widget.store,draft:d))))))]));}
}

class VoiceReviewPage extends StatefulWidget { const VoiceReviewPage({super.key,required this.store,required this.draft}); final Store store; final VoiceDraft draft; @override State<VoiceReviewPage> createState()=>_VoiceReviewPageState(); }
class _VoiceReviewPageState extends State<VoiceReviewPage>{late TextEditingController amount,note;String customerId='';String type='debt';@override void initState(){super.initState();amount=TextEditingController(text:widget.draft.amount>0?widget.draft.amount.toString():'');note=TextEditingController(text:widget.draft.note);customerId=widget.draft.customerId;}@override void dispose(){amount.dispose();note.dispose();super.dispose();}Future<void> approve()async{final v=double.tryParse(amount.text.replaceAll(',','.'))??0;final c=widget.store.customers.firstWhere((x)=>x.id==customerId,orElse:()=>Customer(id:'',name:'',phone:''));if(c.id.isEmpty||v<=0)return;final current=widget.store.balance(c.id);if(type=='debt'&&c.limit>0&&current+v>c.limit){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('العملية تتجاوز السقف الائتماني')));return;}final now=DateTime.now();widget.store.transactions.add(Tx(id:makeId(),customerId:c.id,type:type,amount:v,date:now,note:note.text.trim()));widget.store.voiceDrafts.removeWhere((x)=>x.id==widget.draft.id);await widget.store.save();if(mounted)Navigator.pop(context);} @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('مراجعة التسجيل')),body:ListView(padding:const EdgeInsets.all(16),children:[Text(widget.draft.text,style:const TextStyle(fontSize:18)),DropdownButtonFormField<String>(value:customerId.isEmpty?null:customerId,decoration:const InputDecoration(labelText:'الزبون'),items:widget.store.customers.map((x)=>DropdownMenuItem(value:x.id,child:Text(x.name))).toList(),onChanged:(v)=>setState(()=>customerId=v??'')),SegmentedButton<String>(segments:const[ButtonSegment(value:'debt',label:Text('دَين')),ButtonSegment(value:'payment',label:Text('تسديد'))],selected:{type},onSelectionChanged:(v)=>setState(()=>type=v.first)),TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ')),TextField(controller:note,maxLines:3,decoration:const InputDecoration(labelText:'البيان')),const SizedBox(height:12),FilledButton(onPressed:approve,child:const Text('اعتماد وحفظ'))]));}
}

class SettingsPage extends StatefulWidget { const SettingsPage({super.key,required this.store}); final Store store; @override State<SettingsPage> createState()=>_SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage>{late TextEditingController shop,msg;int taps=0;DateTime? last;@override void initState(){super.initState();shop=TextEditingController(text:widget.store.shop);msg=TextEditingController(text:widget.store.whatsappMessage);}@override void dispose(){shop.dispose();msg.dispose();super.dispose();}void hidden(){final n=DateTime.now();if(last==null||n.difference(last!).inSeconds>2)taps=0;last=n;taps++;if(taps==3){taps=0;showDialog(context:context,builder:(_)=>AdminGate(store:widget.store));}}Future<void> save()async{widget.store.shop=shop.text.trim().isEmpty?'DainPay — دَيْن':shop.text.trim();widget.store.whatsappMessage=msg.text.trim();await widget.store.save();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم الحفظ')));} @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:GestureDetector(onTap:hidden,child:const Text('الإعدادات'))),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:shop,decoration:const InputDecoration(labelText:'اسم المحل / النشاط')),const ListTile(title:Text('المظهر'),subtitle:Text('تلقائي حسب إعداد الجهاز'),trailing:Icon(Icons.brightness_auto)),TextField(controller:msg,maxLines:4,decoration:const InputDecoration(labelText:'رسالة واتساب')),Text('رقم الجهاز: ${widget.store.deviceId}'),FilledButton(onPressed:save,child:const Text('حفظ')),OutlinedButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ActivationPage(store:widget.store))),child:const Text('الاشتراك والتفعيل')),OutlinedButton(onPressed:()async{await widget.store.clearLocal();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم مسح البيانات المحلية')));},child:const Text('مسح البيانات المحلية'))]));}
}

class ActivationPage extends StatefulWidget{const ActivationPage({super.key,required this.store});final Store store;@override State<ActivationPage>createState()=>_ActivationPageState();}
class _ActivationPageState extends State<ActivationPage>{final code=TextEditingController();bool busy=false;@override void dispose(){code.dispose();super.dispose();}Future<void>go()async{setState(()=>busy=true);final ok=await widget.store.activateCode(code.text);if(!mounted)return;setState(()=>busy=false);ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(ok?'تم التفعيل الدائم':'الكود غير صحيح أو مستخدم أو مخصص لجهاز آخر')));if(ok)Navigator.pop(context);}@override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('الاشتراك والتفعيل')),body:ListView(padding:const EdgeInsets.all(16),children:[Text(widget.store.activated?'مفعّل دائمًا':'التجربة المجانية: ${widget.store.trialDaysLeft} أيام',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),Text('رقم الجهاز: ${widget.store.deviceId}'),const Text('الدفع نقدًا فقط — +218934951072'),FilledButton.icon(onPressed:()=>openWhatsApp('+218934951072','طلب تفعيل DainPay - رقم الجهاز: ${widget.store.deviceId}'),icon:const Icon(Icons.chat),label:const Text('طلب التفعيل عبر واتساب')),TextField(controller:code,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'كود التفعيل')),FilledButton(onPressed:busy?null:go,child:Text(busy?'جارٍ التحقق':'تفعيل دائم'))])));}

class AdminGate extends StatefulWidget{const AdminGate({super.key,required this.store});final Store store;@override State<AdminGate>createState()=>_AdminGateState();}
class _AdminGateState extends State<AdminGate>{final pin=TextEditingController();@override void dispose(){pin.dispose();super.dispose();}void enter(){if(pin.text=='116936'){Navigator.pop(context);Navigator.push(context,MaterialPageRoute(builder:(_)=>AdminPage(store:widget.store)));}else{ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('رمز المالك غير صحيح')));}}@override Widget build(BuildContext c)=>AlertDialog(title:const Text('Adreemk'),content:TextField(controller:pin,obscureText:true,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'رمز المالك')),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:enter,child:const Text('دخول'))]);}

class AdminPage extends StatefulWidget{const AdminPage({super.key,required this.store});final Store store;@override State<AdminPage>createState()=>_AdminPageState();}
class _AdminPageState extends State<AdminPage>{final device=TextEditingController();String result='';bool busy=false;@override void dispose(){device.dispose();super.dispose();}Future<void>generate()async{if(device.text.trim().isEmpty)return;setState(()=>busy=true);final x=await widget.store.generateCode(device.text);if(!mounted)return;setState(()=>{busy=false,result=x??'تعذر التوليد. تحقق من اتصال Firebase وصلاحيات Firestore.'});} @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('Adreemk — المالك')),body:ListView(padding:const EdgeInsets.all(16),children:[const Text('توليد رمز دائم خاص بعميل واحد'),TextField(controller:device,decoration:const InputDecoration(labelText:'رقم جهاز العميل')),FilledButton(onPressed:busy?null:generate,child:Text(busy?'جارٍ التوليد...':'توليد الرمز')),if(result.isNotEmpty)Card(child:ListTile(title:const Text('النتيجة'),subtitle:Text(result,style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),trailing:result.length==6?IconButton(onPressed:()=>openWhatsApp('+218934951072','رمز تفعيل DainPay: $result'),icon:const Icon(Icons.send)):null))])));}
