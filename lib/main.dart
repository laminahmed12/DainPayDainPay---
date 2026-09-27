import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (_) {}
  final store = await Store.load();
  runApp(DainPayApp(store: store));
}

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(9999)}';
String money(double value) => '${value.toStringAsFixed(2)} د.ل';

class Customer {
  String id;
  String name;
  String phone;
  Customer(this.id, this.name, this.phone);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone};
  factory Customer.fromJson(dynamic j) => Customer(j['id'], j['name'], j['phone'] ?? '');
}

class Tx {
  String id;
  String customerId;
  String type;
  double amount;
  DateTime date;
  String note;
  Tx(this.id, this.customerId, this.type, this.amount, this.date, this.note);
  Map<String, dynamic> toJson() => {
    'id': id, 'customerId': customerId, 'type': type, 'amount': amount,
    'date': date.toIso8601String(), 'note': note
  };
  factory Tx.fromJson(dynamic j) => Tx(
    j['id'], j['customerId'], j['type'], (j['amount'] as num).toDouble(),
    DateTime.parse(j['date']), j['note'] ?? ''
  );
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  List<Customer> customers = [];
  List<Tx> transactions = [];
  String shopName = 'دفتر دَيْن';
  String whatsappMessage = 'السلام عليكم أخي [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  bool dark = false;
  bool activated = false;
  late DateTime trialStart;
  String deviceCode = '';
  String permanentCode = '';
  Map<String, String> customerCodes = {};
  bool adminUnlocked = false;

  static Future<Store> load() async {
    final s = Store();
    s.prefs = await SharedPreferences.getInstance();
    s.shopName = s.prefs.getString('shopName') ?? s.shopName;
    s.whatsappMessage = s.prefs.getString('whatsappMessage') ?? s.whatsappMessage;
    s.dark = s.prefs.getBool('dark') ?? false;
    s.activated = s.prefs.getBool('activated') ?? false;
    s.deviceCode = s.prefs.getString('deviceCode') ?? '';
    s.permanentCode = s.prefs.getString('permanentCode') ?? '';
    final savedCodes = s.prefs.getString('customerCodes');
    if (savedCodes != null) s.customerCodes = Map<String, String>.from(jsonDecode(savedCodes));
    if (s.deviceCode.isEmpty) { s.deviceCode = 'DP-' + List.generate(8, (_) => 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'[Random().nextInt(36)]).join(); await s.prefs.setString('deviceCode', s.deviceCode); }
    final savedTrial = s.prefs.getString('trialStart');
    s.trialStart = savedTrial == null ? DateTime.now() : DateTime.parse(savedTrial);
    if (savedTrial == null) await s.prefs.setString('trialStart', s.trialStart.toIso8601String());
    final savedCustomers = s.prefs.getString('customers');
    final savedTx = s.prefs.getString('transactions');
    if (savedCustomers != null) {
      s.customers = (jsonDecode(savedCustomers) as List).map(Customer.fromJson).toList();
    }
    if (savedTx != null) {
      s.transactions = (jsonDecode(savedTx) as List).map(Tx.fromJson).toList();
    }
    return s;
  }

  int get trialDaysLeft {
    if (activated) return 999;
    final used = DateTime.now().difference(trialStart).inDays;
    return max(0, 14 - used);
  }

  double balance(String customerId) {
    return transactions.where((x) => x.customerId == customerId).fold(
      0.0, (sum, x) => sum + (x.type == 'debt' ? x.amount : -x.amount)
    );
  }

  double paid(String customerId) {
    return transactions.where((x) => x.customerId == customerId && x.type == 'payment').fold(
      0.0, (sum, x) => sum + x.amount
    );
  }

  Future<String> generatePermanentCode() async {
    if (permanentCode.isNotEmpty) return permanentCode;
    permanentCode = 'DP-' + List.generate(12, (_) => 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[Random().nextInt(32)]).join();
    await save();
    try { await FirebaseFirestore.instance.collection('activation_codes').doc(permanentCode).set({'code': permanentCode, 'deviceCode': deviceCode, 'used': false, 'createdAt': FieldValue.serverTimestamp()}); } catch (_) {}
    return permanentCode;
  }

  Future<String> generateCustomerCode(Customer customer) async {
    final existing = customerCodes[customer.id];
    if (existing != null && existing.isNotEmpty) return existing;
    final code = 'DP-' + List.generate(12, (_) => 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[Random().nextInt(32)]).join();
    customerCodes[customer.id] = code;
    await save();
    try {
      await FirebaseFirestore.instance.collection('activation_codes').doc(code).set({
        'code': code, 'deviceCode': deviceCode, 'customerId': customer.id,
        'customerName': customer.name, 'used': false, 'permanent': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
    return code;
  }

  Future<void> save() async {
    await prefs.setString('customers', jsonEncode(customers.map((x) => x.toJson()).toList()));
    await prefs.setString('transactions', jsonEncode(transactions.map((x) => x.toJson()).toList()));
    await prefs.setString('shopName', shopName);
    await prefs.setString('whatsappMessage', whatsappMessage);
    await prefs.setBool('dark', dark);
    await prefs.setBool('activated', activated);
    await prefs.setString('deviceCode', deviceCode);
    await prefs.setString('permanentCode', permanentCode);
    await prefs.setString('customerCodes', jsonEncode(customerCodes));
    notifyListeners();
  }
}

class DainPayApp extends StatelessWidget {
  final Store store;
  const DainPayApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        themeMode: store.dark ? ThemeMode.dark : ThemeMode.light,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        home: HomePage(store: store),
      ),
    );
  }

  ThemeData appTheme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: const Color(0xFF0F5C6E),
      fontFamily: 'Tajawal',
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF10191D)
          : const Color(0xFFF5F8F9),
    );
  }
}

