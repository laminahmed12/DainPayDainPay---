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

String newId() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(99999)}';
String money(double n) => '${n.toStringAsFixed(2)} د.ل';
String dateText(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

class Customer {
  String id, name, phone;
  double creditLimit;
  Customer(this.id, this.name, this.phone, [this.creditLimit = 0]);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'creditLimit': creditLimit};
  factory Customer.fromJson(Map<String, dynamic> j) => Customer('${j['id']}', '${j['name'] ?? ''}', '${j['phone'] ?? ''}', (j['creditLimit'] as num?)?.toDouble() ?? 0);
}

class TransactionItem {
  String id, customerId, type, note, receiptPath;
  double amount;
  DateTime date;
  TransactionItem(this.id, this.customerId, this.type, this.amount, this.date, this.note, [this.receiptPath = '']);
  Map<String, dynamic> toJson() => {'id': id, 'customerId': customerId, 'type': type, 'amount': amount, 'date': date.toIso8601String(), 'note': note, 'receiptPath': receiptPath};
  factory TransactionItem.fromJson(Map<String, dynamic> j) => TransactionItem('${j['id']}', '${j['customerId']}', '${j['type'] ?? 'debt'}', (j['amount'] as num?)?.toDouble() ?? 0, DateTime.tryParse('${j['date']}') ?? DateTime.now(), '${j['note'] ?? ''}', '${j['receiptPath'] ?? ''}');
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  List<Customer> customers = [];
  List<TransactionItem> transactions = [];
  String shop = 'دفتر دَيْن';
  String message = 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  bool dark = false, firebaseReady = false, syncing = false;
  String uid = '';

  static Future<Store> load() async {
    final s = Store();
    s.prefs = await SharedPreferences.getInstance();
    s.shop = s.prefs.getString('shop') ?? s.shop;
    s.message = s.prefs.getString('message') ?? s.message;
    s.dark = s.prefs.getBool('dark') ?? false;
    try { s.customers = (jsonDecode(s.prefs.getString('customers') ?? '[]') as List).map((e) => Customer.fromJson(Map<String, dynamic>.from(e))).toList(); } catch (_) {}
    try { s.transactions = (jsonDecode(s.prefs.getString('transactions') ?? '[]') as List).map((e) => TransactionItem.fromJson(Map<String, dynamic>.from(e))).toList(); } catch (_) {}
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
      final cs = await customersRef.get();
      final ts = await transactionsRef.get();
      for (final d in cs.docs) {
        final c = Customer.fromJson(d.data());
        final i = customers.indexWhere((x) => x.id == c.id);
        if (i < 0) { customers.add(c); } else { customers[i] = c; }
      }
      for (final d in ts.docs) {
        final j = d.data();
        final rawDate = j['date'];
        final dt = rawDate is Timestamp ? rawDate.toDate() : (DateTime.tryParse('$rawDate') ?? DateTime.now());
        final t = TransactionItem('${j['id'] ?? d.id}', '${j['customerId'] ?? ''}', '${j['type'] ?? 'debt'}', (j['amount'] as num?)?.toDouble() ?? 0, dt, '${j['note'] ?? ''}', '${j['receiptPath'] ?? ''}');
        final i = transactions.indexWhere((x) => x.id == t.id);
        if (i < 0) { transactions.add(t); } else { transactions[i] = t; }
      }
      await saveLocal();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final c in customers) { batch.set(customersRef.doc(c.id), c.toJson()); }
      for (final t in transactions) { batch.set(transactionsRef.doc(t.id), {...t.toJson(), 'date': Timestamp.fromDate(t.date)}); }
      await batch.commit();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveLocal() async {
    await prefs.setString('customers', jsonEncode(customers.map((e) => e.toJson()).toList()));
    await prefs.setString('transactions', jsonEncode(transactions.map((e) => e.toJson()).toList()));
    await prefs.setString('shop', shop);
    await prefs.setString('message', message);
    await prefs.setBool('dark', dark);
  }

  Future<void> save() async { await saveLocal(); notifyListeners(); await saveCloud(); }
  double balance(String id) => transactions.where((t) => t.customerId == id).fold(0.0, (v, t) => v + (t.type == 'debt' ? t.amount : -t.amount));
  double debts(String id) => transactions.where((t) => t.customerId == id && t.type == 'debt').fold(0.0, (v, t) => v + t.amount);
  double paid(String id) => transactions.where((t) => t.customerId == id && t.type == 'payment').fold(0.0, (v, t) => v + t.amount);
  int overdue(String id) { final a = transactions.where((t) => t.customerId == id && t.type == 'debt').toList()..sort((a,b) => b.date.compareTo(a.date)); if (a.isEmpty || balance(id) <= 0) return 0; return DateTime.now().difference(a.first.date).inDays; }
  String risk(String id) { final b = balance(id); if (b <= 0) return 'مسدد'; final d = overdue(id); return d > 90 ? 'خطر' : d > 30 ? 'متأخر' : 'حديث'; }
}

