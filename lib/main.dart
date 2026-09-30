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
const slate = Color(0xFF0F172A);
const slate2 = Color(0xFF172033);
const coral = Color(0xFFF04444);
const mint = Color(0xFF22C55E);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (_) {}
  final store = await Store.load();
  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
String money(double v) => '${v.toStringAsFixed(2)} د.ل';
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
  try { return await launchUrl(Uri.https('wa.me', '/$n', {'text': message}), mode: LaunchMode.externalApplication); } catch (_) { return false; }
}

class Customer {
  Customer({required this.id, required this.name, required this.phone, this.limit = 0});
  String id, name, phone;
  double limit;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'limit': limit};
  factory Customer.fromJson(Map<String, dynamic> j) => Customer(id: '${j['id'] ?? ''}', name: '${j['name'] ?? ''}', phone: '${j['phone'] ?? ''}', limit: (j['limit'] as num?)?.toDouble() ?? 0);
}

class Tx {
  Tx({required this.id, required this.customerId, required this.type, required this.amount, required this.date, required this.note});
  String id, customerId, type, note;
  double amount;
  DateTime date;
  Map<String, dynamic> toJson() => {'id': id, 'customerId': customerId, 'type': type, 'amount': amount, 'date': date.toIso8601String(), 'note': note};
  factory Tx.fromJson(Map<String, dynamic> j) => Tx(id: '${j['id'] ?? ''}', customerId: '${j['customerId'] ?? ''}', type: '${j['type'] ?? 'debt'}', amount: (j['amount'] as num?)?.toDouble() ?? 0, date: DateTime.tryParse('${j['date']}') ?? DateTime.now(), note: '${j['note'] ?? ''}');
}

