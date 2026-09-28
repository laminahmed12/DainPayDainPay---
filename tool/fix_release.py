from pathlib import Path
import re

p = Path('lib/main.dart')
s = p.read_text()

if "package:speech_to_text/speech_to_text.dart" not in s:
    s = s.replace("import 'package:shared_preferences/shared_preferences.dart';", "import 'package:shared_preferences/shared_preferences.dart';\nimport 'package:speech_to_text/speech_to_text.dart' as stt;")
if "package:firebase_storage/firebase_storage.dart" not in s:
    s = s.replace("import 'package:firebase_core/firebase_core.dart';", "import 'package:firebase_core/firebase_core.dart';\nimport 'package:firebase_storage/firebase_storage.dart';")

if 'String normalizePhone(' not in s:
    marker = "String money(double value)"
    pos = s.find(marker)
    end = s.find('\n', pos)
    helper = "String normalizePhone(String value) { var p = value.replaceAll(RegExp(r'[^0-9]'), ''); if (p.startsWith('00')) p = p.substring(2); if (p.startsWith('218')) return p; if (p.startsWith('0')) return '218${p.substring(1)}'; return p; }"
    s = s[:end+1] + helper + '\n' + s[end+1:]

s = re.sub(r"final phone = customer\.phone\.replaceAll\(RegExp\(r'\[\^0-9\]'\), ''\);", "final phone = normalizePhone(customer.phone);", s)
s = s.replace("Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}')", "Uri.https('wa.me', '/$phone', {'text': msg})")

start = s.find('class AddTransactionPage extends StatefulWidget')
end = s.find('class ReceiptPage', start)
if start >= 0 and end > start:
    block = r'''class AddTransactionPage extends StatefulWidget {
  const AddTransactionPage({super.key, required this.store, required this.customer});
  final Store store; final Customer customer;
  @override State<AddTransactionPage> createState() => _AddTransactionPageState();
}

class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount = TextEditingController(), note = TextEditingController(), voice = TextEditingController();
  final picker = ImagePicker();
  final speech = stt.SpeechToText();
  String type = 'debt', receiptPath = '';
  bool listening = false;

  Future<void> voiceInput() async {
    if (listening) { await speech.stop(); if (mounted) setState(() => listening = false); return; }
    final ok = await speech.initialize(onStatus: (s) { if (mounted) setState(() => listening = s == 'listening'); }, onError: (_) { if (mounted) setState(() => listening = false); });
    if (!ok || !mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر تشغيل التعرف الصوتي. تأكد من صلاحية الميكروفون.'))); return; }
    setState(() => listening = true);
    await speech.listen(localeId: 'ar-LY', partialResults: true, onResult: (r) {
      voice.text = r.recognizedWords;
      final n = RegExp(r'(?<!\d)(\d+(?:[.,]\d+)?)(?!\d)').firstMatch(r.recognizedWords);
      if (n != null) amount.text = (double.tryParse(n.group(1)!.replaceAll(',', '.')) ?? 0).toStringAsFixed(2);
      if (r.finalResult && mounted) setState(() => listening = false);
    });
  }

  Future<void> pickReceipt() async {
    final source = await showModalBottomSheet<ImageSource>(context: context, builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.camera_alt), title: const Text('تصوير الإيصال بالكاميرا'), onTap: () => Navigator.pop(c, ImageSource.camera)),
      ListTile(leading: const Icon(Icons.photo), title: const Text('اختيار من المعرض'), onTap: () => Navigator.pop(c, ImageSource.gallery)),
    ])));
    if (source == null) return;
    try {
      final image = await picker.pickImage(source: source, imageQuality: 85, maxWidth: 1800, maxHeight: 2400);
      if (image == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final rd = Directory('${dir.path}/receipts'); await rd.create(recursive: true);
      final f = await File(image.path).copy('${rd.path}/receipt_${DateTime.now().microsecondsSinceEpoch}.jpg');
      receiptPath = f.path;
      if (widget.store.firebaseReady) {
        try { final ref = FirebaseStorage.instance.ref('users/${widget.store.uid}/receipts/${f.uri.pathSegments.last}'); await ref.putFile(f); } catch (_) {}
      }
      if (mounted) setState(() {});
    } catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر حفظ الإيصال'))); }
  }

  Future<void> save() async {
    final a = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
    if (a <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أدخل مبلغًا صحيحًا'))); return; }
    if (type == 'debt' && widget.customer.limit > 0) {
      final current = widget.store.balance(widget.customer.id);
      if (current + a > widget.customer.limit) {
        final available = max(0, widget.customer.limit - current).toDouble();
        await showDialog(context: context, builder: (_) => AlertDialog(title: const Text('تجاوز السقف الائتماني'), content: Text('لا يمكن تسجيل الدين. السقف ${money(widget.customer.limit)} والمتاح ${money(available)}.'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('حسنًا'))]));
        return;
      }
    }
    widget.store.transactions.add(Tx(id: makeId(), customerId: widget.customer.id, type: type, amount: a, date: DateTime.now(), note: note.text.trim(), receiptPath: receiptPath));
    await widget.store.save(); if (mounted) Navigator.pop(context);
  }

  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(type == 'debt' ? 'إضافة دَين' : 'تسجيل تسديد')), body: ListView(padding: const EdgeInsets.all(16), children: [
    Card(child: ListTile(title: Text(widget.customer.name), subtitle: Text('الرصيد الحالي: ${money(widget.store.balance(widget.customer.id))}'), trailing: widget.customer.limit > 0 ? Text('السقف ${money(widget.customer.limit)}') : null)),
    const SizedBox(height: 10),
    SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دَين'), icon: Icon(Icons.add_card)), ButtonSegment(value: 'payment', label: Text('تسديد'), icon: Icon(Icons.payments_outlined))], selected: {type}, onSelectionChanged: (v) => setState(() => type = v.first)),
    TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'المبلغ بالدينار الليبي')),
    TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظات')),
    if (voice.text.isNotEmpty) TextField(controller: voice, readOnly: true, decoration: const InputDecoration(labelText: 'النص المسموع')),
    const SizedBox(height: 8), OutlinedButton.icon(onPressed: voiceInput, icon: Icon(listening ? Icons.stop_circle_outlined : Icons.mic_none), label: Text(listening ? 'إيقاف التسجيل' : 'تسجيل العملية بالصوت')),
    const SizedBox(height: 8), Card(child: ListTile(leading: const Icon(Icons.receipt_long_outlined), title: const Text('صورة الإيصال (اختيارية)'), subtitle: Text(receiptPath.isEmpty ? 'تصوير من داخل التطبيق أو اختيار صورة' : 'تم إرفاق الإيصال'), trailing: IconButton(onPressed: pickReceipt, icon: const Icon(Icons.add_a_photo_outlined)))),
    if (receiptPath.isNotEmpty) Directionality(textDirection: TextDirection.ltr, child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(receiptPath), height: 180, fit: BoxFit.contain))),
    const SizedBox(height: 20), FilledButton(onPressed: save, child: const Text('حفظ العملية')),
  ]));
}

'''
    s = s[:start] + block + s[end:]

p.write_text(s)
