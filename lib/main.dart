// Updated DainPay Code - Full Fixes for Customers Logic & Voice Draft Deletion
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'backup_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';

const Color emerald = Color(0xFF0F5C6E);
const Color mint = Color(0xFF2EC4B6);
const Color burgundy = Color(0xFFE63946);

const int trialLengthDays = 7;
const String cloudflareActivationUrl = 'https://dainpay-activation.lamin-ahmed12.workers.dev';
const String appTitle = 'DainPay — دَيْن';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = await Store.load();

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    store.firebaseInitialized = true;
  } catch (e, stack) {
    store.firebaseInitialized = false;
    debugPrint('Firebase initialization error: $e');
    debugPrintStack(stackTrace: stack);
  }

  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

String makeId() {
  return '${DateTime.now().microsecondsSinceEpoch}_'
      '${Random.secure().nextInt(1000000)}';
}

String money(int cents) {
  final sign = cents < 0 ? '-' : '';
  final value = cents.abs();

  return '$sign${value ~/ 100}.'
      '${(value % 100).toString().padLeft(2, '0')} د.ل';
}

String dateText(DateTime date) {
  return '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/'
      '${date.year}';
}

String timeText(DateTime date) {
  return '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
}

String _digits(String value) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';

  var output = value;

  for (var i = 0; i < 10; i++) {
    output = output.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
  }

  return output;
}

int parseCents(String value) {
  var v = _digits(value)
      .trim()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('٬', '')
      .replaceAll('،', ',');

  if (v.isEmpty) return 0;

  final comma = v.lastIndexOf(',');
  final dot = v.lastIndexOf('.');

  if (comma >= 0 && dot >= 0) {
    final separator = max(comma, dot);

    final integerPart =
        v.substring(0, separator).replaceAll(RegExp(r'[,.]'), '');

    final fraction =
        v.substring(separator + 1).replaceAll(RegExp(r'[^0-9]'), '');

    return _partsToCents(integerPart, fraction);
  }

  if (comma >= 0 || dot >= 0) {
    final separator = comma >= 0 ? comma : dot;

    final integerPart =
        v.substring(0, separator).replaceAll(RegExp(r'[^0-9-]'), '');

    final fraction =
        v.substring(separator + 1).replaceAll(RegExp(r'[^0-9]'), '');

    if (fraction.length <= 2) {
      return _partsToCents(integerPart, fraction);
    }

    final joined = v.replaceAll(RegExp(r'[^0-9-]'), '');
    final amount = int.tryParse(joined) ?? 0;

    return max(0, amount * 100);
  }

  final amount = int.tryParse(v.replaceAll(RegExp(r'[^0-9-]'), '')) ?? 0;

  return max(0, amount * 100);
}

int _partsToCents(String integerPart, String fraction) {
  final whole =
      int.tryParse(integerPart.replaceAll(RegExp(r'[^0-9-]'), '')) ?? 0;

  final f = fraction.padRight(2, '0').substring(0, 2);
  final cents = int.tryParse(f) ?? 0;

  return max(0, whole * 100 + cents);
}

String phone218(String value) {
  var phone = _digits(value).replaceAll(RegExp(r'[^0-9]'), '');

  if (phone.startsWith('00')) {
    phone = phone.substring(2);
  }

  if (phone.startsWith('218')) {
    return phone;
  }

  if (phone.startsWith('0')) {
    return '218${phone.substring(1)}';
  }

  return phone;
}

Future<bool> launchWhatsApp(
  String phone,
  String message,
) async {
  final number = phone218(phone);

  if (number.isEmpty) {
    return false;
  }

  try {
    final uri = Uri.https(
      'wa.me',
      '/$number',
      {'text': message},
    );

    return await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    debugPrint('WhatsApp error: $e');
    return false;
  }
}

Future<bool> makePhoneCall(String phone) async {
  final clean = _digits(phone).replaceAll(
    RegExp(r'[^0-9+]'),
    '',
  );

  if (clean.isEmpty) return false;

  try {
    return await launchUrl(
      Uri.parse('tel:$clean'),
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    debugPrint('Phone error: $e');
    return false;
  }
}

String buildAccountStatement(Store store, Customer customer) {
  final items = store.transactions
      .where((t) => t.customerId == customer.id)
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  final debt = store.debts(customer.id);
  final paid = store.paid(customer.id);
  final balance = store.balance(customer.id);

  final lines = <String>[
    store.shop,
    'كشف حساب',
    '------------------------------',
    'العميل: ${customer.name}',
    if (customer.phone.trim().isNotEmpty) 'الهاتف: ${customer.phone.trim()}',
    'التاريخ: ${dateText(DateTime.now())}',
    '',
    'إجمالي الديون: ${money(debt)}',
    'إجمالي المسدد: ${money(paid)}',
    'المتبقي: ${money(balance)}',
    'الحالة: ${balance <= 0 ? 'مسدد' : 'عليه رصيد'}',
    '',
    'تفاصيل العمليات:',
  ];

  if (items.isEmpty) {
    lines.add('لا توجد عمليات مسجلة.');
  } else {
    for (final item in items) {
      final kind = item.type == 'debt' ? 'دَين' : 'تسديد';
      final note = item.note.trim();
      lines.add(
        '${dateText(item.date)} ${timeText(item.date)} — $kind — ${money(item.amountCents)}'
        '${note.isEmpty ? '' : ' — $note'}',
      );
    }
  }

  lines.addAll([
    '',
    '------------------------------',
    'المتبقي المطلوب: ${money(balance)}',
  ]);

  return lines.join('\\n');
}

// -----------------------------------------------------------------------------
// Models
// -----------------------------------------------------------------------------

class Customer {
  Customer({
    required this.id,
    required this.name,
    required this.phone,
    this.limitCents = 0,
  });

  String id;
  String name;
  String phone;
  int limitCents;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'limitCents': limitCents,
    };
  }

  factory Customer.fromJson(Map<String, dynamic> json) {
    final legacy = json['limit'];

    return Customer(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      phone: '${json['phone'] ?? ''}',
      limitCents: json['limitCents'] is num
          ? (json['limitCents'] as num).toInt()
          : legacy is num
              ? (legacy.toDouble() * 100).round()
              : 0,
    );
  }
}

class Tx {
  Tx({
    required this.id,
    required this.customerId,
    required this.type,
    required this.amountCents,
    required this.date,
    this.note = '',
  });

  String id;
  String customerId;
  String type;
  int amountCents;
  DateTime date;
  String note;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'customerId': customerId,
      'type': type,
      'amountCents': amountCents,
      'date': date.toIso8601String(),
      'note': note,
    };
  }

  factory Tx.fromJson(Map<String, dynamic> json) {
    final legacy = json['amount'];
    DateTime parsedDate;

    final rawDate = json['date'];

    if (rawDate is Timestamp) {
      parsedDate = rawDate.toDate();
    } else {
      parsedDate = DateTime.tryParse('${rawDate ?? ''}') ?? DateTime.now();
    }

    return Tx(
      id: '${json['id'] ?? ''}',
      customerId: '${json['customerId'] ?? ''}',
      type: json['type'] == 'payment' ? 'payment' : 'debt',
      amountCents: json['amountCents'] is num
          ? (json['amountCents'] as num).toInt()
          : legacy is num
              ? (legacy.toDouble() * 100).round()
              : 0,
      date: parsedDate,
      note: '${json['note'] ?? ''}',
    );
  }
}

class VoiceDraft {
  VoiceDraft({
    required this.id,
    required this.text,
    required this.date,
    required this.customerId,
    required this.amountCents,
    required this.note,
  });

