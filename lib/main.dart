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

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(999999)}';
String money(double v) => '${v.toStringAsFixed(2)} د.ل';
String dateText(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
String timeText(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

double numValue(dynamic v) {
  if (v is num) return v.toDouble().isFinite ? v.toDouble() : 0;
  final s = '$v'.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), '');
  return double.tryParse(s) ?? 0;
}

String phone218(String value) {
  var p = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (p.startsWith('00')) p = p.substring(2);
  if (p.startsWith('218')) return p;
  if (p.startsWith('0')) return '218${p.substring(1)}';
  return p;
}

Future<bool> whatsapp(String phone, String message) async {
  final n = phone218(phone);
  if (n.isEmpty) return false;
  try { return await launchUrl(Uri.https('wa.me', '/$n', {'text': message}), mode: LaunchMode.externalApplication); } catch (_) { return false; }
}

class Customer {
  Customer({required this.id, required this.name, required this.phone, this.limit = 0});
  String id, name, phone;
  double limit;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'limit': limit};
  factory Customer.fromJson(Map<String, dynamic> j) => Customer(id: '${j['id'] ?? ''}', name: '${j['name'] ?? ''}', phone: '${j['phone'] ?? ''}', limit: max(0, numValue(j['limit'])));
}

class Tx {
  Tx({required this.id, required this.customerId, required this.type, required this.amount, required this.date, required this.note});
  String id, customerId, type, note;
  double amount;
  DateTime date;
  bool get debt => type == 'debt';
  Map<String, dynamic> toJson() => {'id': id, 'customerId': customerId, 'type': type, 'amount': amount, 'date': date.toIso8601String(), 'note': note};
  factory Tx.fromJson(Map<String, dynamic> j) => Tx(id: '${j['id'] ?? ''}', customerId: '${j['customerId'] ?? ''}', type: '${j['type'] ?? 'debt'}' == 'payment' ? 'payment' : 'debt', amount: max(0, numValue(j['amount'])), date: DateTime.tryParse('${j['date']}') ?? DateTime.now(), note: '${j['note'] ?? ''}');
}

