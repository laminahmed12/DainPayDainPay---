import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.load();
  runApp(DainPay(store: store));
}

String uid() => DateTime.now().microsecondsSinceEpoch.toString() + Random().nextInt(999).toString();
String ly(double n) => '${n.toStringAsFixed(2)} د.ل';

class Customer {
  String id, name, phone;
  Customer(this.id, this.name, this.phone);
  Map<String,dynamic> json()=>{'id':id,'name':name,'phone':phone};
  factory Customer.from(dynamic x)=>Customer(x['id'],x['name'],x['phone']??'');
}
class Transaction {
  String id, customerId, type, note;
  double amount;
  DateTime date;
  Transaction(this.id,this.customerId,this.type,this.amount,this.date,this.note);
  Map<String,dynamic> json()=>{'id':id,'customerId':customerId,'type':type,'amount':amount,'date':date.toIso8601String(),'note':note};
  factory Transaction.from(dynamic x)=>Transaction(x['id'],x['customerId'],x['type'],(x['amount'] as num).toDouble(),DateTime.parse(x['date']),x['note']??'');
}

class Store extends ChangeNotifier {
  late SharedPreferences p;
  List<Customer> customers=[];
  List<Transaction> tx=[];
  String shop='دفتر دَيْن';
  String wa='السلام عليكم أخي [الاسم]، تذكير لطيف بخصوص المتبقي عليكم قدره [المبلغ] د.ل.';
  bool dark=false;
  DateTime? trialStart;
  bool activated=false;

  static Future<Store> load() async {
    final s=Store(); s.p=await SharedPreferences.getInstance();
    s.shop=s.p.getString('shop')??s.shop; s.wa=s.p.getString('wa')??s.wa;
    s.dark=s.p.getBool('dark')??false; s.activated=s.p.getBool('activated')??false;
    final ts=s.p.getString('trial'); if(ts!=null)s.trialStart=DateTime.tryParse(ts);
    if(s.trialStart==null){s.trialStart=DateTime.now();await s.p.setString('trial',s.trialStart!.toIso8601String());}
    final c=s.p.getString('customers'),t=s.p.getString('tx');
    if(c!=null)s.customers=(jsonDecode(c) as List).map(Customer.from).toList();
    if(t!=null)s.tx=(jsonDecode(t) as List).map(Transaction.from).toList();
    return s;
  }
  int daysLeft(){if(activated)return 999; final used=DateTime.now().difference(trialStart!).inDays; return max(0,14-used);}
  double balance(String id)=>tx.where((x)=>x.customerId==id).fold(0,(a,x)=>a+(x.type=='debt'?x.amount:-x.amount));
  double paid(String id)=>tx.where((x)=>x.customerId==id&&x.type=='payment').fold(0,(a,x)=>a+x.amount);
  Future<void> save()async{
    await p.setString('customers',jsonEncode(customers.map((x)=>x.json()).toList()));
    await p.setString('tx',jsonEncode(tx.map((x)=>x.json()).toList()));
    await p.setString('shop',shop);await p.setString('wa',wa);await p.setBool('dark',dark);await p.setBool('activated',activated);notifyListeners();
  }
}

class DainPay extends StatelessWidget {
  final Store store; const DainPay({super.key,required this.store});
  @override Widget build(BuildContext c)=>AnimatedBuilder(animation:store,builder:(_,__)=>MaterialApp(debugShowCheckedModeBanner:false,themeMode:store.dark?ThemeMode.dark:ThemeMode.light,theme:_theme(false),darkTheme:_theme(true),home:Home(store:store)));
  ThemeData _theme(bool d)=>ThemeData(useMaterial3:true,fontFamily:'Tajawal',brightness:d?Brightness.dark:Brightness.light,colorSchemeSeed:const Color(0xFF0F5C6E),scaffoldBackgroundColor:d?const Color(0xFF10181B):const Color(0xFFF5F8F9));
}

