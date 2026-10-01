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

const emerald = Color(0xFF0F5C6E);
const mint = Color(0xFF2EC4B6);
const burgundy = Color(0xFFE63946);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (e) { debugPrint('Firebase init: $e'); }
  final store = await Store.load();
  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
String money(int cents) => '${(cents / 100).toStringAsFixed(2)} د.ل';
String dateText(DateTime d) => '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year}';
String timeText(DateTime d) => '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
int parseCents(String value) {
  final normalized = value.trim().replaceAll('٬','').replaceAll(',','.');
  final n = double.tryParse(normalized);
  return n == null ? 0 : (n * 100).round();
}
String normalizePhone(String value) {
  var p = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (p.startsWith('00')) p = p.substring(2);
  if (p.startsWith('218')) return p;
  if (p.startsWith('0')) return '218${p.substring(1)}';
  return p;
}
Future<bool> openWhatsApp(String phone, String message) async {
  final n = normalizePhone(phone);
  if (n.isEmpty) return false;
  final uri = Uri.https('wa.me', '/$n', {'text': message});
  try { return await launchUrl(uri, mode: LaunchMode.externalApplication); } catch (_) { return false; }
}

class Customer {
  Customer({required this.id, required this.name, required this.phone, this.limitCents = 0});
  String id, name, phone;
  int limitCents;
  Map<String,dynamic> toJson() => {'id':id,'name':name,'phone':phone,'limitCents':limitCents};
  factory Customer.fromJson(Map<String,dynamic> j) => Customer(
    id:'${j['id']??''}', name:'${j['name']??''}', phone:'${j['phone']??''}',
    limitCents: j['limitCents'] is num ? (j['limitCents'] as num).toInt() : ((j['limit'] as num?)?.toDouble() ?? 0 * 100).round(),
  );
}

class Tx {
  Tx({required this.id,required this.customerId,required this.type,required this.amountCents,required this.date,required this.note});
  String id, customerId, type, note;
  int amountCents;
  DateTime date;
  Map<String,dynamic> toJson() => {'id':id,'customerId':customerId,'type':type,'amountCents':amountCents,'date':date.toIso8601String(),'note':note};
  factory Tx.fromJson(Map<String,dynamic> j) => Tx(
    id:'${j['id']??''}', customerId:'${j['customerId']??''}', type:'${j['type']??'debt'}',
    amountCents: j['amountCents'] is num ? (j['amountCents'] as num).toInt() : (((j['amount'] as num?)?.toDouble() ?? 0)*100).round(),
    date:DateTime.tryParse('${j['date']}')??DateTime.now(), note:'${j['note']??''}',
  );
}

class VoiceDraft {
  VoiceDraft({required this.id,required this.text,required this.date,required this.customerId,required this.amountCents,required this.note});
  String id,text,customerId,note; DateTime date; int amountCents;
  Map<String,dynamic> toJson()=>{'id':id,'text':text,'date':date.toIso8601String(),'customerId':customerId,'amountCents':amountCents,'note':note};
  factory VoiceDraft.fromJson(Map<String,dynamic> j)=>VoiceDraft(id:'${j['id']??''}',text:'${j['text']??''}',date:DateTime.tryParse('${j['date']}')??DateTime.now(),customerId:'${j['customerId']??''}',amountCents:j['amountCents'] is num?(j['amountCents'] as num).toInt():(((j['amount'] as num?)?.toDouble()??0)*100).round(),note:'${j['note']??''}');
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  final customers=<Customer>[]; final transactions=<Tx>[]; final voiceDrafts=<VoiceDraft>[];
  String shop='DainPay — دَيْن';
  String whatsappMessage='السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  String uid='',deviceId=''; bool firebaseReady=false,syncing=false,activated=false,isAdmin=false,dark=false;
  DateTime? trialStart;