class VoiceDraft {
  VoiceDraft({required this.id, required this.text, required this.date, this.customerId = '', this.amount = 0, this.note = ''});
  String id, text, customerId, note;
  DateTime date;
  double amount;
  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'date': date.toIso8601String(), 'customerId': customerId, 'amount': amount, 'note': note};
  factory VoiceDraft.fromJson(Map<String, dynamic> j) => VoiceDraft(id: '${j['id'] ?? ''}', text: '${j['text'] ?? ''}', date: DateTime.tryParse('${j['date']}') ?? DateTime.now(), customerId: '${j['customerId'] ?? ''}', amount: max(0, numValue(j['amount'])), note: '${j['note'] ?? ''}');
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  final customers = <Customer>[];
  final transactions = <Tx>[];
  final voiceDrafts = <VoiceDraft>[];
  String shop = 'DainPay — دَيْن';
  String whatsappMessage = 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  String uid = '', deviceId = '', themeMode = 'system';
  bool firebaseReady = false, syncing = false, activated = false;
  DateTime? trialStart;
  Timer? timer;

  static Future<Store> load() async {
    final s = Store();
    s.prefs = await SharedPreferences.getInstance();
    s.shop = s.prefs.getString('shop') ?? s.shop;
    s.whatsappMessage = s.prefs.getString('whatsappMessage') ?? s.whatsappMessage;
    s.themeMode = s.prefs.getString('theme_mode') ?? 'system';
    if (!['system', 'light', 'dark'].contains(s.themeMode)) s.themeMode = 'system';
    s.deviceId = s.prefs.getString('device_id') ?? '';
    if (s.deviceId.isEmpty) {
      s.deviceId = 'DP-${DateTime.now().millisecondsSinceEpoch}-${Random.secure().nextInt(999999)}';
      await s.prefs.setString('device_id', s.deviceId);
    }
    final ts = s.prefs.getString('trial_start');
    if (ts == null) {
      s.trialStart = DateTime.now();
      await s.prefs.setString('trial_start', s.trialStart!.toIso8601String());
    } else {
      s.trialStart = DateTime.tryParse(ts) ?? DateTime.now();
    }
    s.activated = s.prefs.getBool('activated') ?? false;
    try {
      final a = jsonDecode(s.prefs.getString('customers') ?? '[]') as List;
      s.customers.addAll(a.map((e) => Customer.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      final a = jsonDecode(s.prefs.getString('transactions') ?? '[]') as List;
      s.transactions.addAll(a.map((e) => Tx.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      final a = jsonDecode(s.prefs.getString('voice_drafts') ?? '[]') as List;
      s.voiceDrafts.addAll(a.map((e) => VoiceDraft.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    return s;
  }

  int get trialDaysLeft => activated || trialStart == null ? 0 : max(0, 10 - DateTime.now().difference(trialStart!).inDays);
  bool get locked => !activated && trialDaysLeft <= 0;
  ThemeMode get mode => themeMode == 'dark' ? ThemeMode.dark : themeMode == 'light' ? ThemeMode.light : ThemeMode.system;
  CollectionReference<Map<String, dynamic>> get customersRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('customers');
  CollectionReference<Map<String, dynamic>> get transactionsRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('transactions');

  Future<void> connectFirebase() async {
    try {
      var user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) return;
      uid = user.uid;
      firebaseReady = true;
      await pullCloud();
      await loadActivation();
      timer?.cancel();
      timer = Timer.periodic(const Duration(seconds: 60), (_) => saveCloud());
    } catch (_) { firebaseReady = false; }
    notifyListeners();
  }

  Future<void> loadActivation() async {
    if (!firebaseReady) return;
    try {
      final d = await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).get();
      if (d.data()?['activated'] == true) { activated = true; await prefs.setBool('activated', true); }
    } catch (_) {}
  }

  Future<void> pullCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      for (final d in (await customersRef.get()).docs) {
        final c = Customer.fromJson(d.data());
        final i = customers.indexWhere((x) => x.id == c.id);
        if (i < 0) customers.add(c); else customers[i] = c;
      }
      for (final d in (await transactionsRef.get()).docs) {
        final x = d.data();
        final raw = x['date'];
        final dt = raw is Timestamp ? raw.toDate() : DateTime.tryParse('$raw') ?? DateTime.now();
        final t = Tx(id: '${x['id'] ?? d.id}', customerId: '${x['customerId'] ?? ''}', type: '${x['type'] ?? 'debt'}' == 'payment' ? 'payment' : 'debt', amount: max(0, numValue(x['amount'])), date: dt, note: '${x['note'] ?? ''}');
        final i = transactions.indexWhere((z) => z.id == t.id);
        if (i < 0) transactions.add(t); else transactions[i] = t;
      }
      await saveLocal();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final c in customers) batch.set(customersRef.doc(c.id), c.toJson());
      for (final t in transactions) batch.set(transactionsRef.doc(t.id), {...t.toJson(), 'date': Timestamp.fromDate(t.date)});
      await batch.commit();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveLocal() async {
    await prefs.setString('customers', jsonEncode(customers.map((e) => e.toJson()).toList()));
    await prefs.setString('transactions', jsonEncode(transactions.map((e) => e.toJson()).toList()));
    await prefs.setString('voice_drafts', jsonEncode(voiceDrafts.map((e) => e.toJson()).toList()));
    await prefs.setString('shop', shop);
    await prefs.setString('whatsappMessage', whatsappMessage);
    await prefs.setString('theme_mode', themeMode);
  }
  Future<void> save() async { await saveLocal(); notifyListeners(); await saveCloud(); }
  double balance(String id) => transactions.where((t) => t.customerId == id).fold(0.0, (a, t) => a + (t.debt ? t.amount : -t.amount));
  double debts(String id) => transactions.where((t) => t.customerId == id && t.debt).fold(0.0, (a, t) => a + t.amount);
  double paid(String id) => transactions.where((t) => t.customerId == id && !t.debt).fold(0.0, (a, t) => a + t.amount);

  DateTime? oldestOutstandingDebt(String id) {
    final rows = transactions.where((t) => t.customerId == id && t.debt).toList()..sort((a, b) => a.date.compareTo(b.date));
    var p = paid(id);
    for (final row in rows) {
      if (p >= row.amount) { p -= row.amount; } else { return row.date; }
    }
    return null;
  }

  String risk(String id) {
    if (balance(id) <= 0) return 'مسدد';
    final d = oldestOutstandingDebt(id);
    if (d == null) return 'حديث';
    final days = DateTime.now().difference(d).inDays;
    return days > 90 ? 'خطر' : days > 30 ? 'متأخر' : 'حديث';
  }

  String? validate(Customer c, String type, double amount) {
    if (amount <= 0 || !amount.isFinite) return 'أدخل مبلغًا صحيحًا أكبر من صفر.';
    final current = balance(c.id);
    if (type == 'payment' && amount > current + .000001) return 'السداد أكبر من المتبقي: ${money(max(0, current))}.';
    if (type == 'debt' && c.limit > 0 && current + amount > c.limit + .000001) return 'السقف ${money(c.limit)} والمتاح ${money(max(0, c.limit - current))}.';
    return null;
  }

  Future<bool> activateCode(String code) async {
    if (!firebaseReady || code.trim().isEmpty) return false;
    final ref = FirebaseFirestore.instance.collection('activation_codes').doc(code.trim());
    try {
      final ok = await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
        final snap = await tx.get(ref); final d = snap.data();
        if (!snap.exists || d == null || d['used'] == true) return false;
        final bound = '${d['deviceId'] ?? ''}';
        if (bound.isNotEmpty && bound != deviceId) return false;
        tx.update(ref, {'used': true, 'usedAt': FieldValue.serverTimestamp(), 'usedDeviceId': deviceId});
        return true;
      });
      if (!ok) return false;
      await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).set({'activated': true, 'activatedAt': FieldValue.serverTimestamp(), 'uid': uid});
      activated = true;
      await prefs.setBool('activated', true);
      notifyListeners();
      return true;
    } catch (_) { return false; }
  }

  Future<String?> generateCode(String target) async {
    if (!firebaseReady || target.trim().isEmpty) return null;
    try {
      String code;
      do { code = (100000 + Random.secure().nextInt(900000)).toString(); } while ((await FirebaseFirestore.instance.collection('activation_codes').doc(code).get()).exists);
      await FirebaseFirestore.instance.collection('activation_codes').doc(code).set({'deviceId': target.trim(), 'used': false, 'createdAt': FieldValue.serverTimestamp()}).timeout(const Duration(seconds: 12));
      return code;
    } catch (_) { return null; }
  }

  Future<void> clearLocal() async {
    customers.clear(); transactions.clear(); voiceDrafts.clear();
    await prefs.remove('customers'); await prefs.remove('transactions'); await prefs.remove('voice_drafts'); notifyListeners();
  }
  @override void dispose() { timer?.cancel(); super.dispose(); }
}