  String id;
  String text;
  DateTime date;
  String customerId;
  int amountCents;
  String note;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'date': date.toIso8601String(),
      'customerId': customerId,
      'amountCents': amountCents,
      'note': note,
    };
  }

  factory VoiceDraft.fromJson(Map<String, dynamic> json) {
    final legacy = json['amount'];

    return VoiceDraft(
      id: '${json['id'] ?? ''}',
      text: '${json['text'] ?? ''}',
      date: DateTime.tryParse('${json['date'] ?? ''}') ?? DateTime.now(),
      customerId: '${json['customerId'] ?? ''}',
      amountCents: json['amountCents'] is num
          ? (json['amountCents'] as num).toInt()
          : legacy is num
              ? (legacy.toDouble() * 100).round()
              : 0,
      note: '${json['note'] ?? ''}',
    );
  }
}

// -----------------------------------------------------------------------------
// Store
// -----------------------------------------------------------------------------

class Store extends ChangeNotifier {
  late SharedPreferences prefs;

  final List<Customer> customers = [];
  final List<Tx> transactions = [];
  final List<VoiceDraft> voiceDrafts = [];

  String shop = appTitle;
  String whatsappMessage =
      'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ].';

  String uid = '';
  String deviceId = '';
  DateTime? trialStart;

  bool firebaseInitialized = false;
  bool firebaseReady = false;
  bool syncing = false;
  bool activated = false;
  bool dark = false;
  bool isAdmin = false;
  String ownerToken = '';

  final DainPayBackupService backupService = DainPayBackupService();
  String backupRecoveryCode = '';
  DateTime? lastBackupAt;
  DateTime? lastLocalBackupAt;
  String backupGoogleEmail = '';
  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();

  bool _disposed = false;
  bool _syncQueued = false;
  Future<void>? _syncFuture;

  static Future<Store> load() async {
    final store = Store();
    store.prefs = await SharedPreferences.getInstance();

    store.shop = store.prefs.getString('shop') ?? appTitle;
    store.whatsappMessage =
        store.prefs.getString('whatsappMessage') ?? store.whatsappMessage;
    store.dark = store.prefs.getBool('dark') ?? false;
    store.activated = store.prefs.getBool('activated') ?? false;
    store.deviceId = store.prefs.getString('device_id') ?? '';
    store.backupRecoveryCode =
        await store.secureStorage.read(key: 'dainpay_backup_recovery') ?? '';
    if (store.backupRecoveryCode.isEmpty) {
      final legacyRecovery = store.prefs.getString('backup_recovery_code');
      if (legacyRecovery != null && legacyRecovery.isNotEmpty) {
        store.backupRecoveryCode = legacyRecovery;
        await store.secureStorage.write(
          key: 'dainpay_backup_recovery',
          value: legacyRecovery,
        );
        await store.prefs.remove('backup_recovery_code');
      }
    }
    final lastBackup = store.prefs.getString('last_backup_at');
    store.lastBackupAt =
        lastBackup == null ? null : DateTime.tryParse(lastBackup);
    final lastLocal = store.prefs.getString('last_local_backup_at');
    store.lastLocalBackupAt =
        lastLocal == null ? null : DateTime.tryParse(lastLocal);
    store.backupGoogleEmail = store.prefs.getString('backup_google_email') ?? '';

    if (store.deviceId.isEmpty) {
      store.deviceId =
          'DP-${DateTime.now().millisecondsSinceEpoch}-${Random.secure().nextInt(1000000)}';
      await store
          ._pref(() => store.prefs.setString('device_id', store.deviceId));
    }

    final savedTrial = store.prefs.getString('trial_start');
    if (savedTrial == null) {
      store.trialStart = DateTime.now();
      await store._pref(
        () => store.prefs
            .setString('trial_start', store.trialStart!.toIso8601String()),
      );
    } else {
      store.trialStart = DateTime.tryParse(savedTrial);
      if (store.trialStart == null) {
        store.trialStart = DateTime.now();
        await store._pref(
          () => store.prefs
              .setString('trial_start', store.trialStart!.toIso8601String()),
        );
      }
    }

    store._loadList(
        'customers', (json) => store.customers.add(Customer.fromJson(json)));
    store._loadList(
        'transactions', (json) => store.transactions.add(Tx.fromJson(json)));
    store._loadList('voice_drafts',
        (json) => store.voiceDrafts.add(VoiceDraft.fromJson(json)));

    return store;
  }

