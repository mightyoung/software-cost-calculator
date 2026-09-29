import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/motion.dart';
import 'ontology_payload.dart';

typedef OntologyViewBuilder =
    Widget Function(BuildContext context, OntologyViewConfiguration config);

/// A small boundary also used by widget tests instead of a native platform view.
class OntologyViewConfiguration {
  const OntologyViewConfiguration({
    required this.payload,
    required this.onSelect,
    required this.onRendered,
    required this.onError,
  });

  final Map<String, Object?> payload;
  final ValueChanged<String> onSelect;
  final VoidCallback onRendered;
  final ValueChanged<String> onError;
}

class OntologyGraphHost extends StatefulWidget {
  const OntologyGraphHost({
    super.key,
    required this.counts,
    required this.selected,
    required this.onSelect,
    required this.fallback,
    this.viewBuilder,
  });

  final Map<String, int> counts;
  final String selected;
  final ValueChanged<String> onSelect;
  final Widget fallback;
  final OntologyViewBuilder? viewBuilder;

  @override
  State<OntologyGraphHost> createState() => _OntologyGraphHostState();
}

class _OntologyGraphHostState extends State<OntologyGraphHost> {
  Timer? _deadline;
  bool _basic = false;
  bool _rendered = false;
  String? _error;
  int _attempt = 0;

  bool get _supported =>
      widget.viewBuilder != null ||
      (!kIsWeb &&
          (Platform.isWindows ||
              Platform.isMacOS ||
              Platform.isAndroid ||
              Platform.isIOS) &&
          InAppWebViewPlatform.instance != null);

  @override
  void initState() {
    super.initState();
    _startDeadline();
  }

  void _startDeadline() {
    _deadline?.cancel();
    if (_supported && !_basic) {
      _deadline = Timer(const Duration(seconds: 20), () {
        _failed('关系图加载超时，已切换到基础视图。');
      });
    }
  }

  void _failed(String message) {
    if (!mounted || _basic) return;
    _deadline?.cancel();
    setState(() {
      _error = message;
      _basic = true;
    });
  }

