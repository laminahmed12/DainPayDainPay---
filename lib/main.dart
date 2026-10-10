// Updated DainPay Code - Full Fixes for Customers Logic & Voice Draft Deletion
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'backup_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

const Color emerald = Color(0xFF0F5C6E);
const Color mint = Color(0xFF2EC4B6);
const Color burgundy = Color(0xFFE63946);

const int trialLengthDays = 7;
const String cloudflareActivationUrl = 'https://dainpay-activation.lamin-ahmed12.workers.dev';
const String appTitle = 'دفتر الديون';
const String functionsRegion = 'us-central1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load only local state before the first frame. Network services must never
  // block the welcome screen or delay access to the local customer ledger.
  final store = await Store.load();
  runApp(DainPayApp(store: store));

  // Firebase authentication and connection run after the UI is visible.
  unawaited(_initializeBackgroundServices(store));
}

Future<void> _initializeBackgroundServices(Store store) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    store.firebaseInitialized = true;
  } catch (e, stack) {
    store.firebaseInitialized = false;
    debugPrint('Firebase initialization error: $e');
    debugPrintStack(stackTrace: stack);
    store.safeNotify();
    return;
  }

  try {
    await store.connectFirebase();
  } catch (e, stack) {
    debugPrint('Firebase connection error: $e');
    debugPrintStack(stackTrace: stack);
  }
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
    if (store.prepaidCredit(customer.id) > 0)
      'الرصيد المسبق: ${money(store.prepaidCredit(customer.id))}',
    'الحالة: ${balance <= 0
        ? (store.prepaidCredit(customer.id) > 0 ? 'له رصيد مسبق' : 'مسدد')
        : 'عليه رصيد'}',
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
  String lastDeleteError = '';

  final DainPayBackupService backupService = DainPayBackupService();
  String localBackupKey = '';
  DateTime? lastBackupAt;
  DateTime? lastLocalBackupAt;
  String backupGoogleEmail = '';
  final Set<String> pendingDeletedCustomerIds = <String>{};
  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();
  Timer? _localBackupTimer;

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
    store.localBackupKey =
        await store.secureStorage.read(key: 'dainpay_local_backup_key') ?? '';
    if (store.localBackupKey.isEmpty) {
      store.localBackupKey =
          store.prefs.getString('dainpay_local_backup_key') ?? '';
      if (store.localBackupKey.isNotEmpty) {
        await store.secureStorage.write(
          key: 'dainpay_local_backup_key',
          value: store.localBackupKey,
        );
      }
    }
    final lastBackup = store.prefs.getString('last_backup_at');
    store.lastBackupAt =
        lastBackup == null ? null : DateTime.tryParse(lastBackup);
    final lastLocal = store.prefs.getString('last_local_backup_at');
    store.lastLocalBackupAt =
        lastLocal == null ? null : DateTime.tryParse(lastLocal);
    store.backupGoogleEmail = store.prefs.getString('backup_google_email') ?? '';
    final pendingDeleted = store.prefs.getStringList('pending_deleted_customers') ?? const <String>[];
    store.pendingDeletedCustomerIds.addAll(pendingDeleted);

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
    _localBackupTimer?.cancel();
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
    // Customer and transaction data are local-first. Google Drive is the
    // encrypted backup/restore layer; Firestore is not used for customer data.
    return;
  }

  Future<void> saveLocal() async {
    // Keep the interactive save path fast: only persist the primary local data
    // here. The encrypted redundant snapshot is queued in the background.
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
    await _pref(() => prefs.setStringList(
          'pending_deleted_customers',
          pendingDeletedCustomerIds.toList(),
        ));

    _queueEncryptedLocalBackup();
  }

  void _queueEncryptedLocalBackup() {
    _localBackupTimer?.cancel();
    _localBackupTimer = Timer(const Duration(milliseconds: 1200), () async {
      try {
        final localKey = await ensureLocalBackupKey();
        final ok = await backupService.saveLocal(
          payload: backupPayload(),
          localKey: localKey,
        );
        if (ok) {
          lastLocalBackupAt = DateTime.now();
          await _pref(() => prefs.setString(
                'last_local_backup_at',
                lastLocalBackupAt!.toIso8601String(),
              ));
          safeNotify();
        }
      } catch (e) {
        debugPrint('Background local backup error: $e');
      }
    });
  }

  Future<DainPayBackupResult> createLocalBackupNow() async {
    try {
      final localKey = await ensureLocalBackupKey();
      final ok = await backupService.saveLocal(
        payload: backupPayload(),
        localKey: localKey,
      );
      if (!ok) {
        return const DainPayBackupResult(
          success: false,
          message: 'تعذر إنشاء النسخة المحلية.',
        );
      }
      lastLocalBackupAt = DateTime.now();
      await _pref(() => prefs.setString(
            'last_local_backup_at',
            lastLocalBackupAt!.toIso8601String(),
          ));
      safeNotify();
      return const DainPayBackupResult(
        success: true,
        message: 'تم إنشاء النسخة المحلية المشفرة بنجاح.',
        localSaved: true,
      );
    } catch (e) {
      return DainPayBackupResult(
        success: false,
        message: 'تعذر إنشاء النسخة المحلية: $e',
      );
    }
  }

  Future<void> save() async {
    // Primary customer/transaction store: local device.
    // Google Drive is the encrypted backup layer.
    await saveLocal();
    safeNotify();
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
    lastDeleteError = '';
    final currentBalance = balance(customer.id);
    final credit = prepaidCredit(customer.id);

    if (currentBalance != 0) {
      lastDeleteError = 'لا يمكن الحذف: المتبقي على العميل ' +
          money(currentBalance) + '.';
      return false;
    }
    if (credit != 0) {
      lastDeleteError = 'لا يمكن الحذف: للعميل رصيد مسبق ' +
          money(credit) + '.';
      return false;
    }

    transactions.removeWhere((tx) => tx.customerId == customer.id);
    customers.removeWhere((item) => item.id == customer.id);
    pendingDeletedCustomerIds.remove(customer.id);
    await saveLocal();
    safeNotify();
    return true;
  }

  Future<void> deleteVoiceDraft(String id) async {
    voiceDrafts.removeWhere((draft) => draft.id == id);
    await saveLocal();
    safeNotify();
  }

  Future<String> ensureLocalBackupKey() async {
    if (localBackupKey.trim().isEmpty) {
      localBackupKey =
          prefs.getString('dainpay_local_backup_key') ?? '';
    }
    if (localBackupKey.trim().isEmpty) {
      final bytes = List<int>.generate(
        32,
        (_) => Random.secure().nextInt(256),
      );
      localBackupKey = base64UrlEncode(bytes);
      await secureStorage.write(
        key: 'dainpay_local_backup_key',
        value: localBackupKey,
      );
      await _pref(
        () => prefs.setString('dainpay_local_backup_key', localBackupKey),
      );
    }
    return localBackupKey;
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
    final localKey = await ensureLocalBackupKey();
    final result = await backupService.backup(
      payload: backupPayload(),
      localKey: localKey,
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

  Future<DainPayBackupResult> restoreFromGoogleDrive() async {
    try {
      final payload = await backupService.restore();
      final result = await _applyBackupPayload(payload);
      if (result.success) {
        backupGoogleEmail =
            backupService.currentGoogleEmail ?? backupGoogleEmail;
        await _pref(() => prefs.setString(
              'backup_google_email',
              backupGoogleEmail,
            ));
      }
      return result;
    } catch (e) {
      return DainPayBackupResult(
        success: false,
        message: 'تعذر استعادة النسخة: $e',
      );
    }
  }

  Future<DainPayBackupResult> restoreFromLocalBackup() async {
    try {
      _localBackupTimer?.cancel();
      final localKey = localBackupKey.trim().isNotEmpty
          ? localBackupKey
          : await secureStorage.read(key: 'dainpay_local_backup_key');
      if (localKey == null || localKey.trim().isEmpty) {
        return const DainPayBackupResult(
          success: false,
          message: 'مفتاح النسخة المحلية غير موجود على هذا الجهاز.',
        );
      }
      final payload = await backupService.restoreLocal(localKey: localKey);
      return _applyBackupPayload(payload);
    } catch (e) {
      debugPrint('Local restore error: $e');
      return DainPayBackupResult(
        success: false,
        message: e is StateError
            ? e.message.toString()
            : 'تعذر استعادة النسخة المحلية: $e',
      );
    }
  }

  Future<DainPayBackupResult> _applyBackupPayload(
      Map<String, dynamic> payload) async {
    if ((payload['schema'] != 1 &&
            payload['schema'] != 2 &&
            payload['schema'] != 3) ||
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

    // Reject partial/malformed payloads before touching the current ledger.
    if (rawCustomers.any((item) => item is! Map) ||
        rawTransactions.any((item) => item is! Map) ||
        rawDrafts.any((item) => item is! Map)) {
      return const DainPayBackupResult(
        success: false,
        message: 'النسخة تحتوي على سجلات غير صالحة؛ لم تتغير البيانات الحالية.',
      );
    }

    final restoredCustomers = rawCustomers
        .map((item) => Customer.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
    final restoredTransactions = rawTransactions
        .map((item) => Tx.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
    final restoredDrafts = rawDrafts
        .map((item) => VoiceDraft.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();

    final customerIds = restoredCustomers.map((c) => c.id).toList();
    if (customerIds.any((id) => id.trim().isEmpty) ||
        customerIds.toSet().length != customerIds.length) {
      return const DainPayBackupResult(
        success: false,
        message: 'معرّفات العملاء في النسخة غير صالحة أو مكررة؛ لم تتغير البيانات الحالية.',
      );
    }
    final customerIdSet = customerIds.toSet();
    final transactionIds = restoredTransactions.map((tx) => tx.id).toList();
    if (transactionIds.any((id) => id.trim().isEmpty) ||
        transactionIds.toSet().length != transactionIds.length ||
        restoredTransactions.any((tx) =>
            !customerIdSet.contains(tx.customerId) ||
            tx.amountCents <= 0 ||
            (tx.type != 'debt' && tx.type != 'payment'))) {
      return const DainPayBackupResult(
        success: false,
        message: 'سجلات المعاملات غير متطابقة مع العملاء أو غير صالحة؛ لم تتغير البيانات الحالية.',
      );
    }
    final draftIds = restoredDrafts.map((draft) => draft.id).toList();
    if (draftIds.any((id) => id.trim().isEmpty) ||
        draftIds.toSet().length != draftIds.length) {
      return const DainPayBackupResult(
        success: false,
        message: 'معرّفات المسودات الصوتية غير صالحة؛ لم تتغير البيانات الحالية.',
      );
    }

    // Preserve the current ledger as an encrypted recovery point before restore.
    try {
      final localKey = await ensureLocalBackupKey();
      final preserved = await backupService.saveLocal(
        payload: backupPayload(),
        localKey: localKey,
      );
      if (!preserved) {
        return const DainPayBackupResult(
          success: false,
          message: 'تعذر تأمين نسخة من البيانات الحالية قبل الاستعادة؛ أُلغيت الاستعادة.',
        );
      }
    } catch (e) {
      return DainPayBackupResult(
        success: false,
        message: 'تعذر تأمين نسخة من البيانات الحالية قبل الاستعادة؛ أُلغيت العملية: $e',
      );
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
    _queueEncryptedLocalBackup();
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
    // Customer/transaction cloud synchronization is intentionally disabled.
    return;
  }

  int balance(String customerId) {
    final net = transactions.where((t) => t.customerId == customerId).fold<int>(
          0,
          (sum, t) =>
              sum + (t.type == 'debt' ? t.amountCents : -t.amountCents),
        );
    return max(0, net);
  }

  int prepaidCredit(String customerId) {
    final net = transactions.where((t) => t.customerId == customerId).fold<int>(
          0,
          (sum, t) =>
              sum + (t.type == 'debt' ? t.amountCents : -t.amountCents),
        );
    return max(0, -net);
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
    final cleanCode = _digits(code).trim().replaceAll(RegExp(r'\s+'), '');
    if (cleanCode.isEmpty) return false;
    try {
      final response = await http.post(
        Uri.parse(cloudflareActivationUrl),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'action': 'redeem',
          'code': cleanCode,
          'deviceId': deviceId,
        }),
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        debugPrint('Cloudflare redeem failed: ${response.statusCode} ${response.body}');
        return false;
      }
      final data = jsonDecode(response.body);
      if (data is! Map || data['success'] != true) return false;
      activated = true;
      await saveLocal();
      if (firebaseReady && uid.isNotEmpty) {
        try {
          await userRef.doc(uid).set({
            'activated': true,
            'activatedAt': FieldValue.serverTimestamp(),
            'activatedDeviceId': deviceId,
          }, SetOptions(merge: true));
        } catch (e) {
          debugPrint('Activation mirror to Firebase failed: $e');
        }
      }
      safeNotify();
      return true;
    } catch (e) {
      debugPrint('Cloudflare activation error: $e');
      return false;
    }
  }

  Future<bool> loginOwner(String pin) async {
    try {
      final response = await http.post(
        Uri.parse(cloudflareActivationUrl),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'action': 'owner_login', 'adminPin': _digits(pin).trim()}),
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        debugPrint('Cloudflare owner login failed: ${response.statusCode} ${response.body}');
        return false;
      }
      final data = jsonDecode(response.body);
      if (data is! Map || data['success'] != true || data['token'] is! String) {
        return false;
      }
      ownerToken = data['token'] as String;
      isAdmin = true;
      safeNotify();
      return true;
    } catch (e) {
      debugPrint('Cloudflare owner login error: $e');
      return false;
    }
  }

  Future<String?> generateCode() async {
    if (!isAdmin || ownerToken.isEmpty) {
      throw StateError('جلسة المالك غير صالحة. سجّل الدخول مجدداً.');
    }
    try {
      final response = await http.post(
        Uri.parse(cloudflareActivationUrl),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'action': 'generate', 'ownerToken': ownerToken}),
      ).timeout(const Duration(seconds: 20));
      final data = jsonDecode(response.body);
      if (response.statusCode != 200 ||
          data is! Map ||
          data['success'] != true ||
          data['code'] is! String) {
        final message = data is Map
            ? (data['error'] ?? 'تعذر توليد رمز التفعيل')
            : 'استجابة غير صالحة من خدمة التفعيل';
        throw StateError('$message');
      }
      return data['code'] as String;
    } on StateError {
      rethrow;
    } catch (e) {
      debugPrint('Cloudflare code generation error: $e');
      throw StateError('تعذر الاتصال بخدمة التفعيل عبر Cloudflare.');
    }
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
      cardTheme: CardThemeData(
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
            child: WelcomePage(store: store),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Short welcome screen
// -----------------------------------------------------------------------------

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key, required this.store});

  final Store store;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  Timer? _welcomeTimer;

  @override
  void initState() {
    super.initState();
    _welcomeTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => Directionality(
            textDirection: TextDirection.rtl,
            child: HomePage(store: widget.store),
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _welcomeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF101719),
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_rounded,
                size: 66,
                color: Color(0xFF2EC4B6),
              ),
              SizedBox(height: 16),
              Text(
                'دفتر الديون',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 29,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'ديونك محفوظة.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF2EC4B6),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 28),
              Text(
                'Adreemk',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
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
    await widget.store.saveLocal();
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
                      'بيانات العملاء محفوظة محلياً. Firebase يُستخدم لحالة الحساب والتفعيل.'),
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
    final credit = store.prepaidCredit(customer.id);
    if (balance != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('لا يمكن حذف العميل. المتبقي عليه ${money(balance)}')),
      );
      return;
    }
    if (credit != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا يمكن حذف العميل. لديه رصيد مسبق ${money(credit)} محفوظ للمشتريات القادمة.',
          ),
        ),
      );
      return;
    }
    // The local zero-balance ledger is authoritative. Cloud deletion is queued
    // and retried automatically, so a temporary Firebase problem does not
    // block the customer from being removed from the local ledger.

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف العميل؟'),
        content: const Text(
            'سيتم حذف العميل وعملياته لأن رصيده المحلي صفر. وسيتم مزامنة الحذف مع Firebase تلقائياً.'),
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
      final reason = store.lastDeleteError.trim().isNotEmpty
          ? store.lastDeleteError
          : 'تعذر حذف العميل. لم يتم تغيير البيانات.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(reason)),
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
                  if (store.prepaidCredit(customer.id) > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'رصيد مسبق ${money(store.prepaidCredit(customer.id))} '
                        'متاح للعمليات القادمة',
                        style: const TextStyle(
                          color: emerald,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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

    // A payment may exceed the current debt. The excess becomes prepaid
    // credit and is automatically applied to future debts.

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
  String stage = 'جاهز للتسجيل';

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

  Future<bool> _ensureMicrophonePermission() async {
    var status = await Permission.microphone.status;
    if (status.isGranted) return true;

    status = await Permission.microphone.request();
    if (status.isGranted) return true;

    if (status.isPermanentlyDenied && mounted) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('صلاحية الميكروفون'),
          content: const Text(
            'التسجيل الصوتي يحتاج صلاحية الميكروفون. افتح إعدادات التطبيق وفعّل الميكروفون ثم عد إلى DainPay.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await openAppSettings();
              },
              child: const Text('فتح الإعدادات'),
            ),
          ],
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يلزم السماح للميكروفون لاستخدام التسجيل الصوتي.')),
      );
    }
    return false;
  }

  Future<void> record() async {
    if (initializing) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('جارٍ تهيئة التسجيل، انتظر لحظة.')),
        );
      }
      return;
    }

    if (listening) {
      try {
        await speech.stop().timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('Speech stop error: $e');
      }
      if (mounted) {
        setState(() {
          listening = false;
          stage = 'تم إيقاف التسجيل';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        initializing = true;
        stage = 'جارٍ فحص صلاحية الميكروفون...';
        live = '';
      });
    } else {
      initializing = true;
    }

    try {
      if (!await _ensureMicrophonePermission().timeout(
        const Duration(seconds: 20),
      )) {
        stage = 'لم تُمنح صلاحية الميكروفون';
        return;
      }

      if (mounted) setState(() => stage = 'جارٍ تجهيز خدمة الصوت...');
      await speech.cancel().timeout(const Duration(seconds: 4));

      final available = await speech.initialize(
        debugLogging: true,
        onStatus: (status) {
          debugPrint('Speech status: $status');
          if (!mounted) return;
          setState(() {
            if (status == 'listening') {
              listening = true;
              stage = 'الميكروفون يستمع الآن...';
            } else if (status == 'notListening' || status == 'done') {
              listening = false;
              stage = live.isEmpty
                  ? 'توقّف الاستماع دون نص؛ حاول مجدداً'
                  : 'انتهى الاستماع';
            } else {
              stage = 'حالة خدمة الصوت: $status';
            }
          });
        },
        onError: (error) {
          debugPrint('Speech error: ${error.errorMsg}; permanent: ${error.permanent}');
          if (!mounted) return;
          setState(() {
            listening = false;
            stage = 'خطأ في خدمة الصوت: ${error.errorMsg}';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('تعذر تشغيل التعرف الصوتي: ${error.errorMsg}'),
              duration: const Duration(seconds: 5),
            ),
          );
        },
      ).timeout(const Duration(seconds: 12));

      if (!available) {
        if (mounted) {
          setState(() => stage = 'خدمة التعرف الصوتي غير متاحة');
          await showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('التعرف الصوتي غير متاح'),
              content: const Text(
                'لم يستطع الهاتف تشغيل خدمة التعرف الصوتي. تأكد من تفعيل خدمة '
                'التعرف الصوتي وتثبيت حزمة اللغة العربية في الهاتف، ثم أعد المحاولة.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إغلاق'),
                ),
              ],
            ),
          );
        }
        return;
      }

      if (!mounted) return;

      // Avoid speech.locales(): on some Android speech services this native
      // query hangs even though Google voice typing works in the keyboard.
      // Use a widely supported Arabic locale directly to keep startup reliable.
      const arabicLocale = 'ar-SA';
      setState(() {
        listening = false;
        stage = 'جارٍ تشغيل التعرف الصوتي بالعربية...';
      });

      await speech.listen(
        listenOptions: stt.SpeechListenOptions(
          localeId: arabicLocale,
          partialResults: true,
          cancelOnError: true,
        ),
        onResult: (result) async {
          debugPrint('Speech result: final=${result.finalResult}, text=${result.recognizedWords}');
          if (!mounted) return;
          setState(() {
            live = result.recognizedWords;
            if (live.isNotEmpty) stage = 'تم التقاط الكلام';
          });

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
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم حفظ المسودة الصوتية')),
              );
            }
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('انتهى الاستماع دون التقاط كلام واضح.')),
            );
          }

          if (mounted) {
            setState(() {
              listening = false;
              stage = text.isEmpty ? 'لم يتم التقاط كلام' : 'تم حفظ المسودة';
            });
          }
        },
      ).timeout(const Duration(seconds: 8));

      if (mounted && !listening) {
        setState(() => stage = 'تم إرسال أمر بدء الاستماع؛ بانتظار الكلام...');
      }
    } on TimeoutException catch (e, stack) {
      debugPrint('Speech timeout: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        setState(() {
          listening = false;
          stage = 'انتهت مهلة تهيئة الصوت؛ أعد المحاولة';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('خدمة الصوت لم تستجب في الوقت المحدد. تحقق من خدمة التعرف الصوتي في الهاتف ثم أعد المحاولة.'),
            duration: Duration(seconds: 6),
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('Speech start error: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        setState(() {
          listening = false;
          stage = 'فشل بدء التسجيل: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('فشل بدء التسجيل: $e'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      initializing = false;
      if (mounted) setState(() {});
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
              leading: initializing
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      listening ? Icons.stop_circle : Icons.mic_rounded,
                      color: listening ? burgundy : emerald,
                    ),
              title: Text(
                initializing
                    ? 'جارٍ بدء التسجيل...'
                    : listening
                        ? 'جارٍ الاستماع...'
                        : 'تسجيل عملية صوتية',
              ),
              subtitle: Text(live.isNotEmpty ? live : stage.isNotEmpty ? stage : 'مثال: محمد 150 بضاعة'),
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

  Future<void> addCustomerQuickly() async {
    final customerName = TextEditingController();
    final customerPhone = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final create = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إضافة زبون جديد'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: customerName,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'اسم الزبون'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'أدخل اسم الزبون'
                    : null,
              ),
              TextField(
                controller: customerPhone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'رقم الهاتف (اختياري)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() == true) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('حفظ الزبون'),
          ),
        ],
      ),
    );

    if (create == true && mounted) {
      final customer = Customer(
        id: makeId(),
        name: customerName.text.trim(),
        phone: customerPhone.text.trim(),
        limitCents: 0,
      );
      final saved = await widget.store.saveCustomer(customer);
      if (mounted) {
        if (saved) {
          setState(() => customerId = customer.id);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تمت إضافة الزبون وتحديده.')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('يوجد زبون بنفس الاسم ورقم الهاتف.')),
          );
        }
      }
    }
    customerName.dispose();
    customerPhone.dispose();
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

    // A payment may exceed the current debt. The excess becomes prepaid
    // credit and is automatically applied to future debts.

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
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: busy ? null : addCustomerQuickly,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('إضافة زبون جديد'),
          ),
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
                ListTile(
                  leading: const Icon(Icons.cloud_sync_rounded),
                  title: const Text('النسخة الاحتياطية الآمنة'),
                  subtitle: Text(
                    store.backupGoogleEmail.isEmpty
                        ? 'نسخة محلية مشفرة تلقائياً + نسخة Google Drive للحساب الذي تختاره.'
                        : 'حساب Google للنسخة: ${store.backupGoogleEmail}',
                  ),
                ),
                if (store.lastLocalBackupAt != null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.phone_android_rounded),
                    title: const Text('آخر نسخة محلية تلقائية'),
                    subtitle: Text(
                      '${dateText(store.lastLocalBackupAt!)} ${timeText(store.lastLocalBackupAt!)}',
                    ),
                  ),
                if (store.lastBackupAt != null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('آخر نسخة Google Drive ناجحة'),
                    subtitle: Text(
                      '${dateText(store.lastBackupAt!)} ${timeText(store.lastBackupAt!)}',
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final result = await store.createLocalBackupNow();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(result.message)),
                    );
                  },
                  icon: const Icon(Icons.phone_android_rounded),
                  label: const Text('إنشاء / تحديث النسخة المحلية'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final result = await store.backupToGoogleDrive();
                    if (!context.mounted) return;
                    if (result.success) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(result.message)),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(result.message)),
                      );
                    }
                  },
                  icon: const Icon(Icons.cloud_upload_rounded),
                  label: const Text('إنشاء / تحديث نسخة Google Drive'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final result = await store.restoreFromGoogleDrive();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(result.message)),
                    );
                  },
                  icon: const Icon(Icons.cloud_download_rounded),
                  label: const Text('استعادة البيانات من Google Drive'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final result = await store.restoreFromLocalBackup();
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
                        content: Text(
                          'تم تسجيل الخروج من حساب Google. عند النسخ القادم اختر حساب العميل.',
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.switch_account_rounded),
                  label: const Text('تغيير حساب Google للنسخ الاحتياطي'),
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
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
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
    if (busy) return;
    setState(() => busy = true);
    final valid = await widget.store.loginOwner(pin.text);
    if (!mounted) return;
    setState(() => busy = false);
    if (valid) {
      Navigator.of(context).pop();
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AdminPage(store: widget.store)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر دخول المالك. تحقق من الرمز والاتصال بخدمة Cloudflare.')),
      );
    }
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
      generated = e is StateError
          ? e.message
          : 'تعذر توليد رمز التفعيل حالياً.';
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
              subtitle: const Text('دخول المالك وتوليد الرموز عبر Cloudflare'),
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
                trailing: RegExp(r'^[A-Z0-9]{24}$').hasMatch(result)
                    ? Wrap(
                        spacing: 0,
                        children: [
                          IconButton(
                            tooltip: 'نسخ رمز التفعيل',
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: result));
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('تم نسخ رمز التفعيل')),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded),
                          ),
                          IconButton(
                            tooltip: 'إرسال الرمز عبر واتساب',
                            onPressed: () {
                              launchWhatsApp(
                                '+218934951072',
                                'رمز تفعيل DainPay: $result',
                              );
                            },
                            icon: const Icon(Icons.send),
                          ),
                        ],
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