class ColorsDain {
  static const primary = Color(0xFF087F5B);
  static const mint = Color(0xFF2EC4B6);
  static const danger = Color(0xFFE05A67);
  static const dark = Color(0xFF0E1A24);
}

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store});
  final Store store;
  ThemeData theme(Brightness b) => ThemeData(
        useMaterial3: true,
        brightness: b,
        colorScheme: ColorScheme.fromSeed(seedColor: ColorsDain.primary, brightness: b),
        fontFamily: 'Cairo',
        scaffoldBackgroundColor: b == Brightness.dark ? ColorsDain.dark : const Color(0xFFF6F8FA),
        cardTheme: CardTheme(color: b == Brightness.dark ? const Color(0xFF152332) : Colors.white, elevation: 0, margin: const EdgeInsets.symmetric(vertical: 5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        appBarTheme: const AppBarTheme(backgroundColor: ColorsDain.primary, foregroundColor: Colors.white, centerTitle: true),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(borderSide: BorderSide.none)),
        filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: ColorsDain.primary, foregroundColor: Colors.white)),
      );
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: store, builder: (_, __) => MaterialApp(debugShowCheckedModeBanner: false, theme: theme(Brightness.light), darkTheme: theme(Brightness.dark), themeMode: store.mode, home: HomePage(store: store)));
}

