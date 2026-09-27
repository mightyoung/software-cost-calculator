import 'agent_tools.dart';
import 'llm.dart';
import 'ontology.dart';
import 'store.dart';
import 'values.dart';

const maxToolRounds = 8;

/// A record the assistant refers to: `[[type:id|name]]`.
final recordRef = RegExp(
  r'\[\[(\w+):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\|([^\]]+)\]\]',
);

/// What each tool is doing, for progress shown while the assistant works.
const toolActivity = {
  'describe': '查看数据结构',
  'search': '搜索',
  'get': '读取记录',
  'query': '筛选记录',
  'related': '查关联记录',
  'compare_quotes': '比价',
  'quote_options': '为项目选价',
  'project_budget': '查预算',
  'data_quality': '检查数据质量',
  'inquiry_matrix': '查询价单',
};
String _system(String today) =>
    '你是供应商询价与项目成本系统的数据助手。今天是 $today。'
    '只能通过工具查询本机数据，不要编造；查不到就如实说明。'
    '先用 search 找到记录 id，再用 get/query/related 取详情；比价用 compare_quotes，'
    '项目选价用 quote_options，预算用 project_budget，询价单用 inquiry_matrix；'
    '字段含义不清时用 describe。回答使用中文。'
    '提到具体记录时写成 [[类型:id|名称]]，例如 [[supplier:3f2a…|甲泵业]]，'
    '界面会把它显示成可以点开的记录；不要在其他地方写出 id。'
    '工具结果中没有出现的字段表示为空。\n\n${ontologyCard()}';

extension Assistant on Store {
  /// Answers a question about local data using read-only tool calls.
  /// [onTool] hears each tool the model calls, for progress display.
  Future<String> ask(
    LlmClient llm,
    String question, {
    void Function(String tool)? onTool,
  }) async {
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': _system(localDay(clock()))},
      {'role': 'user', 'content': question},
    ];
    for (var round = 0; round < maxToolRounds; round++) {
      final message = await llm.complete(messages, tools: agentTools);
      messages.add(message);
      final calls = message['tool_calls'];
      if (calls is! List || calls.isEmpty) {
        return (message['content'] as String?)?.trim() ?? '';
      }
      for (final call in calls.cast<Map<String, Object?>>()) {
        final function = call['function']! as Map<String, Object?>;
        onTool?.call(function['name'] as String? ?? '');
        messages.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'content': runTool(
            function['name'] as String? ?? '',
            function['arguments'] as String? ?? '{}',
          ),
        });
      }
    }
    throw LlmException('查询步骤过多，请把问题说得更具体一些');
  }
}
