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

const emerald = Color(0xFF10B981);
const deepEmerald = Color(0xFF087F5B);
const navy = Color(0xFF0F172A);
const coral = Color(0xFFF04444);
const mint = Color(0xFF22C55E);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  final store = await Store.load();
  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
String money(double value) => '${value.toStringAsFixed(2)} د.ل';
String dateText(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
String timeText(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String phone218(String value) {
  var p = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (p.startsWith('00')) p = p.substring(2);
  if (p.startsWith('218')) return p;
  if (p.startsWith('0')) return '218${p.substring(1)}';
  return p;
}

Future<bool> openWhatsApp(String phone, String message) async {
  final n = phone218(phone);
  if (n.isEmpty) return false;
  try {
    return await launchUrl(
      Uri.https('wa.me', '/$n', {'text': message}),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}

class Customer {
  Customer({required this.id, required this.name, required this.phone, this.limit = 0});
  String id;
  String name;
  String phone;
  double limit;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'limit': limit,
      };

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        phone: '${json['phone'] ?? ''}',
        limit: (json['limit'] as num?)?.toDouble() ?? 0,
      );
}

class Tx {
  Tx({
    required this.id,
    required this.customerId,
    required this.type,
    required this.amount,
    required this.date,
    required this.note,
  });
  String id;
  String customerId;
  String type;
  double amount;
  DateTime date;
  String note;

  Map<String, dynamic> toJson() => {
        'id': id,
        'customerId': customerId,
        'type': type,
        'amount': amount,
        'date': date.toIso8601String(),
        'note': note,
      };

  factory Tx.fromJson(Map<String, dynamic> json) => Tx(
        id: '${json['id'] ?? ''}',
        customerId: '${json['customerId'] ?? ''}',
        type: '${json['type'] ?? 'debt'}',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        date: DateTime.tryParse('${json['date']}') ?? DateTime.now(),
        note: '${json['note'] ?? ''}',
      );
}

class VoiceDraft {
  VoiceDraft({required this.id, required this.text, required this.date, this.amount = 0});
  String id;
  String text;
  DateTime date;
  double amount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'date': date.toIso8601String(),
        'amount': amount,
      };

  factory VoiceDraft.fromJson(Map<String, dynamic> json) => VoiceDraft(
        id: '${json['id'] ?? ''}',
        text: '${json['text'] ?? ''}',
        date: DateTime.tryParse('${json['date']}') ?? DateTime.now(),
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
      );
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  final customers = <Customer>[];
  final transactions = <Tx>[];
  final voiceDrafts = <VoiceDraft>[];
  String shop = 'DaiynPay — دَيْن';
  String whatsappMessage = 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  String uid = '';
  String deviceId = '';
  bool firebaseReady = false;
  bool syncing = false;
  bool activated = false;
  DateTime? trialStart;
  Timer? syncTimer;

  static Future<Store> load() async {
    final s = Store();
    s.prefs = await SharedPreferences.getInstance();
    s.shop = s.prefs.getString('shop') ?? s.shop;
    s.whatsappMessage = s.prefs.getString('whatsappMessage') ?? s.whatsappMessage;
    s.deviceId = s.prefs.getString('device_id') ?? '';
    if (s.deviceId.isEmpty) {
      s.deviceId = 'DP-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';
      await s.prefs.setString('device_id', s.deviceId);
    }
    final trial = s.prefs.getString('trial_start');
    if (trial == null) {
      s.trialStart = DateTime.now();
      await s.prefs.setString('trial_start', s.trialStart!.toIso8601String());
    } else {
      s.trialStart = DateTime.tryParse(trial);
    }
    s.activated = s.prefs.getBool('activated') ?? false;
    try {
      final data = jsonDecode(s.prefs.getString('customers') ?? '[]') as List;
      s.customers.addAll(data.map((e) => Customer.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      final data = jsonDecode(s.prefs.getString('transactions') ?? '[]') as List;
      s.transactions.addAll(data.map((e) => Tx.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      final data = jsonDecode(s.prefs.getString('voice_drafts') ?? '[]') as List;
      s.voiceDrafts.addAll(data.map((e) => VoiceDraft.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    return s;
  }

  int get trialDaysLeft => activated || trialStart == null
      ? 0
      : max(0, 10 - DateTime.now().difference(trialStart!).inDays);
  bool get locked => !activated && trialDaysLeft <= 0;

  CollectionReference<Map<String, dynamic>> get customersRef =>
      FirebaseFirestore.instance.collection('users').doc(uid).collection('customers');
  CollectionReference<Map<String, dynamic>> get transactionsRef =>
      FirebaseFirestore.instance.collection('users').doc(uid).collection('transactions');

  Future<void> connectFirebase() async {
    try {
      var user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) return;
      uid = user.uid;
      firebaseReady = true;
      await pullCloud();
      await loadActivation();
      syncTimer?.cancel();
      syncTimer = Timer.periodic(const Duration(seconds: 60), (_) => saveCloud());
    } catch (_) {
      firebaseReady = false;
    }
    notifyListeners();
  }

  Future<void> loadActivation() async {
    if (!firebaseReady) return;
    try {
      final snap = await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).get();
      if (snap.data()?['activated'] == true) {
        activated = true;
        await prefs.setBool('activated', true);
      }
    } catch (_) {}
  }

  Future<void> pullCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      for (final doc in (await customersRef.get()).docs) {
        final customer = Customer.fromJson(doc.data());
        final index = customers.indexWhere((x) => x.id == customer.id);
        if (index < 0) {
          customers.add(customer);
        } else {
          customers[index] = customer;
        }
      }
      for (final doc in (await transactionsRef.get()).docs) {
        final data = doc.data();
        final rawDate = data['date'];
        final date = rawDate is Timestamp ? rawDate.toDate() : DateTime.tryParse('$rawDate') ?? DateTime.now();
        final transaction = Tx(
          id: '${data['id'] ?? doc.id}',
          customerId: '${data['customerId'] ?? ''}',
          type: '${data['type'] ?? 'debt'}',
          amount: (data['amount'] as num?)?.toDouble() ?? 0,
          date: date,
          note: '${data['note'] ?? ''}',
        );
        final index = transactions.indexWhere((x) => x.id == transaction.id);
        if (index < 0) {
          transactions.add(transaction);
        } else {
          transactions[index] = transaction;
        }
      }
      await saveLocal();
    } catch (_) {} finally {
      syncing = false;
    }
  }

  Future<void> saveCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final customer in customers) {
        batch.set(customersRef.doc(customer.id), customer.toJson());
      }
      for (final transaction in transactions) {
        batch.set(transactionsRef.doc(transaction.id), {
          ...transaction.toJson(),
          'date': Timestamp.fromDate(transaction.date),
        });
      }
      await batch.commit();
    } catch (_) {} finally {
      syncing = false;
    }
  }

  Future<void> saveLocal() async {
    await prefs.setString('customers', jsonEncode(customers.map((x) => x.toJson()).toList()));
    await prefs.setString('transactions', jsonEncode(transactions.map((x) => x.toJson()).toList()));
    await prefs.setString('voice_drafts', jsonEncode(voiceDrafts.map((x) => x.toJson()).toList()));
    await prefs.setString('shop', shop);
    await prefs.setString('whatsappMessage', whatsappMessage);
  }

  Future<void> save() async {
    await saveLocal();
    notifyListeners();
    await saveCloud();
  }

  double balance(String id) => transactions.where((t) => t.customerId == id).fold(
        0,
        (sum, t) => sum + (t.type == 'debt' ? t.amount : -t.amount),
      );
  double debts(String id) => transactions.where((t) => t.customerId == id && t.type == 'debt').fold(0, (a, t) => a + t.amount);
  double paid(String id) => transactions.where((t) => t.customerId == id && t.type == 'payment').fold(0, (a, t) => a + t.amount);

  String risk(String id) {
    final b = balance(id);
    if (b <= 0) return 'مسدد';
    final debtsList = transactions.where((t) => t.customerId == id && t.type == 'debt').toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    if (debtsList.isEmpty) return 'حديث';
    final days = DateTime.now().difference(debtsList.first.date).inDays;
    if (days > 90) return 'خطر';
    if (days > 30) return 'متأخر';
    return 'حديث';
  }

  Future<bool> activateCode(String code) async {
    if (!firebaseReady || code.trim().isEmpty) return false;
    final ref = FirebaseFirestore.instance.collection('activation_codes').doc(code.trim());
    try {
      final ok = await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        if (!snap.exists || data == null || data['used'] == true) return false;
        final bound = '${data['deviceId'] ?? ''}';
        if (bound.isNotEmpty && bound != deviceId) return false;
        tx.update(ref, {
          'used': true,
          'usedAt': FieldValue.serverTimestamp(),
          'usedDeviceId': deviceId,
        });
        return true;
      });
      if (!ok) return false;
      await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).set({
        'activated': true,
        'activatedAt': FieldValue.serverTimestamp(),
        'uid': uid,
      });
      activated = true;
      await prefs.setBool('activated', true);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> generateCode(String targetDevice) async {
    if (!firebaseReady || targetDevice.trim().isEmpty) return null;
    try {
      String code;
      do {
        code = (100000 + Random().nextInt(900000)).toString();
      } while ((await FirebaseFirestore.instance.collection('activation_codes').doc(code).get()).exists);
      await FirebaseFirestore.instance.collection('activation_codes').doc(code).set({
        'deviceId': targetDevice.trim(),
        'used': false,
        'createdAt': FieldValue.serverTimestamp(),
      }).timeout(const Duration(seconds: 12));
      return code;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    syncTimer?.cancel();
    super.dispose();
  }
}

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store});
  final Store store;

  ThemeData _theme(Brightness brightness) => ThemeData(
        useMaterial3: true,
        brightness: brightness,
        fontFamily: 'Cairo',
        scaffoldBackgroundColor: brightness == Brightness.dark ? navy : const Color(0xFFF6F8FA),
        colorScheme: ColorScheme.fromSeed(seedColor: emerald, brightness: brightness),
        appBarTheme: const AppBarTheme(elevation: 0, centerTitle: false),
        cardTheme: CardTheme(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: store,
        builder: (_, __) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: ThemeMode.system,
          home: HomePage(store: store),
        ),
      );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * .24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF34D399), Color(0xFF087F5B)],
          ),
          boxShadow: [BoxShadow(color: emerald.withOpacity(.28), blurRadius: 16, offset: const Offset(0, 7))],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text('D', style: TextStyle(fontSize: size * .54, fontWeight: FontWeight.w900, color: Colors.white)),
            Positioned(
              right: size * .10,
              bottom: size * .08,
              child: Text('P', style: TextStyle(fontSize: size * .24, fontWeight: FontWeight.w900, color: const Color(0xFFB7F7DB))),
            ),
          ],
        ),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});
  final Store store;
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  String query = '';
  String filter = 'all';
  int taps = 0;
  DateTime? lastTap;

  void openOwnerGate() {
    final now = DateTime.now();
    if (lastTap == null || now.difference(lastTap!).inSeconds > 2) taps = 0;
    lastTap = now;
    taps++;
    if (taps == 3) {
      taps = 0;
      showDialog(context: context, builder: (_) => AdminGate(store: widget.store));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    if (tab == 1) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('العملاء', style: TextStyle(fontWeight: FontWeight.w900))),
          body: CustomersPage(store: s),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddCustomerPage(store: s))),
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('عميل جديد'),
          ),
          bottomNavigationBar: _nav(),
        ),
      );
    }
    if (tab == 2) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('المعاملات', style: TextStyle(fontWeight: FontWeight.w900))),
          body: TransactionsPage(store: s),
          bottomNavigationBar: _nav(),
        ),
      );
    }

    final customers = s.customers.where((c) {
      final matches = query.isEmpty || c.name.contains(query) || c.phone.contains(query);
      final b = s.balance(c.id);
      final matchesFilter = filter == 'all' || (filter == 'debt' && b > 0) || (filter == 'paid' && b <= 0);
      return matches && matchesFilter;
    }).toList()
      ..sort((a, b) => s.balance(b.id).compareTo(s.balance(a.id)));

    final owed = s.customers.fold<double>(0, (sum, c) => sum + max(0, s.balance(c.id)));
    final paidTotal = s.paidTotal;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: openOwnerGate,
            child: Row(children: [const BrandMark(size: 38), const SizedBox(width: 10), const Text('DaiynPay', style: TextStyle(fontWeight: FontWeight.w900))]),
          ),
          actions: [IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(store: s))), icon: const Icon(Icons.tune_rounded))],
        ),
        body: RefreshIndicator(
          onRefresh: s.pullCloud,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              Row(children: [Expanded(child: Text('دفتر مالي أبسط وأوضح', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900))), Text(s.firebaseReady ? 'متصل' : 'محلي', style: TextStyle(color: s.firebaseReady ? mint : Colors.orange, fontWeight: FontWeight.w800))]),
              const SizedBox(height: 14),
              SummaryCard(owed: owed, paid: paidTotal),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: QuickAction(icon: Icons.add_rounded, label: 'إضافة دين', color: emerald, onTap: () => _newTransaction('debt'))),
                const SizedBox(width: 8),
                Expanded(child: QuickAction(icon: Icons.payments_rounded, label: 'تسجيل سداد', color: const Color(0xFF4F7CFF), onTap: () => _newTransaction('payment'))),
                const SizedBox(width: 8),
                Expanded(child: QuickAction(icon: Icons.mic_rounded, label: 'صوتي', color: const Color(0xFF8B5CF6), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VoiceDraftsPage(store: s))))),
              ]),
              const SizedBox(height: 14),
              if (!s.activated) TrialCard(store: s),
              const SizedBox(height: 14),
              TextField(decoration: const InputDecoration(hintText: 'ابحث باسم العميل أو الهاتف', prefixIcon: Icon(Icons.search_rounded)), onChanged: (v) => setState(() => query = v)),
              const SizedBox(height: 10),
              Row(children: [FilterChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) => setState(() => filter = 'all')), const SizedBox(width: 6), FilterChip(label: const Text('عليهم دين'), selected: filter == 'debt', onSelected: (_) => setState(() => filter = 'debt')), const SizedBox(width: 6), FilterChip(label: const Text('مسدد'), selected: filter == 'paid', onSelected: (_) => setState(() => filter = 'paid'))]),
              const SizedBox(height: 12),
              if (customers.isEmpty) const EmptyCard(),
              ...customers.take(20).map((c) => CustomerTile(store: s, customer: c)),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(onPressed: () => _newTransaction('debt'), icon: const Icon(Icons.add), label: const Text('عملية جديدة')),
        bottomNavigationBar: _nav(),
      ),
    );
  }

  Widget _nav() => NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'الرئيسية'),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'العملاء'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'المعاملات'),
        ],
      );

  Future<void> _newTransaction(String type) async {
    final s = widget.store;
    if (s.locked) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: s)));
      return;
    }
    if (s.customers.isEmpty) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => AddCustomerPage(store: s)));
      return;
    }
    final customer = await showModalBottomSheet<Customer>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('اختر العميل', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            ...s.customers.map((c) => ListTile(leading: const CircleAvatar(child: Icon(Icons.person)), title: Text(c.name), subtitle: Text(c.phone), onTap: () => Navigator.pop(sheetContext, c))),
          ],
        ),
      ),
    );
    if (customer != null && mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => AddTransactionPage(store: s, customer: customer, initialType: type)));
      setState(() {});
    }
  }
}