class DainLogo extends StatelessWidget {
  const DainLogo({super.key, this.size = 40});
  final double size;
  @override Widget build(BuildContext context) => Container(width: size, height: size, alignment: Alignment.center, decoration: BoxDecoration(borderRadius: BorderRadius.circular(size * .28), gradient: const LinearGradient(colors: [ColorsDain.primary, ColorsDain.mint])), child: Text('DP', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * .36)));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store}); final Store store;
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  String query = '', filter = 'all'; int taps = 0; DateTime? last;
  void hidden() { final n = DateTime.now(); if (last == null || n.difference(last!).inSeconds > 2) taps = 0; last = n; taps++; if (taps == 3) { taps = 0; showDialog(context: context, builder: (_) => AdminGate(store: widget.store)); } }
  @override Widget build(BuildContext context) {
    final s = widget.store;
    final list = s.customers.where((c) { final b = s.balance(c.id); return (query.isEmpty || c.name.contains(query) || c.phone.contains(query)) && (filter == 'all' || (filter == 'debt' && b > 0) || (filter == 'paid' && b <= 0)); }).toList()..sort((a, b) => s.balance(b.id).compareTo(s.balance(a.id)));
    final total = s.customers.fold<double>(0, (a, c) => a + max(0, s.balance(c.id)));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: GestureDetector(onTap: hidden, child: Row(mainAxisSize: MainAxisSize.min, children: [const DainLogo(size: 30), const SizedBox(width: 8), Text(s.shop)])), actions: [IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(store: s))), icon: const Icon(Icons.settings_outlined))]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (!s.activated) Card(child: ListTile(title: Text(s.locked ? 'انتهت الفترة التجريبية' : 'التجربة المجانية 10 أيام'), subtitle: Text(s.locked ? 'يلزم التفعيل' : 'متبقٍ ${s.trialDaysLeft} أيام'), trailing: FilledButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: s))), child: const Text('تفعيل')))),
        Card(child: ListTile(leading: const DainLogo(size: 44), title: const Text('إجمالي المتبقي'), subtitle: Text(money(total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: ColorsDain.primary)))),
        Card(child: ListTile(leading: const Icon(Icons.mic, color: ColorsDain.primary), title: const Text('التسجيل الصوتي'), subtitle: Text(s.voiceDrafts.isEmpty ? 'سجل ملاحظة ثم راجعها' : '${s.voiceDrafts.length} مسودة'), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VoiceDraftsPage(store: s))))),
        TextField(decoration: const InputDecoration(hintText: 'بحث بالاسم أو الهاتف', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => query = v.trim())),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [ChoiceChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) => setState(() => filter = 'all')), ChoiceChip(label: const Text('عليهم دين'), selected: filter == 'debt', onSelected: (_) => setState(() => filter = 'debt')), ChoiceChip(label: const Text('مسدد'), selected: filter == 'paid', onSelected: (_) => setState(() => filter = 'paid'))]),
        const SizedBox(height: 5),
        if (list.isEmpty) const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('لا يوجد عملاء بعد'))),
        ...list.map((c) { final b = s.balance(c.id); final debt = b > 0; return Card(child: ListTile(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPage(store: s, customer: c))), leading: CircleAvatar(child: Text(c.name.isEmpty ? '؟' : c.name.characters.first)), title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${c.phone}\n${s.risk(c.id)} • دين ${money(s.debts(c.id))} • مسدد ${money(s.paid(c.id))}'), isThreeLine: true, trailing: Text(money(b), style: TextStyle(fontWeight: FontWeight.bold, color: debt ? ColorsDain.danger : ColorsDain.mint)))); }),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: s.locked ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: s))) : () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddCustomerPage(store: s))), icon: Icon(s.locked ? Icons.lock : Icons.person_add), label: Text(s.locked ? 'التفعيل' : 'عميل')),
    );
  }
}

class AddCustomerPage extends StatefulWidget {
  const AddCustomerPage({super.key, required this.store}); final Store store;
  @override State<AddCustomerPage> createState() => _AddCustomerPageState();
}
class _AddCustomerPageState extends State<AddCustomerPage> {
  final name = TextEditingController(), phone = TextEditingController(), limit = TextEditingController(); bool busy = false;
  @override void dispose() { name.dispose(); phone.dispose(); limit.dispose(); super.dispose(); }
  Future<void> save() async { if (name.text.trim().isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أدخل اسم العميل.'))); return; } setState(() => busy = true); widget.store.customers.add(Customer(id: makeId(), name: name.text.trim(), phone: phone.text.trim(), limit: max(0, numValue(limit.text)))); await widget.store.save(); if (mounted) Navigator.pop(context); }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('إضافة عميل')), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل')), const SizedBox(height: 12), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')), const SizedBox(height: 12), TextField(controller: limit, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'السقف الائتماني (اختياري)')), const SizedBox(height: 18), FilledButton(onPressed: busy ? null : save, child: Text(busy ? 'جارٍ الحفظ...' : 'حفظ'))])));
}

