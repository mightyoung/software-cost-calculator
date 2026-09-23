import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_state.dart';
import 'app/shell.dart';
import 'app/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Object? startupError;
  AppState? state;
  try {
    state = await AppState.open();
  } catch (e) {
    startupError = e;
  }
  runApp(SupplierApp(state: state, startupError: startupError));
}

class SupplierApp extends StatelessWidget {
  const SupplierApp({super.key, this.state, this.startupError});
  final AppState? state;
  final Object? startupError;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '询价台账',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: state != null
        ? Shell(state: state!)
        : Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('无法打开本机数据库：$startupError'),
              ),
            ),
          ),
  );
}