  void _loadList(String key, void Function(Map<String, dynamic>) add) {
    try {
      final raw = jsonDecode(prefs.getString(key) ?? '[]');
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            add(Map<String, dynamic>.from(item));
          }
        }
      }
    } catch (e) {
      debugPrint('Local data read [$key]: $e');
    }
  }

  Future<void> _pref(Future<bool> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('SharedPreferences error: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    backupService.dispose();
    super.dispose();
  }

  void safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  int get trialDaysLeft {
    if (activated) return 0;
    final start = trialStart;
    if (start == null) return trialLengthDays;

    final elapsedDays = DateTime.now().difference(start).inDays;
    return max(0, trialLengthDays - elapsedDays);
  }

  bool get locked => !activated && trialDaysLeft <= 0;

  CollectionReference<Map<String, dynamic>> get userRef =>
      FirebaseFirestore.instance.collection('users');

  CollectionReference<Map<String, dynamic>> get activationCodesRef =>
      FirebaseFirestore.instance.collection('activation_codes');

  CollectionReference<Map<String, dynamic>> get customerRef =>
      userRef.doc(uid).collection('customers');

  CollectionReference<Map<String, dynamic>> get transactionRef =>
      userRef.doc(uid).collection('transactions');

  Future<void> connectFirebase() async {
    if (!firebaseInitialized) {
      firebaseReady = false;
      safeNotify();
      return;
    }

    try {
      User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        final credential = await FirebaseAuth.instance.signInAnonymously();
        user = credential.user;
      }

      if (user == null) {
        firebaseReady = false;
        safeNotify();
        return;
      }

      uid = user.uid;
      firebaseReady = true;

      // Load the cloud account state first. This prevents a reinstall/new local
      // trial_start from overwriting the original trial start date.
      await loadAccountState();

      if (trialStart == null) {
        trialStart = DateTime.now();
        await _pref(() => prefs.setString(
              'trial_start',
              trialStart!.toIso8601String(),
            ));
        await userRef.doc(uid).set({
          'trialStart': Timestamp.fromDate(trialStart!),
          'activated': activated,
        }, SetOptions(merge: true));
      }

      await pullCloud();

      safeNotify();
    } catch (e, stack) {
      firebaseReady = false;
      debugPrint('Firebase connection error: $e');
      debugPrintStack(stackTrace: stack);
      safeNotify();
    }
  }

  Future<void> loadAccountState() async {
    if (!firebaseReady || uid.isEmpty) return;

    try {
      final ref = userRef.doc(uid);
      final snap = await ref.get();
      final data = snap.data() ?? <String, dynamic>{};

      if (data['trialStart'] is Timestamp) {
        trialStart = (data['trialStart'] as Timestamp).toDate();
        await _pref(() => prefs.setString(
              'trial_start',
              trialStart!.toIso8601String(),
            ));
      } else if (trialStart != null) {
        await ref.set({
          'trialStart': Timestamp.fromDate(trialStart!),
          'activated': activated,
        }, SetOptions(merge: true));
      }

      if (data['activated'] == true) {
        activated = true;
        await _pref(() => prefs.setBool('activated', true));
      }
    } catch (e) {
      debugPrint('Account state error: $e');
    }
  }

  Future<void> loadActivation() => loadAccountState();

  Future<void> pullCloud() async {
    if (!firebaseReady || uid.isEmpty) return;

    try {
      final customerDocs = await customerRef.get();
      final txDocs = await transactionRef.get();

      for (final doc in customerDocs.docs) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] ??= doc.id;
        final item = Customer.fromJson(data);
        final index = customers.indexWhere((c) => c.id == item.id);
        if (index == -1) {
          customers.add(item);
        } else {
          customers[index] = item;
        }
      }

      for (final doc in txDocs.docs) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] ??= doc.id;

        final rawDate = data['date'];
        if (rawDate is Timestamp) {
          data['date'] = rawDate.toDate().toIso8601String();
        }

        final item = Tx.fromJson(data);
        final index = transactions.indexWhere((t) => t.id == item.id);
        if (index == -1) {
          transactions.add(item);
        } else {
          transactions[index] = item;
        }
      }

      await saveLocal();
      safeNotify();
    } catch (e) {
      debugPrint('Cloud pull error: $e');
    }
  }

  Future<void> saveLocal() async {
    await _pref(() => prefs.setString(
        'customers', jsonEncode(customers.map((e) => e.toJson()).toList())));
    await _pref(() => prefs.setString('transactions',
        jsonEncode(transactions.map((e) => e.toJson()).toList())));
    await _pref(() => prefs.setString('voice_drafts',
        jsonEncode(voiceDrafts.map((e) => e.toJson()).toList())));
    await _pref(() => prefs.setString('shop', shop));
    await _pref(() => prefs.setString('whatsappMessage', whatsappMessage));
    await _pref(() => prefs.setBool('dark', dark));
    await _pref(() => prefs.setBool('activated', activated));

    // Redundant encrypted local snapshot. This runs on every local save so
    // a damaged SharedPreferences record does not destroy the only copy.
    try {
      final recovery = await ensureBackupRecoveryCode();
      final ok = await backupService.saveLocal(
        payload: backupPayload(),
        recoveryCode: recovery,
      );
      if (ok) {
        lastLocalBackupAt = DateTime.now();
        await _pref(() => prefs.setString(
              'last_local_backup_at',
              lastLocalBackupAt!.toIso8601String(),
            ));
      }
    } catch (e) {
      debugPrint('Automatic local backup error: $e');
    }
  }

  Future<void> save() async {
    await saveLocal();
    safeNotify();
    await syncAll();
  }

  Future<bool> saveCustomer(Customer customer) async {
    final normalizedName = customer.name.trim().toLowerCase();
    final normalizedPhone = phone218(customer.phone);

    final duplicate = customers.any((existing) {
      final sameName = existing.name.trim().toLowerCase() == normalizedName;
      final existingPhone = phone218(existing.phone);
      final samePhone = normalizedPhone.isNotEmpty &&
          existingPhone.isNotEmpty &&
          normalizedPhone == existingPhone;
      return sameName && samePhone;
    });

    if (duplicate) return false;

    customer.phone = customer.phone.trim();
    customers.add(customer);
    await save();
    return true;
  }

  Future<bool> saveTx(Tx transaction) async {
    if (transaction.amountCents <= 0) return false;
    if (transaction.type != 'debt' && transaction.type != 'payment')
      return false;

    transactions.add(transaction);
    await save();
    return true;
  }

  Future<bool> deleteCustomer(Customer customer) async {
    if (balance(customer.id) != 0) return false;
    if (!firebaseReady || uid.isEmpty) return false;

    try {
      final txSnap = await transactionRef
          .where('customerId', isEqualTo: customer.id)
          .get();
      var cloudBalance = 0;
      for (final doc in txSnap.docs) {
        final data = doc.data();
        final type = '${data['type'] ?? ''}';
        final raw = data['amountCents'];
        final amount = raw is num
            ? raw.toInt()
            : data['amount'] is num
                ? ((data['amount'] as num).toDouble() * 100).round()
                : 0;
        cloudBalance += type == 'debt' ? amount : -amount;
      }
      if (cloudBalance != 0) return false;

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in txSnap.docs) {
        batch.delete(doc.reference);
      }
      batch.delete(customerRef.doc(customer.id));
      await batch.commit();

      transactions.removeWhere((tx) => tx.customerId == customer.id);
      customers.removeWhere((item) => item.id == customer.id);
      await saveLocal();
      safeNotify();
      return true;
    } catch (e) {
      debugPrint('Delete customer error: $e');
      return false;
    }
  }

  Future<void> deleteVoiceDraft(String id) async {
    voiceDrafts.removeWhere((draft) => draft.id == id);
    await saveLocal();
    safeNotify();
  }

  Future<String> ensureBackupRecoveryCode() async {
    if (backupRecoveryCode.trim().isEmpty) {
      backupRecoveryCode = backupService.generateRecoveryCode();
      await secureStorage.write(
        key: 'dainpay_backup_recovery',
        value: backupRecoveryCode,
      );
    }
    return backupRecoveryCode;
  }

  Map<String, dynamic> backupPayload() {
    return {
      'schema': 1,
      'app': 'DainPay',
      'shop': shop,
      'whatsappMessage': whatsappMessage,
      'dark': dark,
      'activated': activated,
      'trialStart': trialStart?.toIso8601String(),
      'customers': customers.map((e) => e.toJson()).toList(),
      'transactions': transactions.map((e) => e.toJson()).toList(),
      'voiceDrafts': voiceDrafts.map((e) => e.toJson()).toList(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<DainPayBackupResult> backupToGoogleDrive() async {
    final recovery = await ensureBackupRecoveryCode();
    final result = await backupService.backup(
      payload: backupPayload(),
      recoveryCode: recovery,
    );

    if (result.localSaved) {
      lastLocalBackupAt = DateTime.now();
      await _pref(() => prefs.setString(
            'last_local_backup_at',
            lastLocalBackupAt!.toIso8601String(),
          ));
    }
    if (result.cloudSaved) {
      lastBackupAt = DateTime.now();
      await _pref(() => prefs.setString(
            'last_backup_at',
            lastBackupAt!.toIso8601String(),
          ));
      backupGoogleEmail = result.accountEmail ?? '';
      if (backupGoogleEmail.isNotEmpty) {
        await _pref(() => prefs.setString(
              'backup_google_email',
              backupGoogleEmail,
            ));
      }
    }

    safeNotify();
    return result;
  }

  Future<DainPayBackupResult> restoreFromGoogleDrive(
      String recoveryCode) async {
    try {
      final payload = await backupService.restore(
        recoveryCode: recoveryCode,
      );
      return _applyBackupPayload(payload);
    } catch (e) {
      return DainPayBackupResult(
        success: false,
        message: 'تعذر استعادة النسخة: $e',
      );
    }
  }

  Future<DainPayBackupResult> restoreFromLocalBackup(
      String recoveryCode) async {
    try {
      final payload = await backupService.restoreLocal(recoveryCode);
      return _applyBackupPayload(payload);
    } catch (e) {
      return DainPayBackupResult(
        success: false,
        message: 'تعذر استعادة النسخة المحلية: $e',
      );
    }
  }

  Future<DainPayBackupResult> _applyBackupPayload(
      Map<String, dynamic> payload) async {
    if (payload['schema'] != 1 && payload['schema'] != 2 ||
        payload['app'] != 'DainPay') {
      return const DainPayBackupResult(
        success: false,
        message: 'ملف النسخة الاحتياطية غير صالح',
      );
    }

    final rawCustomers = payload['customers'];
    final rawTransactions = payload['transactions'];
    final rawDrafts = payload['voiceDrafts'];

    if (rawCustomers is! List ||
        rawTransactions is! List ||
        rawDrafts is! List) {
      return const DainPayBackupResult(
        success: false,
        message: 'النسخة الاحتياطية ناقصة أو تالفة',
      );
    }

    final restoredCustomers = <Customer>[];
    for (final item in rawCustomers) {
      if (item is Map) {
        restoredCustomers.add(
          Customer.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }

    final restoredTransactions = <Tx>[];
    for (final item in rawTransactions) {
      if (item is Map) {
        restoredTransactions.add(
          Tx.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }

    final restoredDrafts = <VoiceDraft>[];
    for (final item in rawDrafts) {
      if (item is Map) {
        restoredDrafts.add(
          VoiceDraft.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }

    customers
      ..clear()
      ..addAll(restoredCustomers);
    transactions
      ..clear()
      ..addAll(restoredTransactions);
    voiceDrafts
      ..clear()
      ..addAll(restoredDrafts);

    shop = '${payload['shop'] ?? shop}'.trim().isEmpty
        ? shop
        : '${payload['shop']}'.trim();
    whatsappMessage = '${payload['whatsappMessage'] ?? whatsappMessage}';
    dark = payload['dark'] == true;
    activated = payload['activated'] == true;
    trialStart =
        DateTime.tryParse('${payload['trialStart'] ?? ''}') ?? trialStart;

    await saveLocal();
    safeNotify();

    return const DainPayBackupResult(
      success: true,
      message: 'تمت استعادة بيانات DainPay بنجاح',
    );
  }

  Future<void> changeGoogleBackupAccount() async {
    await backupService.changeGoogleAccount();
    backupGoogleEmail = '';
    await _pref(() => prefs.remove('backup_google_email'));
    safeNotify();
  }

  Future<void> syncAll() async {
    if (!firebaseReady || uid.isEmpty) return;

    final running = _syncFuture;
    if (running != null) {
      _syncQueued = true;
      await running;
      return;
    }

    final future = _performSync();
    _syncFuture = future;

    try {
      await future;
    } finally {
      if (identical(_syncFuture, future)) {
        _syncFuture = null;
      }
    }

    if (_syncQueued) {
      _syncQueued = false;
      await syncAll();
    }
  }

  Future<void> _performSync() async {
    syncing = true;
    safeNotify();

    try {
      final firestore = FirebaseFirestore.instance;
      final customerList = List<Customer>.from(customers);
      final transactionList = List<Tx>.from(transactions);
      final operations = <void Function(WriteBatch)>[];

      for (final customer in customerList) {
        operations.add((batch) {
          batch.set(customerRef.doc(customer.id), customer.toJson(),
              SetOptions(merge: true));
        });
      }

      for (final transaction in transactionList) {
        operations.add((batch) {
          batch.set(
            transactionRef.doc(transaction.id),
            {
              ...transaction.toJson(),
              'date': Timestamp.fromDate(transaction.date),
            },
            SetOptions(merge: true),
          );
        });
      }

      const chunkSize = 450;
      for (var start = 0; start < operations.length; start += chunkSize) {
        final end = min(start + chunkSize, operations.length);
        final batch = firestore.batch();
        for (var i = start; i < end; i++) {
          operations[i](batch);
        }
        await batch.commit();
      }
    } catch (e) {
      debugPrint('Cloud sync error: $e');
    } finally {
      syncing = false;
      safeNotify();
    }
  }

  int balance(String customerId) {
    return transactions.where((t) => t.customerId == customerId).fold<int>(0,
        (sum, t) => sum + (t.type == 'debt' ? t.amountCents : -t.amountCents));
  }

  int debts(String customerId) {
    return transactions
        .where((t) => t.customerId == customerId && t.type == 'debt')
        .fold<int>(0, (sum, t) => sum + t.amountCents);
  }

  int paid(String customerId) {
    return transactions
        .where((t) => t.customerId == customerId && t.type == 'payment')
        .fold<int>(0, (sum, t) => sum + t.amountCents);
  }

  String risk(String customerId) {
    final current = balance(customerId);
    if (current <= 0) return 'مسدد';

    final debtsForCustomer = transactions
        .where((t) => t.customerId == customerId && t.type == 'debt')
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    if (debtsForCustomer.isEmpty) return 'حديث';

    final days = DateTime.now().difference(debtsForCustomer.first.date).inDays;
    if (days > 90) return 'خطر';
    if (days > 30) return 'متأخر';
    return 'حديث';
  }

  Future<bool> activateCode(String code) async {
    final cleanCode = _digits(code).trim().replaceAll(RegExp(r'\\s+'), '');
    if (cleanCode.isEmpty) return false;
    try {
      final response = await http.post(Uri.parse(cloudflareActivationUrl), headers: const {'content-type':'application/json'}, body: jsonEncode({'action':'redeem','code':cleanCode,'deviceId':deviceId})).timeout(const Duration(seconds:15));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body);
      if (data is! Map || data['success'] != true) return false;
      activated = true; await saveLocal();
      if (firebaseReady && uid.isNotEmpty) { try { await userRef.doc(uid).set({'activated':true,'activatedAt':FieldValue.serverTimestamp(),'activatedDeviceId':deviceId},SetOptions(merge:true)); } catch(e){debugPrint('Activation cloud mirror failed: $e');} }
      safeNotify(); return true;
    } catch(e){debugPrint('Cloudflare activation error: $e');return false;}
  }
  Future<bool> loginOwner(String pin) async {
    try {
      final response=await http.post(Uri.parse(cloudflareActivationUrl),headers:const {'content-type':'application/json'},body:jsonEncode({'action':'owner_login','adminPin':_digits(pin).trim()})).timeout(const Duration(seconds:15));
      if(response.statusCode!=200)return false; final data=jsonDecode(response.body);
      if(data is! Map||data['success']!=true||data['token'] is! String)return false;
      ownerToken=data['token'] as String;isAdmin=true;safeNotify();return true;
    }catch(e){debugPrint('Cloudflare owner login error: $e');return false;}
  }
  Future<String?> generateCode() async {
    if(!isAdmin||ownerToken.isEmpty)throw StateError('جلسة المالك غير صالحة. سجّل الدخول مجدداً.');
    final response=await http.post(Uri.parse(cloudflareActivationUrl),headers:const {'content-type':'application/json'},body:jsonEncode({'action':'generate','ownerToken':ownerToken})).timeout(const Duration(seconds:15));
    final data=jsonDecode(response.body);
    if(response.statusCode!=200||data is! Map||data['success']!=true||data['code'] is! String){final message=data is Map?(data['error']??'تعذر توليد الرمز'):'استجابة غير صالحة';throw StateError('$message');}
    return data['code'] as String;
  }

}

// -----------------------------------------------------------------------------
// Application
// -----------------------------------------------------------------------------

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store});

  final Store store;

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: emerald,
      brightness: brightness,
    ).copyWith(
      primary: emerald,
      secondary: mint,
      error: burgundy,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Cairo',
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xFFF6F9FA)
          : const Color(0xFF101719),
      appBarTheme: const AppBarTheme(centerTitle: true),
      cardTheme: CardTheme(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 1,
        margin: const EdgeInsets.symmetric(vertical: 5),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        filled: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: appTitle,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: store.dark ? ThemeMode.dark : ThemeMode.light,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: HomePage(store: store),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Logo & Home Component
// -----------------------------------------------------------------------------

class Logo extends StatelessWidget {
  const Logo({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [emerald, mint]),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
              blurRadius: 8, offset: Offset(0, 3), color: Color(0x22000000)),
        ],
      ),
      child: const Text(
        'DP',
        style: TextStyle(
            color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});

  final Store store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String query = '';
  // جعل التصفية الافتراضية 'debt' لإخفاء العملاء المسددين تلقائياً عند فتح القائمة
  String filter = 'debt';

  int taps = 0;
  DateTime? lastTap;

  void hiddenAdmin() {
    final now = DateTime.now();

    // Exactly three consecutive rapid taps. A pause of more than 700 ms
    // breaks the sequence, so three taps spread over seconds cannot unlock it.
    if (lastTap == null ||
        now.difference(lastTap!).inMilliseconds > 700) {
      taps = 0;
    }

    lastTap = now;
    taps++;

    if (taps == 3) {
      taps = 0;
      lastTap = null;
      showDialog(
        context: context,
        builder: (_) => AdminGate(store: widget.store),
      );
    }
  }

  Future<void> refresh() async {
    await widget.store.pullCloud();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    final filtered = store.customers.where((customer) {
      final balance = store.balance(customer.id);
      final normalizedQuery = _digits(query);

      final matchesSearch = query.isEmpty ||
          customer.name.contains(query) ||
          customer.phone.contains(query) ||
          _digits(customer.phone).contains(normalizedQuery);

      final matchesFilter = filter == 'all' ||
          (filter == 'debt' && balance > 0) ||
          (filter == 'paid' && balance <= 0);

      return matchesSearch && matchesFilter;
    }).toList()
      ..sort((a, b) => store.balance(b.id).compareTo(store.balance(a.id)));

    final total = store.customers.fold<int>(
      0,
      (sum, customer) => sum + max(0, store.balance(customer.id)),
    );

    return Scaffold(
      appBar: AppBar(
        leading: const Padding(padding: EdgeInsets.all(8), child: Logo()),
        title: GestureDetector(
          onTap: hiddenAdmin,
          child: Text(store.shop,
              style: const TextStyle(fontWeight: FontWeight.w900)),
        ),
        actions: [
          IconButton(
            tooltip: 'المسودات الصوتية',
            icon: const Icon(Icons.mic_rounded, color: emerald),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => VoiceDraftsPage(store: store)),
              );
            },
          ),
          if (store.syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsPage(store: store)),
              );
            },
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (!store.firebaseReady)
              Card(
                color: burgundy.withOpacity(.10),
                child: ListTile(
                  leading: const Icon(Icons.cloud_off, color: burgundy),
                  title: const Text('Firebase غير متصل'),
                  subtitle: const Text(
                      'البيانات المحلية ما زالت تعمل، وستتم المزامنة عند توفر الخدمة.'),
                  trailing: IconButton(
                    onPressed: store.connectFirebase,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ),
            if (!store.activated)
              Card(
                color: emerald.withOpacity(.08),
                child: ListTile(
                  leading: const Icon(Icons.timer_outlined, color: emerald),
                  title: Text(
                    store.locked
                        ? 'انتهت الفترة التجريبية'
                        : 'الفترة التجريبية: ${store.trialDaysLeft} يوم',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    store.locked
                        ? 'فعّل التطبيق لمواصلة تسجيل العمليات.'
                        : 'يمكنك تفعيل التطبيق في أي وقت برمز تفعيل دائم.',
                  ),
                  trailing: TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ActivationPage(store: store),
                        ),
                      );
                    },
                    child: Text(store.locked ? 'تفعيل' : 'عرض'),
                  ),
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: _Stat(
                          title: 'إجمالي المتبقي',
                          value: money(total),
                          color: burgundy),
                    ),
                    Expanded(
                      child: _Stat(
                          title: 'العملاء عليهم دَين',
                          value: '${filtered.length}',
                          color: emerald),
                    ),
                  ],
                ),
              ),
            ),
            if (store.locked)
              Card(
                color: burgundy.withOpacity(.10),
                child: ListTile(
                  leading: const Icon(Icons.lock_outline, color: burgundy),
                  title: const Text('انتهت التجربة',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('فعّل التطبيق لمواصلة تسجيل العمليات.'),
                  trailing: TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ActivationPage(store: store)),
                      );
                    },
                    child: const Text('تفعيل'),
                  ),
                ),
              ),
            TextField(
              decoration: const InputDecoration(
                hintText: 'بحث بالاسم أو الهاتف',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value.trim()),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('عليهم دَين'),
                  selected: filter == 'debt',
                  onSelected: (_) => setState(() => filter = 'debt'),
                ),
                ChoiceChip(
                  label: const Text('مسدد'),
                  selected: filter == 'paid',
                  onSelected: (_) => setState(() => filter = 'paid'),
                ),
                ChoiceChip(
                  label: const Text('الكل'),
                  selected: filter == 'all',
                  onSelected: (_) => setState(() => filter = 'all'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (filtered.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('لا توجد نتائج')),
                ),
              ),
            ...filtered.map((customer) {
              final customerBalance = store.balance(customer.id);
              return Card(
                child: ListTile(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            CustomerPage(store: store, customer: customer),
                      ),
                    );
                  },
                  leading: CircleAvatar(
                    child: Text(
                      customer.name.trim().isEmpty
                          ? '؟'
                          : customer.name.trim().characters.first,
                    ),
                  ),
                  title: Text(customer.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    '${customer.phone}\n'
                    '${store.risk(customer.id)} • '
                    'دَين ${money(store.debts(customer.id))} • '
                    'مسدد ${money(store.paid(customer.id))}',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    money(customerBalance),
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: customerBalance > 0 ? burgundy : mint,
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: store.locked
            ? () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ActivationPage(store: store)),
                );
              }
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => AddCustomerPage(store: store)),
                );
              },
        icon: Icon(store.locked ? Icons.lock : Icons.person_add_alt_1),
        label: Text(store.locked ? 'التفعيل' : 'عميل جديد'),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.title, required this.value, required this.color});

  final String title;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(title),
        Text(
          value,
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w900, color: color),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Form, Customer, Transactions, Voice & Admin Pages
// -----------------------------------------------------------------------------