class SummaryCard extends StatelessWidget {
  const SummaryCard({super.key, required this.owed, required this.paid});
  final double owed;
  final double paid;
  @override
  Widget build(BuildContext context) => Card(
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: const LinearGradient(colors: [deepEmerald, Color(0xFF0B5F55)])),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('ملخص الدفتر', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('المستحق لك', style: TextStyle(color: Colors.white70)), Text(money(owed), style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w900))])),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('إجمالي السداد', style: TextStyle(color: Colors.white70)), Text(money(paid), style: const TextStyle(color: Color(0xFFB7F7DB), fontSize: 25, fontWeight: FontWeight.w900))])),
            ]),
          ]),
        ),
      );
}

class QuickAction extends StatelessWidget {
  const QuickAction({super.key, required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(18), border: Border.all(color: color.withOpacity(.18))),
          child: Column(children: [Icon(icon, color: color), const SizedBox(height: 5), Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800))]),
        ),
      );
}

class TrialCard extends StatelessWidget {
  const TrialCard({super.key, required this.store});
  final Store store;
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: const Icon(Icons.workspace_premium_rounded, color: Color(0xFFF59E0B)),
          title: Text(store.locked ? 'انتهت الفترة التجريبية' : 'التجربة المجانية 10 أيام', style: const TextStyle(fontWeight: FontWeight.w900)),
          subtitle: Text(store.locked ? 'يلزم التفعيل' : 'متبقٍ ${store.trialDaysLeft} أيام'),
          trailing: FilledButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: store))), child: const Text('تفعيل')),
        ),
      );
}

