import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (_) {}
  final store = await Store.load();
  await store.connectFirebase();
  runApp(DainPayApp(store: store));
}

String id() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(99999)}';
String money(double n) => '${n.toStringAsFixed(2)} د.ل';
String day(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

class Customer {
  String id, name, phone;
  double creditLimit;
  Customer(this.id, this.name, this.phone, [this.creditLimit = 0]);
  Map<String,dynamic> json() => {'id':id,'name':name,'phone':phone,'creditLimit':creditLimit};
  factory Customer.from(dynamic j) => Customer('${j['id']}', '${j['name']}', '${j['phone'] ?? ''}', (j['creditLimit'] as num?)?.toDouble() ?? 0);
}

class Tx {
  String id, customerId, type, note, receiptPath;
  double amount;
  DateTime date;
  Tx(this.id,this.customerId,this.type,this.amount,this.date,this.note,[this.receiptPath='']);
  Map<String,dynamic> json() => {'id':id,'customerId':customerId,'type':type,'amount':amount,'date':date.toIso8601String(),'note':note,'receiptPath':receiptPath};
  factory Tx.from(dynamic j) => Tx('${j['id']}','${j['customerId']}','${j['type'] ?? 'debt'}',(j['amount'] as num).toDouble(),DateTime.tryParse('${j['date']}') ?? DateTime.now(),'${j['note'] ?? ''}','${j['receiptPath'] ?? ''}');
}

class Store extends ChangeNotifier {
  late SharedPreferences prefs;
  List<Customer> customers=[]; List<Tx> transactions=[];
  String shop='دفتر دَيْن', message='السلام عليكم [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  bool dark=false, firebaseReady=false, syncing=false; String uid='';

  static Future<Store> load() async {
    final s=Store(); s.prefs=await SharedPreferences.getInstance();
    s.shop=s.prefs.getString('shop') ?? s.shop; s.message=s.prefs.getString('message') ?? s.message; s.dark=s.prefs.getBool('dark') ?? false;
    try { s.customers=(jsonDecode(s.prefs.getString('customers') ?? '[]') as List).map(Customer.from).toList(); } catch (_) {}
    try { s.transactions=(jsonDecode(s.prefs.getString('tx') ?? '[]') as List).map(Tx.from).toList(); } catch (_) {}
    return s;
  }
  Future<void> connectFirebase() async {
    try { var u=FirebaseAuth.instance.currentUser; u ??= (await FirebaseAuth.instance.signInAnonymously()).user; if(u==null)return; uid=u.uid; firebaseReady=true; await pull(); } catch (_) { firebaseReady=false; }
    notifyListeners();
  }
  CollectionReference<Map<String,dynamic>> get cr => FirebaseFirestore.instance.collection('users').doc(uid).collection('customers');
  CollectionReference<Map<String,dynamic>> get tr => FirebaseFirestore.instance.collection('users').doc(uid).collection('transactions');
  Future<void> pull() async {
    if(!firebaseReady||uid.isEmpty||syncing)return; syncing=true;
    try {
      final cs=await cr.get(), ts=await tr.get();
      for(final d in cs.docs){final c=Customer.from(d.data()); final i=customers.indexWhere((x)=>x.id==c.id); if(i<0)customers.add(c);else customers[i]=c;}
      for(final d in ts.docs){final x=d.data(); final raw=x['date']; final dt=raw is Timestamp?raw.toDate():DateTime.tryParse('$raw')??DateTime.now(); final t=Tx('${x['id']??d.id}','${x['customerId']??''}','${x['type']??'debt'}',(x['amount'] as num?)?.toDouble()??0,dt,'${x['note']??''}','${x['receiptPath']??''}'); final i=transactions.indexWhere((z)=>z.id==t.id); if(i<0)transactions.add(t);else transactions[i]=t;}
      await local();
    } catch (_) {} finally {syncing=false;}
  }
  Future<void> cloud() async {
    if(!firebaseReady||uid.isEmpty||syncing)return; syncing=true;
    try {final b=FirebaseFirestore.instance.batch(); for(final c in customers)b.set(cr.doc(c.id),c.json()); for(final t in transactions)b.set(tr.doc(t.id),{...t.json(),'date':Timestamp.fromDate(t.date)}); await b.commit();} catch (_) {} finally {syncing=false;}
  }
  Future<void> local() async {await prefs.setString('customers',jsonEncode(customers.map((x)=>x.json()).toList()));await prefs.setString('tx',jsonEncode(transactions.map((x)=>x.json()).toList()));await prefs.setString('shop',shop);await prefs.setString('message',message);await prefs.setBool('dark',dark);}
  Future<void> save(){return local().then((_){notifyListeners();return cloud();});}
  double balance(String cid)=>transactions.where((x)=>x.customerId==cid).fold(0.0,(s,x)=>s+(x.type=='debt'?x.amount:-x.amount));
  double debts(String cid)=>transactions.where((x)=>x.customerId==cid&&x.type=='debt').fold(0.0,(s,x)=>s+x.amount);
  double paid(String cid)=>transactions.where((x)=>x.customerId==cid&&x.type=='payment').fold(0.0,(s,x)=>s+x.amount);
  int overdue(String cid){final a=transactions.where((x)=>x.customerId==cid&&x.type=='debt').toList()..sort((a,b)=>b.date.compareTo(a.date)); if(a.isEmpty||balance(cid)<=0)return 0;return DateTime.now().difference(a.first.date).inDays;}
  String risk(String cid){final b=balance(cid);if(b<=0)return 'مسدد';final d=overdue(cid);return d>90?'خطر':d>30?'متأخر':'حديث';}
}

class DainPayApp extends StatelessWidget {
  final Store store; const DainPayApp({super.key,required this.store});
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:store,builder:(_,__)=>MaterialApp(debugShowCheckedModeBanner:false,themeMode:store.dark?ThemeMode.dark:ThemeMode.light,theme:_theme(Brightness.light),darkTheme:_theme(Brightness.dark),home:HomePage(store:store)));
  ThemeData _theme(Brightness b)=>ThemeData(useMaterial3:true,brightness:b,colorSchemeSeed:const Color(0xFF0F5C6E),scaffoldBackgroundColor:b==Brightness.dark?const Color(0xFF0D171A):const Color(0xFFF4F8F9),inputDecorationTheme:const InputDecorationTheme(filled:true,border:OutlineInputBorder(borderRadius:BorderRadius.all(Radius.circular(14)),borderSide:BorderSide.none)));
}

