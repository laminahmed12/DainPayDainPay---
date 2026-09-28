import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
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

String makeId() =>
    DateTime.now().microsecondsSinceEpoch.toString() +
    '_' +
    Random().nextInt(9999).toString();

String money(double value) => value.toStringAsFixed(2) + ' د.ل';

String dateText(DateTime d) =>
    d.day.toString().padLeft(2, '0') +
    '/' +
    d.month.toString().padLeft(2, '0') +
    '/' +
    d.year.toString();

class Customer {
  String id;
  String name;
  String phone;
  double creditLimit;

  Customer(this.id, this.name, this.phone, [this.creditLimit = 0]);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'creditLimit': creditLimit,
      };

  factory Customer.fromJson(dynamic j) => Customer(
        j['id'].toString(),
        j['name'].toString(),
        j['phone']?.toString() ?? '',
        (j['creditLimit'] as num?)?.toDouble() ?? 0,
      );
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
        'id': id,
        'customerId': customerId,
        'type': type,
        'amount': amount,
        'date': date.toIso8601String(),
        'note': note,
      };

  factory Tx.fromJson(dynamic j) => Tx(
        j['id'].toString(),
        j['customerId'].toString(),
        j['type']?.toString() ?? 'debt',
        (j['amount'] as num).toDouble(),
        DateTime.tryParse(j['date'].toString()) ?? DateTime.now(),
        j['note']?.toString() ?? '',
      );
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;

  List<Customer> customers = [];
  List<Tx> transactions = [];

  String shopName = 'دفتر دَيْن';
  String whatsappMessage =
      'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  bool dark = false;

  bool firebaseReady = false;
  bool syncing = false;
  String firebaseUid = '';

  static Future<Store> load() async {
    final s = Store();
    s.prefs = await SharedPreferences.getInstance();

    s.shopName = s.prefs.getString('shopName') ?? s.shopName;
    s.whatsappMessage =
        s.prefs.getString('whatsappMessage') ?? s.whatsappMessage;
    s.dark = s.prefs.getBool('dark') ?? false;

    final savedCustomers = s.prefs.getString('customers');
    final savedTx = s.prefs.getString('transactions');

    if (savedCustomers != null) {
      try {
        s.customers =
            (jsonDecode(savedCustomers) as List).map(Customer.fromJson).toList();
      } catch (_) {}
    }

    if (savedTx != null) {
      try {
        s.transactions =
            (jsonDecode(savedTx) as List).map(Tx.fromJson).toList();
      } catch (_) {}
    }

    return s;
  }

  Future<void> connectFirebase() async {
    try {
      User? user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) return;

      firebaseUid = user.uid;
      firebaseReady = true;
      await syncFromFirebase();
    } catch (_) {
      firebaseReady = false;
    }
    notifyListeners();
  }

  CollectionReference<Map<String, dynamic>> get customersRef =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(firebaseUid)
          .collection('customers');

  CollectionReference<Map<String, dynamic>> get transactionsRef =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(firebaseUid)
          .collection('transactions');

  Future<void> syncFromFirebase() async {
    if (!firebaseReady || firebaseUid.isEmpty || syncing) return;

    syncing = true;
    try {
      final cs = await customersRef.get();
      final ts = await transactionsRef.get();

      for (final d in cs.docs) {
        final data = d.data();
        final c = Customer(
          data['id']?.toString() ?? d.id,
          data['name']?.toString() ?? '',
          data['phone']?.toString() ?? '',
          (data['creditLimit'] as num?)?.toDouble() ?? 0,
        );
        final index = customers.indexWhere((x) => x.id == c.id);
        if (index == -1) {
          customers.add(c);
        } else {
          customers[index] = c;
        }
      }

      for (final d in ts.docs) {
        final data = d.data();
        final rawDate = data['date'];
        final date = rawDate is Timestamp
            ? rawDate.toDate()
            : DateTime.tryParse(rawDate?.toString() ?? '') ?? DateTime.now();

        final t = Tx(
          data['id']?.toString() ?? d.id,
          data['customerId']?.toString() ?? '',
          data['type']?.toString() ?? 'debt',
          (data['amount'] as num?)?.toDouble() ?? 0,
          date,
          data['note']?.toString() ?? '',
        );

        final index = transactions.indexWhere((x) => x.id == t.id);
        if (index == -1) {
          transactions.add(t);
        } else {
          transactions[index] = t;
        }
      }

      await saveLocal();
    } catch (_) {
      // Local data remains available when offline.
    } finally {
      syncing = false;
    }
  }

  Future<void> pushCloud() async {
    if (!firebaseReady || firebaseUid.isEmpty || syncing) return;

    syncing = true;
    try {
      final batch = FirebaseFirestore.instance.batch();

      for (final c in customers) {
        batch.set(customersRef.doc(c.id), c.toJson());
      }

      for (final t in transactions) {
        batch.set(transactionsRef.doc(t.id), {
          ...t.toJson(),
          'date': Timestamp.fromDate(t.date),
        });
      }

      batch.set(
        FirebaseFirestore.instance.collection('users').doc(firebaseUid),
        {
          'shopName': shopName,
          'whatsappMessage': whatsappMessage,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      await batch.commit();
    } catch (_) {
      // Firestore retries when connectivity returns.
    } finally {
      syncing = false;
    }
  }

  Future<void> saveLocal() async {
    await prefs.setString(
      'customers',
      jsonEncode(customers.map((x) => x.toJson()).toList()),
    );
    await prefs.setString(
      'transactions',
      jsonEncode(transactions.map((x) => x.toJson()).toList()),
    );
    await prefs.setString('shopName', shopName);
    await prefs.setString('whatsappMessage', whatsappMessage);
    await prefs.setBool('dark', dark);
  }

  Future<void> save() async {
    await saveLocal();
    notifyListeners();
    await pushCloud();
  }

  double balance(String customerId) {
    return transactions
        .where((x) => x.customerId == customerId)
        .fold(0.0, (sum, x) => sum + (x.type == 'debt' ? x.amount : -x.amount));
  }

  double totalDebt(String customerId) {
    return transactions
        .where((x) => x.customerId == customerId && x.type == 'debt')
        .fold(0.0, (sum, x) => sum + x.amount);
  }

  double paid(String customerId) {
    return transactions
        .where((x) => x.customerId == customerId && x.type == 'payment')
        .fold(0.0, (sum, x) => sum + x.amount);
  }

  int overdueDays(String customerId) {
    final debts = transactions
        .where((x) => x.customerId == customerId && x.type == 'debt')
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    if (debts.isEmpty || balance(customerId) <= 0) return 0;

    final payments = transactions
        .where((x) => x.customerId == customerId && x.type == 'payment')
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    final lastDebt = debts.first.date;
    final lastPayment = payments.isEmpty ? null : payments.first.date;

    if (lastPayment != null && lastPayment.isAfter(lastDebt)) return 0;
    return DateTime.now().difference(lastDebt).inDays;
  }

  String risk(String customerId) {
    final b = balance(customerId);
    if (b <= 0) return 'مسدد';
    final days = overdueDays(customerId);
    if (days > 90) return 'خطر';
    if (days > 30) return 'متأخر';
    return 'حديث';
  }

  double monthDebt(DateTime month) {
    return transactions
        .where((x) =>
            x.type == 'debt' &&
            x.date.year == month.year &&
            x.date.month == month.month)
        .fold(0.0, (sum, x) => sum + x.amount);
  }

  double monthPayment(DateTime month) {
    return transactions
        .where((x) =>
            x.type == 'payment' &&
            x.date.year == month.year &&
            x.date.month == month.month)
        .fold(0.0, (sum, x) => sum + x.amount);
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
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: HomePage(store: store),
      ),
    );
  }

  ThemeData buildTheme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: const Color(0xFF0B6675),
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF0C171A)
          : const Color(0xFFF3F7F8),
      appBarTheme: const AppBarTheme(centerTitle: false),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide.none,
        ),
      ),
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
  String search = '';
  String filter = 'all';

  List<Customer> filtered(Store store) {
    final q = search.trim().toLowerCase();

    final list = store.customers.where((c) {
      final matchesSearch = q.isEmpty ||
          c.name.toLowerCase().contains(q) ||
          c.phone.toLowerCase().contains(q);

      final b = store.balance(c.id);
      final matchesFilter = filter == 'all'
          ? true
          : filter == 'debt'
              ? b > 0
              : b <= 0;

      return matchesSearch && matchesFilter;
    }).toList();

    list.sort((a, b) => store.balance(b.id).compareTo(store.balance(a.id)));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final list = filtered(store);

    final totalOutstanding = store.customers.fold(
      0.0,
      (sum, c) => sum + max(0, store.balance(c.id)),
    );

    final danger = store.customers.where((c) => store.overdueDays(c.id) > 90).toList()
      ..sort((a, b) => store.balance(b.id).compareTo(store.balance(a.id)));

    final top = store.customers.where((c) => store.balance(c.id) > 0).toList()
      ..sort((a, b) => store.balance(b.id).compareTo(store.balance(a.id)));

    final now = DateTime.now();
    final previous = DateTime(now.year, now.month - 1, 1);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            store.shopName,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          actions: [
            IconButton(
              tooltip: 'التقرير',
              icon: const Icon(Icons.insights_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ReportPage(store: store)),
              ),
            ),
            IconButton(
              tooltip: 'الإعدادات',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsPage(store: store)),
              ),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            await store.syncFromFirebase();
            setState(() {});
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: SummaryItem(
                          title: 'إجمالي المتبقي',
                          value: money(totalOutstanding),
                          icon: Icons.account_balance_wallet_outlined,
                        ),
                      ),
                      Expanded(
                        child: SummaryItem(
                          title: 'العملاء',
                          value: store.customers.length.toString(),
                          icon: Icons.people_outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (danger.isNotEmpty)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber_rounded),
                    title: const Text(
                      'تنبيه: ديون تجاوزت 90 يومًا',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      danger.map((c) => c.name).take(3).join('، ') +
                          (danger.length > 3 ? '…' : ''),
                    ),
                    trailing: Text(danger.length.toString()),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                onChanged: (v) => setState(() => search = v),
                decoration: const InputDecoration(
                  hintText: 'ابحث باسم العميل أو الهاتف',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('الكل'),
                    selected: filter == 'all',
                    onSelected: (_) => setState(() => filter = 'all'),
                  ),
                  FilterChip(
                    label: const Text('عليه دين'),
                    selected: filter == 'debt',
                    onSelected: (_) => setState(() => filter = 'debt'),
                  ),
                  FilterChip(
                    label: const Text('مسدد'),
                    selected: filter == 'paid',
                    onSelected: (_) => setState(() => filter = 'paid'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (top.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'أعلى 5 مدينين',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...top.take(5).map(
                              (c) => ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(c.name),
                                subtitle: Text(store.risk(c.id)),
                                trailing: Text(
                                  money(store.balance(c.id)),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                onTap: () => openCustomer(context, store, c),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.bar_chart_outlined),
                  title: const Text(
                    'ملخص الشهر',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    'ائتمان هذا الشهر: ' +
                        money(store.monthDebt(now)) +
                        '\nائتمان الشهر السابق: ' +
                        money(store.monthDebt(previous)) +
                        '\nالسداد هذا الشهر: ' +
                        money(store.monthPayment(now)),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (list.isEmpty)
                EmptyView(
                  onAdd: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AddCustomerPage(store: store),
                    ),
                  ),
                )
              else
                ...list.map(
                  (customer) => CustomerTile(
                    store: store,
                    customer: customer,
                    onTap: () => openCustomer(context, store, customer),
                  ),
                ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AddCustomerPage(store: store),
            ),
          ),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('عميل جديد'),
        ),
      ),
    );
  }
}