class VoiceDraft {
  VoiceDraft({required this.id, required this.text, required this.date, this.customerId = '', this.amount = 0, this.note = ''});
  String id, text, customerId, note;
  DateTime date;
  double amount;
  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'date': date.toIso8601String(), 'customerId': customerId, 'amount': amount, 'note': note};
  factory VoiceDraft.fromJson(Map<String, dynamic> j) => VoiceDraft(id: '${j['id'] ?? ''}', text: '${j['text'] ?? ''}', date: DateTime.tryParse('${j['date']}') ?? DateTime.now(), customerId: '${j['customerId'] ?? ''}', amount: (j['amount'] as num?)?.toDouble() ?? 0, note: '${j['note'] ?? ''}');
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  final customers = <Customer>[];
  final transactions = <Tx>[];
  final voiceDrafts = <VoiceDraft>[];
  String shop = 'DainPay — دَيْن';
  String whatsappMessage = 'السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  String uid = '', deviceId = '';
  bool firebaseReady = false, syncing = false, activated = false;
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
    final ts = s.prefs.getString('trial_start');
    if (ts == null) {
      s.trialStart = DateTime.now();
      await s.prefs.setString('trial_start', s.trialStart!.toIso8601String());
    } else {
      s.trialStart = DateTime.tryParse(ts);
    }
    s.activated = s.prefs.getBool('activated') ?? false;
    try {
      final a = jsonDecode(s.prefs.getString('customers') ?? '[]') as List;
      s.customers.addAll(a.map((e) => Customer.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      final a = jsonDecode(s.prefs.getString('transactions') ?? '[]') as List;
      s.transactions.addAll(a.map((e) => Tx.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      final a = jsonDecode(s.prefs.getString('voice_drafts') ?? '[]') as List;
      s.voiceDrafts.addAll(a.map((e) => VoiceDraft.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    return s;
  }

  int get trialDaysLeft => activated || trialStart == null ? 0 : max(0, 10 - DateTime.now().difference(trialStart!).inDays);
  bool get locked => !activated && trialDaysLeft <= 0;
  CollectionReference<Map<String, dynamic>> get customersRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('customers');
  CollectionReference<Map<String, dynamic>> get transactionsRef => FirebaseFirestore.instance.collection('users').doc(uid).collection('transactions');

  Future<void> connectFirebase() async {
    try {
      var u = FirebaseAuth.instance.currentUser;
      u ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (u == null) return;
      uid = u.uid;
      firebaseReady = true;
      await pullCloud();
      await loadActivation();
      syncTimer?.cancel();
      syncTimer = Timer.periodic(const Duration(seconds: 60), (_) => saveCloud());
    } catch (_) { firebaseReady = false; }
    notifyListeners();
  }

  Future<void> loadActivation() async {
    if (!firebaseReady) return;
    try {
      final d = await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).get();
      if (d.data()?['activated'] == true) {
        activated = true;
        await prefs.setBool('activated', true);
      }
    } catch (_) {}
  }

  Future<void> pullCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      for (final d in (await customersRef.get()).docs) {
        final c = Customer.fromJson(d.data());
        final i = customers.indexWhere((x) => x.id == c.id);
        if (i < 0) customers.add(c); else customers[i] = c;
      }
      for (final d in (await transactionsRef.get()).docs) {
        final x = d.data();
        final raw = x['date'];
        final dt = raw is Timestamp ? raw.toDate() : DateTime.tryParse('$raw') ?? DateTime.now();
        final t = Tx(id: '${x['id'] ?? d.id}', customerId: '${x['customerId'] ?? ''}', type: '${x['type'] ?? 'debt'}', amount: (x['amount'] as num?)?.toDouble() ?? 0, date: dt, note: '${x['note'] ?? ''}');
        final i = transactions.indexWhere((z) => z.id == t.id);
        if (i < 0) transactions.add(t); else transactions[i] = t;
      }
      await saveLocal();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveCloud() async {
    if (!firebaseReady || uid.isEmpty || syncing) return;
    syncing = true;
    try {
      final b = FirebaseFirestore.instance.batch();
      for (final c in customers) b.set(customersRef.doc(c.id), c.toJson());
      for (final t in transactions) b.set(transactionsRef.doc(t.id), {...t.toJson(), 'date': Timestamp.fromDate(t.date)});
      await b.commit();
    } catch (_) {} finally { syncing = false; }
  }

  Future<void> saveLocal() async {
    await prefs.setString('customers', jsonEncode(customers.map((e) => e.toJson()).toList()));
    await prefs.setString('transactions', jsonEncode(transactions.map((e) => e.toJson()).toList()));
    await prefs.setString('voice_drafts', jsonEncode(voiceDrafts.map((e) => e.toJson()).toList()));
    await prefs.setString('shop', shop);
    await prefs.setString('whatsappMessage', whatsappMessage);
  }

  Future<void> save() async { await saveLocal(); notifyListeners(); await saveCloud(); }
  double balance(String id) => transactions.where((t) => t.customerId == id).fold(0.0, (a, t) => a + (t.type == 'debt' ? t.amount : -t.amount));
  double debts(String id) => transactions.where((t) => t.customerId == id && t.type == 'debt').fold(0.0, (a, t) => a + t.amount);
  double paid(String id) => transactions.where((t) => t.customerId == id && t.type == 'payment').fold(0.0, (a, t) => a + t.amount);
  String risk(String id) {
    final b = balance(id);
    if (b <= 0) return 'مسدد';
    final ds = transactions.where((t) => t.customerId == id && t.type == 'debt').toList()..sort((a, b) => a.date.compareTo(b.date));
    if (ds.isEmpty) return 'حديث';
    final days = DateTime.now().difference(ds.first.date).inDays;
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
        final d = snap.data();
        if (!snap.exists || d == null || d['used'] == true) return false;
        final bound = '${d['deviceId'] ?? ''}';
        if (bound.isNotEmpty && bound != deviceId) return false;
        tx.update(ref, {'used': true, 'usedAt': FieldValue.serverTimestamp(), 'usedDeviceId': deviceId});
        return true;
      });
      if (!ok) return false;
      await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).set({'activated': true, 'activatedAt': FieldValue.serverTimestamp(), 'uid': uid});
      activated = true;
      await prefs.setBool('activated', true);
      notifyListeners();
      return true;
    } catch (_) { return false; }
  }

  Future<String?> generateCode(String targetDevice) async {
    if (!firebaseReady || targetDevice.trim().isEmpty) return null;
    try {
      String code;
      do { code = (100000 + Random().nextInt(900000)).toString(); } while ((await FirebaseFirestore.instance.collection('activation_codes').doc(code).get()).exists);
      await FirebaseFirestore.instance.collection('activation_codes').doc(code).set({'deviceId': targetDevice.trim(), 'used': false, 'createdAt': FieldValue.serverTimestamp()}).timeout(const Duration(seconds: 12));
      return code;
    } catch (_) { return null; }
  }

  Future<void> clearLocal() async {
    customers.clear(); transactions.clear(); voiceDrafts.clear();
    await prefs.remove('customers'); await prefs.remove('transactions'); await prefs.remove('voice_drafts');
    notifyListeners();
  }
  @override void dispose() { syncTimer?.cancel(); super.dispose(); }
}

class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store});
  final Store store;
  ThemeData theme(Brightness b) => ThemeData(
    useMaterial3: true,
    brightness: b,
    fontFamily: 'Cairo',
    scaffoldBackgroundColor: b == Brightness.dark ? slate : const Color(0xFFF6F8FA),
    colorScheme: ColorScheme.fromSeed(seedColor: emerald, brightness: b),
    appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    cardTheme: CardThemeData(margin: EdgeInsets.zero, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)), filled: true, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
  );
  @override Widget build(BuildContext c) => AnimatedBuilder(animation: store, builder: (_, __) => MaterialApp(debugShowCheckedModeBanner: false, theme: theme(Brightness.light), darkTheme: theme(Brightness.dark), themeMode: ThemeMode.system, home: HomePage(store: store)));
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 52});
  final double size;
  @override Widget build(BuildContext context) => Container(width: size, height: size, decoration: BoxDecoration(borderRadius: BorderRadius.circular(size * .25), gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF34D399), Color(0xFF087F5B)]), boxShadow: [BoxShadow(color: emerald.withOpacity(.28), blurRadius: 18, offset: const Offset(0, 8))]), child: Center(child: Stack(alignment: Alignment.center, children: [Text('D', style: TextStyle(fontSize: size * .55, fontWeight: FontWeight.w900, color: Colors.white)), Positioned(right: size * .12, bottom: size * .12, child: Text('P', style: TextStyle(fontSize: size * .25, fontWeight: FontWeight.w900, color: const Color(0xFFB7F7DB))))]));
}

