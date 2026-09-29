import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_state.dart';
import 'app/shell.dart';
import 'app/theme.dart';
import 'app/title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initWindow();
  Object? startupError;
  AppState? state;
  try {
    state = await AppState.open();
  } catch (e) {
    startupError = e;
  }
  runApp(SupplierApp(state: state, startupError: startupError));
}

/// Follows the system's light or dark appearance unless the user chose
/// one in settings ("appearance": light / dark).
class SupplierApp extends StatefulWidget {
  const SupplierApp({super.key, this.state, this.startupError});
  final AppState? state;
  final Object? startupError;

  @override
  State<SupplierApp> createState() => _SupplierAppState();
}

class _SupplierAppState extends State<SupplierApp> with WidgetsBindingObserver {
  final _themes = <bool, ThemeData>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => setState(() {});

  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  bool get _dark => switch (widget.state?.setting('appearance')) {
    'light' => false,
    'dark' => true,
    _ =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
  };

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return state == null
        ? _app(null)
        : ListenableBuilder(listenable: state, builder: (_, _) => _app(state));
  }

  Widget _app(AppState? state) {
    final dark = _dark;
    Tokens.dark = dark;
    // Colours are read straight from Tokens, so a change of appearance
    // rebuilds the whole app (open dialogs close).
    return MaterialApp(
      key: ValueKey(dark),
      title: '询价台账',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations:
              MediaQuery.disableAnimationsOf(context) ||
              WidgetsBinding
                  .instance
                  .platformDispatcher
                  .accessibilityFeatures
                  .reduceMotion ||
              state?.setting('reduce_motion') == 'true',
        ),
        child: child!,
      ),
      theme: _themes[dark] ??= buildTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: state != null
          ? Shell(state: state)
          : Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('无法打开本机数据库：${widget.startupError}'),
                ),
              ),
            ),
    );
  }
}
