import 'dart:io';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
Future<void> main() async {
 final db=XlsxStaging(NativeDatabase.memory());
 try {
  final supplied=<String,String?>{
   'record_id':'33333333-3333-4333-8333-333333333333','record_type':'quotation',
   'export_revision_id':'a'*64,'template_version':businessQuotationTemplateVersion,
   'supplier_id':'11111111-1111-4111-8111-111111111111','supplier_name':'供应商甲',
   'product_id':'22222222-2222-4222-8222-222222222222','product_name':'电缆',
   'price':'12.340001','currency':'CNY','tax_mode':'included','tax_rate':'13',
   'unit_snapshot':'件','min_qty':'1','quoted_on':'2026-09-01','valid_until':'2026-09-30',
   'project_name':'配电改造一期','project_number':'000123-A','inquiry_location':'上海展会 A-01',
   'inquirer_name':'张三','inquiry_precision':'instant','inquiry_date':'2026-09-16',
   'inquired_at':'2026-09-16T06:30:00.123Z','inquiry_utc_offset_minutes':'480',
   'capture_mode':'standard','missing_context':'','notes':'Unicode e\u0301 😀\r\n字面 _x005F_x0041_',
  };
  final volume=await const BoundedXlsxWriter().encodeVolume(
    rows:Stream.value(businessQuotationColumns.map((c)=>supplied[c.key]).toList()),
    headers:businessQuotationColumns.map((c)=>c.heading).toList(),validation:db);
  final file=File('../../artifacts/development/business-export-v1.xlsx');
  final sink=file.openWrite();await sink.addStream(volume.openRange(0,volume.byteLength));await sink.close();
  print(jsonEncode({'status':'PASS','path':file.path,'sha256':volume.sha256Hex,'bytes':volume.byteLength,'expanded_bytes':volume.expandedBytes,'rows':volume.dataRows,'columns':businessQuotationColumns.length}));
 }finally{await db.close();}
}