class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child; final EdgeInsets padding;
  @override Widget build(BuildContext context) => Card(child: Padding(padding: padding, child: child));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});
  final Store store;
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  int tab = 0; String query = '', filter = 'all'; int taps = 0; DateTime? lastTap;
  void hidden() { final n = DateTime.now(); if (lastTap == null || n.difference(lastTap!).inSeconds > 2) taps = 0; lastTap = n; taps++; if (taps == 3) { taps = 0; showDialog(context: context, builder: (_) => AdminGate(store: widget.store)); } }
  @override Widget build(BuildContext context) {
    final s = widget.store;
    final customers = s.customers.where((x) => query.isEmpty || x.name.contains(query) || x.phone.contains(query)).toList()..sort((a,b)=>s.balance(b.id).compareTo(s.balance(a.id)));
    final owedToYou = s.customers.fold<double>(0, (a,c)=>a + max(0,s.balance(c.id)));
    final paidTotal = s.transactions.where((t)=>t.type=='payment').fold<double>(0,(a,t)=>a+t.amount);
    final recent = [...s.transactions]..sort((a,b)=>b.date.compareTo(a.date));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: GestureDetector(onTap: hidden, child: Row(children:[const BrandMark(size:38), const SizedBox(width:10), Text('DaiynPay',style:const TextStyle(fontWeight:FontWeight.w800))])), actions:[IconButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SettingsPage(store:s))),icon:const Icon(Icons.tune_rounded))]),
      body: tab==0 ? RefreshIndicator(onRefresh:()=>s.pullCloud(), child: ListView(padding:const EdgeInsets.fromLTRB(16,8,16,100),children:[
        Row(children:[Expanded(child:Text('مرحباً 👋',style:Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight:FontWeight.w800))),Text(s.firebaseReady?'متصل':'محلي',style:TextStyle(color:s.firebaseReady?mint:Colors.orange,fontWeight:FontWeight.w700))]),
        const SizedBox(height:14),
        GlassCard(child:Container(decoration:BoxDecoration(borderRadius:BorderRadius.circular(16),gradient:LinearGradient(colors:[deepEmerald,const Color(0xFF0B5F55)])),padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('ملخص الدفتر',style:TextStyle(color:Colors.white70)),const SizedBox(height:12),Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('المتبقي عليك',style:TextStyle(color:Colors.white70)),Text('0.00 د.ل',style:TextStyle(color:Colors.white,fontSize:24,fontWeight:FontWeight.w900))])),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('المستحق لك',style:TextStyle(color:Colors.white70)),Text(money(owedToYou),style:const TextStyle(color:Color(0xFFB7F7DB),fontSize:24,fontWeight:FontWeight.w900))]))]),const SizedBox(height:8),Text('إجمالي المسدد ${money(paidTotal)}',style:const TextStyle(color:Colors.white70))]))),
        const SizedBox(height:14),
        Row(children:[Expanded(child:_ActionButton(icon:Icons.add_rounded,label:'إضافة دين',color:emerald,onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>AddCustomerPage(store:s))))),const SizedBox(width:8),Expanded(child:_ActionButton(icon:Icons.payments_rounded,label:'تسجيل تسديد',color:const Color(0xFF4F7CFF),onTap:()=>_chooseCustomer(context,s,'payment'))),const SizedBox(width:8),Expanded(child:_ActionButton(icon:Icons.mic_rounded,label:'تسجيل صوتي',color:const Color(0xFF8B5CF6),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>VoiceDraftsPage(store:s)))))]),
        const SizedBox(height:18),
        if(!s.activated) GlassCard(child:ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.workspace_premium_rounded,color:Color(0xFFF59E0B)),title:Text(s.locked?'انتهت التجربة':'التجربة المجانية 10 أيام',style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text(s.locked?'يلزم التفعيل': 'متبقٍ ${s.trialDaysLeft} أيام'),trailing:FilledButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ActivationPage(store:s))),child:const Text('تفعيل')))),
        const SizedBox(height:18),
        TextField(decoration:const InputDecoration(hintText:'ابحث باسم العميل أو الهاتف',prefixIcon:Icon(Icons.search_rounded)),onChanged:(v)=>setState(()=>query=v)),
        const SizedBox(height:12),
        Row(children:[_FilterChip('الكل',filter=='all',()=>setState(()=>filter='all')),_FilterChip('عليهم دين',filter=='debt',()=>setState(()=>filter='debt')),_FilterChip('مسدد',filter=='paid',()=>setState(()=>filter='paid'))]),
        const SizedBox(height:16),
        if(customers.isEmpty) GlassCard(child:Column(children:[const Icon(Icons.menu_book_rounded,size:46,color:emerald),const SizedBox(height:8),const Text('دفترك فارغ حالياً',style:TextStyle(fontWeight:FontWeight.w800)),const SizedBox(height:4),const Text('ابدأ بإضافة أول عميل ودين له.')])),
        ...customers.where((c){final b=s.balance(c.id);return filter=='all'||(filter=='debt'&&b>0)||(filter=='paid'&&b<=0);}).take(20).map((c)=>_CustomerCard(store:s,customer:c)),
        if(recent.isNotEmpty) ...[const SizedBox(height:18),const Text('آخر العمليات',style:TextStyle(fontSize:18,fontWeight:FontWeight.w800)),const SizedBox(height:8),...recent.take(5).map((t){final c=s.customers.where((x)=>x.id==t.customerId).cast<Customer?>().firstWhere((x)=>x!=null,orElse:()=>null);return ListTile(leading:CircleAvatar(backgroundColor:t.type=='debt'?coral.withOpacity(.12):mint.withOpacity(.12),child:Icon(t.type=='debt'?Icons.arrow_downward_rounded:Icons.arrow_upward_rounded,color:t.type=='debt'?coral:mint)),title:Text(c?.name??'عميل'),subtitle:Text('${dateText(t.date)} • ${t.note}'),trailing:Text('${t.type=='debt'?'+':'-'}${money(t.amount)}',style:TextStyle(fontWeight:FontWeight.w800,color:t.type=='debt'?coral:mint)));})]
      ])) : CustomersPage(store:s),
      bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const[NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home),label:'الرئيسية'),NavigationDestination(icon:Icon(Icons.people_outline),selectedIcon:Icon(Icons.people),label:'العملاء'),NavigationDestination(icon:Icon(Icons.receipt_long_outlined),selectedIcon:Icon(Icons.receipt_long),label:'المعاملات')]),
      floatingActionButton:FloatingActionButton.extended(onPressed:()=>_chooseCustomer(context,s,'debt'),icon:const Icon(Icons.add),label:const Text('عملية جديدة')),
    ));
  }
  Future<void> _chooseCustomer(BuildContext context,Store s,String type) async { if(s.locked){await Navigator.push(context,MaterialPageRoute(builder:(_)=>ActivationPage(store:s)));return;} if(s.customers.isEmpty){await Navigator.push(context,MaterialPageRoute(builder:(_)=>AddCustomerPage(store:s)));return;} final c=await showModalBottomSheet<Customer>(context:context,showDragHandle:true,builder:(_)=>Directionality(textDirection:TextDirection.rtl,child:ListView(padding:const EdgeInsets.all(16),children:[const Text('اختر العميل',style:TextStyle(fontSize:20,fontWeight:FontWeight.w800)),const SizedBox(height:10),...s.customers.map((x)=>ListTile(leading:const CircleAvatar(child:Icon(Icons.person)),title:Text(x.name),subtitle:Text(x.phone),onTap:()=>Navigator.pop(context,x)))]))); if(c!=null&&mounted) Navigator.push(context,MaterialPageRoute(builder:(_)=>AddTransactionPage(store:s,customer:c,initialType:type))); }
}

