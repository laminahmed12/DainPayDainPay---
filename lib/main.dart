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
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  final store = await Store.load();
  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(999999)}';

String money(double value) => '${value.toStringAsFixed(2)} د.ل';

String dateText(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

String timeText(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

String phone218(String value) {
  var phone = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (phone.startsWith('00')) phone = phone.substring(2);
  if (phone.startsWith('218')) return phone;
  if (phone.startsWith('0')) return '218${phone.substring(1)}';
  return phone;
}

double parseMoney(dynamic value) {
  if (value is num) return value.toDouble().isFinite ? value.toDouble() : 0;
  if (value == null) return 0;
  final text = '$value'.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), '');
  return double.tryParse(text) ?? 0;
}

Future<bool> openWhatsApp(String phone, String message) async {
  final number = phone218(phone);
  if (number.isEmpty) return false;
  try {
    return await launchUrl(
      Uri.https('wa.me', '/$number', {'text': message}),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}

class Customer {
  Customer({
    required this.id,
    required this.name,
    required this.phone,
    this.limit = 0,
  });

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
        limit: parseMoney(json['limit']),
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

  bool get isDebt => type == 'debt';
  bool get isPayment => type == 'payment';

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
        type: '${json['type'] ?? 'debt'}' == 'payment' ? 'payment' : 'debt',
        amount: max(0, parseMoney(json['amount'])),
        date: DateTime.tryParse('${json['date']}') ?? DateTime.now(),
        note: '${json['note'] ?? ''}',
      );
}

class VoiceDraft {
  VoiceDraft({
    required this.id,
    required this.text,
    required this.date,
    this.customerId = '',
    this.amount = 0,
    this.note = '',
  });

  String id;
  String text;
  DateTime date;
  String customerId;
  double amount;
  String note;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'date': date.toIso8601String(),
        'customerId': customerId,
        'amount': amount,
        'note': note,
      };

  factory VoiceDraft.fromJson(Map<String, dynamic> json) => VoiceDraft(
        id: '${json['id'] ?? ''}',
        text: '${json['text'] ?? ''}',
        date: DateTime.tryParse('${json['date']}') ?? DateTime.now(),
        customerId: '${json['customerId'] ?? ''}',
        amount: max(0, parseMoney(json['amount'])),
        note: '${json['note'] ?? ''}',
      );
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  final customers = <Customer>[];
  final transactions = <Tx>[];
  final voiceDrafts = <VoiceDraft>[];

  String shop = 'DainPay — دَيْن';
  String whatsappMessage =
      'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  String uid = '';
  String deviceId = '';
  String themeMode = 'system';
  bool firebaseReady = false;
  bool syncing = false;
  bool activated = false;
  DateTime? trialStart;
  Timer? syncTimer;

  static Future<Store> load() async {
    final store = Store();
    store.prefs = await SharedPreferences.getInstance();
    store.shop = store.prefs.getString('shop') ?? store.shop;
    store.whatsappMessage =
        store.prefs.getString('whatsappMessage') ?? store.whatsappMessage;
    store.themeMode = store.prefs.getString('theme_mode') ?? 'system';
    if (!{'system', 'light', 'dark'}.contains(store.themeMode)) {
      store.themeMode = 'system';
    }

    store.deviceId = store.prefs.getString('device_id') ?? '';
    if (store.deviceId.isEmpty) {
      store.deviceId =
          'DP-${DateTime.now().millisecondsSinceEpoch}-${Random.secure().nextInt(999999)}';
      await store.prefs.setString('device_id', store.deviceId);
    }

    final savedTrial = store.prefs.getString('trial_start');
    if (savedTrial == null) {
      store.trialStart = DateTime.now();
      await store.prefs.setString(
        'trial_start',
        store.trialStart!.toIso8601String(),
      );
    } else {
      store.trialStart = DateTime.tryParse(savedTrial) ?? DateTime.now();
    }

    store.activated = store.prefs.getBool('activated') ?? false;

    try {
      final list = jsonDecode(store.prefs.getString('customers') ?? '[]') as List;
      store.customers.addAll(
        list.map((item) => Customer.fromJson(Map<String, dynamic>.from(item))),
      );
    } catch (_) {}

    try {
      final list =
          jsonDecode(store.prefs.getString('transactions') ?? '[]') as List;
      store.transactions.addAll(
        list.map((item) => Tx.fromJson(Map<String, dynamic>.from(item))),
      );
    } catch (_) {}

    try {
      final list =
          jsonDecode(store.prefs.getString('voice_drafts') ?? '[]') as List;
      store.voiceDrafts.addAll(
        list.map((item) => VoiceDraft.fromJson(Map<String, dynamic>.from(item))),
      );
    } catch (_) {}

    return store;
  }

  int get trialDaysLeft {
    if (activated || trialStart == null) return 0;
    final elapsed = DateTime.now().difference(trialStart!).inDays;
    return max(0, 10 - elapsed);
  }

  bool get locked => !activated && trialDaysLeft <= 0;

  ThemeMode get materialThemeMode {
    switch (themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  CollectionReference<Map<String, dynamic>> get customersRef =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('customers');

  CollectionReference<Map<String, dynamic>> get transactionsRef =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('transactions');

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
      syncTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => saveCloud(),
      );
    } catch (_) {
      firebaseReady = false;
    }
    notifyListeners();
  }

  Future<void> loadActivation() async {
    if (!firebaseReady) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('device_activations')
          .doc(deviceId)
          .get();
      if (doc.data()?['activated'] == true) {
        activated = true;
        await prefs.setBool('activated', true);
      }
    } catch (_) {}
  }

  Future<void> pullCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      final customerDocs = await customersRef.get();
      for (final doc in customerDocs.docs) {
        final customer = Customer.fromJson(doc.data());
        final index = customers.indexWhere((item) => item.id == customer.id);
        if (index == -1) {
          customers.add(customer);
        } else {
          customers[index] = customer;
        }
      }

      final transactionDocs = await transactionsRef.get();
      for (final doc in transactionDocs.docs) {
        final data = doc.data();
        final rawDate = data['date'];
        final date = rawDate is Timestamp
            ? rawDate.toDate()
            : DateTime.tryParse('$rawDate') ?? DateTime.now();
        final transaction = Tx(
          id: '${data['id'] ?? doc.id}',
          customerId: '${data['customerId'] ?? ''}',
          type: '${data['type'] ?? 'debt'}' == 'payment' ? 'payment' : 'debt',
          amount: max(0, parseMoney(data['amount'])),
          date: date,
          note: '${data['note'] ?? ''}',
        );
        final index =
            transactions.indexWhere((item) => item.id == transaction.id);
        if (index == -1) {
          transactions.add(transaction);
        } else {
          transactions[index] = transaction;
        }
      }
      await saveLocal();
    } catch (_) {
      // Keep the local database available when Firebase is offline.
    } finally {
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
        batch.set(
          transactionsRef.doc(transaction.id),
          {
            ...transaction.toJson(),
            'date': Timestamp.fromDate(transaction.date),
          },
        );
      }
      await batch.commit();
    } catch (_) {
      // Local save remains the source of truth while offline.
    } finally {
      syncing = false;
    }
  }

  Future<void> saveLocal() async {
    await prefs.setString(
      'customers',
      jsonEncode(customers.map((item) => item.toJson()).toList()),
    );
    await prefs.setString(
      'transactions',
      jsonEncode(transactions.map((item) => item.toJson()).toList()),
    );
    await prefs.setString(
      'voice_drafts',
      jsonEncode(voiceDrafts.map((item) => item.toJson()).toList()),
    );
    await prefs.setString('shop', shop);
    await prefs.setString('whatsappMessage', whatsappMessage);
    await prefs.setString('theme_mode', themeMode);
  }

  Future<void> save() async {
    await saveLocal();
    notifyListeners();
    await saveCloud();
  }

  double balance(String customerId) => transactions
      .where((item) => item.customerId == customerId)
      .fold<double>(
        0,
        (total, item) => total + (item.isDebt ? item.amount : -item.amount),
      );

  double debts(String customerId) => transactions
      .where((item) => item.customerId == customerId && item.isDebt)
      .fold<double>(0, (total, item) => total + item.amount);

  double paid(String customerId) => transactions
      .where((item) => item.customerId == customerId && item.isPayment)
      .fold<double>(0, (total, item) => total + item.amount);

  DateTime? oldestOutstandingDebt(String customerId) {
    final debtsList = transactions
        .where((item) => item.customerId == customerId && item.isDebt)
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    var remainingPaid = paid(customerId);
    for (final debt in debtsList) {
      if (remainingPaid >= debt.amount) {
        remainingPaid -= debt.amount;
      } else {
        return debt.date;
      }
    }
    return null;
  }

  String risk(String customerId) {
    if (balance(customerId) <= 0) return 'مسدد';
    final oldest = oldestOutstandingDebt(customerId);
    if (oldest == null) return 'حديث';
    final days = DateTime.now().difference(oldest).inDays;
    if (days > 90) return 'خطر';
    if (days > 30) return 'متأخر';
    return 'حديث';
  }

  String? validateTransaction({
    required Customer customer,
    required String type,
    required double amount,
  }) {
    if (amount <= 0 || !amount.isFinite) return 'أدخل مبلغًا صحيحًا أكبر من صفر.';
    final current = balance(customer.id);
    if (type == 'payment' && amount > current + 0.000001) {
      return 'لا يمكن أن يتجاوز السداد المتبقي: ${money(max(0, current))}.';
    }
    if (type == 'debt' && customer.limit > 0 && current + amount > customer.limit + 0.000001) {
      final available = max(0, customer.limit - current);
      return 'السقف الائتماني ${money(customer.limit)} والمتاح ${money(available)}.';
    }
    return null;
  }

  Future<String?> addTransaction({
    required Customer customer,
    required String type,
    required double amount,
    String note = '',
  }) async {
    final error = validateTransaction(
      customer: customer,
      type: type,
      amount: amount,
    );
    if (error != null) return error;
    transactions.add(
      Tx(
        id: makeId(),
        customerId: customer.id,
        type: type == 'payment' ? 'payment' : 'debt',
        amount: amount,
        date: DateTime.now(),
        note: note.trim(),
      ),
    );
    await save();
    return null;
  }

  Future<bool> activateCode(String code) async {
    if (!firebaseReady || code.trim().isEmpty) return false;
    final ref = FirebaseFirestore.instance
        .collection('activation_codes')
        .doc(code.trim());
    try {
      final ok = await FirebaseFirestore.instance.runTransaction<bool>(
        (transaction) async {
          final snapshot = await transaction.get(ref);
          final data = snapshot.data();
          if (!snapshot.exists || data == null || data['used'] == true) {
            return false;
          }
          final boundDevice = '${data['deviceId'] ?? ''}';
          if (boundDevice.isNotEmpty && boundDevice != deviceId) return false;
          transaction.update(ref, {
            'used': true,
            'usedAt': FieldValue.serverTimestamp(),
            'usedDeviceId': deviceId,
          });
          return true;
        },
      );
      if (!ok) return false;
      await FirebaseFirestore.instance
          .collection('device_activations')
          .doc(deviceId)
          .set({
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
    final target = targetDevice.trim();
    if (!firebaseReady || target.isEmpty) return null;
    try {
      String code;
      do {
        code = (100000 + Random.secure().nextInt(900000)).toString();
      } while ((await FirebaseFirestore.instance
              .collection('activation_codes')
              .doc(code)
              .get())
          .exists);

      await FirebaseFirestore.instance
          .collection('activation_codes')
          .doc(code)
          .set({
        'deviceId': target,
        'used': false,
        'createdAt': FieldValue.serverTimestamp(),
      }).timeout(const Duration(seconds: 12));
      return code;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearLocal() async {
    customers.clear();
    transactions.clear();
    voiceDrafts.clear();
    await prefs.remove('customers');
    await prefs.remove('transactions');
    await prefs.remove('voice_drafts');
    notifyListeners();
  }

  @override
  void dispose() {
    syncTimer?.cancel();
    super.dispose();
  }
}

class DainColors {
  static const primary = Color(0xFF087F5B);
  static const primaryDark = Color(0xFF056047);
  static const mint = Color(0xFF2EC4B6);
  static const danger = Color(0xFFE05A67);
  static const surfaceDark = Color(0xFF0E1A24);
  static const surfaceDark2 = Color(0xFF152332);
  static const surfaceLight = Color(0xFFF6F8FA);
}

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store});
  final Store store;

  ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: DainColors.primary,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Cairo',
      scaffoldBackgroundColor:
          dark ? DainColors.surfaceDark : DainColors.surfaceLight,
      cardTheme: CardTheme(
        elevation: 0,
        color: dark ? DainColors.surfaceDark2 : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.symmetric(vertical: 5),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? DainColors.surfaceDark : DainColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? Colors.white.withOpacity(.05) : Colors.black.withOpacity(.035),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: DainColors.mint, width: 1.3),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: DainColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: store,
        builder: (_, __) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          themeMode: store.materialThemeMode,
          home: HomePage(store: store),
        ),
      );
}