class HomePage extends StatefulWidget {
  final Store store;
  const HomePage({super.key, required this.store});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  String search = '';

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final customers = store.customers.where((c) {
      return c.name.contains(search) || c.phone.contains(search);
    }).toList();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(onTap: () => _adminTap(context, store), child: Text(store.shopName, style: const TextStyle(fontWeight: FontWeight.w900))),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsPage(store: store)),
              ),
            ),
          ],
        ),
        body: Column(
                children: [
                  if (!store.activated)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      color: const Color(0xFFE8A317),
                      child: Text(
                        store.trialDaysLeft > 0
                            ? 'الفترة التجريبية: متبقي ${store.trialDaysLeft} يوم'
                            : 'انتهت الفترة التجريبية — افتح الإعدادات للتفعيل',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: TextField(
                      onChanged: (v) => setState(() => search = v),
                      decoration: InputDecoration(
                        hintText: 'ابحث باسم العميل أو الهاتف',
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: customers.isEmpty
                        ? EmptyView(onAdd: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => AddCustomerPage(store: store)),
                            ))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: customers.length,
                            itemBuilder: (_, i) {
                              final customer = customers[i];
                              final balance = store.balance(customer.id);
                              return Card(
                                child: ListTile(
                                  leading: CircleAvatar(
                                    child: Text(customer.name.isEmpty ? '؟' : customer.name[0]),
                                  ),
                                  title: Text(customer.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                  subtitle: Text(customer.phone.isEmpty ? 'بدون هاتف' : customer.phone),
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        money(balance),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: balance > 0 ? const Color(0xFFE8A317) : Colors.green,
                                        ),
                                      ),
                                      Text('مدفوع ${money(store.paid(customer.id))}'),
                                    ],
                                  ),
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => CustomerPage(store: store, customer: customer),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (v) => setState(() => tab = v),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.menu_book_outlined), label: 'الدفتر'),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AddCustomerPage(store: store)),
                ),
                icon: const Icon(Icons.person_add),
                label: const Text('عميل جديد'),
              ),
      ),
    );
  }
}

class AdminGate {
  static int taps = 0;
  static DateTime last = DateTime.fromMillisecondsSinceEpoch(0);
}