class EmptyCard extends StatelessWidget {
  const EmptyCard({super.key});
  @override Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(30), child: Column(children: const [Icon(Icons.menu_book_rounded, size: 48, color: emerald), SizedBox(height: 8), Text('دفترك فارغ حالياً', style: TextStyle(fontWeight: FontWeight.w900)), SizedBox(height: 4), Text('ابدأ بإضافة أول عميل.')]));
}

class CustomerTile extends StatelessWidget {
  const CustomerTile({super.key, required this.store, required this.customer});
  final Store store;
  final Customer customer;
  @override
  Widget build(BuildContext context) {
    final balance = store.balance(customer.id);
    final risk = store.risk(customer.id);
    final color = balance <= 0 ? mint : risk == 'خطر' ? coral : const Color(0xFFF59E0B);
    final totalDebt = store.debts(customer.id);
    final progress = totalDebt <= 0 ? 1.0 : (store.paid(customer.id) / totalDebt).clamp(0.0, 1.0);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPage(store: store, customer: customer))),
        leading: CircleAvatar(backgroundColor: color.withOpacity(.12), child: Text(customer.name.isEmpty ? '؟' : customer.name.substring(0, 1), style: TextStyle(color: color, fontWeight: FontWeight.w900))),
        title: Text(customer.name, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(customer.phone), const SizedBox(height: 5), LinearProgressIndicator(value: progress, minHeight: 5, borderRadius: BorderRadius.circular(8), color: color)]),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [Text(money(balance), style: TextStyle(color: color, fontWeight: FontWeight.w900)), Text(risk, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800))]),
      ),
    );
  }
}