class PageForm extends StatelessWidget {
  const PageForm({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: children
            .map((widget) => Padding(
                padding: const EdgeInsets.only(bottom: 12), child: widget))
            .toList(),
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
    if (busy) return;

    final customerName = name.text.trim();
    if (customerName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل اسم العميل')),
      );
      return;
    }

    setState(() => busy = true);

    final ok = await widget.store.saveCustomer(
      Customer(
        id: makeId(),
        name: customerName,
        phone: phone.text.trim(),
        limitCents: parseCents(limit.text),
      ),
    );

    if (!mounted) return;
    setState(() => busy = false);

    if (ok) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('العميل موجود مسبقاً بنفس الاسم والهاتف')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageForm(
      title: 'إضافة عميل',
      children: [
        TextField(
          controller: name,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'اسم العميل'),
        ),
        TextField(
          controller: phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'رقم الهاتف'),
        ),
        TextField(
          controller: limit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration:
              const InputDecoration(labelText: 'السقف الائتماني اختياري'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? 'جارٍ الحفظ...' : 'حفظ العميل'),
        ),
      ],
    );
  }
}

class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer});

  final Store store;
  final Customer customer;

  Future<void> openWhatsApp(BuildContext context) async {
    final text = store.whatsappMessage
        .replaceAll('[الاسم]', customer.name)
        .replaceAll('[المبلغ]', money(store.balance(customer.id)));

    final ok = await launchWhatsApp(customer.phone, text);

    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب')),
      );
    }
  }

  Future<void> deleteCustomer(BuildContext context) async {
    final balance = store.balance(customer.id);
    if (balance != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('لا يمكن حذف العميل. المتبقي عليه ${money(balance)}')),
      );
      return;
    }
    if (!store.firebaseReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'الحذف الآمن يحتاج اتصالاً بالإنترنت للتحقق من الرصيد السحابي.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف العميل؟'),
        content: const Text(
            'سيتم حذف العميل وجميع عملياته بعد التحقق من أن الرصيد السحابي يساوي صفرًا.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: burgundy),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف نهائي'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final ok = await store.deleteCustomer(customer);
    if (!context.mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('تم رفض الحذف: الرصيد السحابي ليس صفراً أو تعذر التحقق.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = store.transactions
        .where((t) => t.customerId == customer.id)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      appBar: AppBar(title: Text(customer.name)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  const Icon(Icons.account_balance_wallet_rounded,
                      size: 36, color: emerald),
                  Text(
                    money(store.balance(customer.id)),
                    style: const TextStyle(
                        fontSize: 30, fontWeight: FontWeight.w900),
                  ),
                  Text(
                    'الدَين ${money(store.debts(customer.id))} • '
                    'المسدد ${money(store.paid(customer.id))}',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => openWhatsApp(context),
                        icon: const Icon(Icons.chat_rounded),
                        label: const Text('واتساب'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AccountStatementPage(
                                store: store,
                                customer: customer,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.receipt_long_rounded),
                        label: const Text('كشف الحساب'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final ok = await makePhoneCall(customer.phone);
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('تعذر إجراء الاتصال')),
                            );
                          }
                        },
                        icon: const Icon(Icons.phone_rounded),
                        label: const Text('اتصال'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => deleteCustomer(context),
                        icon: const Icon(Icons.delete_forever_rounded,
                            color: burgundy),
                        label: const Text('حذف العميل'),
                        style:
                            OutlinedButton.styleFrom(foregroundColor: burgundy),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (rows.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('لا توجد عمليات بعد')),
              ),
            ),
          ...rows.map(
            (transaction) => Card(
              child: ListTile(
                leading: Icon(
                  transaction.type == 'debt'
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                  color: transaction.type == 'debt' ? burgundy : mint,
                ),
                title: Text(transaction.type == 'debt' ? 'دَين' : 'تسديد'),
                subtitle: Text(
                  '${dateText(transaction.date)} ${timeText(transaction.date)}'
                  '${transaction.note.isEmpty ? '' : ' • ${transaction.note}'}',
                ),
                trailing: Text(
                  money(transaction.amountCents),
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: transaction.type == 'debt' ? burgundy : mint,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: store.locked
            ? () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ActivationPage(store: store)),
                );
              }
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        AddTransactionPage(store: store, customer: customer),
                  ),
                );
              },
        icon: Icon(store.locked ? Icons.lock : Icons.swap_horiz_rounded),
        label: Text(store.locked ? 'التفعيل' : 'عملية جديدة'),
      ),
    );
  }
}