Future<void> _adminTap(BuildContext context, Store store) async {
  final now = DateTime.now();
  if (now.difference(AdminGate.last).inSeconds > 2) AdminGate.taps = 0;
  AdminGate.last = now;
  AdminGate.taps++;
  if (AdminGate.taps < 3) return;
  AdminGate.taps = 0;
  final code = TextEditingController();
  final ok = await showDialog<bool>(context: context, builder: (_) => Directionality(
    textDirection: TextDirection.rtl,
    child: AlertDialog(
      title: const Text('Adreemk'),
      content: TextField(controller: code, keyboardType: TextInputType.number, obscureText: true, decoration: const InputDecoration(labelText: 'رمز الدخول')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(context, code.text.trim() == '116936'), child: const Text('دخول')),
      ],
    ),
  ));
  if (ok == true && context.mounted) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => AdreemkPage(store: store)));
  }
}

class AdreemkPage extends StatelessWidget {
  final Store store;
  const AdreemkPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('Adreemk • إدارة التفعيل')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Card(child: ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('رقم الجهاز'),
              subtitle: Text(store.deviceCode),
            )),
            const SizedBox(height: 8),
            const Text('رموز العملاء', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (store.customers.isEmpty)
              const Card(child: Padding(
                padding: EdgeInsets.all(18),
                child: Text('أضف العملاء أولاً، ثم يمكنك توليد رمز دائم لكل عميل.'),
              ))
            else
              ...store.customers.map((customer) => Card(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                  title: Text(customer.name),
                  subtitle: Text(store.customerCodes[customer.id] ?? 'لم يتم توليد رمز بعد'),
                  trailing: IconButton(
                    icon: const Icon(Icons.vpn_key_outlined),
                    onPressed: () async {
                      final code = await store.generateCustomerCode(customer);
                      if (!context.mounted) return;
                      showDialog(context: context, builder: (_) => AlertDialog(
                        title: Text('رمز العميل: ' + customer.name),
                        content: SelectableText(code, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
                      ));
                    },
                  ),
                ),
              )),
          ],
        ),
      ),
    );
  }
}
class EmptyView extends StatelessWidget {
  final VoidCallback onAdd;
  const EmptyView({super.key, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.menu_book_outlined, size: 64),
          const SizedBox(height: 12),
          const Text('الدفتر فارغ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('أضف عميلك الأول وسجّل الديون والسداد.'),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('إضافة عميل')),
        ],
      ),
    );
  }
}

class AddCustomerPage extends StatefulWidget {
  final Store store;
  const AddCustomerPage({super.key, required this.store});
  @override
  State<AddCustomerPage> createState() => _AddCustomerPageState();
}

class _AddCustomerPageState extends State<AddCustomerPage> {
  final name = TextEditingController();
  final phone = TextEditingController();

  Future<void> save() async {
    if (name.text.trim().isEmpty) return;
    widget.store.customers.add(Customer(makeId(), name.text.trim(), phone.text.trim()));
    await widget.store.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إضافة عميل')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل')),
            const SizedBox(height: 14),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'رقم الهاتف'),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: save, child: const Text('حفظ العميل')),
          ],
        ),
      ),
    );
  }
}

class CustomerPage extends StatelessWidget {
  final Store store;
  final Customer customer;
  const CustomerPage({super.key, required this.store, required this.customer});

  Future<void> sendWhatsApp(BuildContext context) async {
    final balance = store.balance(customer.id);
    final message = store.whatsappMessage
        .replaceAll('[الاسم]', customer.name)
        .replaceAll('[المبلغ]', money(balance));
    final digits = customer.phone.replaceAll(RegExp(r'[^0-9]'), '');
    final uri = Uri.parse('https://wa.me/218$digits?text=${Uri.encodeComponent(message)}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = store.transactions.where((x) => x.customerId == customer.id).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final balance = store.balance(customer.id);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(customer.name),
          actions: [
            IconButton(
              icon: const Icon(Icons.chat_outlined),
              onPressed: () => sendWhatsApp(context),
            ),
          ],
        ),
        body: Column(
          children: [
            Card(
              margin: const EdgeInsets.all(14),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Stat(title: 'المتبقي', value: money(balance), warning: balance > 0),
                    Stat(title: 'المدفوع', value: money(store.paid(customer.id))),
                  ],
                ),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('لا توجد عمليات'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final tx = list[i];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Icon(tx.type == 'debt' ? Icons.arrow_upward : Icons.arrow_downward),
                            ),
                            title: Text(tx.type == 'debt' ? 'دين' : 'سداد'),
                            subtitle: Text(
                              '${tx.date.day}/${tx.date.month}/${tx.date.year}'
                              '${tx.note.isEmpty ? '' : ' • ${tx.note}'}',
                            ),
                            trailing: Text(
                              money(tx.amount),
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: tx.type == 'debt' ? const Color(0xFFE8A317) : Colors.green,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AddTransactionPage(store: store, customer: customer),
            ),
          ),
          icon: const Icon(Icons.add),
          label: const Text('عملية'),
        ),
      ),
    );
  }
}