void openCustomer(BuildContext context, Store store, Customer customer) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => CustomerPage(store: store, customer: customer),
    ),
  );
}

class SummaryItem extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const SummaryItem({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon),
        const SizedBox(height: 5),
        Text(title),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
        ),
      ],
    );
  }
}

class CustomerTile extends StatelessWidget {
  final Store store;
  final Customer customer;
  final VoidCallback onTap;

  const CustomerTile({
    super.key,
    required this.store,
    required this.customer,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final balance = store.balance(customer.id);
    final days = store.overdueDays(customer.id);
    final risk = store.risk(customer.id);

    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          child: Text(customer.name.isEmpty ? '؟' : customer.name[0]),
        ),
        title: Text(
          customer.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          (customer.phone.isEmpty ? 'بدون هاتف' : customer.phone) +
              (days > 0 ? ' • ' + days.toString() + ' يوم' : ''),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              money(balance),
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: balance > 0
                    ? Theme.of(context).colorScheme.primary
                    : Colors.green,
              ),
            ),
            Text(
              risk,
              style: TextStyle(
                fontSize: 11,
                color: risk == 'خطر'
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 50),
      child: Column(
        children: [
          const Icon(Icons.menu_book_outlined, size: 62),
          const SizedBox(height: 10),
          const Text(
            'الدفتر فارغ',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text('أضف العميل الأول ثم سجّل الدين أو السداد.'),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('إضافة عميل'),
          ),
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
  final limit = TextEditingController();

  Future<void> save() async {
    final n = name.text.trim();
    if (n.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اكتب اسم العميل أولاً')),
      );
      return;
    }

    final credit = double.tryParse(limit.text.replaceAll(',', '.')) ?? 0;
    widget.store.customers.add(
      Customer(makeId(), n, phone.text.trim(), max(0, credit)),
    );

    await widget.store.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FormPage(
      title: 'إضافة عميل',
      children: [
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'اسم العميل'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'رقم الهاتف'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: limit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'الحد الائتماني (اختياري)',
            suffixText: 'د.ل',
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: save,
          child: const Text('حفظ العميل'),
        ),
      ],
    );
  }
}

class CustomerPage extends StatelessWidget {
  final Store store;
  final Customer customer;

