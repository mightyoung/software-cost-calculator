import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import 'app_icon.dart';
import '../app/theme.dart';

/// One column of a [DataGrid]. [value] feeds sorting and Excel export:
/// return a String, a num, a [Num] (exact decimal) or null. [cell] draws
/// the value when plain text is not enough.
class GridColumn<T> {
  const GridColumn(
    this.label, {
    required this.value,
    this.cell,
    this.width,
    this.flex = 1,
    this.numeric = false,
    this.sortable = true,
  });
  final String label;
  final Object? Function(T row) value;
  final Widget Function(T row)? cell;

  /// Fixed width; otherwise the column takes [flex] shares of the rest.
  final double? width;
  final int flex;
  final bool numeric, sortable;
}

/// Sorting chosen in the header: column index and direction.
typedef GridSort = ({int column, bool ascending});

/// A ledger table: sortable header, hover and selected rows, optional
/// multi-select with a bulk-action bar. Sorts in memory unless [onSort] is
/// given (then the caller sorts, e.g. in the database, and passes [sort]).
class DataGrid<T> extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.rows,
    required this.columns,
    required this.id,
    this.onOpen,
    this.bulkActions,
    this.sort,
    this.onSort,
    this.footer,
    this.selectedId,
    this.rowHeight = 52,
  });
  final List<T> rows;
  final List<GridColumn<T>> columns;
  final String Function(T row) id;
  final void Function(T row)? onOpen;

  /// Buttons shown while rows are ticked; [clear] unticks them.
  final List<Widget> Function(List<T> selected, VoidCallback clear)?
  bulkActions;
  final GridSort? sort;
  final void Function(GridSort sort)? onSort;
  final Widget? footer;

  /// The row shown in a detail panel, highlighted.
  final String? selectedId;
  final double rowHeight;

  @override
  State<DataGrid<T>> createState() => _DataGridState<T>();
}

class _DataGridState<T> extends State<DataGrid<T>> {
  final horizontalController = ScrollController();
  @override
  void dispose() {
    horizontalController.dispose();
    super.dispose();
  }

  GridSort? localSort;
  final ticked = <String>{};
  int? hover;
  String? focusedId;

  GridSort? get sort => widget.onSort == null ? localSort : widget.sort;

  List<T> get _rows {
    final s = localSort;
    if (widget.onSort != null || s == null) return widget.rows;
    final key = widget.columns[s.column].value;
    return [...widget.rows]..sort((a, b) {
      final c = compareGridValues(key(a), key(b));
      return s.ascending ? c : -c;
    });
  }

  void _tapHeader(int i) {
    final current = sort;
    final next = (
      column: i,
      ascending: current?.column == i ? !current!.ascending : true,
    );
    if (widget.onSort != null) {
      widget.onSort!(next);
    } else {
      setState(() => localSort = next);
    }
  }

  Widget _cells(List<Widget> children) => Row(children: children);