class _ActionButton extends StatelessWidget { const _ActionButton({required this.icon,required this.label,required this.color,required this.onTap}); final IconData icon;final String label;final Color color;final VoidCallback onTap; @override Widget build(BuildContext c)=>InkWell(onTap:onTap,borderRadius:BorderRadius.circular(18),child:Container(padding:const EdgeInsets.symmetric(vertical:14,horizontal:8),decoration:BoxDecoration(color:color.withOpacity(.12),borderRadius:BorderRadius.circular(18),border:Border.all(color:color.withOpacity(.18))),child:Column(children:[Icon(icon,color:color),const SizedBox(height:5),Text(label,textAlign:TextAlign.center,style:const TextStyle(fontSize:11,fontWeight:FontWeight.w800))]))); }
class _FilterChip extends StatelessWidget { const _FilterChip(this.text,this.selected,this.onTap); final String text;final bool selected;final VoidCallback onTap; @override Widget build(BuildContext c)=>Padding(padding:const EdgeInsets.only(left:6),child:ChoiceChip(label:Text(text),selected:selected,onSelected:(_)=>onTap())); }
class _CustomerCard extends StatelessWidget { const _CustomerCard({required this.store,required this.customer}); final Store store;final Customer customer; @override Widget build(BuildContext c){final b=store.balance(customer.id);final risk=store.risk(customer.id);final color=b<=0?mint:(risk=='خطر'?coral:const Color(0xFFF59E0B));return Padding(padding:const EdgeInsets.only(bottom:8),child:Card(child:ListTile(onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>CustomerPage(store:store,customer:customer))),leading:CircleAvatar(backgroundColor:color.withOpacity(.12),child:Text(customer.name.isEmpty?'؟':customer.name.substring(0,1),style:TextStyle(color:color,fontWeight:FontWeight.w900))),title:Text(customer.name,style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(customer.phone),const SizedBox(height:4),LinearProgressIndicator(value:store.debts(customer.id)<=0?1:(store.paid(customer.id)/store.debts(customer.id)).clamp(0,1),minHeight:5,borderRadius:BorderRadius.circular(8),color:color)]),trailing:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.end,children:[Text(money(b),style:TextStyle(fontWeight:FontWeight.w900,color:color)),Text(risk,style:TextStyle(fontSize:11,color:color,fontWeight:FontWeight.w700))]))));}}

