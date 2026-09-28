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
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  final store = await Store.load();
  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(99999)}';
String money(double value) => '${value.toStringAsFixed(2)} د.ل';
String dateText(DateTime date) => '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

class Customer {
  Customer({required this.id, required this.name, required this.phone, this.limit = 0});
  String id;
  String name;
  String phone;
  double limit;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'limit': limit};
  factory Customer.fromJson(Map<String, dynamic> json) => Customer(id: '${json['id'] ?? ''}', name: '${json['name'] ?? ''}', phone: '${json['phone'] ?? ''}', limit: (json['limit'] as num?)?.toDouble() ?? 0);
}

class Tx {
  Tx({required this.id, required this.customerId, required this.type, required this.amount, required this.date, required this.note, this.receiptPath = ''});
  String id;
  String customerId;
  String type;
  double amount;
  DateTime date;
  String note;
  String receiptPath;
  Map<String, dynamic> toJson() => {'id': id, 'customerId': customerId, 'type': type, 'amount': amount, 'date': date.toIso8601String(), 'note': note, 'receiptPath': receiptPath};
  factory Tx.fromJson(Map<String, dynamic> json) => Tx(id: '${json['id'] ?? ''}', customerId: '${json['customerId'] ?? ''}', type: '${json['type'] ?? 'debt'}', amount: (json['amount'] as num?)?.toDouble() ?? 0, date: DateTime.tryParse('${json['date']}') ?? DateTime.now(), note: '${json['note'] ?? ''}', receiptPath: '${json['receiptPath'] ?? ''}');
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  final List<Customer> customers = [];
  final List<Tx> transactions = [];
  String shop = 'DainPay — دَيْن';
  String whatsappMessage = 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  bool dark = false;
  bool firebaseReady = false;
  bool syncing = false;
  String uid = '';

  static Future<Store> load() async {
    final store = Store();
    store.prefs = await SharedPreferences.getInstance();
    store.shop = store.prefs.getString('shop') ?? store.shop;
    store.whatsappMessage = store.prefs.getString('whatsappMessage') ?? store.whatsappMessage;
    store.dark = store.prefs.getBool('dark') ?? false;
    try { final data = jsonDecode(store.prefs.getString('customers') ?? '[]') as List; store.customers.addAll(data.map((e) => Customer.fromJson(Map<String, dynamic>.from(e)))); } catch (_) {}
    try { final data = jsonDecode(store.prefs.getString('transactions') ?? '[]') as List; store.transactions.addAll(data.map((e) => Tx.fromJson(Map<String, dynamic>.from(e)))); } catch (_) {}
    return store;
  }

