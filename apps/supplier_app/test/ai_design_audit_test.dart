import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/ask_page.dart';
import 'package:supplier_app/features/ai/ai_tasks_page.dart';
import 'package:supplier_app/features/ai/material_import_page.dart';
import 'package:supplier_app/features/ai/list_to_project.dart';
import 'package:supplier_app/features/ai/list_review.dart';
import 'package:supplier_app/features/ai/material_review.dart';
import 'package:supplier_app/features/spec/spec_request_page.dart';
import 'package:supplier_app/features/spec/spec_request_list.dart';
import 'package:supplier_app/features/spec/spec_item_panel.dart';
import 'package:supplier_app/features/spec/spec_match_page.dart';
import 'package:supplier_app/features/spec/param_view.dart';
import 'package:supplier_core/supplier_core.dart';

import 'spec_match_page_test.dart' show seedSensors;

void main() {
  for (final dark in [false, true]) {
    testWidgets('AI and technical workspaces fit phone at 1.4 scale ($dark)', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('ai_design');
      final store = Store.open('${dir.path}/a.db', device: 'test');
      addTearDown(() {
        store.close();
        dir.deleteSync(recursive: true);
      });
      seedSensors(store);
      final request = store.createSpecRequest('泵房', [
        draftItem('温湿度传感器', '（1）测量范围：温度-20℃~+80℃\n（2）防护等级不低于IP65'),
      ]);
      final state = AppState.test(store, dir);
      final jobs = AiJobStore.open('${dir.path}/ai-jobs.sqlite');
      jobs.create(AiTask.listProposal, {'text': '动力电缆300米'});
      jobs.close();
      addTearDown(state.dispose);
      Tokens.dark = dark;
      addTearDown(() => Tokens.dark = false);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final page in <Widget>[
        AskPage(state: state),
        AiTasksPage(state: state),
        MaterialImportPage(state: state),
        ListToProjectPage(state: state),
        MaterialReview(
          state: state,
          plans: [
            store.planOffer(
              cleanOffer({
                'supplier': '甲泵业',
                'name': '泵',
                'unit': '台',
                'price': '3200',
              }),
            ),
          ],
          onBack: () {},
        ),
        ListReview(
          state: state,
          sourceName: null,
          source: '动力电缆约300米',
          lines: [
            ProposedLine(
              RequestedItem('动力电缆', null, '约300', '米', ['电缆']),
              const [],
            ),
          ],
          currency: 'CNY',
          taxMode: 'included',
          onBack: () {},
        ),
        SpecRequestPage(state: state, requestId: request),
        SpecRequestList(state: state),
        SpecItemPanel(
          state: state,
          itemId: store.specItemsOf(request).single.id,
        ),
        SpecMatchPage(state: state),
        ParamViewPage(state: state),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: Scaffold(body: page),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${page.runtimeType}');
        if (page is SpecRequestList) {
          await tester.tap(find.text('导入技术要求'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.widgetWithText(TextField, '或粘贴文字'),
            '温湿度传感器\n（1）温度-20℃~+80℃',
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'requirement import dialog',
          );
        }
        if (page is SpecMatchPage || page is ParamViewPage) {
          await tester.tap(
            find
                .byType(
                  page is ParamViewPage
                      ? DropdownButtonFormField<String>
                      : DropdownButtonFormField<String?>,
                )
                .first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('温湿度传感器').last);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${page.runtimeType} populated',
          );
        }
        await tester.pumpWidget(const SizedBox());
      }
    });
  }
}
