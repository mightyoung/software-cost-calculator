import 'dart:io';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
class Source implements InputSource {
  Source(this.file);
  final File file;
  @override String get displayName=>file.path;
  @override Future<int> length()=>file.length();
  @override Stream<List<int>> openRange(int start,int end)=>file.openRead(start,end);
}
Future<void> main() async {
  final results=<String,Object?>{};
  for(final name in ['supplier-sample.xlsx','supplier-wps-roundtrip.xlsx']){
    final db=XlsxStaging(NativeDatabase.memory());
    try {
      final profile=await const BoundedXlsxReader().readVolume(Source(File('../../artifacts/supplier-probe/$name')),db,sheetName:'quotations');
      final last=(await db.rowsPage()).last.row;
      final cells={for(final c in await db.cellsPage(last,limit:200)) c.cell.coordinate:c.cell.lexical};
      for(final entry in {'D2':'12.340001','Q2':'000123-A','R2':'2026-09-16T14:30:00.123+08:00'}.entries) {
        if(cells[entry.key]!=entry.value) throw StateError('Wrong ${entry.key}: ${cells[entry.key]}');
      }
      results[name]={'status':'PASS',...profile.toJson(),'last_row':(await db.cellsPage(last,limit:200)).map((c)=>{'coordinate':c.cell.coordinate,'type':c.rawType,'lexical':c.cell.lexical}).toList()};
    }catch(error){results[name]={'status':'REJECTED','error':error.toString()};}
    finally{await db.close();}
  }
  print(jsonEncode(results));
}