class DainLogo extends StatelessWidget {
  const DainLogo({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * .28),
          gradient: const LinearGradient(
            colors: [DainColors.primaryDark, DainColors.mint],
          ),
          boxShadow: [
            BoxShadow(
              color: DainColors.primary.withOpacity(.25),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          'DP',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: size * .36,
          ),
        ),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});
  final Store store;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String query = '';
  String filter = 'all';
  int taps = 0;
  DateTime? lastTap;

  void hidden() {
    final now = DateTime.now();
    if (lastTap == null || now.difference(lastTap!).inSeconds > 2) taps = 0;
    lastTap = now;
    taps++;
    if (taps == 3) {
      taps = 0;
      showDialog(
        context: context,
        builder: (_) => AdminGate(store: widget.store),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final customers = store.customers.where((customer) {
      final balance = store.balance(customer.id);
      final matchesQuery = query.isEmpty ||
          customer.name.contains(query) ||
          customer.phone.contains(query);
      final matchesFilter = filter == 'all' ||
          (filter == 'debt' && balance > 0) ||
          (filter == 'paid' && balance <= 0);
      return matchesQuery && matchesFilter;
    }).toList()
      ..sort((a, b) => store.balance(b.id).compareTo(store.balance(a.id)));

    final oldCount = customers.where((customer) {
      final oldest = store.oldestOutstandingDebt(customer.id);
      return oldest != null && DateTime.now().difference(oldest).inDays > 90;
    }).length;

    final total = store.customers.fold<double>(
      0,
      (sum, customer) => sum + max(0, store.balance(customer.id)),
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: hidden,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DainLogo(size: 30),
                const SizedBox(width: 8),
                Text(store.shop, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          actions: [
            IconButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsPage(store: store)),
              ),
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (!store.activated)
              Card(
                child: ListTile(
                  leading: Icon(
                    store.locked ? Icons.lock_outline : Icons.workspace_premium_outlined,
                    color: store.locked ? DainColors.danger : DainColors.mint,
                  ),
                  title: Text(
                    store.locked ? 'انتهت الفترة التجريبية' : 'التجربة المجانية 10 أيام',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    store.locked ? 'يلزم التفعيل للمتابعة' : 'متبقٍ ${store.trialDaysLeft} أيام',
                  ),
                  trailing: FilledButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ActivationPage(store: store)),
                    ),
                    child: const Text('تفعيل'),
                  ),
                ),
              ),
            Card(
              child: ListTile(
                title: const Text('إجمالي المتبقي على العملاء'),
                subtitle: Text(
                  money(total),
                  style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.bold,
                    color: DainColors.primary,
                  ),
                ),
                leading: const DainLogo(size: 46),
              ),
            ),
            if (oldCount > 0)
              Card(
                color: DainColors.danger.withOpacity(.08),
                child: ListTile(
                  leading: const Icon(Icons.warning_amber_rounded, color: DainColors.danger),
                  title: const Text('ديون قديمة معلّقة'),
                  subtitle: Text('$oldCount عميل لديه دين أقدم من 90 يومًا'),
                ),
              ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.mic_rounded, color: DainColors.primary),
                title: const Text('التسجيل الصوتي', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                  store.voiceDrafts.isEmpty
                      ? 'سجل ملاحظة واحفظها كمسودة للمراجعة'
                      : '${store.voiceDrafts.length} مسودة بانتظار المراجعة',
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => VoiceDraftsPage(store: store)),
                ),
              ),
            const SizedBox(height: 5),
            TextField(
              decoration: const InputDecoration(
                hintText: 'بحث بالاسم أو الهاتف',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (value) => setState(() => query = value.trim()),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('الكل'),
                  selected: filter == 'all',
                  onSelected: (_) => setState(() => filter = 'all'),
                ),
                ChoiceChip(
                  label: const Text('عليهم دين'),
                  selected: filter == 'debt',
                  onSelected: (_) => setState(() => filter = 'debt'),
                ),
                ChoiceChip(
                  label: const Text('مسدد'),
                  selected: filter == 'paid',
                  onSelected: (_) => setState(() => filter = 'paid'),
                ),
              ],
            ),
            const SizedBox(height: 5),
            if (customers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('لا يوجد عملاء بعد')),
              ),
            ...customers.map(
              (customer) {
                final balance = store.balance(customer.id);
                final debt = balance > 0;
                return Card(
                  child: ListTile(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CustomerPage(store: store, customer: customer),
                      ),
                    ),
                    leading: CircleAvatar(
                      backgroundColor: (debt ? DainColors.danger : DainColors.mint).withOpacity(.15),
                      child: Text(
                        customer.name.isEmpty ? '؟' : customer.name.characters.first,
                        style: TextStyle(
                          color: debt ? DainColors.danger : DainColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(customer.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      '${customer.phone}\n${store.risk(customer.id)} • دين ${money(store.debts(customer.id))} • مسدد ${money(store.paid(customer.id))}',
                    ),
                    isThreeLine: true,
                    trailing: Text(
                      money(balance),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: debt ? DainColors.danger : DainColors.mint,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: store.locked
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ActivationPage(store: store)),
                  )
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => AddCustomerPage(store: store)),
                  ),
          icon: Icon(store.locked ? Icons.lock_outline : Icons.person_add_alt_1),
          label: Text(store.locked ? 'التفعيل' : 'عميل'),
        ),
      ),
    );
  }
}

