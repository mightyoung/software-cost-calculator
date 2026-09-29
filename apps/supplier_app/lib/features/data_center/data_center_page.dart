import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'ai_tab.dart';
import 'model_tab.dart';
import 'ontology_graph_host.dart';
import 'quality_tab.dart';
import 'relation_graph.dart';

/// The data model, data quality and what AI agents get, in one place.
class DataCenterPage extends StatefulWidget {
  const DataCenterPage({
    super.key,
    required this.state,
    this.ontologyViewBuilder,
  });
  final AppState state;
  final OntologyViewBuilder? ontologyViewBuilder;

  @override
  State<DataCenterPage> createState() => _DataCenterPageState();
}

class _DataCenterPageState extends State<DataCenterPage> {
  var selected = 'quotation';
  late Map<String, int> counts;

  @override
  void initState() {
    super.initState();
    counts = widget.state.store.recordCounts();
    widget.state.addListener(_refreshCounts);
  }

  void _refreshCounts() {
    setState(() => counts = widget.state.store.recordCounts());
  }

  @override
  void didUpdateWidget(DataCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_refreshCounts);
      widget.state.addListener(_refreshCounts);
      counts = widget.state.store.recordCounts();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_refreshCounts);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = RelationGraphPalette.of(context);
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: p.accent,
          onPrimary: p.surface,
          surface: p.surface,
          onSurface: p.ink,
          onSurfaceVariant: p.muted,
          outline: p.border,
          outlineVariant: p.border,
          secondaryContainer: p.tint,
          onSecondaryContainer: p.ink,
        ),
        textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
        scaffoldBackgroundColor: p.canvas,
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          fillColor: p.surface,
        ),
      ),
      child: Material(
        color: p.canvas,
        child: DefaultTabController(
          length: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                child: Text(
                  '数据中心',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  '软件里有哪些数据、它们怎样关联、质量如何，以及 AI 能读到什么。',
                  style: TextStyle(color: p.muted),
                ),
              ),
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.symmetric(horizontal: 12),
                tabs: [
                  Tab(text: '数据模型'),
                  Tab(text: '数据质量'),
                  Tab(text: 'AI 接入'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  // Horizontal gestures belong to the graph and data tables.
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    // Switching tabs must not reload the web view.
                    _KeepAlive(
                      child: OntologyGraphHost(
                        counts: counts,
                        selected: selected,
                        onSelect: (t) => setState(() => selected = t),
                        viewBuilder: widget.ontologyViewBuilder,
                        fallback: OntologyModelTab(
                          counts: counts,
                          selected: selected,
                          onSelect: (t) => setState(() => selected = t),
                        ),
                      ),
                    ),
                    QualityTab(state: widget.state),
                    AiAccessTab(state: widget.state),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget dataCenterCard(
  BuildContext context, {
  required Widget child,
  EdgeInsets? padding,
}) => Container(
  padding: padding ?? const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: RelationGraphPalette.of(context).surface,
    border: Border.all(color: RelationGraphPalette.of(context).border),
    borderRadius: BorderRadius.circular(Tokens.radius),
  ),
  child: child,
);

const dataCenterPadding = EdgeInsets.fromLTRB(24, 16, 24, 24);

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