class DainPayApp extends StatelessWidget {
  final Store store;
  const DainPayApp({super.key, required this.store});
  ThemeData theme(Brightness b) => ThemeData(useMaterial3: true, brightness: b, colorSchemeSeed: const Color(0xFF0F5C6E), fontFamily: 'Cairo', scaffoldBackgroundColor: b == Brightness.dark ? const Color(0xFF0D171A) : const Color(0xFFF4F8F9));
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: store, builder: (_, __) => MaterialApp(debugShowCheckedModeBanner: false, theme: theme(Brightness.light), darkTheme: theme(Brightness.dark), themeMode: store.dark ? ThemeMode.dark : ThemeMode.light, home: HomePage(store: store)));
}

class HomePage extends StatefulWidget { final Store store; const HomePage({super.key, required this.store}); @override State<HomePage> createState() => _HomePageState(); }
class _HomePageState extends State<HomePage> {
  String query = '', filter = 'all';
  @override Widget build(BuildContext context) {
    final s = widget.store;
    final list = s.customers.where((c) { final match = query.isEmpty || c.name.contains(query) || c.phone.contains(query); final b = s.balance(c.id); return match && (filter == 'all' || (filter == 'debt' && b > 0) || (filter == 'paid' && b <= 0)); }).toList()..sort((a,b) => s.balance(b.id).compareTo(s.balance(a.id)));
    final total = s.customers.fold(0.0, (v,c) => v + max(0, s.balance(c.id)));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text(s.shop, style: const TextStyle(fontWeight: FontWeight.w900)), actions: [IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(store: s))), icon: const Icon(Icons.settings_outlined))]), body: ListView(padding: const EdgeInsets.all(12), children: [Card(child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [Expanded(child: _Stat('المتبقي', money(total))), Expanded(child: _Stat('العملاء', '${s.customers.length}'))]))), TextField(decoration: const InputDecoration(hintText: 'بحث بالاسم أو الهاتف', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => query = v)), const SizedBox(height: 8), Wrap(spacing: 8, children: [ChoiceChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) => setState(() => filter = 'all')), ChoiceChip(label: const Text('عليهم دين'), selected: filter == 'debt', onSelected: (_) => setState(() => filter = 'debt')), ChoiceChip(label: const Text('مسدد'), selected: filter == 'paid', onSelected: (_) => setState(() => filter = 'paid'))]), const SizedBox(height: 8), ...list.map((c) => Card(child: ListTile(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPage(store: s, customer: c))), leading: CircleAvatar(child: Text(c.name.isEmpty ? '؟' : c.name[0])), title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${c.phone}\n${s.risk(c.id)} • دين: ${money(s.debts(c.id))} • مسدد: ${money(s.paid(c.id))}'), isThreeLine: true, trailing: Text(money(s.balance(c.id)), style: TextStyle(fontWeight: FontWeight.w900, color: s.balance(c.id) > 0 ? Theme.of(context).colorScheme.primary : Colors.green)))) )]),), floatingActionButton: FloatingActionButton.extended(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddCustomerPage(store: s))), icon: const Icon(Icons.person_add_alt_1), label: const Text('عميل')));
  }
}
class _Stat extends StatelessWidget { final String a,b; const _Stat(this.a,this.b); @override Widget build(BuildContext c) => Column(children: [Text(a), const SizedBox(height: 4), Text(b, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18))]); }

class AddCustomerPage extends StatefulWidget { final Store store; const AddCustomerPage({super.key, required this.store}); @override State<AddCustomerPage> createState() => _AddCustomerPageState(); }
class _AddCustomerPageState extends State<AddCustomerPage> { final name = TextEditingController(), phone = TextEditingController(), limit = TextEditingController(); Future<void> save() async { if (name.text.trim().isEmpty) return; widget.store.customers.add(Customer(newId(), name.text.trim(), phone.text.trim(), double.tryParse(limit.text.replaceAll(',','.')) ?? 0)); await widget.store.save(); if (mounted) Navigator.pop(context); } @override Widget build(BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('إضافة عميل')), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل')), const SizedBox(height: 12), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')), const SizedBox(height: 12), TextField(controller: limit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'السقف الائتماني (اختياري)')), const SizedBox(height: 20), FilledButton(onPressed: save, child: const Text('حفظ'))]))); }