class AddCustomerPage extends StatefulWidget {
  const AddCustomerPage({super.key, required this.store});
  final Store store;
  @override
  State<AddCustomerPage> createState() => _AddCustomerPageState();
}

class _AddCustomerPageState extends State<AddCustomerPage> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final limit = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    limit.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final customerName = name.text.trim();
    if (customerName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل اسم العميل.')),
      );
      return;
    }
    if (busy) return;
    setState(() => busy = true);
    widget.store.customers.add(
      Customer(
        id: makeId(),
        name: customerName,
        phone: phone.text.trim(),
        limit: max(0, parseMoney(limit.text)),
      ),
    );
    await widget.store.save();
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('إضافة عميل')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'اسم العميل',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'رقم الهاتف',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: limit,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'السقف الائتماني (اختياري)',
                  prefixIcon: Icon(Icons.speed_outlined),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: busy ? null : save,
                icon: const Icon(Icons.check_rounded),
                label: Text(busy ? 'جارٍ الحفظ...' : 'حفظ'),
              ),
            ],
          ),
        ),
      );
}

String statementFor(Store store, Customer customer) {
  final rows = store.transactions
      .where((item) => item.customerId == customer.id)
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  var running = 0.0;
  final text = StringBuffer();
  text.writeln('كشف حساب — ${store.shop}');
  text.writeln('الزبون: ${customer.name}');
  if (customer.phone.isNotEmpty) text.writeln('الهاتف: ${customer.phone}');
  text.writeln('────────────────────');
  for (final transaction in rows) {
    running += transaction.isDebt ? transaction.amount : -transaction.amount;
    text.writeln(
      '${dateText(transaction.date)} ${timeText(transaction.date)} — ${transaction.isDebt ? 'دين' : 'سداد'}: ${money(transaction.amount)}${transaction.note.isEmpty ? '' : ' — ${transaction.note}'} — الرصيد ${money(running)}',
    );
  }
  text.writeln('────────────────────');
  text.writeln('إجمالي الدين: ${money(store.debts(customer.id))}');
  text.writeln('إجمالي التسديد: ${money(store.paid(customer.id))}');
  text.writeln('المتبقي: ${money(max(0, store.balance(customer.id)))}');
  return text.toString();
}