class CustomersPage extends StatelessWidget {
  const CustomersPage({super.key, required this.store});
  final Store store;
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: store.customers.map((c) => CustomerTile(store: store, customer: c)).toList());
}

class TransactionsPage extends StatelessWidget {
  const TransactionsPage({super.key, required this.store});
  final Store store;
  @override
  Widget build(BuildContext context) {
    final items = [...store.transactions]..sort((a, b) => b.date.compareTo(a.date));
    return ListView(padding: const EdgeInsets.all(16), children: items.isEmpty ? [const EmptyCard()] : items.take(100).map((t) {
      final customer = store.customers.where((c) => c.id == t.customerId).firstOrNull;
      final color = t.type == 'debt' ? coral : mint;
      return Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(leading: CircleAvatar(backgroundColor: color.withOpacity(.12), child: Icon(t.type == 'debt' ? Icons.arrow_downward : Icons.check, color: color)), title: Text(customer?.name ?? 'عميل', style: const TextStyle(fontWeight: FontWeight.w800)), subtitle: Text('${dateText(t.date)} ${timeText(t.date)} • ${t.note}'), trailing: Text('${t.type == 'debt' ? '+' : '-'}${money(t.amount)}', style: TextStyle(color: color, fontWeight: FontWeight.w900))));
    }).toList());
  }
}

