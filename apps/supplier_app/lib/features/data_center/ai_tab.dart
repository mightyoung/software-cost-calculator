import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../widgets/app_icon.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import 'data_center_page.dart';
import 'relation_graph.dart';

/// The bundled read-only MCP server: next to the exe on Windows, inside
/// the app bundle on macOS; null elsewhere.
String? _mcpCommand() {
  final exe = File(Platform.resolvedExecutable).parent;
  if (Platform.isWindows) return '${exe.path}\\siq-mcp\\bin\\siq_mcp.exe';
  if (Platform.isMacOS) {
    return '${exe.parent.path}/Resources/siq-mcp/bin/siq_mcp';
  }
  return null;
}

class AiAccessTab extends StatefulWidget {
  const AiAccessTab({super.key, required this.state});
  final AppState state;

  @override
  State<AiAccessTab> createState() => _AiTabState();
}

class _AiTabState extends State<AiAccessTab> {
  String query = '';
  bool mcpExpanded = false, rulesExpanded = false;
  AppState get state => widget.state;
  @override
  Widget build(BuildContext context) {
    final guide = agentGuide();
    final filteredTools = agentTools.where((t) {
      final function = t['function']! as Map;
      return '${function['name']} ${function['description']}'
          .toLowerCase()
          .contains(query.trim().toLowerCase());
    }).toList();
    return ListView(
      padding: dataCenterPadding,
      children: [
        dataCenterCard(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '"问数据"里的 AI 助手读取的就是这里的数据模型和规则，并且只能用下列只读工具查询，不能修改数据。'
                '也可以把完整的数据说明复制给其他 AI 工具，让它理解这些数据。',
                style: TextStyle(
                  color: RelationGraphPalette.of(context).muted,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: guide));
                      if (context.mounted) toast(context, '已复制数据说明');
                    },
                    icon: const AppIcon(Icons.copy, size: 18),
                    label: const Text('复制数据说明'),
                  ),
                  Text(
                    '约 ${guide.length} 字，只含结构和规则，不含任何业务数据',
                    style: TextStyle(
                      fontSize: 12,
                      color: RelationGraphPalette.of(context).muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_mcpCommand() case final command?) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('接入其他 AI 工具（MCP）'),
            onExpansionChanged: (value) => setState(() => mcpExpanded = value),
            trailing: AnimatedRotation(
              turns: mcpExpanded ? .25 : 0,
              duration: AppMotion.duration(context),
              child: const AppIcon(Icons.chevron_right),
            ),
            children: [
              _McpCard(
                command: command,
                database:
                    '${state.dataDir.path}${Platform.pathSeparator}supplier.db',
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Text(
          '只读工具 · ${filteredTools.length}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('ai-tool-search'),
          decoration: const InputDecoration(labelText: '搜索工具名称或用途'),
          onChanged: (value) => setState(() => query = value),
        ),
        if (filteredTools.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('没有匹配的只读工具'),
          ),
        const SizedBox(height: 8),
        dataCenterCard(
          context,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, t) in filteredTools.indexed)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: i == 0
                        ? null
                        : Border(
                            top: BorderSide(
                              color: RelationGraphPalette.of(context).border,
                            ),
                          ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final name = Text(
                        (t['function']! as Map)['name'] as String,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      );
                      final description = Text(
                        (t['function']! as Map)['description'] as String,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      );
                      if (constraints.maxWidth < 600 ||
                          MediaQuery.textScalerOf(context).scale(14) > 18) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            name,
                            const SizedBox(height: 6),
                            description,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 170, child: name),
                          const SizedBox(width: 16),
                          Expanded(child: description),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ExpansionTile(
          title: const Text('AI 需要遵守的规则'),
          onExpansionChanged: (value) => setState(() => rulesExpanded = value),
          trailing: AnimatedRotation(
            turns: rulesExpanded ? .25 : 0,
            duration: AppMotion.duration(context),
            child: const AppIcon(Icons.chevron_right),
          ),
          children: [
            dataCenterCard(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in rules)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '· ${r.text}',
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// How to connect Claude Desktop, Cursor and other MCP clients.
class _McpCard extends StatelessWidget {
  const _McpCard({required this.command, required this.database});
  final String command, database;

  @override
  Widget build(BuildContext context) {
    final config = const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'xunjia': {
          'command': command,
          'args': ['--db', database],
        },
      },
    });
    final bundled = File(command).existsSync();
    return dataCenterCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '接入其他 AI 工具（MCP）',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            'Claude Desktop、Cursor 等支持 MCP 的工具，可以通过随软件附带的 siq-mcp 直接查询本机数据：'
            '把下面的配置加入该工具的 MCP 设置并重启它。siq-mcp 以只读方式打开数据库，'
            '用的是上面同一组只读工具；查询到的数据会发送给该工具所用的 AI 服务。',
            style: TextStyle(
              color: RelationGraphPalette.of(context).muted,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          if (!bundled)
            const HintText(
              '当前运行目录未检测到 siq-mcp，暂不能提供可用配置。安装包是否包含该组件需以实际文件为准。',
              icon: Icons.info_outline,
            )
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: RelationGraphPalette.of(context).canvas,
                borderRadius: BorderRadius.circular(Tokens.radius),
              ),
              child: SelectableText(
                config,
                style: const TextStyle(
                  fontFamily: monoFamily,
                  fontFamilyFallback: monoFallback,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: config));
                if (context.mounted) toast(context, '已复制 MCP 配置');
              },
              icon: const AppIcon(Icons.copy, size: 18),
              label: const Text('复制配置'),
            ),
          ],
          if (bundled && Platform.isMacOS) ...[
            const SizedBox(height: 8),
            Text(
              'macOS 首次运行时可能询问是否允许访问其他 App 的数据，请选择允许。',
              style: TextStyle(
                fontSize: 12,
                color: RelationGraphPalette.of(context).muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
