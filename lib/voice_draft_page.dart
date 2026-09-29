import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoiceDraftPage extends StatefulWidget {
  const VoiceDraftPage({super.key, required this.customers, required this.onApprove});
  final List<dynamic> customers;
  final Future<void> Function(dynamic customer, String type, double amount, String note) onApprove;
  @override State<VoiceDraftPage> createState() => _VoiceDraftPageState();
}

class _VoiceDraftPageState extends State<VoiceDraftPage> {
  final speech = stt.SpeechToText();
  final drafts = <Map<String, dynamic>>[];
  bool listening = false;
  String text = '';
  String type = 'debt';
  double amount = 0;

  @override void initState() { super.initState(); _loadDrafts(); }
  Future<void> _loadDrafts() async { final p = await SharedPreferences.getInstance(); final raw = p.getString('voice_drafts_v1'); if (raw != null) { try { drafts.addAll((jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e))); } catch (_) {} } if (mounted) setState(() {}); }
  Future<void> _saveDrafts() async { final p = await SharedPreferences.getInstance(); await p.setString('voice_drafts_v1', jsonEncode(drafts)); }

  double? _amount(String s) {
    final n = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(s);
    if (n != null) return double.tryParse(n.group(1)!.replaceAll(',', '.'));
    const words = {'صفر':0,'واحد':1,'واحدة':1,'اثنين':2,'ثلاثة':3,'أربعة':4,'اربعة':4,'خمسة':5,'ستة':6,'سبعة':7,'ثمانية':8,'تسعة':9,'عشرة':10,'عشرين':20,'ثلاثين':30,'أربعين':40,'خمسين':50,'ستين':60,'سبعين':70,'ثمانين':80,'تسعين':90,'مية':100,'مائة':100,'مئة':100,'ألف':1000};
    for (final e in words.entries) { if (s.contains(e.key)) return e.value.toDouble(); }
    return null;
  }
  dynamic _matchCustomer(String s) { final sorted = [...widget.customers]..sort((a,b) => '${b.name}'.length.compareTo('${a.name}'.length)); for (final c in sorted) { if (s.contains('${c.name}')) return c; } return null; }

  Future<void> _record() async {
    if (listening) { await speech.stop(); if (mounted) setState(() => listening = false); return; }
    final ok = await speech.initialize(onStatus: (x) { if (mounted && x == 'notListening') setState(() => listening = false); }, onError: (_) { if (mounted) { setState(() => listening = false); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر الوصول إلى الميكروفون. تحقق من إذن الميكروفون.'))); } });
    if (!ok) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('خدمة التعرف على الكلام غير متاحة على هذا الجهاز.'))); return; }
    setState(() => listening = true);
    await speech.listen(partialResults: true, onResult: (r) { text = r.recognizedWords; final a = _amount(text); if (a != null) amount = a; if (text.contains('سداد') || text.contains('تسديد') || text.contains('دفعت')) type = 'payment'; else if (text.contains('دين') || text.contains('آجل')) type = 'debt'; if (mounted) setState(() {}); });
  }

  Future<void> _makeDraft() async {
    if (text.trim().isEmpty) return;
    final c = _matchCustomer(text);
    drafts.insert(0, {'id':DateTime.now().microsecondsSinceEpoch.toString(),'text':text,'customerId':c == null ? '' : '${c.id}','customerName':c == null ? '' : '${c.name}','type':type,'amount':amount,'note':text,'createdAt':DateTime.now().toIso8601String()});
    await _saveDrafts();
    if (mounted) { setState(() { text=''; amount=0; }); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ المسودة للمراجعة'))); }
  }
  dynamic _customerFor(Map<String,dynamic> d) { final id='${d['customerId'] ?? ''}'; for (final c in widget.customers) { if ('${c.id}' == id) return c; } return null; }
  Future<void> _approve(int index) async {
    final d=drafts[index]; dynamic c=_customerFor(d);
    if (c == null) c=await showDialog<dynamic>(context:context,builder:(_)=>AlertDialog(title:const Text('اختر العميل'),content:SizedBox(width:double.maxFinite,child:ListView(shrinkWrap:true,children:widget.customers.map((x)=>ListTile(title:Text('${x.name}'),subtitle:Text('${x.phone}'),onTap:()=>Navigator.pop(context,x))).toList()))));
    if (c == null) return; final a=(d['amount'] as num?)?.toDouble() ?? 0;
    if (a <= 0) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('المبلغ غير واضح؛ أعد التسجيل أو راجع المسودة.'))); return; }
    await widget.onApprove(c,'${d['type'] ?? 'debt'}',a,'${d['note'] ?? d['text'] ?? ''}'); drafts.removeAt(index); await _saveDrafts(); if (mounted) setState(() {});
  }
  @override void dispose(){ speech.stop(); super.dispose(); }
  @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(appBar:AppBar(title:const Text('التسجيل الصوتي')),body:ListView(padding:const EdgeInsets.all(16),children:[Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(children:[const Text('سجّل العملية ثم راجعها قبل الحفظ',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('مثال: محمد، دين، مية دينار، بضاعة'),const SizedBox(height:12),FilledButton.icon(onPressed:_record,icon:Icon(listening?Icons.stop:Icons.mic),label:Text(listening?'إيقاف التسجيل':'بدء التسجيل')),if(text.isNotEmpty)Padding(padding:const EdgeInsets.only(top:12),child:Text(text)),if(amount>0)Text('المبلغ المستخرج: ${amount.toStringAsFixed(2)} د.ل'),FilledButton(onPressed:text.trim().isEmpty?null:_makeDraft,child:const Text('حفظ كمسودة للمراجعة'))]))),const SizedBox(height:8),const Text('المسودات',style:TextStyle(fontSize:19,fontWeight:FontWeight.bold)),...drafts.asMap().entries.map((e){final i=e.key;final d=e.value;return Card(child:ListTile(title:Text('${d['customerName'] ?? ''}'.isEmpty?'عميل غير محدد':'${d['customerName']}'),subtitle:Text('${d['text'] ?? ''}\n${d['type']=='payment'?'تسديد':'دين'} • ${((d['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)} د.ل'),isThreeLine:true,trailing:IconButton(onPressed:()=>_approve(i),icon:const Icon(Icons.check_circle))));})])));
}