  static Future<Store> load() async {
    final s=Store();
    try { s.prefs=await SharedPreferences.getInstance(); } catch (_) { rethrow; }
    s.shop=s.prefs.getString('shop')??s.shop; s.whatsappMessage=s.prefs.getString('whatsappMessage')??s.whatsappMessage; s.dark=s.prefs.getBool('dark')??false; s.activated=s.prefs.getBool('activated')??false;
    s.deviceId=s.prefs.getString('device_id')??'';
    if(s.deviceId.isEmpty){s.deviceId='DP-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}'; await safePref(() async=>s.prefs.setString('device_id',s.deviceId));}
    final trial=s.prefs.getString('trial_start');
    if(trial==null){s.trialStart=DateTime.now();await safePref(() async=>s.prefs.setString('trial_start',s.trialStart!.toIso8601String()));}else{s.trialStart=DateTime.tryParse(trial);}
    try{final a=jsonDecode(s.prefs.getString('customers')??'[]') as List;s.customers.addAll(a.map((e)=>Customer.fromJson(Map<String,dynamic>.from(e))));}catch(_){ }
    try{final a=jsonDecode(s.prefs.getString('transactions')??'[]') as List;s.transactions.addAll(a.map((e)=>Tx.fromJson(Map<String,dynamic>.from(e))));}catch(_){ }
    try{final a=jsonDecode(s.prefs.getString('voice_drafts')??'[]') as List;s.voiceDrafts.addAll(a.map((e)=>VoiceDraft.fromJson(Map<String,dynamic>.from(e))));}catch(_){ }
    return s;
  }
  static Future<void> safePref(Future<bool> Function() op) async { try{await op();}catch(e){debugPrint('Prefs: $e');} }
  int get trialDaysLeft=>activated||trialStart==null?0:max(0,10-DateTime.now().difference(trialStart!).inDays);
  bool get locked=>!activated&&trialDaysLeft<=0;
  CollectionReference<Map<String,dynamic>> get customersRef=>FirebaseFirestore.instance.collection('users').doc(uid).collection('customers');
  CollectionReference<Map<String,dynamic>> get transactionsRef=>FirebaseFirestore.instance.collection('users').doc(uid).collection('transactions');