class CustomersPage extends StatelessWidget { const CustomersPage({super.key,required this.store}); final Store store; @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:ListView(padding:const EdgeInsets.all(16),children:[Text('العملاء',style:Theme.of(c).textTheme.headlineSmall?.copyWith(fontWeight:FontWeight.w900)),const SizedBox(height:12),...store.customers.map((x)=>_CustomerCard(store:store,customer:x))])); }

class AddCustomerPage extends StatefulWidget { const AddCustomerPage({super.key,required this.store}); final Store store; @override State<AddCustomerPage> createState()=>_AddCustomerPageState(); }
class _AddCustomerPageState extends State<AddCustomerPage>{final name=TextEditingController(),phone=TextEditingController(),limit=TextEditingController();@override Widget build(BuildContext c)=>_Page(title:'إضافة عميل',children:[_Field(name,'اسم العميل',Icons.person_outline),_Field(phone,'رقم الهاتف',Icons.phone_outlined,type:TextInputType.phone),_Field(limit,'السقف الائتماني اختياري',Icons.account_balance_wallet_outlined,type:TextInputType.number),const SizedBox(height:8),FilledButton.icon(onPressed:()async{if(name.text.trim().isEmpty)return;widget.store.customers.add(Customer(id:makeId(),name:name.text.trim(),phone:phone.text.trim(),limit:double.tryParse(limit.text.replaceAll(',','.'))??0));await widget.store.save();if(mounted)Navigator.pop(c);},icon:const Icon(Icons.check),label:const Text('حفظ العميل'))]);}

class CustomerPage extends StatelessWidget { const CustomerPage({super.key,required this.store,required this.customer}); final Store store;final Customer customer; String statement(){final tx=[...store.transactions.where((t)=>t.customerId==customer.id)]..sort((a,b)=>a.date.compareTo(b.date));var bal=0.0;final b=StringBuffer('كشف حساب — ${customer.name}\n');b.writeln('إجمالي الدين: ${money(store.debts(customer.id))}');b.writeln('إجمالي السداد: ${money(store.paid(customer.id))}');b.writeln('المتبقي: ${money(store.balance(customer.id))}');b.writeln('------------------------------');b.writeln('التاريخ | النوع | المبلغ | الرصيد');for(final t in tx){bal+=t.type=='debt'?t.amount:-t.amount;b.writeln('${dateText(t.date)} | ${t.type=='debt'?'دين':'سداد'} | ${money(t.amount)} | ${money(bal)}');}return b.toString();} String receipt(Tx t)=>'وصل استلام من ${customer.name}\nالمبلغ المستلم: ${money(t.amount)}\nالتاريخ: ${dateText(t.date)} ${timeText(t.date)}\nالمتبقي بعد السداد: ${money(store.balance(customer.id))}\n${store.shop}';@override Widget build(BuildContext c){final tx=[...store.transactions.where((t)=>t.customerId==customer.id)]..sort((a,b)=>b.date.compareTo(a.date));final bal=store.balance(customer.id);return _Page(title:customer.name,children:[GlassCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[const BrandMark(size:44),const SizedBox(width:10),Expanded(child:Text(customer.name,style:const TextStyle(fontSize:20,fontWeight:FontWeight.w900))),_StatusChip(store.risk(customer.id))]),const SizedBox(height:18),Text(money(bal),style:TextStyle(fontSize:32,fontWeight:FontWeight.w900,color:bal<=0?mint:coral)),const Text('الرصيد المتبقي'),const SizedBox(height:12),Row(children:[Expanded(child:Text('الدين ${money(store.debts(customer.id))}')),Expanded(child:Text('السداد ${money(store.paid(customer.id))}'))]),const SizedBox(height:16),Row(children:[Expanded(child:OutlinedButton.icon(onPressed:()=>openWhatsApp(customer.phone,store.whatsappMessage.replaceAll('[الاسم]',customer.name).replaceAll('[المبلغ]',money(bal))),icon:const Icon(Icons.chat),label:const Text('تذكير واتساب'))),const SizedBox(width:8),Expanded(child:FilledButton.icon(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>AddTransactionPage(store:store,customer:customer,initialType:'payment'))),icon:const Icon(Icons.payments),label:const Text('تسجيل سداد')))])])),const SizedBox(height:18),Text('سجل الحركات',style:Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight:FontWeight.w900)),const SizedBox(height:8),...tx.map((t)=>ListTile(leading:CircleAvatar(backgroundColor:(t.type=='debt'?coral:mint).withOpacity(.12),child:Icon(t.type=='debt'?Icons.add:Icons.check,color:t.type=='debt'?coral:mint)),title:Text(t.type=='debt'?'إضافة دين':'تسديد',style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text('${dateText(t.date)} ${timeText(t.date)} • ${t.note}'),trailing:Text(money(t.amount),style:TextStyle(fontWeight:FontWeight.w900,color:t.type=='debt'?coral:mint))),),const SizedBox(height:8),OutlinedButton.icon(onPressed:()=>openWhatsApp(customer.phone,statement()),icon:const Icon(Icons.receipt_long),label:const Text('إرسال كشف الحساب عبر واتساب'))]);}}

