from pathlib import Path
p=Path('lib/main.dart')
s=p.read_text()
prefix=s[:s.index('class DainPayApp')]
ui=r'''
class DainPayApp extends StatelessWidget {
  const DainPayApp({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final light = ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0F5C6E), fontFamily: 'Cairo');
    final dark = ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF0F5C6E), fontFamily: 'Cairo');
    return AnimatedBuilder(
      animation: store,
      builder: (context, child) {
        return MaterialApp(debugShowCheckedModeBanner: false, theme: light, darkTheme: dark, themeMode: ThemeMode.system, home: HomePage(store: store));
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});
  final AppStore store;
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  String search = '';
  String filter = 'all';
  int taps = 0;
  DateTime? lastTap;
  void ownerShortcut() {
    final now = DateTime.now();
    if (lastTap == null || now.difference(lastTap!).inSeconds > 2) { taps = 0; }
    lastTap = now;
    taps++;
    if (taps == 3) {
      taps = 0;
      showDialog(context: context, builder: (context) => OwnerGate(store: widget.store));
    }
  }
  @override Widget build(BuildContext context) {
    final s = widget.store;
    final customers = s.customers.where((c) {
      final balance = s.balance(c.id);
      final textMatch = search.isEmpty || c.name.contains(search) || c.phone.contains(search);
      final filterMatch = filter == 'all' || (filter == 'debt' && balance > 0) || (filter == 'paid' && balance <= 0);
      return textMatch && filterMatch;
    }).toList();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(onTap: ownerShortcut, child: Text(s.shopName)),
          actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () { Navigator.push(context, MaterialPageRoute(builder: (context) => SettingsPage(store: s))); })],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (!s.activated)
              Card(child: ListTile(title: Text(s.locked ? 'انتهت التجربة' : 'التجربة المجانية'), subtitle: Text(s.locked ? 'يلزم التفعيل' : 'متبقٍ ${s.trialDaysLeft} أيام'), trailing: FilledButton(onPressed: () { Navigator.push(context, MaterialPageRoute(builder: (context) => ActivationPage(store: s))); }, child: const Text('التفعيل')))),
            TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'بحث بالاسم أو رقم الهاتف'), onChanged: (value) { setState(() { search = value; }); }),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: const Text('الكل'), selected: filter == 'all', onSelected: (_) { setState(() { filter = 'all'; }); }),
              ChoiceChip(label: const Text('عليهم دين'), selected: filter == 'debt', onSelected: (_) { setState(() { filter = 'debt'; }); }),
              ChoiceChip(label: const Text('مسدد'), selected: filter == 'paid', onSelected: (_) { setState(() { filter = 'paid'; }); }),
            ]),
            const SizedBox(height: 8),
            for (final c in customers)
              Card(child: ListTile(title: Text(c.name), subtitle: Text('${c.phone}\n${money(s.balance(c.id))}'), isThreeLine: true, onTap: () { Navigator.push(context, MaterialPageRoute(builder: (context) => CustomerPage(store: s, customer: c))); })),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: s.locked ? () { Navigator.push(context, MaterialPageRoute(builder: (context) => ActivationPage(store: s))); } : () { Navigator.push(context, MaterialPageRoute(builder: (context) => AddCustomerPage(store: s))); },
          icon: Icon(s.locked ? Icons.lock : Icons.person_add),
          label: Text(s.locked ? 'التفعيل' : 'إضافة عميل'),
        ),
      ),
    );
  }
}

class AddCustomerPage extends StatefulWidget {
  const AddCustomerPage({super.key, required this.store});
  final AppStore store;
  @override State<AddCustomerPage> createState() => _AddCustomerPageState();
}
class _AddCustomerPageState extends State<AddCustomerPage> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final limit = TextEditingController();
  Future<void> save() async {
    if (name.text.trim().isEmpty) return;
    widget.store.customers.add(Customer(id: id(), name: name.text.trim(), phone: phone.text.trim(), limit: double.tryParse(limit.text.replaceAll(',', '.')) ?? 0));
    await widget.store.save();
    if (mounted) Navigator.pop(context);
  }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('إضافة عميل')), body: ListView(padding: const EdgeInsets.all(16), children: [
    TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل')),
    TextField(controller: phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')),
    TextField(controller: limit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'السقف الائتماني اختياري')),
    const SizedBox(height: 16), FilledButton(onPressed: save, child: const Text('حفظ')),
  ]));
}

class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer});
  final AppStore store;
  final Customer customer;
  Future<void> whatsapp() async {
    final text = store.whatsappText.replaceAll('[الاسم]', customer.name).replaceAll('[المبلغ]', money(store.balance(customer.id)));
    final uri = Uri.https('wa.me', '/${cleanPhone(customer.phone)}', {'text': text});
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  @override Widget build(BuildContext context) {
    final items = store.transactions.where((x) => x.customerId == customer.id).toList();
    items.sort((a, b) => b.date.compareTo(a.date));
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Text(customer.name)),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: ListTile(title: Text(money(store.balance(customer.id)), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)), subtitle: Text('دين ${money(store.debt(customer.id))} • مسدد ${money(store.paid(customer.id))}'), trailing: Wrap(children: [IconButton(onPressed: whatsapp, icon: const Icon(Icons.chat)), IconButton(onPressed: () { launchUrl(Uri.parse('tel:${customer.phone}')); }, icon: const Icon(Icons.phone))]))),
        for (final t in items) ListTile(title: Text(t.type == 'debt' ? 'دَين' : 'تسديد'), subtitle: Text('${day(t.date)} ${t.note}'), trailing: Text(money(t.amount))),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: store.locked ? () { Navigator.push(context, MaterialPageRoute(builder: (context) => ActivationPage(store: store))); } : () { Navigator.push(context, MaterialPageRoute(builder: (context) => TransactionPage(store: store, customer: customer))); }, icon: Icon(store.locked ? Icons.lock : Icons.add), label: Text(store.locked ? 'التفعيل' : 'عملية')),
    ));
  }
}

class TransactionPage extends StatefulWidget {
  const TransactionPage({super.key, required this.store, required this.customer});
  final AppStore store;
  final Customer customer;
  @override State<TransactionPage> createState() => _TransactionPageState();
}
class _TransactionPageState extends State<TransactionPage> {
  final amount = TextEditingController();
  final note = TextEditingController();
  final spoken = TextEditingController();
  final picker = ImagePicker();
  final speech = stt.SpeechToText();
  String type = 'debt';
  String receiptPath = '';
  String receiptUrl = '';
  bool listening = false;
  Future<void> startVoice() async {
    if (listening) { await speech.stop(); setState(() { listening = false; }); return; }
    final ok = await speech.initialize(onStatus: (status) { if (mounted) setState(() { listening = status == 'listening'; }); }, onError: (_) { if (mounted) setState(() { listening = false; }); });
    if (!ok) return;
    setState(() { listening = true; });
    await speech.listen(localeId: 'ar-LY', partialResults: true, onResult: (result) {
      spoken.text = result.recognizedWords;
      final match = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(result.recognizedWords);
      if (match != null) amount.text = match.group(1)!.replaceAll(',', '.');
      if (result.finalResult && mounted) setState(() { listening = false; });
    });
  }
  Future<void> pickReceipt() async {
    final source = await showModalBottomSheet<ImageSource>(context: context, builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(title: const Text('تصوير الإيصال بالكاميرا'), onTap: () { Navigator.pop(context, ImageSource.camera); }),
      ListTile(title: const Text('اختيار من المعرض'), onTap: () { Navigator.pop(context, ImageSource.gallery); }),
    ])));
    if (source == null) return;
    final image = await picker.pickImage(source: source, imageQuality: 85);
    if (image == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final file = await File(image.path).copy('${dir.path}/receipt_${DateTime.now().microsecondsSinceEpoch}.jpg');
    receiptPath = file.path;
    if (widget.store.firebaseReady) {
      try { final ref = FirebaseStorage.instance.ref('users/${widget.store.uid}/receipts/${file.uri.pathSegments.last}'); await ref.putFile(file); receiptUrl = await ref.getDownloadURL(); } catch (_) {}
    }
    setState(() {});
  }
  Future<void> save() async {
    final value = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
    if (value <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أدخل مبلغًا صحيحًا'))); return; }
    if (type == 'debt' && widget.customer.limit > 0 && widget.store.balance(widget.customer.id) + value > widget.customer.limit) {
      await showDialog(context: context, builder: (context) => AlertDialog(title: const Text('تجاوز السقف الائتماني'), content: Text('السقف المحدد: ${money(widget.customer.limit)}'), actions: [TextButton(onPressed: () { Navigator.pop(context); }, child: const Text('حسنًا'))]));
      return;
    }
    widget.store.transactions.add(TransactionItem(id: id(), customerId: widget.customer.id, type: type, amount: value, date: DateTime.now(), note: note.text, receiptPath: receiptPath, receiptUrl: receiptUrl));
    await widget.store.save();
    if (mounted) Navigator.pop(context);
  }
  @override Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: Text(type == 'debt' ? 'إضافة دَين' : 'تسديد')), body: ListView(padding: const EdgeInsets.all(16), children: [
    SegmentedButton<String>(segments: const [ButtonSegment(value: 'debt', label: Text('دَين')), ButtonSegment(value: 'payment', label: Text('تسديد'))], selected: {type}, onSelectionChanged: (value) { setState(() { type = value.first; }); }),
    TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'المبلغ')),
    TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظات')),
    OutlinedButton.icon(onPressed: startVoice, icon: Icon(listening ? Icons.stop : Icons.mic), label: Text(listening ? 'إيقاف التسجيل' : 'تسجيل العملية بالصوت')),
    if (spoken.text.isNotEmpty) Text(spoken.text),
    Card(child: ListTile(title: const Text('صورة الإيصال اختيارية'), trailing: IconButton(onPressed: pickReceipt, icon: const Icon(Icons.add_a_photo)))),
    if (receiptPath.isNotEmpty) Image.file(File(receiptPath), height: 180),
    const SizedBox(height: 16), FilledButton(onPressed: save, child: const Text('حفظ العملية')),
  ]));
}

class SettingsPage extends StatefulWidget { const SettingsPage({super.key, required this.store}); final AppStore store; @override State<SettingsPage> createState()=>_SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage>{late TextEditingController shop;late TextEditingController message;int taps=0;DateTime? lastTap;@override void initState(){super.initState();shop=TextEditingController(text:widget.store.shopName);message=TextEditingController(text:widget.store.whatsappText);}void hidden(){final now=DateTime.now();if(lastTap==null||now.difference(lastTap!).inSeconds>2)taps=0;lastTap=now;taps++;if(taps==3){taps=0;showDialog(context:context,builder:(context)=>OwnerGate(store:widget.store));}}Future<void>save()async{widget.store.shopName=shop.text.trim();widget.store.whatsappText=message.text.trim();await widget.store.save();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم الحفظ')));}@override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:GestureDetector(onTap:hidden,child:const Text('الإعدادات'))),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:shop,decoration:const InputDecoration(labelText:'اسم المحل')),TextField(controller:message,maxLines:4,decoration:const InputDecoration(labelText:'رسالة واتساب')),const ListTile(title:Text('المظهر'),subtitle:Text('تلقائي حسب مظهر الجهاز'),trailing:Icon(Icons.brightness_auto)),Text('رقم الجهاز: ${widget.store.deviceId}'),FilledButton(onPressed:save,child:const Text('حفظ')),OutlinedButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(context)=>ActivationPage(store:widget.store))),child:const Text('الاشتراك والتفعيل'))]));}}

class ActivationPage extends StatefulWidget{const ActivationPage({super.key,required this.store});final AppStore store;@override State<ActivationPage> createState()=>_ActivationPageState();}
class _ActivationPageState extends State<ActivationPage>{final code=TextEditingController();bool busy=false;Future<void>activate()async{setState(()=>busy=true);final ok=await widget.store.activateCode(code.text);if(mounted)setState(()=>busy=false);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(ok?'تم التفعيل الدائم':'الكود غير صحيح أو مستخدم')));if(ok&&mounted)Navigator.pop(context);}@override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('الاشتراك والتفعيل')),body:ListView(padding:const EdgeInsets.all(16),children:[Text(widget.store.activated?'مفعّل دائمًا':'التجربة المجانية: ${widget.store.trialDaysLeft} أيام',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),Text('رقم الجهاز: ${widget.store.deviceId}'),const Text('الدفع نقدًا فقط'),FilledButton.icon(onPressed:()=>launchUrl(Uri.parse('https://wa.me/218934951072?text=${Uri.encodeComponent('طلب تفعيل DainPay - رقم الجهاز: ${widget.store.deviceId}')}'),mode:LaunchMode.externalApplication),icon:const Icon(Icons.chat),label:const Text('طلب التفعيل عبر واتساب')),TextField(controller:code,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'كود التفعيل')),FilledButton(onPressed:busy?null:activate,child:Text(busy?'جارٍ التحقق':'تفعيل دائم'))]));}}

class OwnerGate extends StatefulWidget{const OwnerGate({super.key,required this.store});final AppStore store;@override State<OwnerGate> createState()=>_OwnerGateState();}
class _OwnerGateState extends State<OwnerGate>{final pin=TextEditingController();void enter(){if(pin.text=='116936'){Navigator.pop(context);Navigator.push(context,MaterialPageRoute(builder:(context)=>OwnerPage(store:widget.store)));}else{ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('رمز المالك غير صحيح')));}}@override Widget build(BuildContext context)=>AlertDialog(title:const Text('Adreemk'),content:TextField(controller:pin,obscureText:true,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'رمز المالك')),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('إلغاء')),FilledButton(onPressed:enter,child:const Text('دخول'))]);}}
class OwnerPage extends StatefulWidget{const OwnerPage({super.key,required this.store});final AppStore store;@override State<OwnerPage> createState()=>_OwnerPageState();}
class _OwnerPageState extends State<OwnerPage>{final device=TextEditingController();String result='';Future<void>generate()async{final code=await widget.store.generateCode(device.text);setState(()=>result=code??'تعذر التوليد');}@override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('Adreemk — المالك')),body:ListView(padding:const EdgeInsets.all(16),children:[const Text('توليد رمز دائم لمرة واحدة لكل عميل',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),TextField(controller:device,decoration:const InputDecoration(labelText:'رقم جهاز العميل')),FilledButton(onPressed:generate,child:const Text('توليد الرمز')),if(result.isNotEmpty)Card(child:ListTile(title:const Text('رمز التفعيل'),subtitle:Text(result,style:const TextStyle(fontSize:28,fontWeight:FontWeight.bold)),trailing:IconButton(onPressed:()=>launchUrl(Uri.parse('https://wa.me/218934951072?text=${Uri.encodeComponent('رمز تفعيل DainPay: $result')}'),mode:LaunchMode.externalApplication),icon:const Icon(Icons.send))))]));}}
'''
prefix=prefix.replace("if(ts!=null) trialStart=DateTime.tryParse(ts); else {trialStart=DateTime.now();await s.prefs.setString('trial_start',trialStart!.toIso8601String());}","if(ts!=null){s.trialStart=DateTime.tryParse(ts);}else{s.trialStart=DateTime.now();await s.prefs.setString('trial_start',s.trialStart.toIso8601String());}")
p.write_text(prefix+ui)