class Stat extends StatelessWidget {
  final String title;
  final String value;
  final bool warning;
  const Stat({super.key, required this.title, required this.value, this.warning = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(title),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: warning ? const Color(0xFFE8A317) : Colors.green,
          ),
        ),
      ],
    );
  }
}

class AddTransactionPage extends StatefulWidget {
  final Store store;
  final Customer customer;
  const AddTransactionPage({super.key, required this.store, required this.customer});
  @override
  State<AddTransactionPage> createState() => _AddTransactionPageState();
}

class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount = TextEditingController();
  final note = TextEditingController();
  String type = 'debt';

  Future<void> save() async {
    final value = double.tryParse(amount.text.replaceAll(',', '.'));
    if (value == null || value <= 0) return;
    widget.store.transactions.add(
      Tx(makeId(), widget.customer.id, type, value, DateTime.now(), note.text.trim()),
    );
    await widget.store.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إضافة عملية')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'debt', label: Text('دين'), icon: Icon(Icons.add_card)),
                ButtonSegment(value: 'payment', label: Text('سداد'), icon: Icon(Icons.payments)),
              ],
              selected: {type},
              onSelectionChanged: (v) => setState(() => type = v.first),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'المبلغ بالدينار الليبي'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: note,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'ملاحظات'),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: save, child: const Text('حفظ العملية')),
          ],
        ),
      ),
    );
  }
}

class AssociationsPage extends StatelessWidget {
  const AssociationsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.groups_outlined, size: 70),
            const SizedBox(height: 12),
            const Text('الجمعيات الأهلية', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('سيتم ربط الدورات والأعضاء والدفع مع Firebase.'),
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final Store store;
  const SettingsPage({super.key, required this.store});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController shop;
  late TextEditingController message;

  @override
  void initState() {
    super.initState();
    shop = TextEditingController(text: widget.store.shopName);
    message = TextEditingController(text: widget.store.whatsappMessage);
  }

  Future<void> save() async {
    widget.store.shopName = shop.text.trim().isEmpty ? 'دفتر دَيْن' : shop.text.trim();
    widget.store.whatsappMessage = message.text.trim();
    await widget.store.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('الإعدادات')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            TextField(controller: shop, decoration: const InputDecoration(labelText: 'اسم المحل / الدفتر')),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('الوضع الداكن'),
              value: store.dark,
              onChanged: (v) async {
                store.dark = v;
                await store.save();
              },
            ),
            const Divider(),
            const Text('رسالة التذكير عبر واتساب', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: message,
              maxLines: 5,
              decoration: const InputDecoration(hintText: 'استخدم [الاسم] و[المبلغ]'),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: save, child: const Text('حفظ الإعدادات')),
            const SizedBox(height: 20),
            Card(
              child: ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(store.activated ? 'التفعيل الدائم مفعل' : 'الفترة التجريبية'),
                subtitle: Text(store.activated
                    ? 'هذا الجهاز مفعل بشكل دائم.'
                    : 'متبقي ${store.trialDaysLeft} يوم'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('Firebase'),
                subtitle: const Text(
                  'حزم Firebase موجودة في المشروع. يلزم إضافة google-services.json وربط مشروع Firebase الفعلي.',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