class AddCustomerPage extends StatefulWidget {
  const AddCustomerPage({super.key, required this.store});
  final Store store;
  @override State<AddCustomerPage> createState() => _AddCustomerPageState();
}
class _AddCustomerPageState extends State<AddCustomerPage> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final limit = TextEditingController();
  @override
  Widget build(BuildContext context) => PageShell(title: 'إضافة عميل', children: [
        FieldBox(controller: name, label: 'اسم العميل', icon: Icons.person_outline),
        FieldBox(controller: phone, label: 'رقم الهاتف', icon: Icons.phone_outlined, type: TextInputType.phone),
        FieldBox(controller: limit, label: 'السقف الائتماني اختياري', icon: Icons.account_balance_wallet_outlined, type: TextInputType.number),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: () async {
          if (name.text.trim().isEmpty) return;
          widget.store.customers.add(Customer(id: makeId(), name: name.text.trim(), phone: phone.text.trim(), limit: double.tryParse(limit.text.replaceAll(',', '.')) ?? 0));
          await widget.store.save();
          if (mounted) Navigator.pop(context);
        }, icon: const Icon(Icons.check), label: const Text('حفظ العميل')),
      ]);
}

class AddTransactionPage extends StatefulWidget {
  const AddTransactionPage({super.key, required this.store, required this.customer, required this.initialType});
  final Store store;
  final Customer customer;
  final String initialType;
  @override State<AddTransactionPage> createState() => _AddTransactionPageState();
}
class _AddTransactionPageState extends State<AddTransactionPage> {
  late String type;
  final amount = TextEditingController();
  final note = TextEditingController();
  @override void initState() { super.initState(); type = widget.initialType; }
  Future<void> saveTx() async {
    final value = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
    if (value <= 0) return;
    final current = widget.store.balance(widget.customer.id);
    if (type == 'debt' && widget.customer.limit > 0 && current + value > widget.customer.limit) {
      if (mounted) await showDialog(context: context, builder: (_) => AlertDialog(title: const Text('تجاوز السقف الائتماني'), content: Text('السقف ${money(widget.customer.limit)} والمتاح ${money(max(0, widget.customer.limit - current))}.'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('حسنًا'))]));
      return;
    }
    final transaction = Tx(id: makeId(), customerId: widget.customer.id, type: type, amount: value, date: DateTime.now(), note: note.text.trim());
    widget.store.transactions.add(transaction);
    await widget.store.save();
    if (type == 'payment' && mounted) {
      final send = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('تم تسجيل السداد'), content: Text('المتبقي الآن ${money(widget.store.balance(widget.customer.id))}'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('لاحقاً')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إرسال وصل واتساب'))]));
      if (send == true) {
        await openWhatsApp(widget.customer.phone, 'وصل استلام من ${widget.customer.name}\nالمبلغ المستلم: ${money(value)}\nالتاريخ: ${dateText(transaction.date)} ${timeText(transaction.date)}\nالمتبقي: ${money(widget.store.balance(widget.customer.id))}\n${widget.store.shop}');
      }
    }
    if (mounted) Navigator.pop(context);
  }
  @override
  Widget build(BuildContext context) => PageShell(title: type == 'debt' ? 'إضافة دين' : 'تسجيل سداد', children: [
        SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دين')), ButtonSegment(value: 'payment', label: Text('سداد'))], selected: {type}, onSelectionChanged: (v) => setState(() => type = v.first)),
        const SizedBox(height: 16),
        FieldBox(controller: amount, label: 'المبلغ بالدينار الليبي', icon: Icons.payments_outlined, type: TextInputType.number),
        FieldBox(controller: note, label: 'ملاحظات اختيارية', icon: Icons.notes_outlined),
        FilledButton.icon(onPressed: widget.store.locked ? null : saveTx, icon: const Icon(Icons.check_circle_outline), label: const Text('حفظ العملية')),
      ]);
}