String paymentReceipt(Store store, Customer customer, double amount, DateTime date) =>
    'وصل استلام — ${store.shop}\n'
    'الزبون: ${customer.name}\n'
    'المبلغ المستلم: ${money(amount)}\n'
    'التاريخ: ${dateText(date)} ${timeText(date)}\n'
    'المتبقي بعد السداد: ${money(max(0, store.balance(customer.id)))}\n'
    'شكرًا لكم.';

class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer});
  final Store store;
  final Customer customer;

  Future<void> reminder(BuildContext context) async {
    final message = store.whatsappMessage
        .replaceAll('[الاسم]', customer.name)
        .replaceAll('[المبلغ]', money(max(0, store.balance(customer.id))));
    if (!await openWhatsApp(customer.phone, message) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب.')),
      );
    }
  }

  Future<void> statement(BuildContext context) async {
    if (!await openWhatsApp(customer.phone, statementFor(store, customer)) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب.')),
      );
    }
  }

  Future<void> call(BuildContext context) async {
    if (!await launchUrl(
      Uri.parse('tel:${customer.phone}'),
      mode: LaunchMode.externalApplication,
    ) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح الاتصال.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = store.transactions
        .where((item) => item.customerId == customer.id)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final balance = max(0, store.balance(customer.id));

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(customer.name)),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      money(balance),
                      style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                    ),
                    const Text('المتبقي'),
                    const SizedBox(height: 8),
                    Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'),
                    Text('السقف الائتماني: ${customer.limit <= 0 ? 'غير محدد' : money(customer.limit)}'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () => reminder(context),
                          icon: const Icon(Icons.chat),
                          label: const Text('تذكير'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => statement(context),
                          icon: const Icon(Icons.receipt_long),
                          label: const Text('كشف حساب'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => call(context),
                          icon: const Icon(Icons.phone),
                          label: const Text('اتصال'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(30),
                child: Center(child: Text('لا توجد عمليات.')),
              ),
            ...rows.map(
              (transaction) => ListTile(
                leading: Icon(
                  transaction.isDebt ? Icons.arrow_downward : Icons.arrow_upward,
                  color: transaction.isDebt ? DainColors.danger : DainColors.mint,
                ),
                title: Text(transaction.isDebt ? 'دين' : 'سداد'),
                subtitle: Text(
                  '${dateText(transaction.date)} ${timeText(transaction.date)}${transaction.note.isEmpty ? '' : ' • ${transaction.note}'}',
                ),
                trailing: Text(
                  money(transaction.amount),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: store.locked
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ActivationPage(store: store)),
                  )
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AddTransactionPage(store: store, customer: customer),
                    ),
                  ),
          icon: Icon(store.locked ? Icons.lock_outline : Icons.add),
          label: Text(store.locked ? 'التفعيل' : 'عملية'),
        ),
      ),
    );
  }
}