class CustomerPage extends StatelessWidget { final Store store; final Customer customer; const CustomerPage({super.key, required this.store, required this.customer}); Future<void> whatsapp(BuildContext c) async { final msg = store.message.replaceAll('[الاسم]', customer.name).replaceAll('[المبلغ]', money(store.balance(customer.id))); final phone = customer.phone.replaceAll(RegExp(r'[^0-9]'), ''); final uri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}'); if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication); } @override Widget build(BuildContext c) { final tx = store.transactions.where((x) => x.customerId == customer.id).toList()..sort((a,b) => b.date.compareTo(a.date)); return Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text(customer.name)), body: ListView(padding: const EdgeInsets.all(12), children: [Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [Text('الرصيد', style: Theme.of(c).textTheme.titleMedium), Text(money(store.balance(customer.id)), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)), Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'), const SizedBox(height: 12), Wrap(spacing: 8, children: [FilledButton.icon(onPressed: () => whatsapp(c), icon: const Icon(Icons.chat), label: const Text('واتساب')), OutlinedButton.icon(onPressed: () => launchUrl(Uri.parse('tel:${customer.phone}')), icon: const Icon(Icons.phone), label: const Text('اتصال'))])]))), ...tx.map((t) => Card(child: ListTile(title: Text(t.type == 'debt' ? 'دَين' : 'تسديد', style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${dateText(t.date)}${t.note.isEmpty ? '' : ' • ${t.note}'}'), leading: Icon(t.type == 'debt' ? Icons.arrow_downward : Icons.arrow_upward), trailing: Row(mainAxisSize: MainAxisSize.min, children: [if (t.receiptPath.isNotEmpty && File(t.receiptPath).existsSync()) IconButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ReceiptPage(path: t.receiptPath))), icon: const Icon(Icons.receipt_long_outlined)), Text(money(t.amount))])))),]), floatingActionButton: FloatingActionButton.extended(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => AddTransactionPage(store: store, customer: customer))), icon: const Icon(Icons.add), label: const Text('عملية'))); } }

class AddTransactionPage extends StatefulWidget { final Store store; final Customer customer; const AddTransactionPage({super.key, required this.store, required this.customer}); @override State<AddTransactionPage> createState() => _AddTransactionPageState(); }
class _AddTransactionPageState extends State<AddTransactionPage> { final amount = TextEditingController(), note = TextEditingController(); final picker = ImagePicker(); String type = 'debt', receipt = ''; Future<void> pickReceipt() async { final source = await showModalBottomSheet<ImageSource>(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [ListTile(leading: const Icon(Icons.camera_alt), title: const Text('الكاميرا'), onTap: () => Navigator.pop(context, ImageSource.camera)), ListTile(leading: const Icon(Icons.photo), title: const Text('المعرض'), onTap: () => Navigator.pop(context, ImageSource.gallery))]))); if (source == null) return; final x = await picker.pickImage(source: source, imageQuality: 75, maxWidth: 1600, maxHeight: 2200); if (x == null) return; final d = await getApplicationDocumentsDirectory(); final dir = Directory('${d.path}/receipts'); await dir.create(recursive: true); final f = await File(x.path).copy('${dir.path}/${newId()}.jpg'); if (mounted) setState(() => receipt = f.path); } Future<void> save() async { final value = double.tryParse(amount.text.replaceAll(',','.')); if (value == null || value <= 0) return; widget.store.transactions.add(TransactionItem(newId(), widget.customer.id, type, value, DateTime.now(), note.text.trim(), receipt)); await widget.store.save(); if (mounted) Navigator.pop(context); } @override Widget build(BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('إضافة عملية')), body: ListView(padding: const EdgeInsets.all(16), children: [Text(widget.customer.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 14), SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دَين')), ButtonSegment(value: 'payment', label: Text('تسديد'))], selected: {type}, onSelectionChanged: (v) => setState(() => type = v.first)), const SizedBox(height: 14), TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ بالدينار الليبي')), const SizedBox(height: 12), TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظات')), const SizedBox(height: 12), Card(child: ListTile(leading: const Icon(Icons.receipt_long), title: const Text('صورة الإيصال'), subtitle: Text(receipt.isEmpty ? 'اختياري' : 'تم إرفاق الإيصال'), trailing: IconButton(onPressed: pickReceipt, icon: const Icon(Icons.add_a_photo)))), if (receipt.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Image.file(File(receipt), height: 180, fit: BoxFit.cover)), const SizedBox(height: 20), FilledButton(onPressed: save, child: const Text('حفظ العملية'))]))); }

class ReceiptPage extends StatelessWidget { final String path; const ReceiptPage({super.key, required this.path}); @override Widget build(BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('الإيصال')), body: Center(child: InteractiveViewer(child: Image.file(File(path), fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Text('تعذر فتح الصورة')))))); }

class SettingsPage extends StatefulWidget { final Store store; const SettingsPage({super.key, required this.store}); @override State<SettingsPage> createState() => _SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage> { late TextEditingController shop, msg; @override void initState() { super.initState(); shop = TextEditingController(text: widget.store.shop); msg = TextEditingController(text: widget.store.message); } Future<void> save() async { widget.store.shop = shop.text.trim().isEmpty ? 'دفتر دَيْن' : shop.text.trim(); widget.store.message = msg.text.trim(); await widget.store.save(); if (mounted) Navigator.pop(context); } @override Widget build(BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('الإعدادات')), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: shop, decoration: const InputDecoration(labelText: 'اسم المحل / النشاط')), const SizedBox(height: 12), TextField(controller: msg, maxLines: 4, decoration: const InputDecoration(labelText: 'رسالة واتساب')), SwitchListTile(title: const Text('المظهر الداكن'), value: widget.store.dark, onChanged: (v) async { setState(() => widget.store.dark = v); await widget.store.save(); }), const SizedBox(height: 20), FilledButton(onPressed: save, child: const Text('حفظ الإعدادات'))]))); }
