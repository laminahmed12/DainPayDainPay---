import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (_) {}
  final store = await Store.load();
  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(99999)}';
String money(double value) => '${value.toStringAsFixed(2)} د.ل';
String dateText(DateTime date) => '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

class Customer {
  Customer({required this.id, required this.name, required this.phone, this.limit = 0});
  String id, name, phone;
  double limit;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'limit': limit};
  factory Customer.fromJson(Map<String, dynamic> j) => Customer(id: '${j['id'] ?? ''}', name: '${j['name'] ?? ''}', phone: '${j['phone'] ?? ''}', limit: (j['limit'] as num?)?.toDouble() ?? 0);
}

class Tx {
  Tx({required this.id, required this.customerId, required this.type, required this.amount, required this.date, required this.note, this.receiptPath = ''});
  String id, customerId, type, note, receiptPath;
  double amount;
  DateTime date;
  Map<String, dynamic> toJson() => {'id': id, 'customerId': customerId, 'type': type, 'amount': amount, 'date': date.toIso8601String(), 'note': note, 'receiptPath': receiptPath};
  factory Tx.fromJson(Map<String, dynamic> j) => Tx(id: '${j['id'] ?? ''}', customerId: '${j['customerId'] ?? ''}', type: '${j['type'] ?? 'debt'}', amount: (j['amount'] as num?)?.toDouble() ?? 0, date: DateTime.tryParse('${j['date']}') ?? DateTime.now(), note: '${j['note'] ?? ''}', receiptPath: '${j['receiptPath'] ?? ''}');
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  final customers = <Customer>[];
  final transactions = <Tx>[];
  String shop = 'DainPay — دَيْن';
  String whatsappMessage = 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  bool dark = false, firebaseReady = false, syncing = false;
  String uid = '';

  static Future<Store> load() async {
    final s = Store();
    s.prefs = await SharedPreferences.getInstance();
    s.shop = s.prefs.getString('shop') ?? s.shop;
    s.whatsappMessage = s.prefs.getString('whatsappMessage') ?? s.whatsappMessage;
    s.dark = s.prefs.getBool('dark') ?? false;
    try { final d = jsonDecode(s.prefs.getString('customers') ?? '[]') as List; s.customers.addAll(d.map((e) => Customer.fromJson(Map<String, dynamic>.from(e)))); } catch (_) {}
    try { final d = jsonDecode(s.prefs.getString('transactions') ?? '[]') as List; s.transactions.addAll(d.map((e) => Tx.fromJson(Map<String, dynamic>.from(e)))); } catch (_) {}
    return s;
  }

  Future<void> connectFirebase() async {
    try {
      var user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) return;
      uid = user.uid;
      firebaseReady = true;
      await pullCloud();
    } catch (_) { firebaseReady = false; }
    notifyListeners();
  }
  CollectionReference<Map<String, dynamic>> get customersRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('customers');
  CollectionReference<Map<String, dynamic>> get transactionsRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('transactions');

  Future<void> pullCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      for (final doc in (await customersRef.get()).docs) {
        final c = Customer.fromJson(doc.data()); final i = customers.indexWhere((x) => x.id == c.id);
        if (i < 0) { customers.add(c); } else { customers[i] = c; }
      }
      for (final doc in (await transactionsRef.get()).docs) {
        final d = doc.data(); final raw = d['date']; final date = raw is Timestamp ? raw.toDate() : DateTime.tryParse('$raw') ?? DateTime.now();
        final t = Tx(id: '${d['id'] ?? doc.id}', customerId: '${d['customerId'] ?? ''}', type: '${d['type'] ?? 'debt'}', amount: (d['amount'] as num?)?.toDouble() ?? 0, date: date, note: '${d['note'] ?? ''}', receiptPath: '${d['receiptPath'] ?? ''}');
        final i = transactions.indexWhere((x) => x.id == t.id); if (i < 0) { transactions.add(t); } else { transactions[i] = t; }
      }
      await saveLocal();
    } catch (_) {} finally { syncing = false; }
  }
  Future<void> saveCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try { final b = FirebaseFirestore.instance.batch(); for (final c in customers) { b.set(customersRef.doc(c.id), c.toJson()); } for (final t in transactions) { b.set(transactionsRef.doc(t.id), {...t.toJson(), 'date': Timestamp.fromDate(t.date)}); } await b.commit(); } catch (_) {} finally { syncing = false; }
  }
  Future<void> saveLocal() async { await prefs.setString('customers', jsonEncode(customers.map((e) => e.toJson()).toList())); await prefs.setString('transactions', jsonEncode(transactions.map((e) => e.toJson()).toList())); await prefs.setString('shop', shop); await prefs.setString('whatsappMessage', whatsappMessage); await prefs.setBool('dark', dark); }
  Future<void> save() async { await saveLocal(); notifyListeners(); await saveCloud(); }
  double balance(String id) => transactions.where((t) => t.customerId == id).fold(0.0, (total, t) => total + (t.type == 'debt' ? t.amount : -t.amount));
  double debts(String id) => transactions.where((t) => t.customerId == id && t.type == 'debt').fold(0.0, (total, t) => total + t.amount);
  double paid(String id) => transactions.where((t) => t.customerId == id && t.type == 'payment').fold(0.0, (total, t) => total + t.amount);
  String risk(String id) { final current = balance(id); if (current <= 0) return 'مسدد'; final items = transactions.where((t) => t.customerId == id && t.type == 'debt').toList()..sort((a, b) => b.date.compareTo(a.date)); if (items.isEmpty) return 'حديث'; final days = DateTime.now().difference(items.first.date).inDays; if (days > 90) return 'خطر'; if (days > 30) return 'متأخر'; return 'حديث'; }
}

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store}); final Store store;
  ThemeData theme(Brightness b) => ThemeData(useMaterial3: true, brightness: b, colorSchemeSeed: const Color(0xFF0F5C6E), fontFamily: 'Cairo');
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: store, builder: (_, __) => MaterialApp(debugShowCheckedModeBanner: false, theme: theme(Brightness.light), darkTheme: theme(Brightness.dark), themeMode: store.dark ? ThemeMode.dark : ThemeMode.light, home: HomePage(store: store)));
}