  Future<void> connectFirebase() async {
    try{
      var user=FirebaseAuth.instance.currentUser;
      user??=(await FirebaseAuth.instance.signInAnonymously()).user;
      if(user==null)return; uid=user.uid; firebaseReady=true;
      await pullCloud(); await loadActivation();
    }catch(e){firebaseReady=false;debugPrint('Firebase: $e');}
    notifyListeners();
  }
  Future<void> loadActivation() async { if(!firebaseReady)return; try{final d=await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).get();if(d.data()?['activated']==true){activated=true;await safePref(()=>prefs.setBool('activated',true));}}catch(e){debugPrint('Activation load: $e');} }
  Future<void> pullCloud() async {
    if(!firebaseReady||uid.isEmpty||syncing)return; syncing=true;
    try{
      final cs=await customersRef.get(); for(final d in cs.docs){final c=Customer.fromJson(d.data());final i=customers.indexWhere((x)=>x.id==c.id);if(i<0)customers.add(c);else customers[i]=c;}
      final ts=await transactionsRef.get(); for(final d in ts.docs){final x=d.data();final raw=x['date'];final dt=raw is Timestamp?raw.toDate():DateTime.tryParse('$raw')??DateTime.now();final t=Tx(id:'${x['id']??d.id}',customerId:'${x['customerId']??''}',type:'${x['type']??'debt'}',amountCents:x['amountCents'] is num?(x['amountCents'] as num).toInt():(((x['amount'] as num?)?.toDouble()??0)*100).round(),date:dt,note:'${x['note']??''}');final i=transactions.indexWhere((z)=>z.id==t.id);if(i<0)transactions.add(t);else transactions[i]=t;}
      await saveLocal();
    }catch(e){debugPrint('Cloud pull: $e');}finally{syncing=false;}
  }
  Future<void> saveLocal() async {
    await safePref(()=>prefs.setString('customers',jsonEncode(customers.map((e)=>e.toJson()).toList())));
    await safePref(()=>prefs.setString('transactions',jsonEncode(transactions.map((e)=>e.toJson()).toList())));
    await safePref(()=>prefs.setString('voice_drafts',jsonEncode(voiceDrafts.map((e)=>e.toJson()).toList())));
    await safePref(()=>prefs.setString('shop',shop)); await safePref(()=>prefs.setString('whatsappMessage',whatsappMessage)); await safePref(()=>prefs.setBool('dark',dark));
  }
  Future<void> save() async { await saveLocal(); notifyListeners(); await syncAll(); }
  Future<void> syncAll() async {
    if(!firebaseReady||uid.isEmpty||syncing)return; syncing=true;
    try{
      final batch=FirebaseFirestore.instance.batch();
      for(final c in customers)batch.set(customersRef.doc(c.id),c.toJson());
      for(final t in transactions)batch.set(transactionsRef.doc(t.id),{...t.toJson(),'date':Timestamp.fromDate(t.date)});
      await batch.commit();
    }catch(e){debugPrint('Cloud batch: $e');}finally{syncing=false;}
  }
  Future<void> saveCustomer(Customer c) async {customers.add(c);await save();}
  Future<void> saveTx(Tx t) async {transactions.add(t);await save();}
  int balance(String id)=>transactions.where((t)=>t.customerId==id).fold(0,(a,t)=>a+(t.type=='debt'?t.amountCents:-t.amountCents));
  int debts(String id)=>transactions.where((t)=>t.customerId==id&&t.type=='debt').fold(0,(a,t)=>a+t.amountCents);
  int paid(String id)=>transactions.where((t)=>t.customerId==id&&t.type=='payment').fold(0,(a,t)=>a+t.amountCents);
  String risk(String id){final b=balance(id);if(b<=0)return'مسدد';final ds=transactions.where((t)=>t.customerId==id&&t.type=='debt').toList()..sort((a,b)=>a.date.compareTo(b.date));if(ds.isEmpty)return'حديث';final days=DateTime.now().difference(ds.first.date).inDays;if(days>90)return'خطر';if(days>30)return'متأخر';return'حديث';}
  Future<bool> activateCode(String code) async {
    if(!firebaseReady||code.trim().isEmpty)return false; final ref=FirebaseFirestore.instance.collection('activation_codes').doc(code.trim());
    try{final ok=await FirebaseFirestore.instance.runTransaction<bool>((tx)async{final snap=await tx.get(ref);final d=snap.data();if(!snap.exists||d==null||d['used']==true)return false;final bound='${d['deviceId']??''}';if(bound.isNotEmpty&&bound!=deviceId)return false;tx.update(ref,{'used':true,'usedAt':FieldValue.serverTimestamp(),'usedDeviceId':deviceId});return true;});if(!ok)return false;await FirebaseFirestore.instance.collection('device_activations').doc(deviceId).set({'activated':true,'activatedAt':FieldValue.serverTimestamp(),'uid':uid});activated=true;await safePref(()=>prefs.setBool('activated',true));notifyListeners();return true;}catch(e){debugPrint('Activate: $e');return false;}
  }
  Future<bool> checkAdmin(String pin) async {if(!firebaseReady)return false;try{final d=await FirebaseFirestore.instance.collection('config').doc('admin').get();if(d.data()?['pin']==pin){isAdmin=true;notifyListeners();return true;}}catch(e){debugPrint('Admin: $e');}return false;}
  Future<String?> generateCode(String device) async {if(!firebaseReady||!isAdmin||device.trim().isEmpty)return null;try{final code=(100000+Random().nextInt(900000)).toString();await FirebaseFirestore.instance.collection('activation_codes').doc(code).set({'deviceId':device.trim(),'used':false,'createdAt':FieldValue.serverTimestamp()});return code;}catch(e){debugPrint('Code: $e');return null;}}
}