class AddTransactionPage extends StatefulWidget {
  const AddTransactionPage({super.key, required this.store, required this.customer});
  final Store store;
  final Customer customer;
  @override
  State<AddTransactionPage> createState() => _AddTransactionPageState();
}

class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount = TextEditingController();
  final note = TextEditingController();
  String type = 'debt';
  bool busy = false;

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> saveTx() async {
    if (busy) return;
    final value = parseMoney(amount.text);
    final error = widget.store.validateTransaction(
      customer: widget.customer,
      type: type,
      amount: value,
    );
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    setState(() => busy = true);
    final date = DateTime.now();
    widget.store.transactions.add(
      Tx(
        id: makeId(),
        customerId: widget.customer.id,
        type: type,
        amount: value,
        date: date,
        note: note.text.trim(),
      ),
    );
    await widget.store.save();
    if (!mounted) return;

    if (type == 'payment') {
      final send = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('إرسال وصل استلام؟'),
          content: Text(
            'تم تسجيل السداد بقيمة ${money(value)}.\nهل تريد إرسال وصل استلام للزبون عبر واتساب؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('لا'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('إرسال الوصل'),
            ),
          ],
        ),
      );
      if (send == true) {
        final ok = await openWhatsApp(
          widget.customer.phone,
          paymentReceipt(widget.store, widget.customer, value, date),
        );
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر فتح واتساب.')),
          );
        }
      }
    }

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: Text(type == 'debt' ? 'إضافة دين' : 'تسجيل سداد')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'debt', label: Text('دين')),
                  ButtonSegment(value: 'payment', label: Text('سداد')),
                ],
                selected: {type},
                onSelectionChanged: busy
                    ? null
                    : (value) => setState(() => type = value.first),
              ),
              const SizedBox(height: 14),
              Text(
                type == 'payment'
                    ? 'المتبقي الحالي: ${money(max(0, widget.store.balance(widget.customer.id)))}'
                    : 'السقف الائتماني: ${widget.customer.limit <= 0 ? 'غير محدد' : money(widget.customer.limit)}',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'المبلغ بالدينار الليبي'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'البيان / ملاحظات'),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: busy ? null : saveTx,
                icon: const Icon(Icons.check_rounded),
                label: Text(busy ? 'جارٍ الحفظ...' : 'حفظ العملية'),
              ),
            ],
          ),
        ),
      );
}