  void _toggle() {
    setState(() {
      _basic = !_basic;
      _rendered = false;
      _error = null;
      _attempt++;
    });
    _startDeadline();
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return widget.fallback;
    final attempt = _attempt;
    final config = OntologyViewConfiguration(
      payload: ontologyHostPayload(
        counts: widget.counts,
        selected: widget.selected,
        dark: Theme.of(context).brightness == Brightness.dark,
        reducedMotion: AppMotion.reduced(context),
        textScale: MediaQuery.textScalerOf(context).scale(14) / 14,
      ),
      onSelect: (id) {
        if (mounted &&
            !_basic &&
            attempt == _attempt &&
            ontologySelection([id]) != null) {
          widget.onSelect(id);
        }
      },
      onRendered: () {
        if (!mounted || _basic || attempt != _attempt) return;
        _deadline?.cancel();
        setState(() => _rendered = true);
      },
      onError: (message) {
        if (attempt == _attempt) _failed(message);
      },
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error ?? (_basic ? '基础视图 · 对象与字段' : '对象类型与引用关系'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _toggle,
                child: Text(_basic ? '打开关系图' : '基础视图'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _basic
              ? widget.fallback
              : Stack(
                  children: [
                    Positioned.fill(
                      child: KeyedSubtree(
                        key: ValueKey(_attempt),
                        child:
                            widget.viewBuilder?.call(context, config) ??
                            _OntologyWebView(config: config),
                      ),
                    ),
                    if (!_rendered)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: const Center(child: Text('正在打开关系图…')),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _OntologyWebView extends StatefulWidget {
  const _OntologyWebView({required this.config});
  final OntologyViewConfiguration config;

  @override
  State<_OntologyWebView> createState() => _OntologyWebViewState();
}

/// One WebView2 environment for the whole app: creating it is the slowest
/// step of opening the graph on Windows, and every graph view can share it.
Future<WebViewEnvironment>? _windowsEnvironment;

Future<WebViewEnvironment> _sharedWindowsEnvironment() =>
    _windowsEnvironment ??=
        () async {
          if (await WebViewEnvironment.getAvailableVersion() == null) {
            throw StateError('WebView2 unavailable');
          }
          final support = await getApplicationSupportDirectory();
          final dir = Directory(
            '${support.path}${Platform.pathSeparator}ontology_webview',
          );
          await dir.create(recursive: true);
          return WebViewEnvironment.create(
            settings: WebViewEnvironmentSettings(userDataFolder: dir.path),
          );
        }().catchError((Object error) {
          _windowsEnvironment = null; // a later attempt may succeed
          throw error;
        });

class _OntologyWebViewState extends State<_OntologyWebView> {
  InAppWebViewController? _controller;
  WebViewEnvironment? _environment;
  String? _sent;
  bool _prepared = false;
  bool _ready = false;
  bool _sending = false;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      if (Platform.isWindows) _environment = await _sharedWindowsEnvironment();
      if (mounted) setState(() => _prepared = true);
    } catch (error, stack) {
      developer.log(
        'Ontology environment initialization failed',
        name: 'ontology',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        widget.config.onError(
          Platform.isWindows
              ? '关系图运行环境不可用，可继续使用基础视图；请检查 WebView2 Runtime。'
              : '关系图暂时无法打开，已切换到基础视图。',
        );
      }
    }
  }

  @override
  void didUpdateWidget(_OntologyWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_push());
  }

  Future<void> _push() async {
    _pending = true;
    if (!_ready || _sending || _controller == null) return;
    _sending = true;
    try {
      while (mounted && _pending && _ready) {
        _pending = false;
        // Parents rebuild on every data change; only a different state is
        // worth a round trip into the page.
        final script = ontologyUpdateScript(widget.config.payload);
        if (script == _sent) continue;
        await _controller!.evaluateJavascript(source: script);
        _sent = script;
      }
    } catch (error, stack) {
      developer.log(
        'Ontology state delivery failed',
        name: 'ontology',
        error: error,
        stackTrace: stack,
      );
      if (mounted) widget.config.onError('关系图更新失败，已切换到基础视图。');
    } finally {
      _sending = false;
    }
  }

  @override
  void dispose() {
    // The shared Windows environment lives as long as the app.
    _ready = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_prepared) return const SizedBox.expand();
    return InAppWebView(
      initialFile: 'assets/ontology_graph/index.html',
      webViewEnvironment: _environment,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        disableContextMenu: true,
        useShouldOverrideUrlLoading: true,
        supportZoom: false,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'ontologyReady',
          callback: (_) {
            if (!mounted) return null;
            _sent = ontologyUpdateScript(widget.config.payload);
            return widget.config.payload;
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'ontologyRendered',
          callback: (_) {
            if (!mounted) return null;
            _ready = true;
            widget.config.onRendered();
            unawaited(_push());
            return null;
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'ontologySelect',
          callback: (args) {
            final id = ontologySelection(args);
            if (mounted && id != null) widget.config.onSelect(id);
            return null;
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'ontologyError',
          callback: (args) {
            developer.log(
              'Ontology renderer reported a failure',
              name: 'ontology',
              error: args.isEmpty ? null : args.first,
            );
            if (mounted) widget.config.onError('关系图显示失败，已切换到基础视图。');
            return null;
          },
        );
      },
      shouldOverrideUrlLoading: (_, action) async {
        final url = action.request.url;
        return url != null &&
                (url.scheme == 'file' || url.toString() == 'about:blank')
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      onReceivedError: (_, request, error) {
        if (mounted && request.isForMainFrame != false) {
          developer.log(
            'Ontology asset load failed',
            name: 'ontology',
            error: error,
          );
          widget.config.onError('关系图资源加载失败，已切换到基础视图。');
        }
      },
      onWebContentProcessDidTerminate: (_) {
        if (mounted) widget.config.onError('关系图已停止，已切换到基础视图。');
      },
      onRenderProcessGone: (_, detail) {
        if (mounted) widget.config.onError('关系图已停止，已切换到基础视图。');
      },
    );
  }
}
