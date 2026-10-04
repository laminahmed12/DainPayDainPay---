from pathlib import Path

p = Path('lib/main.dart')
s = p.read_text(encoding='utf-8')

imp = "import 'package:firebase_core/firebase_core.dart';\n"
if "import 'backup_service.dart';" not in s:
    s = s.replace(imp, imp + "import 'backup_service.dart';\n", 1)

field_anchor = "  bool isAdmin = false;\n"
fields = """  bool isAdmin = false;\n\n  final DainPayBackupService backupService = DainPayBackupService();\n  String backupRecoveryCode = '';\n  DateTime? lastBackupAt;\n"""
if 'final DainPayBackupService backupService' not in s:
    if field_anchor not in s:
        raise SystemExit('STORE_FIELDS_ANCHOR_NOT_FOUND')
    s = s.replace(field_anchor, fields, 1)

load_anchor = "    store.deviceId = store.prefs.getString('device_id') ?? '';\n"
load_add = """    store.deviceId = store.prefs.getString('device_id') ?? '';\n    store.backupRecoveryCode = store.prefs.getString('backup_recovery_code') ?? '';\n    final lastBackup = store.prefs.getString('last_backup_at');\n    store.lastBackupAt = lastBackup == null ? null : DateTime.tryParse(lastBackup);\n"""
if 'backup_recovery_code' not in s:
    if load_anchor not in s:
        raise SystemExit('LOAD_ANCHOR_NOT_FOUND')
    s = s.replace(load_anchor, load_add, 1)

# Dispose backup HTTP client together with Store.
dispose_anchor = "  @override\n  void dispose() {\n    _disposed = true;\n    super.dispose();\n  }"
dispose_new = """  @override\n  void dispose() {\n    _disposed = true;\n    backupService.dispose();\n    super.dispose();\n  }"""
if 'backupService.dispose();' not in s:
    if dispose_anchor not in s:
        raise SystemExit('DISPOSE_ANCHOR_NOT_FOUND')
    s = s.replace(dispose_anchor, dispose_new, 1)

methods_anchor = "  Future<void> syncAll() async {\n"
methods = r'''  Future<String> ensureBackupRecoveryCode() async {
    if (backupRecoveryCode.trim().isEmpty) {
      backupRecoveryCode = backupService.generateRecoveryCode();
      await _pref(() => prefs.setString('backup_recovery_code', backupRecoveryCode));
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
    if (result.success) {
      lastBackupAt = DateTime.now();
      await _pref(() => prefs.setString('last_backup_at', lastBackupAt!.toIso8601String()));
      safeNotify();
    }
    return result;
  }

  Future<DainPayBackupResult> restoreFromGoogleDrive(String recoveryCode) async {
    try {
      final payload = await backupService.restore(recoveryCode: recoveryCode);
      if (payload['schema'] != 1 || payload['app'] != 'DainPay') {
        return const DainPayBackupResult(success: false, message: 'ملف النسخة الاحتياطية غير صالح');
      }

      final rawCustomers = payload['customers'];
      final rawTransactions = payload['transactions'];
      final rawDrafts = payload['voiceDrafts'];
      if (rawCustomers is! List || rawTransactions is! List || rawDrafts is! List) {
        return const DainPayBackupResult(success: false, message: 'النسخة الاحتياطية ناقصة أو تالفة');
      }

      final restoredCustomers = <Customer>[];
      for (final item in rawCustomers) {
        if (item is Map) restoredCustomers.add(Customer.fromJson(Map<String, dynamic>.from(item)));
      }
      final restoredTransactions = <Tx>[];
      for (final item in rawTransactions) {
        if (item is Map) restoredTransactions.add(Tx.fromJson(Map<String, dynamic>.from(item)));
      }
      final restoredDrafts = <VoiceDraft>[];
      for (final item in rawDrafts) {
        if (item is Map) restoredDrafts.add(VoiceDraft.fromJson(Map<String, dynamic>.from(item)));
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
      shop = '${payload['shop'] ?? shop}'.trim().isEmpty ? shop : '${payload['shop']}'.trim();
      whatsappMessage = '${payload['whatsappMessage'] ?? whatsappMessage}';
      dark = payload['dark'] == true;
      activated = payload['activated'] == true;
      trialStart = DateTime.tryParse('${payload['trialStart'] ?? ''}') ?? trialStart;

      await saveLocal();
      safeNotify();
      return const DainPayBackupResult(success: true, message: 'تمت استعادة بيانات DainPay بنجاح');
    } catch (e) {
      return const DainPayBackupResult(success: false, message: 'تعذر فك النسخة الاحتياطية. تحقق من رمز الاسترداد.');
    }
  }

'''
if 'Future<DainPayBackupResult> backupToGoogleDrive()' not in s:
    if methods_anchor not in s:
        raise SystemExit('SYNC_ANCHOR_NOT_FOUND')
    s = s.replace(methods_anchor, methods + methods_anchor, 1)

# Add backup/restore controls to SettingsPage.
settings_anchor = """          OutlinedButton(\n            onPressed: () {\n              Navigator.push(\n                context,\n                MaterialPageRoute(builder: (_) => VoiceDraftsPage(store: store)),\n              );\n            },\n            child: const Text('المسودات الصوتية'),\n          ),\n"""
settings_insert = settings_anchor + r'''          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.cloud_sync_rounded),
                  title: Text('النسخة الاحتياطية الآمنة'),
                  subtitle: Text('نسخة مشفرة في Google Drive الخاص بالحساب.'),
                ),
                if (store.lastBackupAt != null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('آخر نسخة ناجحة'),
                    subtitle: Text('${dateText(store.lastBackupAt!)} ${timeText(store.lastBackupAt!)}'),
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
                            'تم حفظ نسخة مشفرة في حساب Google.\n\nرمز الاسترداد الخاص بك:\n${store.backupRecoveryCode}\n\nاحفظ هذا الرمز خارج الهاتف. بدونه لا يمكن فك النسخة بعد تغيير الجهاز.',
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: const Text('حفظت الرمز')),
                          ],
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
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
                          decoration: const InputDecoration(labelText: 'رمز الاسترداد'),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
                          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('استعادة')),
                        ],
                      ),
                    );
                    controller.dispose();
                    if (recovery == null || recovery.isEmpty || !context.mounted) return;
                    final result = await store.restoreFromGoogleDrive(recovery);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
                  },
                  icon: const Icon(Icons.cloud_download_rounded),
                  label: const Text('استعادة البيانات من Google Drive'),
                ),
              ],
            ),
          ),
'''
if 'إنشاء / تحديث النسخة الاحتياطية' not in s:
    if settings_anchor not in s:
        raise SystemExit('SETTINGS_ANCHOR_NOT_FOUND')
    s = s.replace(settings_anchor, settings_insert, 1)

p.write_text(s, encoding='utf-8')
print('DRIVE_BACKUP_PATCH_OK')
'''