  Future<void> connectFirebase() async {
    try {
      User? user = FirebaseAuth.instance.currentUser;
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
      final customerDocs = await customersRef.get();
      for (final doc in customerDocs.docs) {
        final customer = Customer.fromJson(doc.data());
        final index = customers.indexWhere((item) => item.id == customer.id);
        if (index == -1) { customers.add(customer); } else { customers[index] = customer; }
      }
      final txDocs = await transactionsRef.get();
      for (final doc in txDocs.docs) {
        final data = doc.data();
        final rawDate = data['date'];
        final date = rawDate is Timestamp ? rawDate.toDate() : DateTime.tryParse('$rawDate') ?? DateTime.now();
        final transaction = Tx(id: '${data['id'] ?? doc.id}', customerId: '${data['customerId'] ?? ''}', type: '${data['type'] ?? 'debt'}', amount: (data['amount'] as num?)?.toDouble() ?? 0, date: date, note: '${data['note'] ?? ''}', receiptPath: '${data['receiptPath'] ?? ''}');
        final index = transactions.indexWhere((item) => item.id == transaction.id);
        if (index == -1) { transactions.add(transaction); } else { transactions[index] = transaction; }
      }
      await saveLocal();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final customer in customers) { batch.set(customersRef.doc(customer.id), customer.toJson()); }
      for (final transaction in transactions) { batch.set(transactionsRef.doc(transaction.id), {...transaction.toJson(), 'date': Timestamp.fromDate(transaction.date)}); }
      await batch.commit();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveLocal() async {
    await prefs.setString('customers', jsonEncode(customers.map((e) => e.toJson()).toList()));
    await prefs.setString('transactions', jsonEncode(transactions.map((e) => e.toJson()).toList()));
    await prefs.setString('shop', shop);
    await prefs.setString('whatsappMessage', whatsappMessage);
    await prefs.setBool('dark', dark);
  }
  Future<void> save() async { await saveLocal(); notifyListeners(); await saveCloud(); }
  double balance(String id) => transactions.where((t) => t.customerId == id).fold(0.0, (sum, t) => sum + (t.type == 'debt' ? t.amount : -t.amount));
  double debts(String id) => transactions.where((t) => t.customerId == id && t.type == 'debt').fold(0.0, (sum, t) => sum + t.amount);
  double paid(String id) => transactions.where((t) => t.customerId == id && t.type == 'payment').fold(0.0, (sum, t) => sum + t.amount);
  String risk(String id) { final current = balance(id); if (current <= 0) return 'مسدد'; final items = transactions.where((t) => t.customerId == id && t.type == 'debt').toList(); if (items.isEmpty) return 'حديث'; items.sort((a, b) => b.date.compareTo(a.date)); final days = DateTime.now().difference(items.first.date).inDays; if (days > 90) return 'خطر'; if (days > 30) return 'متأخر'; return 'حديث'; }
}

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store});
  final Store store;
  ThemeData theme(Brightness brightness) => ThemeData(useMaterial3: true, brightness: brightness, colorSchemeSeed: const Color(0xFF0F5C6E), fontFamily: 'Cairo');
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: store, builder: (context, child) => MaterialApp(debugShowCheckedModeBanner: false, theme: theme(Brightness.light), darkTheme: theme(Brightness.dark), themeMode: store.dark ? ThemeMode.dark : ThemeMode.light, home: HomePage(store: store)));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});
  final Store store;
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  String query = '';
  String filter = 'all';
  @override Widget build(BuildContext context) {
    final store = widget.store;
    final customers = store.customers.where((customer) { final balance = store.balance(customer.id); final search = query.isEmpty || customer.name.contains(query) || customer.phone.contains(query); final f = filter == 'all' || (filter == 'debt' && balance > 0) || (filter == 'paid' && balance <= 0); return search && f; }).toList();
    customers.sort((a, b) => store.balance(b.id).compareTo(store.balance(a.id)));
    final total = store.customers.fold<double>(0, (sum, customer) => sum + max(0, store.balance(customer.id)));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Text(store.shop, style: const TextStyle(fontWeight: FontWeight.w900)), actions: [IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(store: store))))]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [Expanded(child: Stat(title: 'المتبقي', value: money(total))), Expanded(child: Stat(title: 'العملاء', value: '${store.customers.length}'))]))),
        TextField(decoration: const InputDecoration(hintText: 'بحث بالاسم أو الهاتف', prefixIcon: Icon(Icons.search)), onChanged: (value) => setState(() => query = value)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [ChoiceChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) => setState(() => filter = 'all')), ChoiceChip(label: const Text('عليهم دين'), selected: filter == 'debt', onSelected: (_) => setState(() => filter = 'debt')), ChoiceChip(label: const Text('مسدد'), selected: filter == 'paid', onSelected: (_) => setState(() => filter = 'paid'))]),
        const SizedBox(height: 8),
        ...customers.map((customer) { final balance = store.balance(customer.id); return Card(child: ListTile(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPage(store: store, customer: customer))), leading: CircleAvatar(child: Text(customer.name.isEmpty ? '؟' : customer.name[0])), title: Text(customer.name, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${customer.phone}\n${store.risk(customer.id)} • دين: ${money(store.debts(customer.id))} • مسدد: ${money(store.paid(customer.id))}'), isThreeLine: true, trailing: Text(money(balance), style: const TextStyle(fontWeight: FontWeight.w900)))); }),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddCustomerPage(store: store))), icon: const Icon(Icons.person_add_alt_1), label: const Text('عميل')),
    );
  }
}

class Stat extends StatelessWidget { const Stat({super.key, required this.title, required this.value}); final String title; final String value; @override Widget build(BuildContext context) => Column(children: [Text(title), const SizedBox(height: 4), Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900))]); }

class AddCustomerPage extends StatefulWidget { const AddCustomerPage({super.key, required this.store}); final Store store; @override State<AddCustomerPage> createState() => _AddCustomerPageState(); }
class _AddCustomerPageState extends State<AddCustomerPage> {
  final name = TextEditingController(); final phone = TextEditingController(); final limit = TextEditingController();
  Future<void> save() async { if (name.text.trim().isEmpty) return; widget.store.customers.add(Customer(id: makeId(), name: name.text.trim(), phone: phone.text.trim(), limit: double.tryParse(limit.text.replaceAll(',', '.')) ?? 0)); await widget.store.save(); if (mounted) Navigator.pop(context); }
  @override Widget build(BuildContext context) { return Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('إضافة عميل')), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل')), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')), TextField(controller: limit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'السقف الائتماني اختياري')), const SizedBox(height: 20), FilledButton(onPressed: save, child: const Text('حفظ'))])); }
}