class AccountStatementPage extends StatelessWidget {
  const AccountStatementPage({
    super.key,
    required this.store,
    required this.customer,
  });

  final Store store;
  final Customer customer;

  Future<void> copyStatement(BuildContext context) async {
    final text = buildAccountStatement(store, customer);
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم نسخ كشف الحساب')),
      );
    }
  }

  Future<void> sendStatement(BuildContext context) async {
    final text = buildAccountStatement(store, customer);
    final ok = await launchWhatsApp(customer.phone, text);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final statement = buildAccountStatement(store, customer);

    return Scaffold(
      appBar: AppBar(
        title: const Text('كشف الحساب'),
        actions: [
          IconButton(
            tooltip: 'نسخ الكشف',
            onPressed: () => copyStatement(context),
            icon: const Icon(Icons.copy_all_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                statement,
                textDirection: TextDirection.rtl,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.7,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => sendStatement(context),
            icon: const Icon(Icons.send_rounded),
            label: const Text('إرسال الكشف للزبون عبر واتساب'),
          ),
          OutlinedButton.icon(
            onPressed: () => copyStatement(context),
            icon: const Icon(Icons.content_copy_rounded),
            label: const Text('نسخ كشف الحساب'),
          ),
        ],
      ),
    );
  }
}

class AddTransactionPage extends StatefulWidget {
  const AddTransactionPage(
      {super.key, required this.store, required this.customer});

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