class VoiceDraftsPage extends StatefulWidget {
  const VoiceDraftsPage({super.key, required this.store});
  final Store store;
  @override
  State<VoiceDraftsPage> createState() => _VoiceDraftsPageState();
}

class _VoiceDraftsPageState extends State<VoiceDraftsPage> {
  final speech = stt.SpeechToText();
  bool listening = false;
  String live = '';

  @override
  void dispose() {
    speech.stop();
    super.dispose();
  }

  double? parseAmount(String text) {
    final match = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(text);
    if (match != null) return parseMoney(match.group(1));
    const words = <String, double>{
      'صفر': 0,
      'واحد': 1,
      'واحدة': 1,
      'اثنين': 2,
      'اثنان': 2,
      'ثلاثة': 3,
      'أربعة': 4,
      'اربعة': 4,
      'خمسة': 5,
      'ستة': 6,
      'سبعة': 7,
      'ثمانية': 8,
      'تسعة': 9,
      'عشرة': 10,
      'عشرين': 20,
      'ثلاثين': 30,
      'أربعين': 40,
      'أربعين': 40,
      'خمسين': 50,
      'ستين': 60,
      'سبعين': 70,
      'ثمانين': 80,
      'تسعين': 90,
      'مية': 100,
      'مائة': 100,
      'مئة': 100,
      'ألف': 1000,
      'الف': 1000,
    };
    for (final entry in words.entries) {
      if (text.contains(entry.key)) return entry.value;
    }
    return null;
  }

  String matchCustomer(String text) {
    for (final customer in widget.store.customers) {
      if (text.contains(customer.name)) return customer.id;
    }
    return '';
  }