class DainPayApp extends StatelessWidget{
  const DainPayApp({super.key,required this.store});final Store store;
  ThemeData buildTheme(Brightness b){final cs=ColorScheme.fromSeed(seedColor:emerald,brightness:b).copyWith(primary:emerald,secondary:mint,error:burgundy);final surface=b==Brightness.dark?const Color(0xFF12191C):const Color(0xFFF6F8F8);return ThemeData(useMaterial3:true,brightness:b,colorScheme:cs,fontFamily:'Cairo',scaffoldBackgroundColor:surface,cardTheme:CardThemeData(shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16)),elevation:1,margin:const EdgeInsets.symmetric(vertical:5)),inputDecorationTheme:InputDecorationTheme(border:OutlineInputBorder(borderRadius:BorderRadius.circular(14)),filled:true));}
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:store,builder:(_,__)=>MaterialApp(debugShowCheckedModeBanner:false,title:'DainPay',theme:buildTheme(Brightness.light),darkTheme:buildTheme(Brightness.dark),themeMode:store.dark?ThemeMode.dark:ThemeMode.light,home:HomePage(store:store)));
}

class BrandLogo extends StatelessWidget{const BrandLogo({super.key});@override Widget build(BuildContext c)=>Container(width:42,height:42,decoration:BoxDecoration(color:emerald,borderRadius:BorderRadius.circular(13),boxShadow:[BoxShadow(blurRadius:8,color:emerald.withOpacity(.25))]),alignment:Alignment.center,child:const Text('DP',style:TextStyle(color:Colors.white,fontWeight:FontWeight.w900,fontSize:15)));}