String statementFor(Store s, Customer c) {
  final rows = s.transactions.where((t) => t.customerId == c.id).toList()..sort((a, b) => a.date.compareTo(b.date));
  var running = 0.0; final out = StringBuffer('كشف حساب — ${s.shop}\nالزبون: ${c.name}\nالهاتف: ${c.phone}\n────────────────────\n');
  for (final t in rows) { running += t.debt ? t.amount : -t.amount; out.writeln('${dateText(t.date)} ${timeText(t.date)} — ${t.debt ? 'دين' : 'سداد'} ${money(t.amount)}${t.note.isEmpty ? '' : ' — ${t.note}'} — الرصيد ${money(running)}'); }
  out.writeln('────────────────────'); out.writeln('إجمالي الدين: ${money(s.debts(c.id))}'); out.writeln('إجمالي التسديد: ${money(s.paid(c.id))}'); out.writeln('المتبقي: ${money(max(0, s.balance(c.id)))}'); return out.toString();
}

String receiptFor(Store s, Customer c, double amount, DateTime date) => 'وصل استلام — ${s.shop}\nالزبون: ${c.name}\nالمبلغ المستلم: ${money(amount)}\nالتاريخ: ${dateText(date)} ${timeText(date)}\nالمتبقي بعد السداد: ${money(max(0, s.balance(c.id)))}\nشكرًا لكم.';

class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer}); final Store store; final Customer customer;
  Future<void> statement(BuildContext context) async { if (!await whatsapp(customer.phone, statementFor(store, customer)) && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب.'))); }
  Future<void> reminder(BuildContext context) async { final m = store.whatsappMessage.replaceAll('[الاسم]', customer.name).replaceAll('[المبلغ]', money(max(0, store.balance(customer.id)))); if (!await whatsapp(customer.phone, m) && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب.'))); }
  @override Widget build(BuildContext context) {
    final rows = store.transactions.where((t) => t.customerId == customer.id).toList()..sort((a, b) => b.date.compareTo(a.date));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Text(customer.name)),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [Text(money(max(0, store.balance(customer.id))), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)), const Text('المتبقي'), Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'), Text('السقف: ${customer.limit <= 0 ? 'غير محدد' : money(customer.limit)}'), Wrap(spacing: 8, children: [FilledButton.icon(onPressed: () => reminder(context), icon: const Icon(Icons.chat), label: const Text('تذكير')), OutlinedButton.icon(onPressed: () => statement(context), icon: const Icon(Icons.receipt_long), label: const Text('كشف حساب'))])]))),
        if (rows.isEmpty) const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('لا توجد عمليات.'))),
        ...rows.map((t) => ListTile(leading: Icon(t.debt ? Icons.arrow_downward : Icons.arrow_upward, color: t.debt ? ColorsDain.danger : ColorsDain.mint), title: Text(t.debt ? 'دين' : 'سداد'), subtitle: Text('${dateText(t.date)} ${timeText(t.date)}${t.note.isEmpty ? '' : ' • ${t.note}'}'), trailing: Text(money(t.amount))),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: store.locked ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: store))) : () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddTransactionPage(store: store, customer: customer))), icon: Icon(store.locked ? Icons.lock : Icons.add), label: Text(store.locked ? 'التفعيل' : 'عملية')),
    ));
  }
}