class Home extends StatefulWidget {
  final Store store; const Home({super.key,required this.store});
  @override State<Home> createState()=>_HomeState();
}
class _HomeState extends State<Home>{
  int tab=0;String q='';
  @override Widget build(BuildContext c){
    final s=widget.store;
    return Directionality(textDirection:TextDirection.rtl,child:Scaffold(
      appBar:AppBar(title:Text(s.shop,style:const TextStyle(fontWeight:FontWeight.w900)),actions:[IconButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Settings(store:s))),icon:const Icon(Icons.settings_outlined))]),
      body:tab==1?const Associations():Column(children:[
        if(!s.activated) Container(width:double.infinity,padding:const EdgeInsets.symmetric(horizontal:16,vertical:10),color:const Color(0xFFE8A317),child:Text(s.daysLeft()>0?'الفترة التجريبية: متبقي ${s.daysLeft()} يوم':'انتهت الفترة التجريبية — افتح الإعدادات للتفعيل',style:const TextStyle(fontWeight:FontWeight.bold))),
        Padding(padding:const EdgeInsets.all(14),child:TextField(onChanged:(v)=>setState(()=>q=v),decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'ابحث باسم العميل أو الهاتف',filled:true,border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none)))),
        Expanded(child:Builder(builder:(_){final list=s.customers.where((x)=>x.name.contains(q)||x.phone.contains(q)).toList();if(list.isEmpty)return Empty(onAdd:()=>newCustomer(c,s));return ListView.builder(padding:const EdgeInsets.symmetric(horizontal:12),itemCount:list.length,itemBuilder:(_,i){final x=list[i],b=s.balance(x.id);return Card(child:ListTile(contentPadding:const EdgeInsets.all(12),leading:CircleAvatar(child:Text(x.name.isEmpty?'؟':x.name[0])),title:Text(x.name,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text(x.phone.isEmpty?'بدون هاتف':x.phone),trailing:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.end,children:[Text(ly(b),style:TextStyle(fontWeight:FontWeight.w900,color:b>0?const Color(0xFFE8A317):Colors.green)),Text('مدفوع ${ly(s.paid(x.id))}',style:Theme.of(c).textTheme.bodySmall)]),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>CustomerPage(store:s,customer:x))));});})),
      ]),
      bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const[NavigationDestination(icon:Icon(Icons.menu_book_outlined),selectedIcon:Icon(Icons.menu_book),label:'الدفتر'),NavigationDestination(icon:Icon(Icons.groups_outlined),selectedIcon:Icon(Icons.groups),label:'الجمعيات')]),
      floatingActionButton:tab==0?FloatingActionButton.extended(onPressed:()=>newCustomer(c,s),icon:const Icon(Icons.person_add),label:const Text('عميل جديد')):null));
  }
}

class Empty extends StatelessWidget{final VoidCallback onAdd;const Empty({super.key,required this.onAdd});@override Widget build(BuildContext c)=>Center(child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.menu_book_outlined,size:64),const SizedBox(height:10),const Text('الدفتر فارغ',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('أضف عميلك الأول وسجّل الديون والسداد.'),const SizedBox(height:16),FilledButton.icon(onPressed:onAdd,icon:const Icon(Icons.add),label:const Text('إضافة عميل'))]));}

Future<void> newCustomer(BuildContext c,Store s)async{
 final n=TextEditingController(),p=TextEditingController();
 await showModalBottomSheet(context:c,isScrollControlled:true,builder:(x)=>Directionality(textDirection:TextDirection.rtl,child:Padding(padding:EdgeInsets.only(left:20,right:20,top:20,bottom:MediaQuery.of(x).viewInsets.bottom+20),child:Column(mainAxisSize:MainAxisSize.min,children:[const Text('عميل جديد',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),TextField(controller:n,decoration:const InputDecoration(labelText:'اسم العميل')),TextField(controller:p,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'الهاتف')),const SizedBox(height:16),SizedBox(width:double.infinity,child:FilledButton(onPressed:(){if(n.text.trim().isEmpty)return;s.customers.add(Customer(uid(),n.text.trim(),p.text.trim()));s.save();Navigator.pop(x);},child:const Text('حفظ')))]))));
}

