import 'package:flutter/material.dart';

import '../features/exchange/exchange_page.dart';
import '../features/query/records_page.dart';
import '../features/records/record_editor.dart';
import 'workspace.dart';

class SupplierApp extends StatelessWidget {
  const SupplierApp({super.key, required this.workspace});
  final SupplierWorkspace workspace;

  ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorSchemeSeed: Colors.indigo,
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      alignLabelWithHint: true,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '供应商与询价',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: _WorkspaceShell(workspace: workspace),
  );
}

class _WorkspaceShell extends StatefulWidget {
  const _WorkspaceShell({required this.workspace});
  final SupplierWorkspace workspace;
  @override
  State<_WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<_WorkspaceShell> {
  late SupplierWorkspace _workspace = widget.workspace;
  var _destination = 0;
  var _revision = 0;
  static const _labels = ['查询与比价', '供应商', '产品', '导入导出/备份'];
  static const _icons = [
    Icons.manage_search,
    Icons.store_outlined,
    Icons.inventory_2_outlined,
    Icons.import_export,
  ];

  Future<void> _newQuotation() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordEditor(workspace: _workspace, type: 'quotation'),
      ),
    );
    if (saved == true && mounted) setState(() => _revision++);
  }

  void _replaceWorkspace(SupplierWorkspace workspace, {String? message}) {
    setState(() {
      _workspace = workspace;
      _revision++;
    });
    if (message != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final content = _destination == 3
          ? ExchangePage(
              workspace: _workspace,
              onWorkspaceReplaced: _replaceWorkspace,
            )
          : RecordsPage(
              key: ValueKey('$_destination:$_revision'),
              workspace: _workspace,
              type: ['quotation', 'supplier', 'product'][_destination],
            );
      return Scaffold(
        appBar: AppBar(
          title: const Text('供应商与询价'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: _workspace.readOnlyReason == null
                    ? _newQuotation
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('新增报价'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_workspace.readOnlyReason case final String reason)
                MaterialBanner(
                  content: Text('只读模式：$reason'),
                  leading: const Icon(Icons.lock_outline),
                  actions: [
                    TextButton(
                      onPressed: () => setState(() => _revision++),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              Expanded(
                child: Row(
                  children: [
                    if (wide) ...[
                      NavigationRail(
                        extended: constraints.maxWidth >= 1200,
                        selectedIndex: _destination,
                        onDestinationSelected: (index) =>
                            setState(() => _destination = index),
                        destinations: [
                          for (var i = 0; i < _labels.length; i++)
                            NavigationRailDestination(
                              icon: Icon(_icons[i]),
                              label: Text(_labels[i]),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(child: content),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _destination,
                onDestinationSelected: (index) =>
                    setState(() => _destination = index),
                destinations: [
                  for (var i = 0; i < _labels.length; i++)
                    NavigationDestination(
                      icon: Icon(_icons[i]),
                      label: i == 3 ? '文件与备份' : _labels[i],
                    ),
                ],
              ),
      );
    },
  );
}