class AddTransactionPage extends StatefulWidget {
  const AddTransactionPage({super.key, required this.store, required this.customer}); final Store store; final Customer customer;
  @override State<AddTransactionPage> createState() => _AddTransactionPageState();
}
class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount = TextEditingController(), note = TextEditingController(); String type = 'debt'; bool busy = false;
  @override void dispose() { amount.dispose(); note.dispose(); super.dispose(); }
  Future<void> saveTx() async {
    if (busy) return;
    final value = numValue(amount.text); final error = widget.store.validate(widget.customer, type, value);
    if (error != null) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error))); return; }
    setState(() => busy = true); final date = DateTime.now();
    widget.store.transactions.add(Tx(id: makeId(), customerId: widget.customer.id, type: type, amount: value, date: date, note: note.text.trim()));
    await widget.store.save(); if (!mounted) return;
    if (type == 'payment') {
      final send = await showDialog<bool>(context: context, barrierDismissible: false, builder: (d) => AlertDialog(title: const Text('إرسال وصل استلام؟'), content: const Text('تم تسجيل السداد. هل تريد إرسال الوصل للزبون عبر واتساب؟'), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('لا')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('إرسال الوصل'))]));
      if (send == true) await whatsapp(widget.customer.phone, receiptFor(widget.store, widget.customer, value, date));
    }
    if (mounted) Navigator.pop(context);
  }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text(type == 'debt' ? 'إضافة دين' : 'تسجيل سداد')), body: ListView(padding: const EdgeInsets.all(16), children: [SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دين')), ButtonSegment(value: 'payment', label: Text('سداد'))], selected: {type}, onSelectionChanged: busy ? null : (v) => setState(() => type = v.first)), const SizedBox(height: 12), Text(type == 'payment' ? 'المتبقي: ${money(max(0, widget.store.balance(widget.customer.id)))}' : 'السقف: ${widget.customer.limit <= 0 ? 'غير محدد' : money(widget.customer.limit)}'), TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'المبلغ')), TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'البيان / ملاحظات')), const SizedBox(height: 18), FilledButton(onPressed: busy ? null : saveTx, child: Text(busy ? 'جارٍ الحفظ...' : 'حفظ العملية'))])));
}

class VoiceDraftsPage extends StatefulWidget {
  const VoiceDraftsPage({super.key, required this.store}); final Store store;
  @override State<VoiceDraftsPage> createState() => _VoiceDraftsPageState();
}
class _VoiceDraftsPageState extends State<VoiceDraftsPage> {
  final speech = stt.SpeechToText(); bool listening = false; String live = '';
  @override void dispose() { speech.stop(); super.dispose(); }
  double? amountFromSpeech(String text) { final m = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(text); if (m != null) return numValue(m.group(1)); const w = {'مية': 100.0, 'مائة': 100.0, 'مئة': 100.0, 'ألف': 1000.0, 'الف': 1000.0, 'عشرة': 10.0, 'عشرين': 20.0, 'ثلاثين': 30.0, 'أربعين': 40.0, 'خمسين': 50.0, 'ستين': 60.0, 'سبعين': 70.0, 'ثمانين': 80.0, 'تسعين': 90.0}; for (final e in w.entries) { if (text.contains(e.key)) return e.value; } return null; }
  String match(String text) { for (final c in widget.store.customers) { if (text.contains(c.name)) return c.id; } return ''; }
  Future<void> record() async {
    if (listening) { await speech.stop(); if (mounted) setState(() => listening = false); return; }
    final ok = await speech.initialize(onStatus: (x) { if (mounted && (x == 'notListening' || x == 'done')) setState(() => listening = false); }, onError: (_) { if (mounted) setState(() => listening = false); });
    if (!ok) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر الوصول إلى الميكروفون. تحقق من الإذن.'))); return; }
    final locales = await speech.locales();
    String? locale;
    for (final l in locales) { if (l.localeId.toLowerCase().replaceAll('-', '_') == 'ar_ly') { locale = l.localeId; break; } }
    locale ??= locales.firstWhere((l) => l.localeId.toLowerCase().startsWith('ar'), orElse: () => locales.isNotEmpty ? locales.first : stt.LocaleName('ar', 'Arabic')).localeId;
    if (mounted) setState(() { listening = true; live = ''; });
    await speech.listen(localeId: locale, partialResults: true, listenFor: const Duration(seconds: 45), pauseFor: const Duration(seconds: 4), onResult: (r) async {
      if (mounted) setState(() => live = r.recognizedWords);
      if (!r.finalResult) return;
      final text = r.recognizedWords.trim();
      if (text.isNotEmpty) { widget.store.voiceDrafts.insert(0, VoiceDraft(id: makeId(), text: text, date: DateTime.now(), customerId: match(text), amount: amountFromSpeech(text) ?? 0, note: text)); await widget.store.saveLocal(); widget.store.notifyListeners(); }
      if (mounted) setState(() => listening = false);
    });
  }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('المسودات الصوتية')), body: ListView(padding: const EdgeInsets.all(12), children: [Card(child: ListTile(leading: Icon(listening ? Icons.stop : Icons.mic), title: Text(listening ? 'جارٍ التسجيل...' : 'اضغط للتسجيل'), subtitle: Text(live.isEmpty ? 'مثال: محمد 100 دينار بضاعة' : live), onTap: record)), if (widget.store.voiceDrafts.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا توجد مسودات'))), ...widget.store.voiceDrafts.map((d) { final c = widget.store.customers.firstWhere((x) => x.id == d.customerId, orElse: () => Customer(id: '', name: 'عميل غير محدد', phone: '')); return Card(child: ListTile(title: Text(c.name), subtitle: Text('${d.text}\nالمبلغ: ${money(d.amount)}'), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VoiceReviewPage(store: widget.store, draft: d))))); })])));
}

class VoiceReviewPage extends StatefulWidget {
  const VoiceReviewPage({super.key, required this.store, required this.draft}); final Store store; final VoiceDraft draft;
  @override State<VoiceReviewPage> createState() => _VoiceReviewPageState();
}
class _VoiceReviewPageState extends State<VoiceReviewPage> {
  late TextEditingController amount, note; String customerId = '', type = 'debt';
  @override void initState() { super.initState(); amount = TextEditingController(text: widget.draft.amount > 0 ? widget.draft.amount.toString() : ''); note = TextEditingController(text: widget.draft.note); customerId = widget.draft.customerId; }
  @override void dispose() { amount.dispose(); note.dispose(); super.dispose(); }
  Future<void> approve() async {
    final c = widget.store.customers.firstWhere((x) => x.id == customerId, orElse: () => Customer(id: '', name: '', phone: '')); final value = numValue(amount.text);
    final error = c.id.isEmpty ? 'اختر الزبون أولاً.' : widget.store.validate(c, type, value);
    if (error != null) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error))); return; }
    final date = DateTime.now(); widget.store.transactions.add(Tx(id: makeId(), customerId: c.id, type: type, amount: value, date: date, note: note.text.trim())); widget.store.voiceDrafts.removeWhere((x) => x.id == widget.draft.id); await widget.store.save(); if (mounted) Navigator.pop(context);
  }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('مراجعة التسجيل')), body: ListView(padding: const EdgeInsets.all(16), children: [Text(widget.draft.text, style: const TextStyle(fontSize: 18)), DropdownButtonFormField<String>(value: customerId.isEmpty ? null : customerId, decoration: const InputDecoration(labelText: 'الزبون'), items: widget.store.customers.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(), onChanged: (v) => setState(() => customerId = v ?? '')), SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دين')), ButtonSegment(value: 'payment', label: Text('سداد'))], selected: {type}, onSelectionChanged: (v) => setState(() => type = v.first)), TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'المبلغ')), TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'البيان')), const SizedBox(height: 12), FilledButton(onPressed: approve, child: const Text('اعتماد وحفظ'))])));
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store}); final Store store;
  @override State<SettingsPage> createState() => _SettingsPageState();
}
class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController shop, message; int taps = 0; DateTime? last;
  @override void initState() { super.initState(); shop = TextEditingController(text: widget.store.shop); message = TextEditingController(text: widget.store.whatsappMessage); }
  @override void dispose() { shop.dispose(); message.dispose(); super.dispose(); }
  void hidden() { final n = DateTime.now(); if (last == null || n.difference(last!).inSeconds > 2) taps = 0; last = n; taps++; if (taps == 3) { taps = 0; showDialog(context: context, builder: (_) => AdminGate(store: widget.store)); } }
  Future<void> save() async { widget.store.shop = shop.text.trim().isEmpty ? 'DainPay — دَيْن' : shop.text.trim(); widget.store.whatsappMessage = message.text.trim().isEmpty ? 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.' : message.text.trim(); await widget.store.save(); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الحفظ'))); }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: GestureDetector(onTap: hidden, child: const Text('الإعدادات'))), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: shop, decoration: const InputDecoration(labelText: 'اسم المحل / النشاط')), const SizedBox(height: 12), SegmentedButton<String>(segments: const [ButtonSegment(value: 'system', label: Text('تلقائي')), ButtonSegment(value: 'light', label: Text('فاتح')), ButtonSegment(value: 'dark', label: Text('داكن'))], selected: {widget.store.themeMode}, onSelectionChanged: (v) async { widget.store.themeMode = v.first; await widget.store.saveLocal(); widget.store.notifyListeners(); }), const SizedBox(height: 12), TextField(controller: message, maxLines: 4, decoration: const InputDecoration(labelText: 'رسالة واتساب')), Text('رقم الجهاز: ${widget.store.deviceId}'), FilledButton(onPressed: save, child: const Text('حفظ')), OutlinedButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: widget.store))), child: const Text('الاشتراك والتفعيل'))])));
}