class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer});
  final Store store;
  final Customer customer;

  String statement() {
    final items = [...store.transactions.where((t) => t.customerId == customer.id)]..sort((a, b) => a.date.compareTo(b.date));
    var balance = 0.0;
    final out = StringBuffer('كشف حساب — ${customer.name}\n');
    out.writeln('إجمالي الدين: ${money(store.debts(customer.id))}');
    out.writeln('إجمالي السداد: ${money(store.paid(customer.id))}');
    out.writeln('المتبقي: ${money(store.balance(customer.id))}');
    out.writeln('------------------------------');
    out.writeln('التاريخ | النوع | المبلغ | الرصيد');
    for (final t in items) {
      balance += t.type == 'debt' ? t.amount : -t.amount;
      out.writeln('${dateText(t.date)} | ${t.type == 'debt' ? 'دين' : 'سداد'} | ${money(t.amount)} | ${money(balance)}');
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final items = [...store.transactions.where((t) => t.customerId == customer.id)]..sort((a, b) => b.date.compareTo(a.date));
    final balance = store.balance(customer.id);
    return PageShell(title: customer.name, children: [
      Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const BrandMark(size: 44), const SizedBox(width: 10), Expanded(child: Text(customer.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))), StatusChip(store.risk(customer.id))]),
        const SizedBox(height: 18),
        Text(money(balance), style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: balance <= 0 ? mint : coral)),
        const Text('الرصيد المتبقي'),
        const SizedBox(height: 12),
        Row(children: [Expanded(child: Text('الدين ${money(store.debts(customer.id))}')), Expanded(child: Text('السداد ${money(store.paid(customer.id))}'))]),
        const SizedBox(height: 14),
        Row(children: [Expanded(child: OutlinedButton.icon(onPressed: () => openWhatsApp(customer.phone, store.whatsappMessage.replaceAll('[الاسم]', customer.name).replaceAll('[المبلغ]', money(balance))), icon: const Icon(Icons.chat), label: const Text('تذكير واتساب'))), const SizedBox(width: 8), Expanded(child: FilledButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddTransactionPage(store: store, customer: customer, initialType: 'payment'))), icon: const Icon(Icons.payments), label: const Text('تسجيل سداد')))]),
      ]))),
      const SizedBox(height: 16),
      Text('سجل الحركات', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      ...items.map((t) {
        final color = t.type == 'debt' ? coral : mint;
        return Card(margin: const EdgeInsets.only(bottom: 6), child: ListTile(leading: CircleAvatar(backgroundColor: color.withOpacity(.12), child: Icon(t.type == 'debt' ? Icons.add : Icons.check, color: color)), title: Text(t.type == 'debt' ? 'إضافة دين' : 'تسديد', style: const TextStyle(fontWeight: FontWeight.w800)), subtitle: Text('${dateText(t.date)} ${timeText(t.date)} • ${t.note}'), trailing: Text(money(t.amount), style: TextStyle(color: color, fontWeight: FontWeight.w900))));
      }),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: () => openWhatsApp(customer.phone, statement()), icon: const Icon(Icons.receipt_long), label: const Text('إرسال كشف الحساب عبر واتساب')),
    ]);
  }
}

class VoiceDraftsPage extends StatefulWidget {
  const VoiceDraftsPage({super.key, required this.store});
  final Store store;
  @override State<VoiceDraftsPage> createState() => _VoiceDraftsPageState();
}
class _VoiceDraftsPageState extends State<VoiceDraftsPage> {
  final speech = stt.SpeechToText();
  bool listening = false;
  String text = '';