class AddTransactionPage extends StatefulWidget { const AddTransactionPage({super.key,required this.store,required this.customer,required this.initialType}); final Store store;final Customer customer;final String initialType;@override State<AddTransactionPage> createState()=>_AddTransactionPageState(); }
class _AddTransactionPageState extends State<AddTransactionPage>{late String type;final amount=TextEditingController(),note=TextEditingController();@override void initState(){super.initState();type=widget.initialType;}Future<void> saveTx()async{final v=double.tryParse(amount.text.replaceAll(',','.'))??0;if(v<=0)return;final current=widget.store.balance(widget.customer.id);if(type=='debt'&&widget.customer.limit>0&&current+v>widget.customer.limit){if(mounted)showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('تجاوز السقف الائتماني'),content:Text('السقف ${money(widget.customer.limit)} والمتاح ${money(max(0,widget.customer.limit-current))}.'),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('حسنًا'))]));return;}final t=Tx(id:makeId(),customerId:widget.customer.id,type:type,amount:v,date:DateTime.now(),note:note.text.trim());widget.store.transactions.add(t);await widget.store.save();if(type=='payment'&&mounted){final send=await showDialog<bool>(context:context,builder:(_)=>AlertDialog(title:const Text('تم تسجيل السداد'),content:Text('المتبقي ${money(widget.store.balance(widget.customer.id))}'),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('لا')),FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('إرسال وصل واتساب'))]));if(send==true)await openWhatsApp(widget.customer.phone,'وصل استلام من ${widget.customer.name}\nالمبلغ المستلم: ${money(v)}\nالتاريخ: ${dateText(t.date)} ${timeText(t.date)}\nالمتبقي: ${money(widget.store.balance(widget.customer.id))}\n${widget.store.shop}');}if(mounted)Navigator.pop(context);}@override Widget build(BuildContext c)=>_Page(title:type=='debt'?'إضافة دين':'تسجيل سداد',children:[SegmentedButton<String>(segments:const[ButtonSegment(value:'debt',label:Text('دين')),ButtonSegment(value:'payment',label:Text('سداد'))],selected:{type},onSelectionChanged:(v)=>setState(()=>type=v.first)),const SizedBox(height:16),_Field(amount,'المبلغ بالدينار الليبي',Icons.payments_outlined,type:TextInputType.number),_Field(note,'ملاحظات اختيارية',Icons.notes_outlined),const SizedBox(height:8),FilledButton.icon(onPressed:widget.store.locked?null:saveTx,icon:const Icon(Icons.check_circle_outline),label:const Text('حفظ العملية'))]);}