class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer});
  final Store store; final Customer customer;
  Future<void> openWhatsapp() async { final phone = customer.phone.replaceAll(RegExp(r'[^0-9]'), ''); final message = store.whatsappMessage.replaceAll('[الاسم]', customer.name).replaceAll('[المبلغ]', money(store.balance(customer.id))); final uri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(message)}'); if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication); }
  @override Widget build(BuildContext context) {
    final items = store.transactions.where((t) => t.customerId == customer.id).toList()..sort((a, b) => b.date.compareTo(a.date));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Text(customer.name)),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [const Text('الرصيد'), Text(money(store.balance(customer.id)), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)), Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'), Wrap(children: [FilledButton.icon(onPressed: openWhatsapp, icon: const Icon(Icons.chat), label: const Text('واتساب')), OutlinedButton.icon(onPressed: () => launchUrl(Uri.parse('tel:${customer.phone}')), icon: const Icon(Icons.phone), label: const Text('اتصال'))])]))),
        ...items.map((transaction) => Card(child: ListTile(title: Text(transaction.type == 'debt' ? 'دَين' : 'تسديد'), subtitle: Text('${dateText(transaction.date)}${transaction.note.isEmpty ? '' : ' • ${transaction.note}'}'), leading: Icon(transaction.type == 'debt' ? Icons.arrow_downward : Icons.arrow_upward), trailing: Row(mainAxisSize: MainAxisSize.min, children: [if (transaction.receiptPath.isNotEmpty && File(transaction.receiptPath).existsSync()) IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReceiptPage(path: transaction.receiptPath))), icon: const Icon(Icons.receipt_long_outlined)), Text(money(transaction.amount))]))),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddTransactionPage(store: store, customer: customer))), icon: const Icon(Icons.add), label: const Text('عملية')),
    );
  }
}

class AddTransactionPage extends StatefulWidget { const AddTransactionPage({super.key, required this.store, required this.customer}); final Store store; final Customer customer; @override State<AddTransactionPage> createState() => _AddTransactionPageState(); }
class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount = TextEditingController(); final note = TextEditingController(); final picker = ImagePicker(); String type = 'debt'; String receiptPath = '';
  Future<void> pickReceipt() async { final source = await showModalBottomSheet<ImageSource>(context: context, builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [ListTile(leading: const Icon(Icons.camera_alt), title: const Text('الكاميرا'), onTap: () => Navigator.pop(context, ImageSource.camera)), ListTile(leading: const Icon(Icons.photo), title: const Text('المعرض'), onTap: () => Navigator.pop(context, ImageSource.gallery))]))); if (source == null) return; final image = await picker.pickImage(source: source, imageQuality: 75, maxWidth: 1600, maxHeight: 2200); if (image == null) return; final root = await getApplicationDocumentsDirectory(); final directory = Directory('${root.path}/receipts'); await directory.create(recursive: true); final saved = await File(image.path).copy('${directory.path}/${makeId()}.jpg'); if (mounted) setState(() => receiptPath = saved.path); }
  Future<void> save() async { final value = double.tryParse(amount.text.replaceAll(',', '.')); if (value == null || value <= 0) return; widget.store.transactions.add(Tx(id: makeId(), customerId: widget.customer.id, type: type, amount: value, date: DateTime.now(), note: note.text.trim(), receiptPath: receiptPath)); await widget.store.save(); if (mounted) Navigator.pop(context); }
  @override Widget build(BuildContext context) { return Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text('عملية — ${widget.customer.name}')), body: ListView(padding: const EdgeInsets.all(16), children: [SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دَين')), ButtonSegment(value: 'payment', label: Text('تسديد'))], selected: {type}, onSelectionChanged: (value) => setState(() => type = value.first)), TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ بالدينار الليبي')), TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'ملاحظات')), Card(child: ListTile(leading: const Icon(Icons.receipt_long_outlined), title: const Text('صورة الإيصال'), subtitle: Text(receiptPath.isEmpty ? 'اختيارية' : 'تم إرفاق الصورة'), trailing: IconButton(onPressed: pickReceipt, icon: const Icon(Icons.add_a_photo_outlined)))), if (receiptPath.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Image.file(File(receiptPath), height: 180, fit: BoxFit.cover)), const SizedBox(height: 16), FilledButton(onPressed: save, child: const Text('حفظ العملية'))])); }
}

class ReceiptPage extends StatelessWidget { const ReceiptPage({super.key, required this.path}); final String path; @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('الإيصال')), body: Center(child: InteractiveViewer(child: Image.file(File(path))))); }

class SettingsPage extends StatefulWidget { const SettingsPage({super.key, required this.store}); final Store store; @override State<SettingsPage> createState() => _SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController shop; late TextEditingController message;
  @override void initState() { super.initState(); shop = TextEditingController(text: widget.store.shop); message = TextEditingController(text: widget.store.whatsappMessage); }
  Future<void> save() async { widget.store.shop = shop.text.trim().isEmpty ? 'DainPay — دَيْن' : shop.text.trim(); widget.store.whatsappMessage = message.text.trim(); await widget.store.save(); if (mounted) Navigator.pop(context); }
  @override Widget build(BuildContext context) { return Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('الإعدادات')), body: ListView(padding: const EdgeInsets.all(16), children: [TextField(controller: shop, decoration: const InputDecoration(labelText: 'اسم المحل / النشاط')), SwitchListTile(title: const Text('المظهر الداكن'), value: widget.store.dark, onChanged: (value) async { widget.store.dark = value; await widget.store.save(); setState(() {}); }), TextField(controller: message, maxLines: 4, decoration: const InputDecoration(labelText: 'رسالة واتساب')), const SizedBox(height: 20), FilledButton(onPressed: save, child: const Text('حفظ'))])); }
}