  Future<void> save() async {
    if (busy) return;

    final cents = parseCents(amount.text);
    final current = widget.store.balance(widget.customer.id);

    if (cents <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل مبلغاً صحيحاً أكبر من صفر')),
      );
      return;
    }

    if (type == 'payment' && cents > current) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('قيمة التسديد أكبر من المتبقي على العميل')),
      );
      return;
    }

    if (type == 'debt' &&
        widget.customer.limitCents > 0 &&
        current + cents > widget.customer.limitCents) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('العملية تتجاوز السقف الائتماني')),
      );
      return;
    }

    setState(() => busy = true);

    final saved = await widget.store.saveTx(
      Tx(
        id: makeId(),
        customerId: widget.customer.id,
        type: type,
        amountCents: cents,
        date: DateTime.now(),
        note: note.text.trim(),
      ),
    );

    if (!mounted) return;
    setState(() => busy = false);

    if (saved) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageForm(
      title: type == 'debt' ? 'إضافة دَين' : 'تسجيل تسديد',
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
                value: 'debt',
                label: Text('دَين'),
                icon: Icon(Icons.arrow_downward)),
            ButtonSegment(
                value: 'payment',
                label: Text('تسديد'),
                icon: Icon(Icons.arrow_upward)),
          ],
          selected: {type},
          onSelectionChanged: (values) {
            if (values.isEmpty) return;
            setState(() => type = values.first);
          },
        ),
        TextField(
          controller: amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
              labelText: 'المبلغ', hintText: 'مثال: 150 أو 150.50'),
        ),
        TextField(
          controller: note,
          decoration: const InputDecoration(labelText: 'البيان / الملاحظات'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? 'جارٍ الحفظ...' : 'حفظ العملية'),
        ),
      ],
    );
  }
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
  bool initializing = false;
  String live = '';

  int? amountCentsFromText(String text) {
    final normalized = _digits(text);
    final match = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(normalized);

    if (match != null) {
      return parseCents(match.group(1)!);
    }

    const words = {
      'مائة': 100,
      'مئة': 100,
      'مية': 100,
      'ألف': 1000,
      'الف': 1000,
      'عشرة': 10,
      'عشرين': 20,
      'ثلاثين': 30,
      'أربعين': 40,
      'خمسين': 50,
      'ستين': 60,
      'سبعين': 70,
      'ثمانين': 80,
      'تسعين': 90,
    };

    for (final entry in words.entries) {
      if (text.contains(entry.key)) {
        return entry.value * 100;
      }
    }

    return null;
  }

  String findCustomer(String text) {
    for (final customer in widget.store.customers) {
      if (text.contains(customer.name)) {
        return customer.id;
      }
    }
    return '';
  }

  Future<void> record() async {
    if (initializing) return;

    if (listening) {
      try {
        await speech.stop();
      } catch (_) {}
      if (mounted) setState(() => listening = false);
      return;
    }

    initializing = true;

    try {
      final available = await speech.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'notListening' || status == 'done') {
            setState(() => listening = false);
          }
        },
        onError: (error) {
          debugPrint('Speech error: $error');
          if (!mounted) return;
          setState(() => listening = false);
        },
      );

      if (!available) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'التعرف الصوتي غير متاح أو لا توجد صلاحية للميكروفون')),
          );
        }
        return;
      }

      if (!mounted) return;
      setState(() => listening = true);

      await speech.listen(
        localeId: 'ar-LY',
        onResult: (result) async {
          if (!mounted) return;
          setState(() => live = result.recognizedWords);

          if (!result.finalResult) return;

          final text = result.recognizedWords.trim();
          if (text.isNotEmpty) {
            widget.store.voiceDrafts.insert(
              0,
              VoiceDraft(
                id: makeId(),
                text: text,
                date: DateTime.now(),
                customerId: findCustomer(text),
                amountCents: amountCentsFromText(text) ?? 0,
                note: text,
              ),
            );
            await widget.store.saveLocal();
            widget.store.safeNotify();
          }

          if (mounted) setState(() => listening = false);
        },
      );
    } catch (e) {
      debugPrint('Speech start error: $e');
      if (mounted) {
        setState(() => listening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر تشغيل التسجيل الصوتي')),
        );
      }
    } finally {
      initializing = false;
    }
  }

  @override
  void dispose() {
    try {
      speech.stop();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final drafts = widget.store.voiceDrafts;

    return Scaffold(
      appBar: AppBar(title: const Text('المسودات الصوتية')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              onTap: record,
              leading: Icon(
                listening ? Icons.stop_circle : Icons.mic_rounded,
                color: listening ? burgundy : emerald,
              ),
              title: Text(listening ? 'جارٍ الاستماع...' : 'تسجيل عملية صوتية'),
              subtitle: Text(live.isEmpty ? 'مثال: محمد 150 بضاعة' : live),
            ),
          ),
          if (drafts.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('لا توجد مسودات صوتية')),
              ),
            ),
          ...drafts.map((draft) {
            final customer = widget.store.customers
                .where((c) => c.id == draft.customerId)
                .firstOrNull;
            return Dismissible(
              key: Key(draft.id),
              direction: DismissDirection.endToStart,
              background: Container(
                color: burgundy,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: const Icon(Icons.delete_forever, color: Colors.white),
              ),
              onDismissed: (_) async {
                await widget.store.deleteVoiceDraft(draft.id);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تم حذف المسودة الصوتية')),
                );
              },
              child: Card(
                child: ListTile(
                  title: Text(customer?.name ?? 'عميل غير محدد'),
                  subtitle: Text(
                      '${draft.text}\nالمبلغ: ${money(draft.amountCents)}'),
                  isThreeLine: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: burgundy),
                    onPressed: () async {
                      await widget.store.deleteVoiceDraft(draft.id);
                      setState(() {});
                    },
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            VoiceReviewPage(store: widget.store, draft: draft),
                      ),
                    );
                  },
                ),
              ),
            );
          }),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: record,
        child: Icon(listening ? Icons.stop : Icons.mic),
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
  late final TextEditingController amount;
  late final TextEditingController note;
  String customerId = '';
  String type = 'debt';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    amount = TextEditingController(
      text: widget.draft.amountCents > 0
          ? '${widget.draft.amountCents ~/ 100}.${(widget.draft.amountCents % 100).toString().padLeft(2, '0')}'
          : '',
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

    final cents = parseCents(amount.text);
    final customer =
        widget.store.customers.where((c) => c.id == customerId).firstOrNull;

    if (customer == null || cents <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر العميل وأدخل مبلغاً صحيحاً')),
      );
      return;
    }

    final current = widget.store.balance(customer.id);

    if (type == 'payment' && cents > current) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('قيمة التسديد أكبر من المتبقي')),
      );
      return;
    }

    if (type == 'debt' &&
        customer.limitCents > 0 &&
        current + cents > customer.limitCents) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('العملية تتجاوز السقف الائتماني')),
      );
      return;
    }

    setState(() => busy = true);

    final saved = await widget.store.saveTx(
      Tx(
        id: makeId(),
        customerId: customer.id,
        type: type,
        amountCents: cents,
        date: DateTime.now(),
        note: note.text.trim(),
      ),
    );

    if (!saved) {
      if (mounted) setState(() => busy = false);
      return;
    }

    widget.store.voiceDrafts
        .removeWhere((draft) => draft.id == widget.draft.id);
    await widget.store.saveLocal();

    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final validId = widget.store.customers.any((c) => c.id == customerId)
        ? customerId
        : null;

    return PageForm(
      title: 'مراجعة التسجيل الصوتي',
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              widget.draft.text,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
        DropdownButtonFormField<String>(
          value: validId,
          decoration: const InputDecoration(labelText: 'العميل'),
          items: widget.store.customers
              .map((customer) => DropdownMenuItem(
                  value: customer.id, child: Text(customer.name)))
              .toList(),
          onChanged: (value) => setState(() => customerId = value ?? ''),
        ),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'debt', label: Text('دَين')),
            ButtonSegment(value: 'payment', label: Text('تسديد')),
          ],
          selected: {type},
          onSelectionChanged: (values) {
            if (values.isEmpty) return;
            setState(() => type = values.first);
          },
        ),
        TextField(
          controller: amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'المبلغ'),
        ),
        TextField(
          controller: note,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'البيان'),
        ),
        FilledButton(
          onPressed: busy ? null : approve,
          child: Text(busy ? 'جارٍ الاعتماد...' : 'اعتماد وحفظ'),
        ),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});

  final Store store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController shop;
  late final TextEditingController message;
  bool saving = false;

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

  Future<void> save() async {
    if (saving) return;

    setState(() => saving = true);

    widget.store.shop = shop.text.trim().isEmpty ? appTitle : shop.text.trim();
    widget.store.whatsappMessage = message.text.trim().isEmpty
        ? 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ].'
        : message.text.trim();

    await widget.store.save();

    if (!mounted) return;
    setState(() => saving = false);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حفظ الإعدادات')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: shop,
            decoration: const InputDecoration(labelText: 'اسم المحل / النشاط'),
          ),
          SwitchListTile(
            value: store.dark,
            onChanged: (value) async {
              setState(() => store.dark = value);
              await store.saveLocal();
              store.safeNotify();
            },
            title: const Text('الوضع الداكن'),
          ),
          TextField(
            controller: message,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'قالب رسالة واتساب',
              helperText: 'يمكنك استخدام [الاسم] و [المبلغ]',
            ),
          ),
          ListTile(
            title: const Text('رقم الجهاز'),
            subtitle: SelectableText(store.deviceId),
          ),
          ListTile(
            title: const Text('حالة Firebase'),
            subtitle: Text(store.firebaseReady ? 'متصل' : 'غير متصل'),
            trailing: Icon(
              store.firebaseReady ? Icons.cloud_done : Icons.cloud_off,
              color: store.firebaseReady ? mint : burgundy,
            ),
          ),
          FilledButton(
            onPressed: saving ? null : save,
            child: Text(saving ? 'جارٍ الحفظ...' : 'حفظ'),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => VoiceDraftsPage(store: store)),
              );
            },
            child: const Text('المسودات الصوتية'),
          ),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.cloud_sync_rounded),
                  title: Text('النسخة الاحتياطية الآمنة'),
                  subtitle: Text(
                    store.backupGoogleEmail.isEmpty
                        ? 'نسخة محلية مشفرة تلقائياً + نسخة Google Drive للحساب الذي تختاره.'
                        : 'Google Drive: ${store.backupGoogleEmail}',
                  ),
                ),
                if (store.lastLocalBackupAt != null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.phone_android_rounded),
                    title: const Text('آخر نسخة محلية تلقائية'),
                    subtitle: Text(
                        '${dateText(store.lastLocalBackupAt!)} ${timeText(store.lastLocalBackupAt!)}'),
                  ),
                if (store.lastBackupAt != null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('آخر نسخة ناجحة'),
                    subtitle: Text(
                        '${dateText(store.lastBackupAt!)} ${timeText(store.lastBackupAt!)}'),
                  ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final result = await store.backupToGoogleDrive();
                    if (!context.mounted) return;
                    if (result.success) {
                      await showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('تم تأمين النسخة'),
                          content: SelectableText(
                            'تم تأمين البيانات محلياً.\n' +
                            (result.cloudSaved
                                ? 'نسخة Google Drive: ${result.accountEmail ?? 'الحساب المحدد'}\n'
                                : 'تعذر Google Drive حالياً، لكن النسخة المحلية محفوظة.\n') +
                            '\nرمز الاسترداد الخاص بك:\n${store.backupRecoveryCode}\n\nاحفظ هذا الرمز خارج الهاتف. بدونه لا يمكن فك النسخة بعد تغيير الجهاز.',
                          ),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('حفظت الرمز')),
                          ],
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(result.message)));
                    }
                  },
                  icon: const Icon(Icons.cloud_upload_rounded),
                  label: const Text('إنشاء / تحديث النسخة الاحتياطية'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final controller = TextEditingController();
                    final recovery = await showDialog<String>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('استعادة النسخة الاحتياطية'),
                        content: TextField(
                          controller: controller,
                          autofocus: true,
                          textCapitalization: TextCapitalization.characters,
                          decoration:
                              const InputDecoration(labelText: 'رمز الاسترداد'),
                        ),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('إلغاء')),
                          FilledButton(
                              onPressed: () => Navigator.pop(
                                  context, controller.text.trim()),
                              child: const Text('استعادة')),
                        ],
                      ),
                    );
                    controller.dispose();
                    if (recovery == null ||
                        recovery.isEmpty ||
                        !context.mounted) return;
                    final result = await store.restoreFromGoogleDrive(recovery);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(result.message)));
                  },
                  icon: const Icon(Icons.cloud_download_rounded),
                  label: const Text('استعادة البيانات من Google Drive'),
                OutlinedButton.icon(
                  onPressed: () async {
                    final controller = TextEditingController();
                    final recovery = await showDialog<String>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('استعادة النسخة المحلية'),
                        content: TextField(
                          controller: controller,
                          autofocus: true,
                          textCapitalization: TextCapitalization.characters,
                          decoration:
                              const InputDecoration(labelText: 'رمز الاسترداد'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('إلغاء'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(
                              context,
                              controller.text.trim(),
                            ),
                            child: const Text('استعادة'),
                          ),
                        ],
                      ),
                    );
                    controller.dispose();
                    if (recovery == null ||
                        recovery.isEmpty ||
                        !context.mounted) return;
                    final result =
                        await store.restoreFromLocalBackup(recovery);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(result.message)),
                    );
                  },
                  icon: const Icon(Icons.phone_android_rounded),
                  label: const Text('استعادة من النسخة المحلية'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await store.changeGoogleBackupAccount();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('تم تسجيل الخروج من حساب Google. عند النسخ القادم اختر حساب العميل.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.switch_account_rounded),
                  label: const Text('تغيير حساب Google للنسخ الاحتياطي'),
                ),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ActivationPage(store: store)),
              );
            },
            child: const Text('التفعيل'),
          ),
        ],
      ),
    );
  }
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

    if (!widget.store.firebaseReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'لا يوجد اتصال بالخدمة حالياً. حاول بعد الاتصال بالإنترنت.')),
      );
      return;
    }

    final entered = code.text.trim();
    if (entered.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل كود التفعيل')),
      );
      return;
    }

    setState(() => busy = true);
    final ok = await widget.store.activateCode(entered);

    if (!mounted) return;
    setState(() => busy = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'تم التفعيل الدائم بنجاح' : 'الكود غير صحيح أو مستخدم',
        ),
      ),
    );

    if (ok) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    return Scaffold(
      appBar: AppBar(title: const Text('التفعيل')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Icon(Icons.verified_rounded, size: 42, color: mint),
                  const SizedBox(height: 8),
                  Text(
                    store.activated
                        ? 'التطبيق مفعّل بصفة دائمة'
                        : 'المتبقي من التجربة: ${store.trialDaysLeft} أيام',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          TextField(
            controller: code,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'كود التفعيل'),
            onSubmitted: (_) => activate(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : activate,
            child: Text(busy ? 'جارٍ التحقق...' : 'تفعيل دائم'),
          ),
        ],
      ),
    );
  }
}