class ActivationPage extends StatefulWidget { const ActivationPage({super.key, required this.store}); final Store store; @override State<ActivationPage> createState() => _ActivationPageState(); }
class _ActivationPageState extends State<ActivationPage> {
  final code = TextEditingController(); bool busy = false;
  @override void dispose() { code.dispose(); super.dispose(); }
  Future<void> go() async { if (busy) return; setState(() => busy = true); final ok = await widget.store.activateCode(code.text.trim()); if (!mounted) return; setState(() => busy = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'تم التفعيل الدائم' : 'الكود غير صحيح أو مستخدم أو مخصص لجهاز آخر'))); if (ok) Navigator.pop(context); }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('الاشتراك والتفعيل')), body: ListView(padding: const EdgeInsets.all(16), children: [Text(widget.store.activated ? 'مفعّل دائمًا' : 'التجربة المجانية: ${widget.store.trialDaysLeft} أيام', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), Text('رقم الجهاز: ${widget.store.deviceId}'), const Text('الدفع نقدًا فقط — +218934951072'), FilledButton.icon(onPressed: () => whatsapp('+218934951072', 'طلب تفعيل DainPay - رقم الجهاز: ${widget.store.deviceId}'), icon: const Icon(Icons.chat), label: const Text('طلب التفعيل عبر واتساب')), TextField(controller: code, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: 'كود التفعيل')), FilledButton(onPressed: busy ? null : go, child: Text(busy ? 'جارٍ التحقق...' : 'تفعيل دائم'))])));
}