class HomePage extends StatefulWidget{const HomePage({super.key,required this.store});final Store store;@override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage>{String q='',filter='all';int taps=0;DateTime? last;
  void hidden(){final n=DateTime.now();if(last==null||n.difference(last!).inSeconds>2)taps=0;last=n;if(++taps==3){taps=0;showDialog(context:context,builder:(_)=>AdminGate(store:widget.store));}}
  @override Widget build(BuildContext context){final s=widget.store;final list=s.customers.where((c){final b=s.balance(c.id);return(q.isEmpty||c.name.contains(q)||c.phone.contains(q))&&(filter=='all'||filter=='debt'&&b>0||filter=='paid'&&b<=0);}).toList()..sort((a,b)=>s.balance(b.id).compareTo(s.balance(a.id)));final total=s.customers.fold<int>(0,(a,c)=>a+max(0,s.balance(c.id)));
    return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(leading:const Padding(padding:EdgeInsets.all(8),child:BrandLogo()),title:GestureDetector(onTap:hidden,child:Text(s.shop,style:const TextStyle(fontWeight:FontWeight.w900))),actions:[IconButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SettingsPage(store:s))),icon:const Icon(Icons.settings_outlined))]),body:ListView(padding:const EdgeInsets.all(12),children:[Card(child:Padding(padding:const EdgeInsets.all(16),child:Row(children:[Expanded(child:Column(children:[const Text('إجمالي المتبقي'),Text('',style:TextStyle(fontSize:2)),Text(money(total),style:const TextStyle(fontSize:21,fontWeight:FontWeight.w900))])),Expanded(child:Column(children:[const Text('العملاء'),Text('${s.customers.length}',style:const TextStyle(fontSize:21,fontWeight:FontWeight.w900))]))]))),TextField(decoration:const InputDecoration(hintText:'بحث بالاسم أو الهاتف',prefixIcon:Icon(Icons.search)),onChanged:(v)=>setState(()=>q=v.trim())),const SizedBox(height:8),Wrap(spacing:8,children:[ChoiceChip(label:const Text('الكل'),selected:filter=='all',onSelected:(_)=>setState(()=>filter='all')),ChoiceChip(label:const Text('عليهم دين'),selected:filter=='debt',onSelected:(_)=>setState(()=>filter='debt')),ChoiceChip(label:const Text('مسدد'),selected:filter=='paid',onSelected:(_)=>setState(()=>filter='paid'))]),const SizedBox(height:6),...list.map((c)=>Card(child:ListTile(onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CustomerPage(store:s,customer:c))),leading:CircleAvatar(child:Text(c.name.isEmpty?'؟':c.name.characters.first)),title:Text(c.name,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${c.phone}\n${s.risk(c.id)} • دين ${money(s.debts(c.id))} • مسدد ${money(s.paid(c.id))}'),isThreeLine:true,trailing:Text(money(s.balance(c.id)),style:const TextStyle(fontWeight:FontWeight.w900)))) )]),floatingActionButton:FloatingActionButton.extended(onPressed:s.locked?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ActivationPage(store:s))):()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>AddCustomerPage(store:s))),icon:Icon(s.locked?Icons.lock:Icons.person_add_alt_1),label:Text(s.locked?'التفعيل':'عميل جديد'))));}
}

class AddCustomerPage extends StatefulWidget{const AddCustomerPage({super.key,required this.store});final Store store;@override State<AddCustomerPage> createState()=>_AddCustomerPageState();}
class _AddCustomerPageState extends State<AddCustomerPage>{final name=TextEditingController(),phone=TextEditingController(),limit=TextEditingController();@override void dispose(){name.dispose();phone.dispose();limit.dispose();super.dispose();}Future<void> save()async{final n=name.text.trim();if(n.isEmpty)return;final c=Customer(id:makeId(),name:n,phone:phone.text.trim(),limitCents:parseCents(limit.text));await widget.store.saveCustomer(c);if(mounted)Navigator.pop(context);} @override Widget build(BuildContext c)=>FormPage(title:'إضافة عميل',children:[TextField(controller:name,decoration:const InputDecoration(labelText:'اسم العميل')),TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم الهاتف')),TextField(controller:limit,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'السقف الائتماني اختياري')),const SizedBox(height:18),FilledButton(onPressed:save,child:const Text('حفظ العميل'))]);}

class FormPage extends StatelessWidget{const FormPage({super.key,required this.title,required this.children});final String title;final List<Widget> children;@override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:Text(title)),body:ListView(padding:const EdgeInsets.all(16),children:children.map((w)=>Padding(padding:const EdgeInsets.only(bottom:12),child:w)).toList())));}

class CustomerPage extends StatelessWidget{const CustomerPage({super.key,required this.store,required this.customer});final Store store;final Customer customer;
  Future<void> wa(BuildContext c)async{final ok=await openWhatsApp(customer.phone,store.whatsappMessage.replaceAll('[الاسم]',customer.name).replaceAll('[المبلغ]',money(store.balance(customer.id))));if(!ok&&c.mounted)ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('تعذر فتح واتساب')));}
  @override Widget build(BuildContext c){final items=store.transactions.where((t)=>t.customerId==customer.id).toList()..sort((a,b)=>b.date.compareTo(a.date));return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:Text(customer.name)),body:ListView(padding:const EdgeInsets.all(12),children:[Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(children:[const Icon(Icons.account_balance_wallet_rounded,size:34,color:emerald),Text(money(store.balance(customer.id)),style:const TextStyle(fontSize:30,fontWeight:FontWeight.w900)),Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'),const SizedBox(height:10),Wrap(spacing:8,children:[FilledButton.icon(onPressed:()=>wa(c),icon:const Icon(Icons.chat_rounded),label:const Text('واتساب')),OutlinedButton.icon(onPressed:()=>launchUrl(Uri.parse('tel:${customer.phone}')),icon:const Icon(Icons.phone_rounded),label:const Text('اتصال'))])]))),...items.map((t)=>Card(child:ListTile(leading:CircleAvatar(backgroundColor:t.type=='debt'?burgundy.withOpacity(.12):mint.withOpacity(.15),child:Icon(t.type=='debt'?Icons.arrow_downward_rounded:Icons.arrow_upward_rounded,color:t.type=='debt'?burgundy:mint)),title:Text(t.type=='debt'?'دَين':'تسديد',style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${dateText(t.date)} ${timeText(t.date)}${t.note.isEmpty?'':' • ${t.note}'}'),trailing:Text(money(t.amountCents),style:TextStyle(fontWeight:FontWeight.w900,color:t.type=='debt'?burgundy:mint)))) )]),floatingActionButton:FloatingActionButton.extended(onPressed:store.locked?()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ActivationPage(store:store))):()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>AddTransactionPage(store:store,customer:customer)),),icon:Icon(store.locked?Icons.lock:Icons.swap_horiz_rounded),label:Text(store.locked?'التفعيل':'عملية جديدة'))));}
}