class HomePage extends StatefulWidget { const HomePage({super.key, required this.store}); final Store store; @override State<HomePage> createState() => _HomePageState(); }
class _HomePageState extends State<HomePage> {
  String query = '', filter = 'all';
  @override Widget build(BuildContext context) {
    final s = widget.store;
    final list = s.customers.where((c) { final b = s.balance(c.id); final q = query.isEmpty || c.name.contains(query) || c.phone.contains(query); final f = filter == 'all' || (filter == 'debt' && b > 0) || (filter == 'paid' && b <= 0); return q && f; }).toList()..sort((a, b) => s.balance(b.id).compareTo(s.balance(a.id)));
    final total = s.customers.fold<double>(0, (total, c) => total + max(0, s.balance(c.id)));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Text(s.shop, style: const TextStyle(fontWeight: FontWeight.w900)), actions: [IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(store: s))))]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [Expanded(child: Stat(title: 'المتبقي', value: money(total))), Expanded(child: Stat(title: 'العملاء', value: '${s.customers.length}'))]))),
        TextField(decoration: const InputDecoration(hintText: 'بحث بالاسم أو الهاتف', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => query = v)),
        const SizedBox(height: 8), Wrap(spacing: 8, children: [ChoiceChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) => setState(() => filter = 'all')), ChoiceChip(label: const Text('عليهم دين'), selected: filter == 'debt', onSelected: (_) => setState(() => filter = 'debt')), ChoiceChip(label: const Text('مسدد'), selected: filter == 'paid', onSelected: (_) => setState(() => filter = 'paid'))]),
        const SizedBox(height: 8),
        ...list.map((c) { final b = s.balance(c.id); return Card(child: ListTile(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPage(store: s, customer: c))), leading: CircleAvatar(child: Text(c.name.isEmpty ? '؟' : c.name[0])), title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${c.phone}\n${s.risk(c.id)} • دين: ${money(s.debts(c.id))} • مسدد: ${money(s.paid(c.id))}'), isThreeLine: true, trailing: Text(money(b), style: const TextStyle(fontWeight: FontWeight.w900)))); }),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddCustomerPage(store: s))), icon: const Icon(Icons.person_add_alt_1), label: const Text('عميل')),
    ));
  }
}

class Stat extends StatelessWidget { const Stat({super.key, required this.title, required this.value}); final String title, value; @override Widget build(BuildContext context) => Column(children: [Text(title), const SizedBox(height: 4), Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900))]); }

class AddCustomerPage extends StatefulWidget { const AddCustomerPage({super.key, required this.store}); final Store store; @override State<AddCustomerPage> createState() => _AddCustomerPageState(); }
class _AddCustomerPageState extends State<AddCustomerPage> {
  final name = TextEditingController(), phone = TextEditingController(), limit = TextEditingController();
  Future<void> save() async { if (name.text.trim().isEmpty) return; widget.store.customers.add(Customer(id: makeId(), name: name.text.trim(), phone: phone.text.trim(), limit: double.tryParse(limit.text.replaceAll(',', '.')) ?? 0)); await widget.store.save(); if (mounted) Navigator.pop(context); }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('إضافة عميل')), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل')), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')), TextField(controller: limit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'السقف الائتماني اختياري')), const SizedBox(height: 20), FilledButton(onPressed: save, child: const Text('حفظ'))])));
}