  Future<void> record() async {
    if (listening) {
      await speech.stop();
      if (mounted) setState(() => listening = false);
      return;
    }

    final available = await speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'notListening' || status == 'done') {
          setState(() => listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => listening = false);
      },
    );

    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الوصول إلى الميكروفون. اسمح بإذن الميكروفون وتأكد من توفر التعرف على الكلام.'),
          ),
        );
      }
      return;
    }

    final locales = await speech.locales();
    String? localeId;
    for (final locale in locales) {
      if (locale.localeId.toLowerCase().replaceAll('-', '_') == 'ar_ly') {
        localeId = locale.localeId;
        break;
      }
    }
    localeId ??= locales
        .firstWhere(
          (locale) => locale.localeId.toLowerCase().startsWith('ar'),
          orElse: () => locales.isNotEmpty ? locales.first : stt.LocaleName('ar', 'Arabic'),
        )
        .localeId;

    live = '';
    if (mounted) setState(() => listening = true);
    await speech.listen(
      localeId: localeId,
      partialResults: true,
      listenFor: const Duration(seconds: 45),
      pauseFor: const Duration(seconds: 4),
      onResult: (result) async {
        if (mounted) setState(() => live = result.recognizedWords);
        if (!result.finalResult) return;
        final text = result.recognizedWords.trim();
        if (text.isNotEmpty) {
          widget.store.voiceDrafts.insert(
            0,
            VoiceDraft(
              id: makeId(),
              text: text,
              date: DateTime.now(),
              customerId: matchCustomer(text),
              amount: parseAmount(text) ?? 0,
              note: text,
            ),
          );
          await widget.store.saveLocal();
          widget.store.notifyListeners();
        }
        if (mounted) setState(() => listening = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final drafts = widget.store.voiceDrafts;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('المسودات الصوتية')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: ListTile(
                leading: Icon(
                  listening ? Icons.stop_circle_outlined : Icons.mic_rounded,
                  color: listening ? DainColors.danger : DainColors.primary,
                  size: 32,
                ),
                title: Text(listening ? 'جارٍ التسجيل...' : 'اضغط للتسجيل'),
                subtitle: Text(
                  live.isEmpty ? 'مثال: محمد 100 دينار بضاعة' : live,
                ),
                onTap: record,
              ),
            ),
            if (drafts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('لا توجد مسودات')),
              ),
            ...drafts.map((draft) {
              final customer = widget.store.customers.firstWhere(
                (item) => item.id == draft.customerId,
                orElse: () => Customer(id: '', name: 'عميل غير محدد', phone: ''),
              );
              return Card(
                child: ListTile(
                  title: Text(customer.name),
                  subtitle: Text('${draft.text}\nالمبلغ المستخرج: ${money(draft.amount)}'),
                  isThreeLine: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      widget.store.voiceDrafts.removeWhere((item) => item.id == draft.id);
                      await widget.store.saveLocal();
                      if (mounted) setState(() {});
                    },
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => VoiceReviewPage(store: widget.store, draft: draft),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class VoiceReviewPage extends StatefulWidget {
  const VoiceReviewPage({super.key, required this.store, required this.draft});
  final Store store;
  final VoiceDraft draft;
  @override
  State<VoiceReviewPage> createState() => _VoiceReviewPageState();
}

class _VoiceReviewPageState extends State<VoiceReviewPage> {
  late TextEditingController amount;
  late TextEditingController note;
  String customerId = '';
  String type = 'debt';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    amount = TextEditingController(
      text: widget.draft.amount > 0 ? widget.draft.amount.toString() : '',
    );
    note = TextEditingController(text: widget.draft.note);
    customerId = widget.draft.customerId;
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> approve() async {
    if (busy) return;
    final customer = widget.store.customers.firstWhere(
      (item) => item.id == customerId,
      orElse: () => Customer(id: '', name: '', phone: ''),
    );
    final value = parseMoney(amount.text);
    if (customer.id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر الزبون أولاً.')),
      );
      return;
    }
    final error = widget.store.validateTransaction(
      customer: customer,
      type: type,
      amount: value,
    );
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    setState(() => busy = true);
    final date = DateTime.now();
    widget.store.transactions.add(
      Tx(
        id: makeId(),
        customerId: customer.id,
        type: type,
        amount: value,
        date: date,
        note: note.text.trim(),
      ),
    );
    widget.store.voiceDrafts.removeWhere((item) => item.id == widget.draft.id);
    await widget.store.save();
    if (!mounted) return;

    if (type == 'payment') {
      final send = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('إرسال وصل استلام؟'),
          content: Text('هل تريد إرسال وصل استلام بقيمة ${money(value)} إلى ${customer.name}؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('لا'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('إرسال'),
            ),
          ],
        ),
      );
      if (send == true) {
        await openWhatsApp(customer.phone, paymentReceipt(widget.store, customer, value, date));
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('مراجعة التسجيل')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(widget.draft.text, style: const TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: customerId.isEmpty ? null : customerId,
                decoration: const InputDecoration(labelText: 'الزبون'),
                items: widget.store.customers
                    .map((customer) => DropdownMenuItem<String>(
                          value: customer.id,
                          child: Text(customer.name),
                        ))
                    .toList(),
                onChanged: busy ? null : (value) => setState(() => customerId = value ?? ''),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'debt', label: Text('دين')),
                  ButtonSegment(value: 'payment', label: Text('سداد')),
                ],
                selected: {type},
                onSelectionChanged: busy
                    ? null
                    : (value) => setState(() => type = value.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'البيان'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : approve,
                child: Text(busy ? 'جارٍ الاعتماد...' : 'اعتماد وحفظ'),
              ),
            ],
          ),
        ),
      );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});
  final Store store;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController shop;
  late TextEditingController message;
  int taps = 0;
  DateTime? lastTap;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    shop = TextEditingController(text: widget.store.shop);
    message = TextEditingController(text: widget.store.whatsappMessage);
  }

  @override
  void dispose() {
    shop.dispose();
    message.dispose();
    super.dispose();
  }

  void hidden() {
    final now = DateTime.now();
    if (lastTap == null || now.difference(lastTap!).inSeconds > 2) taps = 0;
    lastTap = now;
    taps++;
    if (taps == 3) {
      taps = 0;
      showDialog(
        context: context,
        builder: (_) => AdminGate(store: widget.store),
      );
    }
  }

  Future<void> save() async {
    if (busy) return;
    setState(() => busy = true);
    widget.store.shop = shop.text.trim().isEmpty ? 'DainPay — دَيْن' : shop.text.trim();
    widget.store.whatsappMessage = message.text.trim().isEmpty
        ? 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.'
        : message.text.trim();
    await widget.store.save();
    if (!mounted) return;
    setState(() => busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم الحفظ')),
    );
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(
            title: GestureDetector(onTap: hidden, child: const Text('الإعدادات')),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: shop,
                decoration: const InputDecoration(labelText: 'اسم المحل / النشاط'),
              ),
              const SizedBox(height: 14),
              const Text('المظهر', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'system', label: Text('تلقائي')),
                  ButtonSegment(value: 'light', label: Text('فاتح')),
                  ButtonSegment(value: 'dark', label: Text('داكن')),
                ],
                selected: {widget.store.themeMode},
                onSelectionChanged: (value) async {
                  widget.store.themeMode = value.first;
                  await widget.store.saveLocal();
                  widget.store.notifyListeners();
                },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: message,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'رسالة واتساب للتذكير',
                  helperText: 'يمكنك استخدام [الاسم] و[المبلغ].',
                ),
              ),
              const SizedBox(height: 12),
              Text('رقم الجهاز: ${widget.store.deviceId}'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : save,
                child: Text(busy ? 'جارٍ الحفظ...' : 'حفظ'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ActivationPage(store: widget.store)),
                ),
                child: const Text('الاشتراك والتفعيل'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await widget.store.clearLocal();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('تم مسح البيانات المحلية')),
                  );
                },
                child: const Text('مسح البيانات المحلية'),
              ),
            ],
          ),
        ),
      );
}