  Future<void> record() async {
    if (listening) {
      await speech.stop();
      setState(() => listening = false);
      return;
    }
    final available = await speech.initialize(
      onStatus: (status) { if (mounted) setState(() => listening = status == 'listening'); },
      onError: (_) { if (mounted) setState(() => listening = false); },
    );
    if (!available) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر تشغيل الميكروفون. تأكد من إذن الميكروفون.')));
      return;
    }
    setState(() => listening = true);
    await speech.listen(localeId: 'ar-LY', partialResults: true, onResult: (result) {
      if (mounted) setState(() => text = result.recognizedWords);
    });
  }

  Future<void> saveDraft() async {
    if (text.trim().isEmpty) return;
    final match = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(text);
    final value = double.tryParse(match?.group(1)?.replaceAll(',', '.') ?? '') ?? 0;
    widget.store.voiceDrafts.insert(0, VoiceDraft(id: makeId(), text: text.trim(), date: DateTime.now(), amount: value));
    await widget.store.saveLocal();
    widget.store.notifyListeners();
    setState(() => text = '');
  }

  @override
  Widget build(BuildContext context) => PageShell(title: 'التسجيل الصوتي', children: [
        Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(children: [const Icon(Icons.mic_none_rounded, size: 54, color: Color(0xFF8B5CF6)), const SizedBox(height: 8), const Text('سجل الكلام ثم راجعه قبل اعتماد العملية', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 14), FilledButton.icon(onPressed: record, icon: Icon(listening ? Icons.stop : Icons.mic), label: Text(listening ? 'إيقاف التسجيل' : 'بدء التسجيل')), if (text.isNotEmpty) ...[const SizedBox(height: 12), Text(text, textAlign: TextAlign.center), const SizedBox(height: 10), FilledButton.icon(onPressed: saveDraft, icon: const Icon(Icons.save), label: const Text('حفظ كمسودة'))]])),
        const SizedBox(height: 16),
        ...widget.store.voiceDrafts.map((draft) => Card(child: ListTile(title: Text(draft.text), subtitle: Text('${dateText(draft.date)} • ${draft.amount > 0 ? money(draft.amount) : 'المبلغ غير محدد'}'), trailing: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 16), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VoiceReviewPage(store: widget.store, draft: draft))))))),
      ]);
}

class VoiceReviewPage extends StatefulWidget {
  const VoiceReviewPage({super.key, required this.store, required this.draft});
  final Store store;
  final VoiceDraft draft;
  @override State<VoiceReviewPage> createState() => _VoiceReviewPageState();
}
class _VoiceReviewPageState extends State<VoiceReviewPage> {
  Customer? customer;
  late final TextEditingController amount;
  late final TextEditingController note;
  String type = 'debt';
  @override void initState() { super.initState(); amount = TextEditingController(text: widget.draft.amount > 0 ? widget.draft.amount.toString() : ''); note = TextEditingController(text: widget.draft.text); }
  Future<void> commit() async {
    if (customer == null) return;
    final value = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
    if (value <= 0) return;
    widget.store.transactions.add(Tx(id: makeId(), customerId: customer!.id, type: type, amount: value, date: DateTime.now(), note: note.text.trim()));
    widget.store.voiceDrafts.remove(widget.draft);
    await widget.store.save();
    if (mounted) Navigator.pop(context);
  }
  @override Widget build(BuildContext context) => PageShell(title: 'مراجعة التسجيل', children: [Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(widget.draft.text))), const SizedBox(height: 12), DropdownButtonFormField<Customer>(decoration: const InputDecoration(labelText: 'العميل'), items: widget.store.customers.map((c) => DropdownMenuItem(value: c, child: Text(c.name))).toList(), onChanged: (v) => setState(() => customer = v)), const SizedBox(height: 12), SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دين')), ButtonSegment(value: 'payment', label: Text('سداد'))], selected: {type}, onSelectionChanged: (v) => setState(() => type = v.first)), const SizedBox(height: 12), FieldBox(controller: amount, label: 'المبلغ', icon: Icons.payments, type: TextInputType.number), FieldBox(controller: note, label: 'البيان', icon: Icons.notes), FilledButton.icon(onPressed: commit, icon: const Icon(Icons.check), label: const Text('اعتماد العملية'))]);
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});
  final Store store;
  @override State<SettingsPage> createState() => _SettingsPageState();
}
class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController shop;
  late final TextEditingController message;
  int taps = 0;
  DateTime? last;
  @override void initState() { super.initState(); shop = TextEditingController(text: widget.store.shop); message = TextEditingController(text: widget.store.whatsappMessage); }
  void owner() { final now = DateTime.now(); if (last == null || now.difference(last!).inSeconds > 2) taps = 0; last = now; taps++; if (taps == 3) { taps = 0; showDialog(context: context, builder: (_) => AdminGate(store: widget.store)); } }
  @override Widget build(BuildContext context) => PageShell(title: 'الإعدادات', children: [GestureDetector(onTap: owner, child: const ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.brightness_auto), title: Text('المظهر'), subtitle: Text('تلقائي حسب مظهر الجهاز'))), FieldBox(controller: shop, label: 'اسم المحل / النشاط', icon: Icons.storefront_outlined), FieldBox(controller: message, label: 'رسالة تذكير واتساب', icon: Icons.chat_outlined, maxLines: 4), Text('رقم الجهاز: ${widget.store.deviceId}', style: const TextStyle(fontSize: 12)), const SizedBox(height: 8), FilledButton(onPressed: () async { widget.store.shop = shop.text.trim(); widget.store.whatsappMessage = message.text.trim(); await widget.store.save(); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الحفظ'))); }, child: const Text('حفظ الإعدادات')), OutlinedButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: widget.store))), child: const Text('الاشتراك والتفعيل'))]);
}

class ActivationPage extends StatefulWidget {
  const ActivationPage({super.key, required this.store});
  final Store store;
  @override State<ActivationPage> createState() => _ActivationPageState();
}
class _ActivationPageState extends State<ActivationPage> {
  final code = TextEditingController();
  bool busy = false;
  Future<void> activate() async { setState(() => busy = true); final ok = await widget.store.activateCode(code.text); if (mounted) setState(() => busy = false); if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'تم التفعيل الدائم' : 'الكود غير صحيح أو مستخدم أو مخصص لجهاز آخر'))); if (ok && mounted) Navigator.pop(context); }
  @override Widget build(BuildContext context) => PageShell(title: 'الاشتراك والتفعيل', children: [Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.store.activated ? 'مفعّل دائماً' : 'التجربة المجانية 10 أيام', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)), Text(widget.store.activated ? 'لا يوجد انتهاء' : 'متبقٍ ${widget.store.trialDaysLeft} أيام'), const SizedBox(height: 6), Text('رقم الجهاز: ${widget.store.deviceId}', style: const TextStyle(fontSize: 12))]))), const SizedBox(height: 12), FilledButton.icon(onPressed: () => openWhatsApp('218934951072', 'طلب تفعيل DainPay - رقم الجهاز: ${widget.store.deviceId}'), icon: const Icon(Icons.chat), label: const Text('طلب التفعيل عبر واتساب')), FieldBox(controller: code, label: 'كود التفعيل', icon: Icons.key, type: TextInputType.number), FilledButton(onPressed: busy ? null : activate, child: Text(busy ? 'جارٍ التحقق...' : 'تفعيل دائم'))]);
}