class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer}); final Store store; final Customer customer;
  Future<void> openWhatsapp() async { final phone = customer.phone.replaceAll(RegExp(r'[^0-9]'), ''); final msg = store.whatsappMessage.replaceAll('[الاسم]', customer.name).replaceAll('[المبلغ]', money(store.balance(customer.id))); final uri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}'); if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication); }
  @override Widget build(BuildContext context) {
    final items = store.transactions.where((t) => t.customerId == customer.id).toList()..sort((a, b) => b.date.compareTo(a.date));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Text(customer.name)),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [const Text('الرصيد'), Text(money(store.balance(customer.id)), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)), Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'), Wrap(children: [FilledButton.icon(onPressed: openWhatsapp, icon: const Icon(Icons.chat), label: const Text('واتساب')), OutlinedButton.icon(onPressed: () => launchUrl(Uri.parse('tel:${customer.phone}')), icon: const Icon(Icons.phone), label: const Text('اتصال'))])]))),
        ...items.map((t) => Card(child: ListTile(title: Text(t.type == 'debt' ? 'دَين' : 'تسديد'), subtitle: Text('${dateText(t.date)}${t.note.isEmpty ? '' : ' • ${t.note}'}'), leading: Icon(t.type == 'debt' ? Icons.arrow_downward : Icons.arrow_upward), trailing: Row(mainAxisSize: MainAxisSize.min, children: [if (t.receiptPath.isNotEmpty && File(t.receiptPath).existsSync()) IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReceiptPage(path: t.receiptPath))), icon: const Icon(Icons.receipt_long_outlined)), Text(money(t.amount))])))),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddTransactionPage(store: store, customer: customer))), icon: const Icon(Icons.add), label: const Text('عملية')),
    ));
  }
}

class AddTransactionPage extends StatefulWidget { const AddTransactionPage({super.key, required this.store, required this.customer}); final Store store; final Customer customer; @override State<AddTransactionPage> createState() => _AddTransactionPageState(); }
class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount = TextEditingController(), note = TextEditingController(); final picker = ImagePicker(); String type = 'debt', receiptPath = '';
  Future<void> pickReceipt() async { final source = await showModalBottomSheet<ImageSource>(context: context, builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [ListTile(leading: const Icon(Icons.camera_alt), title: const Text('الكاميرا'), onTap: () => Navigator.pop(context, ImageSource.camera)), ListTile(leading: const Icon(Icons.photo), title: const Text('المعرض'), onTap: () => Navigator.pop(context, ImageSource.gallery))]))); if (source == null) return; final image = await picker.pickImage(source: source, imageQuality: 75, maxWidth: 1600, maxHeight: 2200); if (image == null) return; final root = await getApplicationDocumentsDirectory(); final directory = Directory('${root.path}/receipts'); await directory.create(recursive: true); final saved = await File(image.path).copy('${directory.path}/${makeId()}.jpg'); if (mounted) setState(() => receiptPath = saved.path); }
  Future<void> save() async { final value = double.tryParse(amount.text.replaceAll(',', '.')); if (value == null || value <= 0) return; widget.store.transactions.add(Tx(id: makeId(), customerId: widget.customer.id, type: type, amount: value, date: DateTime.now(), note: note.text.trim(), receiptPath: receiptPath)); await widget.store.save(); if (mounted) Navigator.pop(context); }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text('عملية — ${widget.customer.name}')), body: ListView(padding: const EdgeInsets.all(16), children: [SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دَين')), ButtonSegment(value: 'payment', label: Text('تسديد'))], selected: {type}, onSelectionChanged: (v) => setState(() => type = v.first)), TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ بالدينار الليبي')), TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'ملاحظات')), Card(child: ListTile(leading: const Icon(Icons.receipt_long_outlined), title: const Text('صورة الإيصال'), subtitle: Text(receiptPath.isEmpty ? 'اختيارية' : 'تم إرفاق الصورة'), trailing: IconButton(onPressed: pickReceipt, icon: const Icon(Icons.add_a_photo_outlined)))), if (receiptPath.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Image.file(File(receiptPath), height: 180, fit: BoxFit.cover)), const SizedBox(height: 16), FilledButton(onPressed: save, child: const Text('حفظ العملية'))])));
}

class ReceiptPage extends StatelessWidget { const ReceiptPage({super.key, required this.path}); final String path; @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('الإيصال')), body: Center(child: InteractiveViewer(child: Image.file(File(path))))); }

class SettingsPage extends StatefulWidget { const SettingsPage({super.key, required this.store}); final Store store; @override State<SettingsPage> createState() => _SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController shop, message;
  @override void initState() { super.initState(); shop = TextEditingController(text: widget.store.shop); message = TextEditingController(text: widget.store.whatsappMessage); }
  Future<void> save() async { widget.store.shop = shop.text.trim().isEmpty ? 'DainPay — دَيْن' : shop.text.trim(); widget.store.whatsappMessage = message.text.trim(); await widget.store.save(); if (mounted) Navigator.pop(context); }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('الإعدادات')), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: shop, decoration: const InputDecoration(labelText: 'اسم المحل / النشاط')), SwitchListTile(title: const Text('المظهر الداكن'), value: widget.store.dark, onChanged: (v) async { widget.store.dark = v; await widget.store.save(); setState(() {}); }), TextField(controller: message, maxLines: 4, decoration: const InputDecoration(labelText: 'رسالة واتساب')), const SizedBox(height: 20), FilledButton(onPressed: save, child: const Text('حفظ'))])));
}