class VoiceDraftsPage extends StatefulWidget { const VoiceDraftsPage({super.key,required this.store}); final Store store; @override State<VoiceDraftsPage> createState()=>_VoiceDraftsPageState(); }
class _VoiceDraftsPageState extends State<VoiceDraftsPage>{final speech=stt.SpeechToText();bool listening=false;String text='';Future<void> start()async{if(listening){await speech.stop();setState(()=>listening=false);return;}final ok=await speech.initialize(onStatus:(x){if(mounted)setState(()=>listening=x=='listening');},onError:(_){if(mounted)setState(()=>listening=false);});if(!ok){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تعذر تشغيل الميكروفون. تأكد من إذن الميكروفون.')));return;}setState(()=>listening=true);await speech.listen(localeId:'ar-LY',partialResults:true,onResult:(r){if(mounted)setState(()=>text=r.recognizedWords);if(r.finalResult&&mounted)setState(()=>listening=false);});}void saveDraft()async{if(text.trim().isEmpty)return;final m=RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(text);final amount=double.tryParse(m?.group(1)?.replaceAll(',','.')??'')??0;widget.store.voiceDrafts.insert(0,VoiceDraft(id:makeId(),text:text.trim(),date:DateTime.now(),amount:amount,note:text.trim()));await widget.store.save();setState(()=>text='');} @override Widget build(BuildContext c)=>_Page(title:'التسجيل الصوتي',children:[GlassCard(child:Column(children:[const Icon(Icons.mic_none_rounded,size:54,color:Color(0xFF8B5CF6)),const SizedBox(height:8),const Text('سجل الكلام ثم راجعه قبل الحفظ',style:TextStyle(fontWeight:FontWeight.w800)),const SizedBox(height:14),FilledButton.icon(onPressed:start,icon:Icon(listening?Icons.stop:Icons.mic),label:Text(listening?'إيقاف التسجيل':'بدء التسجيل')),if(text.isNotEmpty)...[const SizedBox(height:12),Text(text,textAlign:TextAlign.center),const SizedBox(height:10),FilledButton.icon(onPressed:saveDraft,icon:const Icon(Icons.save),label:const Text('حفظ كمسودة'))]])),const SizedBox(height:18),...widget.store.voiceDrafts.map((d)=>Card(child:ListTile(title:Text(d.text),subtitle:Text('${dateText(d.date)} • ${d.amount>0?money(d.amount):'المبلغ غير محدد'}'),trailing:PopupMenuButton<String>(onSelected:(v)async{if(v=='delete'){widget.store.voiceDrafts.remove(d);await widget.store.save();setState((){});}if(v=='review')await Navigator.push(c,MaterialPageRoute(builder:(_)=>VoiceReviewPage(store:widget.store,draft:d)));},itemBuilder:(_)=>const[PopupMenuItem(value:'review',child:Text('مراجعة وتحويل إلى عملية')),PopupMenuItem(value:'delete',child:Text('حذف المسودة'))]))))]);}

class VoiceReviewPage extends StatefulWidget{const VoiceReviewPage({super.key,required this.store,required this.draft});final Store store;final VoiceDraft draft;@override State<VoiceReviewPage> createState()=>_VoiceReviewPageState();}
class _VoiceReviewPageState extends State<VoiceReviewPage>{late Customer? customer;late TextEditingController amount,note;String type='debt';@override void initState(){super.initState();customer=widget.draft.customerId.isEmpty?null:widget.store.customers.where((x)=>x.id==widget.draft.customerId).cast<Customer?>().firstWhere((x)=>x!=null,orElse:()=>null);amount=TextEditingController(text:widget.draft.amount>0?widget.draft.amount.toString():'');note=TextEditingController(text:widget.draft.note);}@override Widget build(BuildContext c)=>_Page(title:'مراجعة التسجيل',children:[GlassCard(child:Text(widget.draft.text,style:const TextStyle(fontSize:16))),const SizedBox(height:12),DropdownButtonFormField<Customer>(value:customer,decoration:const InputDecoration(labelText:'العميل'),items:widget.store.customers.map((x)=>DropdownMenuItem(value:x,child:Text(x.name))).toList(),onChanged:(v)=>setState(()=>customer=v)),const SizedBox(height:12),SegmentedButton<String>(segments:const[ButtonSegment(value:'debt',label:Text('دين')),ButtonSegment(value:'payment',label:Text('سداد'))],selected:{type},onSelectionChanged:(v)=>setState(()=>type=v.first)),const SizedBox(height:12),_Field(amount,'المبلغ',Icons.payments,type:TextInputType.number),_Field(note,'البيان',Icons.notes),FilledButton.icon(onPressed:()async{if(customer==null)return;final v=double.tryParse(amount.text.replaceAll(',','.'))??0;if(v<=0)return;widget.store.transactions.add(Tx(id:makeId(),customerId:customer!.id,type:type,amount:v,date:DateTime.now(),note:note.text.trim()));widget.store.voiceDrafts.remove(widget.draft);await widget.store.save();if(mounted)Navigator.pop(c);},icon:const Icon(Icons.check),label:const Text('اعتماد العملية'))]);}

class SettingsPage extends StatefulWidget{const SettingsPage({super.key,required this.store});final Store store;@override State<SettingsPage> createState()=>_SettingsPageState();}
class _SettingsPageState extends State<SettingsPage>{late TextEditingController shop,msg;int taps=0;DateTime? last;@override void initState(){super.initState();shop=TextEditingController(text:widget.store.shop);msg=TextEditingController(text:widget.store.whatsappMessage);}void hidden(){final n=DateTime.now();if(last==null||n.difference(last!).inSeconds>2)taps=0;last=n;taps++;if(taps==3){taps=0;showDialog(context:context,builder:(_)=>AdminGate(store:widget.store));}}@override Widget build(BuildContext c)=>_Page(title:'الإعدادات',children:[GestureDetector(onTap:hidden,child:const ListTile(contentPadding:EdgeInsets.zero,leading:Icon(Icons.brightness_auto),title:Text('المظهر'),subtitle:Text('تلقائي حسب إعداد الجهاز'))),_Field(shop,'اسم المحل / النشاط',Icons.storefront_outlined),_Field(msg,'رسالة واتساب',Icons.chat_outlined,maxLines:4),Text('رقم الجهاز: ${widget.store.deviceId}',style:const TextStyle(fontSize:12)),const SizedBox(height:8),FilledButton(onPressed:()async{widget.store.shop=shop.text.trim();widget.store.whatsappMessage=msg.text.trim();await widget.store.save();if(mounted)ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('تم الحفظ')));},child:const Text('حفظ الإعدادات')),OutlinedButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ActivationPage(store:widget.store))),child:const Text('التفعيل والاشتراك'))]);}