class AddTransactionPage extends StatefulWidget{const AddTransactionPage({super.key,required this.store,required this.customer});final Store store;final Customer customer;@override State<AddTransactionPage> createState()=>_AddTransactionPageState();}
class _AddTransactionPageState extends State<AddTransactionPage>{final amount=TextEditingController(),note=TextEditingController();String type='debt';@override void dispose(){amount.dispose();note.dispose();super.dispose();}Future<void> save()async{final cents=parseCents(amount.text);if(cents<=0)return;final current=widget.store.balance(widget.customer.id);if(type=='debt'&&widget.customer.limitCents>0&&current+cents>widget.customer.limitCents){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('العملية تتجاوز السقف الائتماني')));return;}final t=Tx(id:makeId(),customerId:widget.customer.id,type:type,amountCents:cents,date:DateTime.now(),note:note.text.trim());await widget.store.saveTx(t);if(mounted)Navigator.pop(context);} @override Widget build(BuildContext c)=>FormPage(title:type=='debt'?'إضافة دَين':'تسجيل تسديد',children:[SegmentedButton<String>(segments:const[ButtonSegment(value:'debt',label:Text('دَين')),ButtonSegment(value:'payment',label:Text('تسديد'))],selected:{type},onSelectionChanged:(v)=>setState(()=>type=v.first)),TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ بالدينار الليبي')),TextField(controller:note,decoration:const InputDecoration(labelText:'البيان / الملاحظات')),FilledButton(onPressed:save,child:const Text('حفظ العملية'))]);}

class VoiceDraftsPage extends StatefulWidget{const VoiceDraftsPage({super.key,required this.store});final Store store;@override State<VoiceDraftsPage> createState()=>_VoiceDraftsPageState();}
class _VoiceDraftsPageState extends State<VoiceDraftsPage>{final speech=stt.SpeechToText();bool listening=false;String live='';
  double? amount(String text){final m=RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(text);if(m!=null)return double.tryParse(m.group(1)!.replaceAll(',','.'));const words={'مية':100,'مائة':100,'مئة':100,'ألف':1000,'الف':1000,'عشرة':10,'عشرين':20,'ثلاثين':30,'أربعين':40,'خمسين':50,'ستين':60,'سبعين':70,'ثمانين':80,'تسعين':90};for(final e in words.entries){if(text.contains(e.key))return e.value.toDouble();}return null;}
  String customerId(String text){for(final c in widget.store.customers){if(text.contains(c.name))return c.id;}return '';}
  Future<void> record()async{if(listening){try{await speech.stop();}catch(_){ }if(mounted)setState(()=>listening=false);return;}try{final ok=await speech.initialize(onStatus:(status){if(!mounted)return;if(status=='notListening')setState(()=>listening=false);},onError:(_){if(mounted)setState(()=>listening=false);});if(!ok){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('التعرف الصوتي غير متاح أو لا توجد صلاحية للميكروفون')));return;}if(!mounted)return;setState(()=>listening=true);await speech.listen(localeId:'ar-LY',partialResults:true,onResult:(r){if(!mounted)return;setState(()=>live=r.recognizedWords);if(r.finalResult){final text=r.recognizedWords.trim();if(text.isNotEmpty){widget.store.voiceDrafts.insert(0,VoiceDraft(id:makeId(),text:text,date:DateTime.now(),customerId:customerId(text),amountCents:((amount(text)??0)*100).round(),note:text));widget.store.save();}if(mounted)setState(()=>listening=false);}});}catch(e){if(mounted){setState(()=>listening=false);ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('خطأ في التسجيل: $e')));}}}
  @override void dispose(){speech.stop();super.dispose();}
  @override Widget build(BuildContext c){final drafts=widget.store.voiceDrafts;return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('المسودات الصوتية')),body:ListView(padding:const EdgeInsets.all(12),children:[Card(child:ListTile(onTap:record,leading:Icon(listening?Icons.stop_circle:Icons.mic_rounded,color:listening?burgundy:emerald),title:Text(listening?'جارٍ الاستماع...':'تسجيل عملية صوتية'),subtitle:Text(live.isEmpty?'مثال: محمد 150 بضاعة':live))),if(drafts.isEmpty)const Padding(padding:EdgeInsets.all(28),child:Center(child:Text('لا توجد مسودات'))),...drafts.map((d)=>Card(child:ListTile(title:Text(d.customerId.isEmpty?'عميل غير محدد':widget.store.customers.firstWhere((x)=>x.id==d.customerId,orElse:()=>Customer(id:'',name:'غير معروف',phone:'')).name),subtitle:Text('${d.text}\nالمبلغ: ${money(d.amountCents)}'),isThreeLine:true,onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>VoiceReviewPage(store:widget.store,draft:d)))))]),floatingActionButton:FloatingActionButton(onPressed:record,child:Icon(listening?Icons.stop:Icons.mic))));}
}

