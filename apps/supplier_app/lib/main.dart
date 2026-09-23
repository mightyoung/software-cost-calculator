import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'platform/platform_capabilities.dart';
import 'app/supplier_app.dart';
import 'app/workspace.dart';
import 'platform/workspace_factory.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SupplierStartup());
}

class SupplierStartup extends StatefulWidget {
  const SupplierStartup({super.key});
  @override
  State<SupplierStartup> createState() => _SupplierStartupState();
}

class _SupplierStartupState extends State<SupplierStartup> {
  late Future<SupplierWorkspace> _workspace = openSupplierWorkspace();
  @override
  Widget build(BuildContext context) => FutureBuilder<SupplierWorkspace>(
    future: _workspace,
    builder: (context, snapshot) {
      if (snapshot.hasData) return SupplierApp(workspace: snapshot.data!);
      return MaterialApp(
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: snapshot.hasError
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('本地数据库未能打开'),
                        const SizedBox(height: 12),
                        SelectableText('${snapshot.error}'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => setState(() {
                            _workspace = openSupplierWorkspace();
                          }),
                          child: const Text('重试'),
                        ),
                      ],
                    )
                  : const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('正在打开本地资料库…'),
                      ],
                    ),
            ),
          ),
        ),
      );
    },
  );
}

class SupplierProbeApp extends StatelessWidget {
  const SupplierProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '供应商系统 · 平台验证',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: Colors.indigo,
    ),
    themeMode: ThemeMode.system,
    home: const PlatformProbePage(),
  );
}

class PlatformProbePage extends StatefulWidget {
  const PlatformProbePage({super.key});

  @override
  State<PlatformProbePage> createState() => _PlatformProbePageState();
}

class _PlatformProbePageState extends State<PlatformProbePage> {
  late final Future<PlatformCapabilities> _report = UnverifiedPlatformProbe(
    kIsWeb ? 'web' : defaultTargetPlatform.name,
  ).inspect();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('平台能力验证')),
    body: FutureBuilder<PlatformCapabilities>(
      future: _report,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('验证未完成，业务写入保持关闭。'));
        }
        final report = snapshot.data;
        if (report == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '运行平台：${report.target}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text('业务写入已关闭', key: Key('write-gate')),
            const Text('当前为工程验证壳，不存储业务数据。构建或启动成功不能证明数据持久化。'),
            const SizedBox(height: 16),
            for (final capability in Capability.values)
              Card(
                child: ListTile(
                  title: Text(capability.label),
                  subtitle: Text(report.result(capability).detail),
                  trailing: Text(switch (report.result(capability).status) {
                    ProbeStatus.pass => '已验证',
                    ProbeStatus.fail => '失败',
                    ProbeStatus.blocked => '待验证',
                  }),
                ),
              ),
          ],
        );
      },
    ),
  );
}