class CustomerPage extends StatelessWidget{
 final Store store;final Customer customer;const CustomerPage({super.key,required this.store,required this.customer});
 @override Widget build(BuildContext c){final list=store.tx.where((x)=>x.customerId==customer.id).toList()..sort((a,b)=>b.date.compareTo(a.date));final b=store.balance(customer.id);
 return Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:Text(customer.name),actions:[IconButton(onPressed:()=>whatsapp(c,store,customer,b),icon:const Icon(Icons.chat))]),body:Column(children:[
 Card(margin:const EdgeInsets.all(14),child:Padding(padding:const EdgeInsets.all(16),child:Row(mainAxisAlignment:MainAxisAlignment.spaceAround,children:[_stat('المتبقي',ly(b),b>0),_stat('المدفوع',ly(store.paid(customer.id)),false)]))),
 Expanded(child:list.isEmpty?const Center(child:Text('لا توجد عمليات')):ListView.builder(padding:const EdgeInsets.all(12),itemCount:list.length,itemBuilder:(_,i){final x=list[i];return Card(child:ListTile(leading:CircleAvatar(child:Icon(x.type=='debt'?Icons.arrow_upward:Icons.arrow_downward)),title:Text(x.type=='debt'?'دين':'سداد',style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${x.date.day}/${x.date.month}/${x.date.year}${x.note.isEmpty?'':' • ${x.note}'}'),trailing:Text(ly(x.amount),style:TextStyle(fontWeight:FontWeight.w900,color:x.type=='debt'?const Color(0xFFE8A317):Colors.green)));})),
 ]),floatingActionButton:FloatingActionButton.extended(onPressed:()=>addTx(c,store,customer),icon:const Icon(Icons.add),label:const Text('عملية')));
 }
 Widget _stat(String a,String b,bool w)=>Column(children:[Text(a),Text(b,style:TextStyle(fontWeight:FontWeight.w900,fontSize:18,color:w?const Color(0xFFE8A317):Colors.green))]);
}

Future<void> addTx(BuildContext c,Store s,Customer customer)async{
 final a=TextEditingController(),n=TextEditingController();String type='debt';
 await showModalBottomSheet(context:c,isScrollControlled:true,builder:(x)=>Directionality(textDirection:TextDirection.rtl,child:StatefulBuilder(builder:(x,set)=>Padding(padding:EdgeInsets.only(left:20,right:20,top:20,bottom:MediaQuery.of(x).viewInsets.bottom+20),child:Column(mainAxisSize:MainAxisSize.min,children:[const Text('إضافة عملية',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),const SizedBox(height:10),SegmentedButton<String>(segments:const[ButtonSegment(value:'debt',label:Text('دين')),ButtonSegment(value:'payment',label:Text('سداد'))],selected:{type},onSelectionChanged:(v)=>set(()=>type=v.first)),TextField(controller:a,keyboardType:const TextInputType.numberWithOptions(decimal:true),inputFormatters:[FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],decoration:const InputDecoration(labelText:'المبلغ (د.ل)')),TextField(controller:n,decoration:const InputDecoration(labelText:'ملاحظات')),const SizedBox(height:16),SizedBox(width:double.infinity,child:FilledButton(onPressed:(){final val=double.tryParse(a.text);if(val==null||val<=0)return;s.tx.add(Transaction(uid(),customer.id,type,val,DateTime.now(),n.text.trim()));s.save();Navigator.pop(x);},child:const Text('حفظ العملية')))]))));
}

Future<void> whatsapp(BuildContext c,Store s,Customer x,double b)async{
 final msg=s.wa.replaceAll('[الاسم]',x.name).replaceAll('[المبلغ]',ly(b));
 final uri=Uri.parse('https://wa.me/218${x.phone.replaceAll(RegExp(r'[^0-9]'),'')}?text=${Uri.encodeComponent(msg)}');
 if(!await launchUrl(uri,mode:LaunchMode.externalApplication)&&c.mounted)ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('تعذر فتح واتساب')));
}

class Associations extends StatelessWidget{const Associations({super.key});@override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Center(child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.groups_outlined,size:70),const SizedBox(height:12),const Text('الجمعيات الأهلية',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),const SizedBox(height:6),const Text('إدارة الدورات والأعضاء قيد التطوير في الربط السحابي.'),const SizedBox(height:16),FilledButton.icon(onPressed:(){ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('سيتم تفعيل إدارة الجمعيات مع قاعدة Firebase.')));},icon:const Icon(Icons.add),label:const Text('جمعية جديدة'))])));}

class Settings extends StatefulWidget{final Store store;const Settings({super.key,required this.store});@override State<Settings> createState()=>_SettingsState();}
class _SettingsState extends State<Settings>{late TextEditingController shop,wa;@override void initState(){super.initState();shop=TextEditingController(text:widget.store.shop);wa=TextEditingController(text:widget.store.wa);}
@override Widget build(BuildContext c)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('الإعدادات')),body:ListView(padding:const EdgeInsets.all(16),children:[
 TextField(controller:shop,decoration:const InputDecoration(labelText:'اسم المحل / الدفتر')),const SizedBox(height:12),
 SwitchListTile(title:const Text('الوضع الداكن'),value:widget.store.dark,onChanged:(v)async{widget.store.dark=v;await widget.store.save();setState((){});}),
 const Divider(),const Text('رسالة التذكير عبر واتساب',style:TextStyle(fontWeight:FontWeight.bold)),TextField(controller:wa,maxLines:4,decoration:const InputDecoration(hintText:'[الاسم] و[المبلغ] متغيرات تلقائية')),const SizedBox(height:12),
 FilledButton(onPressed:()async{widget.store.shop=shop.text.trim().isEmpty?'دفتر دَيْن':shop.text.trim();widget.store.wa=wa.text.trim();await widget.store.save();if(c.mounted)Navigator.pop(c);},child:const Text('حفظ')),
 const SizedBox(height:20),Card(child:ListTile(leading:const Icon(Icons.timer_outlined),title:Text(widget.store.activated?'التفعيل الدائم مفعل':'الفترة التجريبية'),subtitle:Text(widget.store.activated?'هذا الجهاز مفعل بشكل دائم.':'متبقي ${widget.store.daysLeft()} يوم'))),
 if(!widget.store.activated)Card(child:ListTile(leading:const Icon(Icons.lock_open_outlined),title:const Text('التفعيل النقدي'),subtitle:const Text('سيتم ربط رمز التفعيل برقم الجهاز وقاعدة Firebase في مرحلة الربط السحابي.'),onTap:()=>showDialog(context:c,builder:(_)=>AlertDialog(title:const Text('التفعيل'),content:const Text('لإتمام التفعيل الدائم نحتاج ربط مشروع Firebase الخاص بك. لا نضع أكواد تفعيل سرية داخل التطبيق.'),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('حسناً'))])))),
 Card(child:ListTile(leading:const Icon(Icons.cloud_outlined),title:const Text('Firebase'),subtitle:const Text('الحزم مضافة للمشروع. إضافة google-services.json وربط مشروعك هي الخطوة المطلوبة للبيانات السحابية.')))
]));}
}