class AdminGate extends StatefulWidget { const AdminGate({super.key, required this.store}); final Store store; @override State<AdminGate> createState() => _AdminGateState(); }
class _AdminGateState extends State<AdminGate> {
  final pin = TextEditingController();
  @override void dispose() { pin.dispose(); super.dispose(); }
  void enter() { if (pin.text == '116936') { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => AdminPage(store: widget.store))); } else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('رمز المالك غير صحيح'))); } }
  @override Widget build(BuildContext context) => AlertDialog(title: const Text('Adreemk'), content: TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'رمز المالك')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')), FilledButton(onPressed: enter, child: const Text('دخول'))]);
}

class AdminPage extends StatefulWidget { const AdminPage({super.key, required this.store}); final Store store; @override State<AdminPage> createState() => _AdminPageState(); }
class _AdminPageState extends State<AdminPage> {
  final device = TextEditingController(); String result = ''; bool busy = false;
  @override void dispose() { device.dispose(); super.dispose(); }
  Future<void> generate() async { if (device.text.trim().isEmpty || busy) return; setState(() { busy = true; result = ''; }); final x = await widget.store.generateCode(device.text).timeout(const Duration(seconds: 15), onTimeout: () => null); if (!mounted) return; setState(() { busy = false; result = x ?? 'تعذر التوليد. تحقق من اتصال Firebase وصلاحيات Firestore.'; }); }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('Adreemk — المالك')), body: ListView(padding: const EdgeInsets.all(16), children: [const Text('توليد رمز دائم خاص بجهاز عميل واحد'), TextField(controller: device, decoration: const InputDecoration(labelText: 'رقم جهاز العميل')), FilledButton(onPressed: busy ? null : generate, child: Text(busy ? 'جارٍ التوليد...' : 'توليد الرمز')), if (result.isNotEmpty) Card(child: ListTile(title: const Text('النتيجة'), subtitle: Text(result, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), trailing: result.length == 6 ? IconButton(onPressed: () => whatsapp('+218934951072', 'رمز تفعيل DainPay: $result'), icon: const Icon(Icons.send)) : null))])));
}