class HomePage extends StatefulWidget {final Store store;const HomePage({super.key,required this.store});@override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage>{String q='';String filter='all';
  @override Widget build(BuildContext context){final s=widget.store;var list=s.customers.where((c){final ok=q.isEmpty||c.name.contains(q)||c.phone.contains(q);final b=s.balance(c.id);return ok&&(filter=='all'||(filter=='debt'&&b>0)||(filter=='paid'&&b<=0));}).toList()..sort((a,b)=>s.balance(b.id).compareTo(s.balance(a.id)));final total=s.customers.fold(0.0,(v,c)=>v+max(0,s.balance(c.id)));
    return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:Text(s.shop,style:const TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ReportPage(store:s))),icon:const Icon(Icons.insights_outlined)),IconButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SettingsPage(store:s))),icon:const Icon(Icons.settings_outlined))]),body:ListView(padding:const EdgeInsets.all(12),children:[Card(child:Padding(padding:const EdgeInsets.all(16),child:Row(children:[Expanded(child:Stat(title:'المتبقي',value:money(total))),Expanded(child:Stat(title:'العملاء',value:'${s.customers.length}'))]))),TextField(decoration:const InputDecoration(hintText:'بحث بالاسم أو الهاتف',prefixIcon:Icon(Icons.search)),onChanged:(v)=>setState(()=>q=v)),const SizedBox(height:8),Wrap(spacing:8,children:[ChoiceChip(label:const Text('الكل'),selected:filter=='all',onSelected:(_)=>setState(()=>filter='all')),ChoiceChip(label:const Text('عليهم دين'),selected:filter=='debt',onSelected:(_)=>setState(()=>filter='debt')),ChoiceChip(label:const Text('مسدد'),selected:filter=='paid',onSelected:(_)=>setState(()=>filter='paid'))]),const SizedBox(height:8),...list.map((c)=>Card(child:ListTile(onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CustomerPage(store:s,customer:c))),leading:CircleAvatar(child:Text(c.name.isEmpty?'؟':c.name[0])),title:Text(c.name,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${c.phone}\n${s.risk(c.id)} • دين: ${money(s.debts(c.id))} • مسدد: ${money(s.paid(c.id))}'),isThreeLine:true,trailing:Text(money(s.balance(c.id)),style:TextStyle(fontWeight:FontWeight.w900,color:s.balance(c.id)>0?Theme.of(context).colorScheme.primary:Colors.green)))) )],),floatingActionButton:FloatingActionButton.extended(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>AddCustomerPage(store:s))),icon:const Icon(Icons.add),label:const Text('عميل'))));}
}
class Stat extends StatelessWidget{final String title,value;const Stat({super.key,required this.title,required this.value});@override Widget build(BuildContext c)=>Column(children:[Text(title),const SizedBox(height:4),Text(value,style:const TextStyle(fontWeight:FontWeight.w900,fontSize:18))]);}

class AddCustomerPage extends StatefulWidget{final Store store;const AddCustomerPage({super.key,required this.store});@override State<AddCustomerPage> createState()=>_AddCustomerPageState();}
class _AddCustomerPageState extends State<AddCustomerPage>{final n=TextEditingController(),p=TextEditingController(),limit=TextEditingController();Future<void> save()async{if(n.text.trim().isEmpty)return;final c=Customer(id(),n.text.trim(),p.text.trim(),double.tryParse(limit.text.replaceAll(',','.'))??0);widget.store.customers.add(c);await widget.store.save();if(mounted)Navigator.pop(context);} @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('إضافة عميل')),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:n,decoration:const InputDecoration(labelText:'اسم العميل')),const SizedBox(height:12),TextField(controller:p,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم الهاتف')),const SizedBox(height:12),TextField(controller:limit,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'السقف الائتماني (اختياري)')),const SizedBox(height:20),FilledButton(onPressed:save,child:const Text('حفظ'))])));}

class CustomerPage extends StatelessWidget{final Store store;final Customer customer;const CustomerPage({super.key,required this.store,required this.customer});
  Future<void> wa(BuildContext c)async{var msg=store.message.replaceAll('[الاسم]',customer.name).replaceAll('[المبلغ]',money(store.balance(customer.id)));final phone=customer.phone.replaceAll(RegExp(r'[^0-9]'),'');final uri=Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');if(await canLaunchUrl(uri))await launchUrl(uri,mode:LaunchMode.externalApplication);}
  @override Widget build(BuildContext c){final tx=store.transactions.where((x)=>x.customerId==customer.id).toList()..sort((a,b)=>b.date.compareTo(a.date));return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:Text(customer.name)),body:ListView(padding:const EdgeInsets.all(12),children:[Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(children:[Text('الرصيد',style:Theme.of(c).textTheme.titleMedium),Text(money(store.balance(customer.id)),style:const TextStyle(fontSize:30,fontWeight:FontWeight.w900)),Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'),const SizedBox(height:12),Wrap(spacing:8,children:[FilledButton.icon(onPressed:()=>wa(c),icon:const Icon(Icons.chat),label:const Text('واتساب')),OutlinedButton.icon(onPressed:()=>launchUrl(Uri.parse('tel:${customer.phone}')),icon:const Icon(Icons.phone),label:const Text('اتصال'))])]))),...tx.map((t)=>Card(child:ListTile(title:Text(t.type=='debt'?'دَين':'تسديد',style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${day(t.date)}${t.note.isEmpty?'':' • ${t.note}'}'),leading:Icon(t.type=='debt'?Icons.arrow_downward:Icons.arrow_upward),trailing:Row(mainAxisSize:MainAxisSize.min,children:[if(t.receiptPath.isNotEmpty&&File(t.receiptPath).existsSync())IconButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ReceiptPage(path:t.receiptPath))),icon:const Icon(Icons.receipt_long_outlined)),Text(money(t.amount))])))),]),floatingActionButton:FloatingActionButton.extended(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>AddTransactionPage(store:store,customer:customer))),icon:const Icon(Icons.add),label:const Text('عملية'))));}
}