class VoiceReviewPage extends StatefulWidget{const VoiceReviewPage({super.key,required this.store,required this.draft});final Store store;final VoiceDraft draft;@override State<VoiceReviewPage> createState()=>_VoiceReviewPageState();}
class _VoiceReviewPageState extends State<VoiceReviewPage>{late TextEditingController amount,note;String customerId='',type='debt';@override void initState(){super.initState();amount=TextEditingController(text:widget.draft.amountCents>0?(widget.draft.amountCents/100).toStringAsFixed(2):'');note=TextEditingController(text:widget.draft.note);customerId=widget.draft.customerId;}@override void dispose(){amount.dispose();note.dispose();super.dispose();}Future<void> approve()async{final cents=parseCents(amount.text);final c=widget.store.customers.where((x)=>x.id==customerId).isEmpty?null:widget.store.customers.firstWhere((x)=>x.id==customerId);if(c==null||cents<=0)return;final current=widget.store.balance(c.id);if(type=='debt'&&c.limitCents>0&&current+cents>c.limitCents){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('العملية تتجاوز السقف الائتماني')));return;}await widget.store.saveTx(Tx(id:makeId(),customerId:c.id,type:type,amountCents:cents,date:DateTime.now(),note:note.text.trim()));widget.store.voiceDrafts.removeWhere((x)=>x.id==widget.draft.id);await widget.store.saveLocal();if(mounted)Navigator.pop(context);} @override Widget build(BuildContext c)=>FormPage(title:'مراجعة التسجيل الصوتي',children:[Card(child:Padding(padding:const EdgeInsets.all(14),child:Text(widget.draft.text,style:const TextStyle(fontWeight:FontWeight.bold)))),DropdownButtonFormField<String>(value:customerId.isEmpty?null:customerId,decoration:const InputDecoration(labelText:'الزبون'),items:widget.store.customers.map((x)=>DropdownMenuItem(value:x.id,child:Text(x.name))).toList(),onChanged:(v)=>setState(()=>customerId=v??'')),SegmentedButton<String>(segments:const[ButtonSegment(value:'debt',label:Text('دَين')),ButtonSegment(value:'payment',label:Text('تسديد'))],selected:{type},onSelectionChanged:(v)=>setState(()=>type=v.first)),TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ')),TextField(controller:note,maxLines:2,decoration:const InputDecoration(labelText:'البيان')),FilledButton(onPressed:approve,child:const Text('اعتماد وحفظ'))]);}

class SettingsPage extends StatefulWidget{const SettingsPage({super.key,required this.store});final Store store;@override State<SettingsPage> createState()=>_SettingsPageState();}
class _SettingsPageState extends State<SettingsPage>{late TextEditingController shop,msg;@override void initState(){super.initState();shop=TextEditingController(text:widget.store.shop);msg=TextEditingController(text:widget.store.whatsappMessage);}@override void dispose(){shop.dispose();msg.dispose();super.dispose();}Future<void> save()async{widget.store.shop=shop.text.trim().isEmpty?'DainPay — دَيْن':shop.text.trim();widget.store.whatsappMessage=msg.text.trim();await widget.store.save();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم حفظ الإعدادات')));} @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('الإعدادات')),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:shop,decoration:const InputDecoration(labelText:'اسم المحل / النشاط')),SwitchListTile(value:widget.store.dark,onChanged:(v){setState(()=>widget.store.dark=v);widget.store.save();},title:const Text('الوضع الداكن'),secondary:const Icon(Icons.dark_mode_outlined)),TextField(controller:msg,maxLines:3,decoration:const InputDecoration(labelText:'قالب رسالة واتساب')),ListTile(title:const Text('رقم الجهاز'),subtitle:Text(widget.store.deviceId)),const SizedBox(height:10),FilledButton(onPressed:save,child:const Text('حفظ')),OutlinedButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>VoiceDraftsPage(store:widget.store))),child:const Text('المسودات الصوتية')),OutlinedButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ActivationPage(store:widget.store))),child:const Text('التفعيل'))]));}
}

class ActivationPage extends StatefulWidget{const ActivationPage({super.key,required this.store});final Store store;@override State<ActivationPage> createState()=>_ActivationPageState();}
class _ActivationPageState extends State<ActivationPage>{final code=TextEditingController();bool busy=false;@override void dispose(){code.dispose();super.dispose();}Future<void> go()async{if(mounted)setState(()=>busy=true);final ok=await widget.store.activateCode(code.text);if(!mounted)return;setState(()=>busy=false);ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(ok?'تم التفعيل الدائم بنجاح':'الكود غير صحيح أو مستخدم أو مخصص لجهاز آخر')));if(ok)Navigator.pop(context);} @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('التفعيل')),body:ListView(padding:const EdgeInsets.all(16),children:[Text(widget.store.activated?'التطبيق مفعّل دائماً':'التجربة المجانية: ${widget.store.trialDaysLeft} أيام',style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold)),ListTile(title:const Text('رقم الجهاز'),subtitle:Text(widget.store.deviceId)),FilledButton.icon(onPressed:()=>openWhatsApp('+218934951072','طلب تفعيل DainPay - رقم الجهاز: ${widget.store.deviceId}'),icon:const Icon(Icons.chat),label:const Text('طلب رمز عبر واتساب')),TextField(controller:code,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'كود التفعيل')),FilledButton(onPressed:busy?null:go,child:Text(busy?'جارٍ التحقق...':'تفعيل دائم'))]));}
}

