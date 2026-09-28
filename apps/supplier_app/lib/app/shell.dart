import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../features/ai/ask_page.dart';
import '../features/catalog/catalog_page.dart';
import '../features/data_center/data_center_page.dart';
import '../features/exchange/exchange_page.dart';
import '../features/home/command_palette.dart';
import '../features/home/home_page.dart';
import '../features/projects/projects_page.dart';
import '../features/quotes/quote_form.dart';
import '../features/quotes/quotes_page.dart';
import '../features/settings/settings_page.dart';
import 'app_state.dart';
import 'theme.dart';
import 'title_bar.dart';

/// Sidebar order: work, then AI, then system; Ctrl+1… follow it.
enum Section {
  home('工作台', Icons.space_dashboard_outlined),
  projects('项目', Icons.folder_copy_outlined),
  quotes('报价', Icons.manage_search),
  suppliers('供应商', Icons.factory_outlined),
  products('物料', Icons.inventory_2_outlined),
  ask('问数据', Icons.forum_outlined),
  exchange('同步与交换', Icons.sync_alt),
  data('数据中心', Icons.hub_outlined),
  settings('设置', Icons.settings_outlined);

  const Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _mobileBreakpoint = 720.0;

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state, this.initial = Section.home});
  final AppState state;
  final Section initial;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late var section = widget.initial;

  void go(Section s) => setState(() => section = s);

  Widget _page() => switch (section) {
    Section.home => HomePage(state: widget.state, onGo: go),
    Section.projects => ProjectsPage(state: widget.state),
    Section.quotes => QuotesPage(state: widget.state),
    Section.ask => AskPage(state: widget.state),
    Section.suppliers => CatalogPage(state: widget.state, type: 'supplier'),
    Section.products => CatalogPage(state: widget.state, type: 'product'),
    Section.exchange => ExchangePage(state: widget.state),
    Section.data => DataCenterPage(state: widget.state),
    Section.settings => SettingsPage(state: widget.state),
  };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _mobileBreakpoint;
    final page = Column(
      children: [
        ListenableBuilder(
          listenable: widget.state,
          builder: (_, _) {
            final n = widget.state.incoming.length;
            if (n == 0 || section == Section.exchange) return const SizedBox();
            return _IncomingBar(
              text:
                  '收到 ${widget.state.incoming.first.fromName}'
                  '${n > 1 ? ' 等 $n 份' : '的'}局域网推送，确认后才会导入',
              onOpen: () => go(Section.exchange),
            );
          },
        ),
        Expanded(
          child: KeyedSubtree(key: ValueKey(section), child: _page()),
        ),
      ],
    );
    return CallbackShortcuts(
      bindings: {
        // Ctrl on Windows and Android keyboards, ⌘ on macOS; both work.
        for (final meta in [false, true]) ...{
          for (var i = 0; i < 8; i++)
            SingleActivator(
              LogicalKeyboardKey(0x31 + i),
              control: !meta,
              meta: meta,
            ): () =>
                go(Section.values[i]),
          SingleActivator(
            LogicalKeyboardKey.comma,
            control: !meta,
            meta: meta,
          ): () =>
              go(Section.settings),
          SingleActivator(
            LogicalKeyboardKey.keyN,
            control: !meta,
            meta: meta,
          ): () =>
              showQuoteForm(context, widget.state),
          SingleActivator(
            LogicalKeyboardKey.keyK,
            control: !meta,
            meta: meta,
          ): () =>
              showCommandPalette(context, widget.state, go),
          SingleActivator(
            LogicalKeyboardKey.keyF,
            control: !meta,
            meta: meta,
          ): () =>
              showCommandPalette(context, widget.state, go),
          SingleActivator(
            LogicalKeyboardKey.slash,
            control: !meta,
            meta: meta,
          ): () =>
              showShortcutHelp(context),
        },
        const SingleActivator(LogicalKeyboardKey.f1): () =>
            showShortcutHelp(context),
      },
      child: Focus(
        autofocus: true,
        child: wide
            ? Scaffold(
                body: Row(
                  children: [
                    _Sidebar(
                      current: section,
                      device: widget.state.deviceName,
                      onSelect: (s) => setState(() => section = s),
                    ),
                    Expanded(
                      child: customTitleBar
                          ? Column(
                              children: [
                                const TitleBar(),
                                Expanded(child: page),
                              ],
                            )
                          : page,
                    ),
                  ],
                ),
              )
            : Scaffold(
                body: SafeArea(child: page),
                bottomNavigationBar: _BottomNav(
                  current: section,
                  onSelect: (s) => setState(() => section = s),
                ),
              ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.current,
    required this.device,
    required this.onSelect,
  });
  final Section current;
  final String device;
  final ValueChanged<Section> onSelect;

  @override
  Widget build(BuildContext context) {
    Widget item(Section s) {
      final on = s == current;
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: on ? Tokens.navHover : Colors.transparent,
          borderRadius: BorderRadius.circular(Tokens.radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            hoverColor: Tokens.navHover,
            onTap: () => onSelect(s),
            child: Container(
              // The selected entry is marked by a bar, not a block of colour,
              // so it does not compete with primary buttons.
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: on ? Tokens.accent : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(9, 9, 10, 9),
              child: Row(
                children: [
                  Icon(
                    s.icon,
                    size: 18,
                    color: on ? Colors.white : Tokens.navInk3,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    s.label,
                    style: TextStyle(
                      fontSize: 14,
                      color: on ? Colors.white : Tokens.navInk,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget group(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 10, 6),
      child: Text(label, style: TextStyle(fontSize: 12, color: Tokens.navInk3)),
    );

    return Container(
      width: 176,
      color: Tokens.nav,
      padding: const EdgeInsets.fromLTRB(10, 18, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The window is dragged by the top of the sidebar too.
          if (customTitleBar)
            SizedBox(
              height: sidebarTopInset,
              child: const DragToMoveArea(child: SizedBox.expand()),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Row(
              children: [
                AppMark(size: 22),
                SizedBox(width: 8),
                Text(
                  '询价台账',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          group('工作'),
          for (final s in [
            Section.home,
            Section.projects,
            Section.quotes,
            Section.suppliers,
            Section.products,
          ])
            item(s),
          group('智能'),
          item(Section.ask),
          group('系统'),
          item(Section.exchange),
          item(Section.data),
          const Spacer(),
          Divider(color: Tokens.navHover),
          const SizedBox(height: 8),
          item(Section.settings),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
            child: Text(
              '本机：$device',
              style: TextStyle(fontSize: 12, color: Tokens.navInk3),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.current, required this.onSelect});
  final Section current;
  final ValueChanged<Section> onSelect;

  static const _primary = [Section.home, Section.projects, Section.quotes];

  @override
  Widget build(BuildContext context) {
    final index = _primary.indexOf(current);
    return NavigationBar(
      height: 64,
      backgroundColor: Tokens.canvas,
      indicatorColor: Tokens.accentTint,
      selectedIndex: index < 0 ? 3 : index,
      onDestinationSelected: (i) async {
        if (i < 3) return onSelect(_primary[i]);
        final picked = await showModalBottomSheet<Section>(
          context: context,
          builder: (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in [
                  Section.products,
                  Section.suppliers,
                  Section.ask,
                  Section.exchange,
                  Section.data,
                  Section.settings,
                ])
                  ListTile(
                    minTileHeight: 56,
                    leading: Icon(s.icon),
                    title: Text(s.label),
                    onTap: () => Navigator.pop(context, s),
                  ),
              ],
            ),
          ),
        );
        if (picked != null) onSelect(picked);
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.space_dashboard_outlined),
          label: '工作台',
        ),
        NavigationDestination(
          icon: Icon(Icons.folder_copy_outlined),
          label: '项目',
        ),
        NavigationDestination(icon: Icon(Icons.manage_search), label: '报价'),
        NavigationDestination(icon: Icon(Icons.more_horiz), label: '更多'),
      ],
    );
  }
}

class _IncomingBar extends StatelessWidget {
  const _IncomingBar({required this.text, required this.onOpen});
  final String text;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Container(
    color: Tokens.accentTint,
    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
    child: Row(
      children: [
        Icon(Icons.move_to_inbox, color: Tokens.accentDeep, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
        TextButton(onPressed: onOpen, child: const Text('去查看')),
      ],
    ),
  );
}

/// The app icon's ledger mark: three rows, the chosen one in blue.
class AppMark extends StatelessWidget {
  const AppMark({super.key, required this.size});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MarkPainter());
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    void bar(double top, double length, Color colour) => canvas.drawRRect(
      RRect.fromLTRBR(
        w * 0.08,
        w * top,
        w * (0.08 + length),
        w * (top + 0.14),
        Radius.circular(w * 0.07),
      ),
      Paint()..color = colour,
    );
    bar(0.16, 0.66, Tokens.navInk3);
    bar(0.43, 0.58, Tokens.accent);
    bar(0.70, 0.44, Tokens.navInk3);
    canvas.drawCircle(
      Offset(w * 0.82, w * 0.50),
      w * 0.12,
      Paint()..color = const Color(0xFF6F9BFF),
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}
