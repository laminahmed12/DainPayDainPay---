from pathlib import Path

code = r'''import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  final store = await AppStore.load();
  await store.connect();
  runApp(DainPayApp(store: store));
}

String id() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
String money(double n) => '${n.toStringAsFixed(2)} د.ل';
String cleanPhone(String value) {
  var p = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (p.startsWith('00')) p = p.substring(2);
  if (p.startsWith('218')) return p;
  if (p.startsWith('0')) return '218${p.substring(1)}';
  return p;
}
String day(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

class Customer {
  Customer({required this.id, required this.name, required this.phone, this.limit = 0});
  String id;
  String name;
  String phone;
  double limit;
  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'phone': phone, 'limit': limit};
  factory Customer.fromMap(Map<String, dynamic> m) => Customer(
    id: '${m['id'] ?? ''}', name: '${m['name'] ?? ''}', phone: '${m['phone'] ?? ''}',
    limit: (m['limit'] as num?)?.toDouble() ?? 0,
  );
}

class TransactionItem {
  TransactionItem({required this.id, required this.customerId, required this.type, required this.amount, required this.date, this.note = '', this.receiptPath = '', this.receiptUrl = ''});
  String id;
  String customerId;
  String type;
  double amount;
  DateTime date;
  String note;
  String receiptPath;
  String receiptUrl;
  Map<String, dynamic> toMap() => {'id': id, 'customerId': customerId, 'type': type, 'amount': amount, 'date': date.toIso8601String(), 'note': note, 'receiptPath': receiptPath, 'receiptUrl': receiptUrl};
  factory TransactionItem.fromMap(Map<String, dynamic> m) => TransactionItem(
    id: '${m['id'] ?? ''}', customerId: '${m['customerId'] ?? ''}', type: '${m['type'] ?? 'debt'}',
    amount: (m['amount'] as num?)?.toDouble() ?? 0, date: DateTime.tryParse('${m['date']}') ?? DateTime.now(),
    note: '${m['note'] ?? ''}', receiptPath: '${m['receiptPath'] ?? ''}', receiptUrl: '${m['receiptUrl'] ?? ''}',
  );
}

class AppStore extends ChangeNotifier {
  late SharedPreferences prefs;
  final customers = <Customer>[];
  final transactions = <TransactionItem>[];
  String shopName = 'DainPay — دَيْن';
  String whatsappText = 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  String deviceId = '';
  String uid = '';
  bool firebaseReady = false;
  bool activated = false;
  DateTime trialStart = DateTime.now();

  static Future<AppStore> load() async {
    final s = AppStore();
    s.prefs = await SharedPreferences.getInstance();
    s.shopName = s.prefs.getString('shop_name') ?? s.shopName;
    s.whatsappText = s.prefs.getString('whatsapp_text') ?? s.whatsappText;
    s.deviceId = s.prefs.getString('device_id') ?? '';
    if (s.deviceId.isEmpty) {
      s.deviceId = 'DP-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';
      await s.prefs.setString('device_id', s.deviceId);
    }
    final trial = s.prefs.getString('trial_start');
    if (trial == null) {
      s.trialStart = DateTime.now();
      await s.prefs.setString('trial_start', s.trialStart.toIso8601String());
    } else {
      s.trialStart = DateTime.tryParse(trial) ?? DateTime.now();
    }
    s.activated = s.prefs.getBool('activated') ?? false;
    try {
      final raw = jsonDecode(s.prefs.getString('customers') ?? '[]') as List;
      s.customers.addAll(raw.map((e) => Customer.fromMap(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      final raw = jsonDecode(s.prefs.getString('transactions') ?? '[]') as List;
      s.transactions.addAll(raw.map((e) => TransactionItem.fromMap(Map<String, dynamic>.from(e))));
    } catch (_) {}
    return s;
  }

  int get trialDaysLeft {
    if (activated) return 0;
    final used = DateTime.now().difference(trialStart).inDays;
    return max(0, 10 - used);
  }
  bool get locked => !activated && trialDaysLeft <= 0;

  Future<void> connect() async {
    try {
      final user = FirebaseAuth.instance.currentUser ?? (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) return;
      uid = user.uid;
      firebaseReady = true;
      final activation = await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).get();
      if (activation.exists && activation.data()?['activated'] == true) {
        activated = true;
        await prefs.setBool('activated', true);
      }
      await pullCloud();
    } catch (_) {
      firebaseReady = false;
    }
    notifyListeners();
  }

  CollectionReference<Map<String, dynamic>> get customerRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('customers');
  CollectionReference<Map<String, dynamic>> get transactionRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('transactions');

  Future<void> pullCloud() async {
    if (!firebaseReady) return;
    try {
      final cs = await customerRef.get();
      for (final d in cs.docs) {
        final c = Customer.fromMap(d.data());
        final i = customers.indexWhere((x) => x.id == c.id);
        if (i < 0) customers.add(c); else customers[i] = c;
      }
      final ts = await transactionRef.get();
      for (final d in ts.docs) {
        final m = d.data();
        final rawDate = m['date'];
        final date = rawDate is Timestamp ? rawDate.toDate() : DateTime.tryParse('${rawDate ?? ''}') ?? DateTime.now();
        final t = TransactionItem(id: '${m['id'] ?? d.id}', customerId: '${m['customerId'] ?? ''}', type: '${m['type'] ?? 'debt'}', amount: (m['amount'] as num?)?.toDouble() ?? 0, date: date, note: '${m['note'] ?? ''}', receiptPath: '${m['receiptPath'] ?? ''}', receiptUrl: '${m['receiptUrl'] ?? ''}');
        final i = transactions.indexWhere((x) => x.id == t.id);
        if (i < 0) transactions.add(t); else transactions[i] = t;
      }
      await saveLocal();
    } catch (_) {}
  }

  double balance(String customerId) {
    var value = 0.0;
    for (final t in transactions.where((x) => x.customerId == customerId)) {
      value += t.type == 'debt' ? t.amount : -t.amount;
    }
    return value;
  }
  double debt(String customerId) => transactions.where((x) => x.customerId == customerId && x.type == 'debt').fold(0.0, (a, x) => a + x.amount);
  double paid(String customerId) => transactions.where((x) => x.customerId == customerId && x.type == 'payment').fold(0.0, (a, x) => a + x.amount);

  Future<void> saveLocal() async {
    await prefs.setString('customers', jsonEncode(customers.map((e) => e.toMap()).toList()));
    await prefs.setString('transactions', jsonEncode(transactions.map((e) => e.toMap()).toList()));
    await prefs.setString('shop_name', shopName);
    await prefs.setString('whatsapp_text', whatsappText);
  }
  Future<void> save() async {
    await saveLocal();
    if (firebaseReady) {
      try {
        final batch = FirebaseFirestore.instance.batch();
        for (final c in customers) batch.set(customerRef.doc(c.id), c.toMap());
        for (final t in transactions) batch.set(transactionRef.doc(t.id), {...t.toMap(), 'date': Timestamp.fromDate(t.date)});
        await batch.commit();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<bool> activateCode(String code) async {
    if (!firebaseReady || code.trim().isEmpty) return false;
    try {
      final ref = FirebaseFirestore.instance.collection('activation_codes').doc(code.trim());
      final ok = await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        if (!snap.exists || data == null || data['used'] == true) return false;
        final bound = '${data['deviceId'] ?? ''}';
        if (bound.isNotEmpty && bound != deviceId) return false;
        tx.update(ref, {'used': true, 'usedDeviceId': deviceId, 'usedAt': FieldValue.serverTimestamp()});
        return true;
      });
      if (!ok) return false;
      await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).set({'activated': true, 'uid': uid, 'activatedAt': FieldValue.serverTimestamp()});
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
    final ref = FirebaseFirestore.instance.collection('activation_codes');
    String code = '';
    for (var i = 0; i < 10; i++) {
      final candidate = '${100000 + Random().nextInt(900000)}';
      if (!(await ref.doc(candidate).get()).exists) { code = candidate; break; }
    }
    if (code.isEmpty) return null;
    await ref.doc(code).set({'deviceId': targetDevice.trim(), 'used': false, 'createdAt': FieldValue.serverTimestamp()});
    return code;
  }
}

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store});
  final AppStore store;
  ThemeData makeTheme(Brightness b) => ThemeData(useMaterial3: true, brightness: b, colorSchemeSeed: const Color(0xFF0F5C6E), fontFamily: 'Cairo');
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: store, builder: (_, __) => MaterialApp(debugShowCheckedModeBanner: false, theme: makeTheme(Brightness.light), darkTheme: makeTheme(Brightness.dark), themeMode: ThemeMode.system, home: HomePage(store: store)));
}

class HomePage extends StatefulWidget { const HomePage({super.key, required this.store}); final AppStore store; @override State<HomePage> createState() => _HomePageState(); }
class _HomePageState extends State<HomePage> {
  String search = ''; String filter = 'all'; int taps = 0; DateTime? lastTap;
  void ownerShortcut() { final now = DateTime.now(); if (lastTap == null || now.difference(lastTap!).inSeconds > 2) taps = 0; lastTap = now; taps++; if (taps == 3) { taps = 0; showDialog(context: context, builder: (_) => OwnerGate(store: widget.store)); } }
  @override Widget build(BuildContext context) {
    final s = widget.store;
    final list = s.customers.where((c) {
      final b = s.balance(c.id); final match = search.isEmpty || c.name.contains(search) || c.phone.contains(search);
      final type = filter == 'all' || (filter == 'debt' && b > 0) || (filter == 'paid' && b <= 0); return match && type;
    }).toList();
    list.sort((a, b) => s.balance(b.id).compareTo(s.balance(a.id)));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: GestureDetector(onTap: ownerShortcut, child: Text(s.shopName)), actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(store: s))))]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (!s.activated) Card(child: ListTile(title: Text(s.locked ? 'انتهت التجربة' : 'الفترة التجريبية'), subtitle: Text(s.locked ? 'يلزم التفعيل' : 'متبقٍ ${s.trialDaysLeft} أيام'), trailing: FilledButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: s))), child: const Text('التفعيل')))),
        TextField(decoration: const InputDecoration(hintText: 'بحث بالاسم أو رقم الهاتف', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => search = v)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [ChoiceChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) => setState(() => filter = 'all')), ChoiceChip(label: const Text('عليهم دين'), selected: filter == 'debt', onSelected: (_) => setState(() => filter = 'debt')), ChoiceChip(label: const Text('مسدد'), selected: filter == 'paid', onSelected: (_) => setState(() => filter = 'paid'))]),
        const SizedBox(height: 8),
        ...list.map((c) => Card(child: ListTile(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPage(store: s, customer: c))), title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${c.phone}\n${s.balance(c.id) > 0 ? 'عليه دين' : 'مسدد'}'), isThreeLine: true, trailing: Text(money(s.balance(c.id))))),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: s.locked ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationPage(store: s))) : () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddCustomerPage(store: s))), icon: Icon(s.locked ? Icons.lock : Icons.person_add), label: Text(s.locked ? 'التفعيل' : 'إضافة عميل')),
    );
  }
}

class AddCustomerPage extends StatefulWidget { const AddCustomerPage({super.key, required this.store}); final AppStore store; @override State<AddCustomerPage> createState() => _AddCustomerPageState(); }
class _AddCustomerPageState extends State<AddCustomerPage> { final name=TextEditingController(); final phone=TextEditingController(); final limit=TextEditingController(); Future<void> save() async { if(name.text.trim().isEmpty)return; widget.store.customers.add(Customer(id:id(),name:name.text.trim(),phone:phone.text.trim(),limit:double.tryParse(limit.text.replaceAll(',','.'))??0)); await widget.store.save(); if(mounted)Navigator.pop(context); } @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('إضافة عميل')),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:name,decoration:const InputDecoration(labelText:'اسم العميل')),TextField(controller:phone,decoration:const InputDecoration(labelText:'رقم الهاتف')),TextField(controller:limit,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'السقف الائتماني اختياري')),const SizedBox(height:16),FilledButton(onPressed:save,child:const Text('حفظ'))]))); }

class CustomerPage extends StatelessWidget { const CustomerPage({super.key,required this.store,required this.customer}); final AppStore store; final Customer customer; Future<void> whatsapp() async { final msg=store.whatsappText.replaceAll('[الاسم]',customer.name).replaceAll('[المبلغ]',money(store.balance(customer.id))); await launchUrl(Uri.https('wa.me','/${cleanPhone(customer.phone)}',{'text':msg}),mode:LaunchMode.externalApplication); } @override Widget build(BuildContext context){ final items=store.transactions.where((x)=>x.customerId==customer.id).toList()..sort((a,b)=>b.date.compareTo(a.date)); return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:Text(customer.name)),body:ListView(padding:const EdgeInsets.all(12),children:[Card(child:ListTile(title:Text(money(store.balance(customer.id)),style:const TextStyle(fontSize:26,fontWeight:FontWeight.bold)),subtitle:Text('دين ${money(store.debt(customer.id))} • مسدد ${money(store.paid(customer.id))}'),trailing:Wrap(children:[IconButton(onPressed:whatsapp,icon:const Icon(Icons.chat)),IconButton(onPressed:()=>launchUrl(Uri.parse('tel:${customer.phone}')),icon:const Icon(Icons.phone))]))),...items.map((t)=>ListTile(title:Text(t.type=='debt'?'دَين':'تسديد'),subtitle:Text('${day(t.date)} ${t.note}'),trailing:Text(money(t.amount))))]),floatingActionButton:FloatingActionButton.extended(onPressed:store.locked?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ActivationPage(store:store))):()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>TransactionPage(store:store,customer:customer))),icon:Icon(store.locked?Icons.lock:Icons.add),label:Text(store.locked?'التفعيل':'عملية')))); } }

class TransactionPage extends StatefulWidget { const TransactionPage({super.key,required this.store,required this.customer}); final AppStore store; final Customer customer; @override State<TransactionPage> createState()=>_TransactionPageState(); }
class _TransactionPageState extends State<TransactionPage>{ final amount=TextEditingController(); final note=TextEditingController(); final spoken=TextEditingController(); final picker=ImagePicker(); final speech=stt.SpeechToText(); String type='debt'; String receiptPath=''; String receiptUrl=''; bool listening=false;
 Future<void>voice()async{if(listening){await speech.stop();setState(()=>listening=false);return;}final ok=await speech.initialize(onStatus:(x){if(mounted)setState(()=>listening=x=='listening');},onError:(_){if(mounted)setState(()=>listening=false);});if(!ok)return;setState(()=>listening=true);await speech.listen(localeId:'ar-LY',partialResults:true,onResult:(r){spoken.text=r.recognizedWords;final m=RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(r.recognizedWords);if(m!=null)amount.text=m.group(1)!.replaceAll(',','.');if(r.finalResult&&mounted)setState(()=>listening=false);});}
 Future<void>receipt()async{final source=await showModalBottomSheet<ImageSource>(context:context,builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[ListTile(title:const Text('تصوير الإيصال بالكاميرا'),onTap:()=>Navigator.pop(c,ImageSource.camera)),ListTile(title:const Text('اختيار من المعرض'),onTap:()=>Navigator.pop(c,ImageSource.gallery))])));if(source==null)return;final image=await picker.pickImage(source:source,imageQuality:85);if(image==null)return;final dir=await getApplicationDocumentsDirectory();final file=await File(image.path).copy('${dir.path}/receipt_${DateTime.now().microsecondsSinceEpoch}.jpg');receiptPath=file.path;if(widget.store.firebaseReady){try{final ref=FirebaseStorage.instance.ref('users/${widget.store.uid}/receipts/${file.uri.pathSegments.last}');await ref.putFile(file);receiptUrl=await ref.getDownloadURL();}catch(_){}}setState((){});}
 Future<void>save()async{final value=double.tryParse(amount.text.replaceAll(',','.'))??0;if(value<=0){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('أدخل مبلغًا صحيحًا')));return;}if(type=='debt'&&widget.customer.limit>0&&widget.store.balance(widget.customer.id)+value>widget.customer.limit){await showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('تجاوز السقف الائتماني'),content:Text('السقف ${money(widget.customer.limit)}. لا يمكن تسجيل الدين.'),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('حسنًا'))]));return;}widget.store.transactions.add(TransactionItem(id:id(),customerId:widget.customer.id,type:type,amount:value,date:DateTime.now(),note:note.text,receiptPath:receiptPath,receiptUrl:receiptUrl));await widget.store.save();if(mounted)Navigator.pop(context);}
 @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:Text(type=='debt'?'إضافة دَين':'تسديد')),body:ListView(padding:const EdgeInsets.all(16),children:[SegmentedButton<String>(segments:const[ButtonSegment(value:'debt',label:Text('دَين')),ButtonSegment(value:'payment',label:Text('تسديد'))],selected:{type},onSelectionChanged:(v)=>setState(()=>type=v.first)),TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ')),TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات')),OutlinedButton.icon(onPressed:voice,icon:Icon(listening?Icons.stop:Icons.mic),label:Text(listening?'إيقاف التسجيل':'تسجيل العملية بالصوت')),if(spoken.text.isNotEmpty)Text(spoken.text),Card(child:ListTile(title:const Text('صورة الإيصال اختيارية'),trailing:IconButton(onPressed:receipt,icon:const Icon(Icons.add_a_photo)))),if(receiptPath.isNotEmpty)Image.file(File(receiptPath),height:180),const SizedBox(height:16),FilledButton(onPressed:save,child:const Text('حفظ العملية'))]));}
}

class SettingsPage extends StatefulWidget{const SettingsPage({super.key,required this.store});final AppStore store;@override State<SettingsPage> createState()=>_SettingsPageState();}
class _SettingsPageState extends State<SettingsPage>{late TextEditingController shop,msg;int taps=0;DateTime? last;@override void initState(){super.initState();shop=TextEditingController(text:widget.store.shopName);msg=TextEditingController(text:widget.store.whatsappText);}void owner(){final n=DateTime.now();if(last==null||n.difference(last!).inSeconds>2)taps=0;last=n;taps++;if(taps==3){taps=0;showDialog(context:context,builder:(_)=>OwnerGate(store:widget.store));}}Future<void>save()async{widget.store.shopName=shop.text.trim();widget.store.whatsappText=msg.text.trim();await widget.store.save();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم الحفظ')));}@override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:GestureDetector(onTap:owner,child:const Text('الإعدادات'))),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:shop,decoration:const InputDecoration(labelText:'اسم المحل')),TextField(controller:msg,maxLines:4,decoration:const InputDecoration(labelText:'رسالة واتساب')),const ListTile(title:Text('المظهر'),subtitle:Text('تلقائي حسب وقت/مظهر الجهاز'),trailing:Icon(Icons.brightness_auto)),Text('رقم الجهاز: ${widget.store.deviceId}'),FilledButton(onPressed:save,child:const Text('حفظ')),OutlinedButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ActivationPage(store:widget.store))),child:const Text('الاشتراك والتفعيل'))]));}}

class ActivationPage extends StatefulWidget{const ActivationPage({super.key,required this.store});final AppStore store;@override State<ActivationPage> createState()=>_ActivationPageState();}
class _ActivationPageState extends State<ActivationPage>{final code=TextEditingController();bool busy=false;Future<void>activate()async{setState(()=>busy=true);final ok=await widget.store.activateCode(code.text);if(mounted)setState(()=>busy=false);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(ok?'تم التفعيل الدائم':'الكود غير صحيح أو مستخدم أو غير مرتبط بالجهاز')));if(ok&&mounted)Navigator.pop(context);}@override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('الاشتراك والتفعيل')),body:ListView(padding:const EdgeInsets.all(16),children:[Text(widget.store.activated?'التطبيق مفعّل دائمًا':'التجربة المجانية: ${widget.store.trialDaysLeft} أيام',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),Text('رقم الجهاز: ${widget.store.deviceId}'),FilledButton.icon(onPressed:()=>launchUrl(Uri.parse('https://wa.me/218934951072?text=${Uri.encodeComponent('طلب تفعيل DainPay - رقم الجهاز: ${widget.store.deviceId}')}'),mode:LaunchMode.externalApplication),icon:const Icon(Icons.chat),label:const Text('طلب التفعيل عبر واتساب')),TextField(controller:code,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'كود التفعيل')),FilledButton(onPressed:busy?null:activate,child:Text(busy?'جارٍ التحقق':'تفعيل دائم'))]));}}

class OwnerGate extends StatefulWidget{const OwnerGate({super.key,required this.store});final AppStore store;@override State<OwnerGate> createState()=>_OwnerGateState();}
class _OwnerGateState extends State<OwnerGate>{final pin=TextEditingController();void enter(){if(pin.text=='116936'){Navigator.pop(context);Navigator.push(context,MaterialPageRoute(builder:(_)=>OwnerPage(store:widget.store)));}else{ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('رمز المالك غير صحيح')));}}@override Widget build(BuildContext context)=>AlertDialog(title:const Text('Adreemk'),content:TextField(controller:pin,obscureText:true,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'رمز المالك')),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('إلغاء')),FilledButton(onPressed:enter,child:const Text('دخول'))]);}}
class OwnerPage extends StatefulWidget{const OwnerPage({super.key,required this.store});final AppStore store;@override State<OwnerPage> createState()=>_OwnerPageState();}
class _OwnerPageState extends State<OwnerPage>{final device=TextEditingController();String generated='';Future<void>generate()async{final code=await widget.store.generateCode(device.text);setState(()=>generated=code??'تعذر التوليد');}@override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('Adreemk — المالك')),body:ListView(padding:const EdgeInsets.all(16),children:[const Text('توليد رمز دائم لمرة واحدة لكل عميل',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),TextField(controller:device,decoration:const InputDecoration(labelText:'رقم جهاز العميل')),FilledButton(onPressed:generate,child:const Text('توليد الرمز')),if(generated.isNotEmpty)Card(child:ListTile(title:const Text('رمز التفعيل'),subtitle:Text(generated,style:const TextStyle(fontSize:28,fontWeight:FontWeight.bold)),trailing:IconButton(onPressed:()=>launchUrl(Uri.parse('https://wa.me/218934951072?text=${Uri.encodeComponent('رمز تفعيل DainPay: $generated')}'),mode:LaunchMode.externalApplication),icon:const Icon(Icons.send))))]));}}
'''
Path('lib/main.dart').write_text(code)