  const CustomerPage({
    super.key,
    required this.store,
    required this.customer,
  });

  Future<void> whatsapp(BuildContext context) async {
    final balance = store.balance(customer.id);
    final message = store.whatsappMessage
        .replaceAll('[الاسم]', customer.name)
        .replaceAll('[المبلغ]', money(balance));

    final raw = customer.phone.replaceAll(RegExp(r'[^0-9]'), '');
    final phone = raw.startsWith('218') ? raw : '218' + raw;

    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف رقم هاتف العميل أولاً')),
      );
      return;
    }

    final uri = Uri.parse(
      'https://wa.me/' + phone + '?text=' + Uri.encodeComponent(message),
    );

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر فتح واتساب')),
        );
      }
    }
  }

  Future<void> call(BuildContext context) async {
    final raw = customer.phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف رقم الهاتف أولاً')),
      );
      return;
    }
    await launchUrl(Uri.parse('tel:' + raw));
  }

  @override
  Widget build(BuildContext context) {
    final list = store.transactions
        .where((x) => x.customerId == customer.id)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    final balance = store.balance(customer.id);
    final days = store.overdueDays(customer.id);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(customer.name),
          actions: [
            IconButton(
              tooltip: 'اتصال',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => call(context),
            ),
            IconButton(
              tooltip: 'واتساب',
              icon: const Icon(Icons.chat_outlined),
              onPressed: () => whatsapp(context),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Stat(title: 'المتبقي', value: money(balance), warning: balance > 0),
                        Stat(title: 'إجمالي الدين', value: money(store.totalDebt(customer.id))),
                        Stat(title: 'إجمالي السداد', value: money(store.paid(customer.id))),
                      ],
                    ),
                    const Divider(height: 24),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'الحالة: ' +
                            store.risk(customer.id) +
                            (days > 0 ? ' • متأخر ' + days.toString() + ' يوم' : ''),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (customer.creditLimit > 0)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'الحد الائتماني: ' +
                                money(customer.creditLimit) +
                                ' • المتاح: ' +
                                money(max(0, customer.creditLimit - balance)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (customer.creditLimit > 0 && balance > customer.creditLimit)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const ListTile(
                  leading: Icon(Icons.block_outlined),
                  title: Text(
                    'تجاوز الحد الائتماني',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('لا تضف دينًا جديدًا إلا بعد مراجعة الحد.'),
                ),
              ),
            const SizedBox(height: 4),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: Text('لا توجد عمليات بعد')),
              )
            else
              ...list.map(
                (tx) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Icon(
                        tx.type == 'debt'
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                      ),
                    ),
                    title: Text(tx.type == 'debt' ? 'دين' : 'سداد'),
                    subtitle: Text(
                      dateText(tx.date) +
                          (tx.note.isEmpty ? '' : ' • ' + tx.note),
                    ),
                    trailing: Text(
                      money(tx.amount),
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: tx.type == 'debt'
                            ? Theme.of(context).colorScheme.primary
                            : Colors.green,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AddTransactionPage(
                store: store,
                customer: customer,
              ),
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

  const Stat({
    super.key,
    required this.title,
    required this.value,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: warning
                ? Theme.of(context).colorScheme.primary
                : Colors.green,
          ),
        ),
      ],
    );
  }
}