class AddTransactionPage extends StatefulWidget{final Store store;final Customer customer;const AddTransactionPage({super.key,required this.store,required this.customer});@override State<AddTransactionPage> createState()=>_AddTransactionPageState();}
class _AddTransactionPageState extends State<AddTransactionPage>{final amount=TextEditingController(),note=TextEditingController();final picker=ImagePicker();String type='debt',receipt='';
 Future<void> pick()async{final src=await showModalBottomSheet<ImageSource>(context:context,builder:(_)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[ListTile(leading:const Icon(Icons.camera_alt),title:const Text('الكاميرا'),onTap:()=>Navigator.pop(context,ImageSource.camera)),ListTile(leading:const Icon(Icons.photo),title:const Text('المعرض'),onTap:()=>Navigator.pop(context,ImageSource.gallery))])));if(src==null)return;final x=await picker.pickImage(source:src,imageQuality:75,maxWidth:1600,maxHeight:2200);if(x==null)return;final d=await getApplicationDocumentsDirectory();final dir=Directory('${d.path}/receipts');await dir.create(recursive:true);final f=await File(x.path).copy('${dir.path}/${id()}.jpg');if(mounted)setState(()=>receipt=f.path);}
 Future<void> save()async{final a=double.tryParse(amount.text.replaceAll(',','.'));if(a==null||a<=0)return;widget.store.transactions.add(Tx(id(),widget.customer.id,type,a,DateTime.now(),note.text.trim(),receipt));await widget.store.save();if(mounted)Navigator.pop(context);}
 @override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('إضافة عملية')),body:ListView(padding:const EdgeInsets.all(16),children:[Text(widget.customer.name,style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const SizedBox(height:14),SegmentedButton<String>(segments:const [ButtonSegment(value:'debt',label:Text('دَين')),ButtonSegment(value:'payment',label:Text('تسديد'))],selected:{type},onSelectionChanged:(v)=>setState(()=>type=v.first)),const SizedBox(height:14),TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ بالدينار الليبي')),const SizedBox(height:12),TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات')),const SizedBox(height:12),Card(child:ListTile(leading:const Icon(Icons.receipt_long),title:const Text('صورة الإيصال'),subtitle:Text(receipt.isEmpty?'اختياري':'تم إرفاق الإيصال'),trailing:IconButton(onPressed:pick,icon:const Icon(Icons.add_a_photo)))),if(receipt.isNotEmpty)Padding(padding:const EdgeInsets.only(top:8),child:Image.file(File(receipt),height:180,fit:BoxFit.cover)),const SizedBox(height:20),FilledButton(onPressed:save,child:const Text('حفظ العملية'))])));}
}