class AdminGate extends StatefulWidget{const AdminGate({super.key,required this.store});final Store store;@override State<AdminGate> createState()=>_AdminGateState();}
class _AdminGateState extends State<AdminGate>{final pin=TextEditingController();bool busy=false;@override void dispose(){pin.dispose();super.dispose();}Future<void> enter()async{setState(()=>busy=true);final ok=await widget.store.checkAdmin(pin.text.trim());if(!mounted)return;setState(()=>busy=false);if(ok){Navigator.pop(context);Navigator.push(context,MaterialPageRoute(builder:(_)=>AdminPage(store:widget.store)));}else{ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('رمز المالك غير صحيح أو لا توجد صلاحية')));}}@override Widget build(BuildContext c)=>AlertDialog(title:const Text('لوحة المالك'),content:TextField(controller:pin,obscureText:true,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'رمز المالك')),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:busy?null:enter,child:Text(busy?'جارٍ التحقق...':'دخول'))]);}

class AdminPage extends StatefulWidget{const AdminPage({super.key,required this.store});final Store store;@override State<AdminPage> createState()=>_AdminPageState();}
class _AdminPageState extends State<AdminPage>{final device=TextEditingController();String result='';bool busy=false;@override void dispose(){device.dispose();super.dispose();}Future<void> generate()async{if(device.text.trim().isEmpty)return;setState(()=>busy=true);final r=await widget.store.generateCode(device.text);if(!mounted)return;setState((){busy=false;result=r??'تعذر التوليد';});} @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('إدارة التفعيل')),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:device,decoration:const InputDecoration(labelText:'Device ID')),FilledButton(onPressed:busy?null:generate,child:Text(busy?'جارٍ التوليد...':'توليد رمز')),if(result.isNotEmpty)Card(child:ListTile(title:const Text('رمز التفعيل'),subtitle:Text(result,style:const TextStyle(fontSize:24,fontWeight:FontWeight.w900)),trailing:result.length==6?IconButton(onPressed:()=>openWhatsApp('+218934951072','رمز تفعيل DainPay: $result'),icon:const Icon(Icons.send)):null))]));}