class AddTransactionPage extends StatefulWidget {
  final Store store;
  final Customer customer;

  const AddTransactionPage({
    super.key,
    required this.store,
    required this.customer,
  });

  @override
  State<AddTransactionPage> createState() => _AddTransactionPageState();
}

class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount = TextEditingController();
  final note = TextEditingController();
  String type = 'debt';

  Future<void> save() async {
    final value = double.tryParse(amount.text.replaceAll(',', '.'));
    if (value == null || value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل مبلغًا صحيحًا')),
      );
      return;
    }

    if (type == 'debt' &&
        widget.customer.creditLimit > 0 &&
        widget.store.balance(widget.customer.id) + value >
            widget.customer.creditLimit) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('تجاوز الحد الائتماني'),
          content: const Text(
            'هذا الدين سيتجاوز الحد الائتماني المحدد للعميل. هل تريد المتابعة؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('متابعة'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    widget.store.transactions.add(
      Tx(
        makeId(),
        widget.customer.id,
        type,
        value,
        DateTime.now(),
        note.text.trim(),
      ),
    );

    await widget.store.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FormPage(
      title: 'إضافة عملية',
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'debt',
              label: Text('دين'),
              icon: Icon(Icons.add_card),
            ),
            ButtonSegment(
              value: 'payment',
              label: Text('سداد'),
              icon: Icon(Icons.payments_outlined),
            ),
          ],
          selected: {type},
          onSelectionChanged: (v) => setState(() => type = v.first),
        ),
        const SizedBox(height: 16),
        Text(
          'الرصيد الحالي: ' + money(widget.store.balance(widget.customer.id)),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'المبلغ',
            suffixText: 'د.ل',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: note,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'ملاحظات'),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: save,
          child: const Text('حفظ العملية'),
        ),
      ],
    );
  }
}