class AdminGate extends StatefulWidget {
  const AdminGate({super.key, required this.store});
  final Store store;
  @override State<AdminGate> createState() => _AdminGateState();
}
class _AdminGateState extends State<AdminGate> {
  final pin = TextEditingController();
  @override Widget build(BuildContext context) => AlertDialog(title: const Text('Adreemk'), content: TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'رمز المالك')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')), FilledButton(onPressed: () { if (pin.text == '116936') { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => AdminPage(store: widget.store))); } else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('رمز المالك غير صحيح'))); } }, child: const Text('دخول'))]);
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.store});
  final Store store;
  @override State<AdminPage> createState() => _AdminPageState();
}
class _AdminPageState extends State<AdminPage> {
  final device = TextEditingController();
  String result = '';
  bool busy = false;
  Future<void> generate() async { if (device.text.trim().isEmpty) return; setState(() => busy = true); final code = await widget.store.generateCode(device.text); if (mounted) setState(() { busy = false; result = code ?? 'تعذر التوليد. تحقق من اتصال Firebase.'; }); }
  @override Widget build(BuildContext context) => PageShell(title: 'Adreemk — المالك', children: [Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('توليد رمز دائم خاص بعميل واحد', style: TextStyle(fontWeight: FontWeight.w900)), const SizedBox(height: 12), FieldBox(controller: device, label: 'رقم جهاز العميل', icon: Icons.phone_android), FilledButton.icon(onPressed: busy ? null : generate, icon: const Icon(Icons.generating_tokens), label: Text(busy ? 'جارٍ التوليد...' : 'توليد الرمز')), if (result.isNotEmpty) ...[const SizedBox(height: 12), SelectableText(result, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900))]]))]);
}

class PageShell extends StatelessWidget {
  const PageShell({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900))), body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: children));
}

class FieldBox extends StatelessWidget {
  const FieldBox({super.key, required this.controller, required this.label, required this.icon, this.type = TextInputType.text, this.maxLines = 1});
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType type;
  final int maxLines;
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: controller, keyboardType: type, maxLines: maxLines, decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)));
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.text, {super.key});
  final String text;
  @override Widget build(BuildContext context) { final color = text == 'خطر' ? coral : text == 'مسدد' ? mint : const Color(0xFFF59E0B); return Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(30)), child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800))); }
}

extension StoreTotals on Store {
  double get paidTotal => transactions.where((t) => t.type == 'payment').fold(0, (sum, t) => sum + t.amount);
}
