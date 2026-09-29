import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class DainPayPdf {
  static Future<void> customerStatement({required String shop, required String customerName, required String phone, required double balance, required double debts, required double paid, required List<Map<String, String>> operations}) async {
    final data = await rootBundle.load('assets/fonts/NotoSansArabicUI-Regular.ttf');
    final font = pw.Font.ttf(data);
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: font),
      build: (_) => [
        pw.Header(level: 0, child: pw.Text(shop, style: pw.TextStyle(font: font, fontSize: 22))),
        pw.Text('كشف حساب العميل', style: pw.TextStyle(font: font, fontSize: 18)),
        pw.SizedBox(height: 8),
        pw.Text('العميل: $customerName', style: pw.TextStyle(font: font)),
        pw.Text('الهاتف: $phone', style: pw.TextStyle(font: font)),
        pw.SizedBox(height: 10),
        pw.Text('الرصيد المتبقي: ${balance.toStringAsFixed(2)} د.ل', style: pw.TextStyle(font: font, fontSize: 16)),
        pw.Text('إجمالي الدين: ${debts.toStringAsFixed(2)} د.ل', style: pw.TextStyle(font: font)),
        pw.Text('إجمالي المسدد: ${paid.toStringAsFixed(2)} د.ل', style: pw.TextStyle(font: font)),
        pw.SizedBox(height: 15),
        pw.TableHelper.fromTextArray(
          headers: ['التاريخ', 'النوع', 'المبلغ', 'الملاحظة'],
          data: operations.map((e) => [e['date'] ?? '', e['type'] ?? '', e['amount'] ?? '', e['note'] ?? '']).toList(),
          headerStyle: pw.TextStyle(font: font, fontSize: 9),
          cellStyle: pw.TextStyle(font: font, fontSize: 8),
        ),
      ],
    ));
    await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(await doc.save()));
  }
}