class AdminGate extends StatefulWidget {
  const AdminGate({super.key, required this.store});

  final Store store;

  @override
  State<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGate> {
  final pin = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  Future<void> enter() async {
    if(busy)return;setState(()=>busy=true);final valid=await widget.store.loginOwner(pin.text);
    if(!mounted)return;setState(()=>busy=false);
    if(valid){Navigator.of(context).pop();Navigator.of(context).push(MaterialPageRoute(builder:(_)=>AdminPage(store:widget.store)));}
    else{ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تعذر دخول المالك: تحقق من الرمز والاتصال بالخدمة')));}
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('لوحة المالك'),
      content: TextField(
        controller: pin,
        obscureText: true,
        keyboardType: TextInputType.number,
        onSubmitted: (_) => enter(),
        decoration: const InputDecoration(labelText: 'رمز المالك'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: enter,
          child: const Text('دخول'),
        ),
      ],
    );
  }
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.store});

  final Store store;

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  String result = '';
  bool busy = false;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> generate() async {
    if (busy) return;

    setState(() => busy = true);
    String? generated;
    try {
      generated = await widget.store.generateCode();
    } on FirebaseException catch (e) {
      generated = 'Firebase ${e.code}: ${e.message ?? ''}'.trim();
    } catch (e) {
      generated = 'خطأ: $e';
    }

    if (!mounted) return;
    setState(() {
      busy = false;
      result = generated ?? 'تعذر توليد الرمز';
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    return Scaffold(
      appBar: AppBar(title: const Text('إدارة التفعيل')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('وضع المالك'),
              subtitle: const Text('جلسة المالك موثقة عبر Cloudflare Workers'),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.vpn_key_rounded),
              title: Text('رمز دائم لمرة واحدة'),
              subtitle:
                  Text('الرمز غير مرتبط بالهاتف ويمكن استخدامه مرة واحدة فقط.'),
            ),
          ),
          FilledButton(
            onPressed: busy ? null : generate,
            child: Text(busy ? 'جارٍ التوليد...' : 'توليد رمز تفعيل'),
          ),
          if (result.isNotEmpty)
            Card(
              child: ListTile(
                title: const Text('رمز التفعيل'),
                subtitle: SelectableText(
                  result,
                  style: const TextStyle(
                      fontSize: 25, fontWeight: FontWeight.w900),
                ),
                trailing: result.length >= 20
                    ? IconButton(
                        onPressed: () {
                          launchWhatsApp(
                            '+218934951072',
                            'رمز تفعيل DainPay: $result',
                          );
                        },
                        icon: const Icon(Icons.send),
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