class ReceiptPage extends StatelessWidget{final String path;const ReceiptPage({super.key,required this.path});@override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('الإيصال')),body:Center(child:InteractiveViewer(child:Image.file(File(path),fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Text('تعذر فتح الصورة')))));}

class ReportPage extends StatelessWidget{final Store store;const ReportPage({super.key,required this.store});@override Widget build(BuildContext c){final now=DateTime.now(),prev=DateTime(now.year,now.month-1,1);final d=store.transactions.where((x)=>x.type=='debt'&&x.date.year==now.year&&x.date.month==now.month).fold(0.0,(a,x)=>a+x.amount);final pd=store.transactions.where((x)=>x.type=='debt'&&x.date.year==prev.year&&x.date.month==prev.month).fold(0.0,(a,x)=>a+x.amount);final top=[...store.customers]..sort((a,b)=>store.balance(b.id).compareTo(store.balance(a.id)));return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('التقارير')),body:ListView(padding:const EdgeInsets.all(16),children:[Card(child:ListTile(title:const Text('المبيعات الآجلة هذا الشهر'),trailing:Text(money(d)))),Card(child:ListTile(title:const Text('الشهر الماضي'),trailing:Text(money(pd)))),const SizedBox(height:12),const Text('أعلى العملاء ديناً',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),...top.take(5).map((x)=>ListTile(title:Text(x.name),trailing:Text(money(store.balance(x.id)))))])));}}

class SettingsPage extends StatefulWidget{final Store store;const SettingsPage({super.key,required this.store});@override State<SettingsPage> createState()=>_SettingsPageState();}
class _SettingsPageState extends State<SettingsPage>{late TextEditingController shop,msg;@override void initState(){super.initState();shop=TextEditingController(text:widget.store.shop);msg=TextEditingController(text:widget.store.message);}Future<void> save()async{widget.store.shop=shop.text.trim().isEmpty?'دفتر دَيْن':shop.text.trim();widget.store.message=msg.text.trim();await widget.store.save();if(mounted)Navigator.pop(context);}@override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('الإعدادات')),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:shop,decoration:const InputDecoration(labelText:'اسم المحل / النشاط')),const SizedBox(height:12),TextField(controller:msg,maxLines:4,decoration:const InputDecoration(labelText:'رسالة واتساب')),SwitchListTile(title:const Text('المظهر الداكن'),value:widget.store.dark,onChanged:(v)async{setState(()=>widget.store.dark=v);await widget.store.save();}),const SizedBox(height:20),FilledButton(onPressed:save,child:const Text('حفظ الإعدادات'))]));}}