class ActivationPage extends StatefulWidget{const ActivationPage({super.key,required this.store});final Store store;@override State<ActivationPage> createState()=>_ActivationPageState();}
class _ActivationPageState extends State<ActivationPage>{final code=TextEditingController();bool busy=false;Future<void> go()async{setState(()=>busy=true);final ok=await widget.store.activateCode(code.text);if(mounted)setState(()=>busy=false);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(ok?'تم التفعيل الدائم':'الكود غير صحيح أو مستخدم أو مخصص لجهاز آخر')));if(ok&&mounted)Navigator.pop(context);}@override Widget build(BuildContext c)=>_Page(title:'الاشتراك والتفعيل',children:[GlassCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(widget.store.activated?'مفعّل دائماً':'التجربة المجانية 10 أيام',style:const TextStyle(fontSize:20,fontWeight:FontWeight.w900)),const SizedBox(height:6),Text(widget.store.activated?'لا يوجد انتهاء':'متبقٍ ${widget.store.trialDaysLeft} أيام'),const SizedBox(height:8),Text('رقم الجهاز: ${widget.store.deviceId}',style:const TextStyle(fontSize:12))])),const SizedBox(height:12),FilledButton.icon(onPressed:()=>openWhatsApp('218934951072','طلب تفعيل DainPay - رقم الجهاز: ${widget.store.deviceId}'),icon:const Icon(Icons.chat),label:const Text('طلب التفعيل عبر واتساب')), _Field(code,'كود التفعيل',Icons.key,type:TextInputType.number),FilledButton(onPressed:busy?null:go,child:Text(busy?'جارٍ التحقق...':'تفعيل دائم'))]);}

class AdminGate extends StatefulWidget{const AdminGate({super.key,required this.store});final Store store;@override State<AdminGate> createState()=>_AdminGateState();}
class _AdminGateState extends State<AdminGate>{final pin=TextEditingController();@override Widget build(BuildContext c)=>AlertDialog(title:const Text('Adreemk'),content:TextField(controller:pin,obscureText:true,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'رمز المالك')),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:(){if(pin.text=='116936'){Navigator.pop(c);Navigator.push(c,MaterialPageRoute(builder:(_)=>AdminPage(store:widget.store)));}else{ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('رمز المالك غير صحيح')));}},child:const Text('دخول'))]);}}

class AdminPage extends StatefulWidget{const AdminPage({super.key,required this.store});final Store store;@override State<AdminPage> createState()=>_AdminPageState();}
class _AdminPageState extends State<AdminPage>{final device=TextEditingController();String result='';bool busy=false;Future<void> generate()async{if(device.text.trim().isEmpty)return;setState(()=>busy=true);final x=await widget.store.generateCode(device.text);if(mounted)setState((){busy=false;result=x??'تعذر التوليد. تحقق من اتصال Firebase.';});}@override Widget build(BuildContext c)=>_Page(title:'Adreemk — المالك',children:[GlassCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('توليد رمز دائم خاص بعميل واحد',style:TextStyle(fontWeight:FontWeight.w800)),const SizedBox(height:12),_Field(device,'رقم جهاز العميل',Icons.phone_android),FilledButton.icon(onPressed:busy?null:generate,icon:const Icon(Icons.generating_tokens),label:Text(busy?'جارٍ التوليد...':'توليد الرمز')),if(result.isNotEmpty)Padding(padding:const EdgeInsets.only(top:12),child:SelectableText(result,style:const TextStyle(fontSize:28,fontWeight:FontWeight.w900))) ]))]);}

class _Page extends StatelessWidget{const _Page({required this.title,required this.children});final String title;final List<Widget> children;@override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:Text(title,style:const TextStyle(fontWeight:FontWeight.w800))),body:ListView(padding:const EdgeInsets.fromLTRB(16,8,16,32),children:children));}
class _Field extends StatelessWidget{const _Field(this.controller,this.label,this.icon,{this.type=TextInputType.text,this.maxLines=1});final TextEditingController controller;final String label;final IconData icon;final TextInputType type;final int maxLines;@override Widget build(BuildContext c)=>Padding(padding:const EdgeInsets.only(bottom:12),child:TextField(controller:controller,keyboardType:type,maxLines:maxLines,decoration:InputDecoration(labelText:label,prefixIcon:Icon(icon))));}
class _StatusChip extends StatelessWidget{const _StatusChip(this.text);final String text;@override Widget build(BuildContext c){final color=text=='خطر'?coral:text=='مسدد'?mint:const Color(0xFFF59E0B);return Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:5),decoration:BoxDecoration(color:color.withOpacity(.12),borderRadius:BorderRadius.circular(30)),child:Text(text,style:TextStyle(color:color,fontSize:11,fontWeight:FontWeight.w800)));}}
