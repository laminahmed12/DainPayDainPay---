from pathlib import Path

p=Path('lib/main.dart')
s=p.read_text(encoding='utf-8')
start=s.find('class CustomerPage extends StatelessWidget')
end=s.find('class SettingsPage extends StatefulWidget', start)
if start<0 or end<0:
    raise SystemExit('SOURCE_BLOCK_ANCHOR_NOT_FOUND')

block=r'''class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.store, required this.customer});
  final Store store;
  final Customer customer;

  Future<void> wa() async {
    final m=store.whatsappMessage.replaceAll('[الاسم]',customer.name).replaceAll('[المبلغ]',money(store.balance(customer.id)));
    final u=Uri.https('wa.me','/${phone218(customer.phone)}',{'text':m});
    if(await canLaunchUrl(u)) await launchUrl(u,mode:LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final a=store.transactions.where((t)=>t.customerId==customer.id).toList()..sort((x,y)=>y.date.compareTo(x.date));
    return Directionality(
      textDirection:TextDirection.rtl,
      child:Scaffold(
        appBar:AppBar(title:Text(customer.name)),
        body:ListView(
          padding:const EdgeInsets.all(12),
          children:[
            Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(children:[
              Text(money(store.balance(customer.id)),style:const TextStyle(fontSize:28,fontWeight:FontWeight.bold)),
              Text('الدين ${money(store.debts(customer.id))} • المسدد ${money(store.paid(customer.id))}'),
              Wrap(children:[
                FilledButton.icon(onPressed:wa,icon:const Icon(Icons.chat),label:const Text('واتساب')),
                OutlinedButton.icon(onPressed:()=>launchUrl(Uri.parse('tel:${customer.phone}')),icon:const Icon(Icons.phone),label:const Text('اتصال')),
              ]),
            ]))),
            ...a.map((t)=>ListTile(title:Text(t.type=='debt'?'دَين':'تسديد'),subtitle:Text('${dateText(t.date)} ${t.note}'),trailing:Text(money(t.amount)))),
          ],
        ),
        floatingActionButton:FloatingActionButton.extended(
          onPressed:store.locked?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ActivationPage(store:store))):()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>AddTransactionPage(store:store,customer:customer))),
          icon:Icon(store.locked?Icons.lock:Icons.add),
          label:Text(store.locked?'التفعيل':'عملية'),
        ),
      ),
    );
  }
}

class AddTransactionPage extends StatefulWidget {
  const AddTransactionPage({super.key,required this.store,required this.customer});
  final Store store;
  final Customer customer;
  @override State<AddTransactionPage> createState()=>_AddTransactionPageState();
}

class _AddTransactionPageState extends State<AddTransactionPage> {
  final amount=TextEditingController();
  final note=TextEditingController();
  final spoken=TextEditingController();
  final picker=ImagePicker();
  final speech=stt.SpeechToText();
  String type='debt',receiptPath='',receiptUrl='';
  bool listening=false;

  Future<void> voice() async {
    if(listening){await speech.stop();if(mounted)setState(()=>listening=false);return;}
    final ok=await speech.initialize(onStatus:(x){if(mounted)setState(()=>listening=x=='listening');},onError:(_){if(mounted)setState(()=>listening=false);});
    if(!ok)return;
    if(mounted)setState(()=>listening=true);
    await speech.listen(localeId:'ar-LY',partialResults:true,onResult:(r){
      spoken.text=r.recognizedWords;
      final m=RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(r.recognizedWords);
      if(m!=null)amount.text=m.group(1)!.replaceAll(',','.');
      if(r.finalResult&&mounted)setState(()=>listening=false);
    });
  }

  Future<void> receipt() async {
    final src=await showModalBottomSheet<ImageSource>(context:context,builder:(x)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[
      ListTile(leading:const Icon(Icons.camera_alt),title:const Text('تصوير الإيصال'),onTap:()=>Navigator.pop(x,ImageSource.camera)),
      ListTile(leading:const Icon(Icons.photo),title:const Text('اختيار من المعرض'),onTap:()=>Navigator.pop(x,ImageSource.gallery)),
    ])));
    if(src==null)return;
    final im=await picker.pickImage(source:src,imageQuality:85,maxWidth:1800,maxHeight:2400);
    if(im==null)return;
    final root=await getApplicationDocumentsDirectory();
    final dir=Directory('${root.path}/receipts');
    await dir.create(recursive:true);
    final f=await File(im.path).copy('${dir.path}/${makeId()}.jpg');
    receiptPath=f.path;
    if(widget.store.firebaseReady){
      try{
        final r=FirebaseStorage.instance.ref('users/${widget.store.uid}/receipts/${f.uri.pathSegments.last}');
        await r.putFile(f); receiptUrl=await r.getDownloadURL();
      }catch(_){ }
    }
    if(mounted)setState((){});
  }

  Future<void> saveTx() async {
    final v=double.tryParse(amount.text.replaceAll(',','.'))??0;
    if(v<=0){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('أدخل مبلغًا صحيحًا')));return;}
    final current=widget.store.balance(widget.customer.id);
    if(type=='debt'&&widget.customer.limit>0&&current+v>widget.customer.limit){
      await showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('تجاوز السقف الائتماني'),content:Text('السقف ${money(widget.customer.limit)} والمتاح ${money(max(0,widget.customer.limit-current))}.'),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('حسنًا'))]));
      return;
    }
    widget.store.transactions.add(Tx(id:makeId(),customerId:widget.customer.id,type:type,amount:v,date:DateTime.now(),note:note.text.trim(),receiptPath:receiptPath,receiptUrl:receiptUrl));
    await widget.store.save();
    if(mounted)Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(
    appBar:AppBar(title:Text(type=='debt'?'إضافة دَين':'تسجيل تسديد')),
    body:ListView(padding:const EdgeInsets.all(16),children:[
      SegmentedButton<String>(segments:const[ButtonSegment(value:'debt',label:Text('دَين')),ButtonSegment(value:'payment',label:Text('تسديد'))],selected:{type},onSelectionChanged:(v)=>setState(()=>type=v.first)),
      TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ بالدينار الليبي')),
      TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات')),
      OutlinedButton.icon(onPressed:voice,icon:Icon(listening?Icons.stop:Icons.mic),label:Text(listening?'إيقاف التسجيل':'تسجيل العملية بالصوت')),
      if(spoken.text.isNotEmpty)Text(spoken.text),
      Card(child:ListTile(title:const Text('صورة الإيصال — اختيارية'),subtitle:Text(receiptPath.isEmpty?'تصوير بالكاميرا أو اختيار من المعرض':'تم إرفاق الإيصال'),trailing:IconButton(onPressed:receipt,icon:const Icon(Icons.add_a_photo)))),
      if(receiptPath.isNotEmpty)Image.file(File(receiptPath),height:180,fit:BoxFit.contain),
      const SizedBox(height:16),
      FilledButton(onPressed:saveTx,child:const Text('حفظ العملية')),
    ]),
  ));
}

'''
s=s[:start]+block+s[end:]
p.write_text(s,encoding='utf-8')
print('SOURCE_INTEGRITY_STEP1_OK')