class ReportPage extends StatelessWidget {
  final Store store;

  const ReportPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final previous = DateTime(now.year, now.month - 1, 1);

    final debtors = store.customers.where((c) => store.balance(c.id) > 0).toList()
      ..sort((a, b) => store.balance(b.id).compareTo(store.balance(a.id)));

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('التقرير')),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.credit_score_outlined),
                title: const Text('ائتمان الشهر الحالي'),
                trailing: Text(
                  money(store.monthDebt(now)),
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.compare_arrows_outlined),
                title: const Text('ائتمان الشهر السابق'),
                trailing: Text(
                  money(store.monthDebt(previous)),
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('السداد هذا الشهر'),
                trailing: Text(
                  money(store.monthPayment(now)),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Colors.green,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'المدينون الحاليون',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            ...debtors.map(
              (c) => Card(
                child: ListTile(
                  title: Text(c.name),
                  subtitle: Text(store.risk(c.id)),
                  trailing: Text(
                    money(store.balance(c.id)),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ),
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
    widget.store.shopName =
        shop.text.trim().isEmpty ? 'دفتر دَيْن' : shop.text.trim();
    widget.store.whatsappMessage = message.text.trim();
    await widget.store.save();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ الإعدادات')),
      );
    }
  }

  @override
  void dispose() {
    shop.dispose();
    message.dispose();
    super.dispose();
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
            TextField(
              controller: shop,
              decoration: const InputDecoration(
                labelText: 'اسم المحل / الدفتر',
              ),
            ),
            const SizedBox(height: 14),
            SwitchListTile(
              title: const Text('الوضع الداكن'),
              value: store.dark,
              onChanged: (v) async {
                store.dark = v;
                await store.save();
              },
            ),
            const Divider(height: 30),
            const Text(
              'رسالة واتساب',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: message,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'استخدم [الاسم] و[المبلغ]',
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: save,
              child: const Text('حفظ الإعدادات'),
            ),
            const SizedBox(height: 20),
            Card(
              child: ListTile(
                leading: Icon(
                  store.firebaseReady
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                ),
                title: const Text('المزامنة'),
                subtitle: Text(
                  store.firebaseReady
                      ? 'متصل. البيانات المحلية والمزامنة السحابية تعملان.'
                      : 'غير متصل. التطبيق يستمر محليًا.',
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Card(
              child: ListTile(
                leading: Icon(Icons.shield_outlined),
                title: Text('تصميم النسخة'),
                subtitle: Text(
                  'تم حذف الميزات الثقيلة أو الحساسة التي تحتاج خدمات إضافية. هذه النسخة تركز على دفتر الديون نفسه.',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FormPage extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const FormPage({
    super.key,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: children,
        ),
      ),
    );
  }
}