class ActivationPage extends StatefulWidget {
  const ActivationPage({super.key, required this.store});
  final Store store;
  @override
  State<ActivationPage> createState() => _ActivationPageState();
}

class _ActivationPageState extends State<ActivationPage> {
  final code = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> activate() async {
    if (busy) return;
    final value = code.text.trim();
    if (value.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل رمز التفعيل المكوّن من 6 أرقام.')),
      );
      return;
    }
    setState(() => busy = true);
    final ok = await widget.store.activateCode(value);
    if (!mounted) return;
    setState(() => busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'تم التفعيل الدائم' : 'الكود غير صحيح أو مستخدم أو مخصص لجهاز آخر')),
    );
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('الاشتراك والتفعيل')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                widget.store.activated
                    ? 'مفعّل دائمًا'
                    : 'التجربة المجانية: ${widget.store.trialDaysLeft} أيام',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('رقم الجهاز: ${widget.store.deviceId}'),
              const SizedBox(height: 8),
              const Text('الدفع نقدًا فقط — +218934951072'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => openWhatsApp(
                  '+218934951072',
                  'طلب تفعيل DainPay - رقم الجهاز: ${widget.store.deviceId}',
                ),
                icon: const Icon(Icons.chat),
                label: const Text('طلب التفعيل عبر واتساب'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(labelText: 'كود التفعيل'),
              ),
              FilledButton(
                onPressed: busy ? null : activate,
                child: Text(busy ? 'جارٍ التحقق...' : 'تفعيل دائم'),
              ),
            ],
          ),
        ),
      );
}

class AdminGate extends StatefulWidget {
  const AdminGate({super.key, required this.store});
  final Store store;
  @override
  State<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGate> {
  final pin = TextEditingController();

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  void enter() {
    if (pin.text == '116936') {
      Navigator.pop(context);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => AdminPage(store: widget.store)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('رمز المالك غير صحيح')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Adreemk'),
        content: TextField(
          controller: pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'رمز المالك'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(onPressed: enter, child: const Text('دخول')),
        ],
      );
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.store});
  final Store store;
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final device = TextEditingController();
  String result = '';
  bool busy = false;

  @override
  void dispose() {
    device.dispose();
    super.dispose();
  }

  Future<void> generate() async {
    final target = device.text.trim();
    if (target.isEmpty || busy) return;
    setState(() {
      busy = true;
      result = '';
    });
    final code = await widget.store
        .generateCode(target)
        .timeout(const Duration(seconds: 15), onTimeout: () => null);
    if (!mounted) return;
    setState(() {
      busy = false;
      result = code ?? 'تعذر التوليد. تحقق من اتصال Firebase وصلاحيات Firestore.';
    });
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('Adreemk — المالك')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'توليد رمز دائم خاص بجهاز عميل واحد',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: device,
                decoration: const InputDecoration(labelText: 'رقم جهاز العميل'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : generate,
                child: Text(busy ? 'جارٍ التوليد...' : 'توليد الرمز'),
              ),
              if (result.isNotEmpty)
                Card(
                  child: ListTile(
                    title: const Text('النتيجة'),
                    subtitle: Text(
                      result,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    trailing: result.length == 6
                        ? IconButton(
                            onPressed: () => openWhatsApp(
                              '+218934951072',
                              'رمز تفعيل DainPay: $result',
                            ),
                            icon: const Icon(Icons.send),
                          )
                        : null,
                  ),
                ),
            ],
          ),
        ),
      );
}