  Widget _sized(GridColumn<T> c, Widget child) {
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Align(
        alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
        child: child,
      ),
    );
    return c.width != null
        ? SizedBox(width: c.width, child: padded)
        : Expanded(flex: c.flex, child: padded);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final selectable = widget.bulkActions != null;
    // Drop ticks for rows that went away (deleted, filtered out).
    ticked.retainAll({for (final r in widget.rows) widget.id(r)});
    final selected = [
      for (final r in rows)
        if (ticked.contains(widget.id(r))) r,
    ];
    final header = Container(
      height: 42,
      decoration: BoxDecoration(
        color: Tokens.sunken,
        border: Border(bottom: BorderSide(color: Tokens.rule)),
      ),
      child: _cells([
        if (selectable)
          SizedBox(
            width: 44,
            child: Checkbox(
              tristate: true,
              value: selected.isEmpty
                  ? false
                  : selected.length == rows.length
                  ? true
                  : null,
              onChanged: (_) => setState(() {
                if (selected.length == rows.length) {
                  ticked.clear();
                } else {
                  ticked.addAll(rows.map(widget.id));
                }
              }),
            ),
          ),
        for (final (i, c) in widget.columns.indexed)
          _sized(
            c,
            InkWell(
              onTap: c.sortable ? () => _tapHeader(i) : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      c.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Tokens.ink2,
                      ),
                    ),
                  ),
                  if (sort?.column == i)
                    AppIcon(
                      sort!.ascending
                          ? Icons.arrow_upward
                          : Icons.arrow_downward,
                      size: 14,
                      color: Tokens.accentDeep,
                    ),
                ],
              ),
            ),
          ),
      ]),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Tokens.surface,
        border: Border.all(color: Tokens.rule),
        borderRadius: BorderRadius.circular(Tokens.radius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Fixed columns retain their widths. Flexible columns get a readable
          // floor; only the grid scrolls horizontally, keeping rows virtualized.
          final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final minimumWidth = widget.columns.fold<double>(
            selectable ? 44 : 0,
            (width, column) =>
                width + (column.width ?? 120 * textScale * column.flex),
          );
          final contentWidth = minimumWidth > constraints.maxWidth
              ? minimumWidth
              : constraints.maxWidth;
          return Scrollbar(
            controller: horizontalController,
            thumbVisibility: contentWidth > constraints.maxWidth,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: horizontalController,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                height: constraints.maxHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (selected.isNotEmpty)
                      Container(
                        color: Tokens.accentTint,
                        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '已选 ${selected.length} 项',
                              style: TextStyle(
                                color: Tokens.accentDeep,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 12),
                            ...widget.bulkActions!(
                              selected,
                              () => setState(ticked.clear),
                            ),
                            TextButton(
                              onPressed: () => setState(ticked.clear),
                              child: const Text('取消选择'),
                            ),
                          ],
                        ),
                      ),
                    header,
                    Expanded(
                      child: ListView.builder(
                        itemCount:
                            rows.length + (widget.footer == null ? 0 : 1),
                        itemExtent: null,
                        itemBuilder: (context, i) {
                          if (i == rows.length) return widget.footer!;
                          final row = rows[i];
                          final id = widget.id(row);
                          final on =
                              id == widget.selectedId || ticked.contains(id);
                          return MouseRegion(
                            onEnter: (_) => setState(() => hover = i),
                            onExit: (_) => setState(() => hover = null),
                            child: Semantics(
                              selected: on,
                              button: widget.onOpen != null,
                              child: Material(
                                color: on
                                    ? Tokens.accentTint
                                    : (hover == i
                                          ? Tokens.groupRow
                                          : Tokens.surface),
                                child: InkWell(
                                  onFocusChange: (focused) => setState(() {
                                    focusedId = focused
                                        ? id
                                        : (focusedId == id ? null : focusedId);
                                  }),
                                  focusColor: Tokens.accentTint,
                                  onTap: widget.onOpen == null
                                      ? null
                                      : () => widget.onOpen!(row),
                                  child: Container(
                                    constraints: BoxConstraints(
                                      minHeight: widget.rowHeight,
                                    ),
                                    decoration: BoxDecoration(
                                      border: focusedId == id
                                          ? Border.all(
                                              color: Tokens.accent,
                                              width: 2,
                                            )
                                          : Border(
                                              bottom: BorderSide(
                                                color: Tokens.rule,
                                              ),
                                            ),
                                    ),
                                    child: _cells([
                                      if (selectable)
                                        SizedBox(
                                          width: 44,
                                          child: Checkbox(
                                            value: ticked.contains(id),
                                            onChanged: (v) => setState(
                                              () => v!
                                                  ? ticked.add(id)
                                                  : ticked.remove(id),
                                            ),
                                          ),
                                        ),
                                      for (final c in widget.columns)
                                        _sized(
                                          c,
                                          c.cell?.call(row) ??
                                              Text(
                                                gridText(c.value(row)),
                                                overflow: TextOverflow.ellipsis,
                                                style: c.numeric
                                                    ? const TextStyle(
                                                        fontFeatures: tabular,
                                                      )
                                                    : null,
                                              ),
                                        ),
                                    ]),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Nulls last; numbers by value (exact decimals too); text by code point.
int compareGridValues(Object? a, Object? b) {
  if (a == null || b == null) {
    return a == null ? (b == null ? 0 : 1) : -1;
  }
  num? n(Object v) => switch (v) {
    num x => x,
    Num x => double.tryParse(x.decimal),
    _ => null,
  };
  final (x, y) = (n(a), n(b));
  if (x != null && y != null) return x.compareTo(y);
  return '$a'.compareTo('$b');
}

String gridText(Object? v) => switch (v) {
  null => '',
  Num x => x.decimal,
  _ => '$v',
};

/// The rows as shown (in [columns] order) as one Excel sheet.
Uint8List gridToXlsx<T>(
  String sheet,
  List<GridColumn<T>> columns,
  List<T> rows,
) => writeXlsx([
  SheetData(
    sheet,
    [
      [for (final c in columns) c.label],
      for (final r in rows)
        [
          for (final c in columns)
            switch (c.value(r)) {
              final num n => Num('$n'),
              final Object? v => v,
            },
        ],
    ],
    boldRows: const {0},
  ),
]);
