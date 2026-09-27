import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/features/ai/ask_page.dart';
import 'package:supplier_core/supplier_core.dart';

const _id = '546aff01-c05c-4e08-ac41-09ffc126235a';

void main() {
  test('answers keep record marks and lose stray ids', () {
    final mark = '[[supplier:$_id|甲泵业]]';
    expect(tidyAnswer('$mark 报价最低（ID $_id），交期 15 天。'), '$mark 报价最低，交期 15 天。');
    expect(tidyAnswer('配电柜更换项目（编号 P-002，ID `$_id`）没有预算行'), '配电柜更换项目没有预算行');
    expect(tidyAnswer('离心水泵，id：`$_id`，单位台'), '离心水泵，单位台');
    final m = recordRef.firstMatch(tidyAnswer('见 $mark'))!;
    expect([m[1], m[2], m[3]], ['supplier', _id, '甲泵业']);
  });
}
