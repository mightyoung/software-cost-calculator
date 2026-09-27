import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/ai/ask_page.dart';
import '../features/catalog/catalog_page.dart';
import '../features/exchange/exchange_page.dart';
import '../features/projects/projects_page.dart';
import '../features/quotes/quote_form.dart';
import '../features/quotes/quotes_page.dart';
import '../features/settings/settings_page.dart';
import 'app_state.dart';
import 'theme.dart';

enum Section {
  projects('项目', Icons.folder_copy_outlined),
  quotes('报价查询', Icons.manage_search),
  ask('问数据', Icons.forum_outlined),
  suppliers('供应商', Icons.factory_outlined),
  products('物料', Icons.inventory_2_outlined),
  exchange('数据交换', Icons.sync_alt),
  settings('设置', Icons.settings_outlined);

  const Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _mobileBreakpoint = 720.0;

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  var section = Section.projects;

  Widget _page() => switch (section) {
    Section.projects => ProjectsPage(state: widget.state),
    Section.quotes => QuotesPage(state: widget.state),
    Section.ask => AskPage(state: widget.state),
    Section.suppliers => CatalogPage(state: widget.state, type: 'supplier'),
    Section.products => CatalogPage(state: widget.state, type: 'product'),
    Section.exchange => ExchangePage(state: widget.state),
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
              onOpen: () => setState(() => section = Section.exchange),
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
        for (var i = 0; i < 6; i++)
          SingleActivator(LogicalKeyboardKey(0x31 + i), control: true): () =>
              setState(() => section = Section.values[i]),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            showQuoteForm(context, widget.state),
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
                    Expanded(child: page),
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
          color: on ? Tokens.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(Tokens.radius),
          child: InkWell(
            borderRadius: BorderRadius.circular(Tokens.radius),
            hoverColor: Tokens.navHover,
            onTap: () => onSelect(s),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    s.icon,
                    size: 18,
                    color: on ? Colors.white : Tokens.navInk,
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

    return Container(
      width: 176,
      color: Tokens.nav,
      padding: const EdgeInsets.fromLTRB(10, 18, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 0, 10, 20),
            child: Row(
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  color: Color(0xFF6F9BFF),
                  size: 20,
                ),
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
          for (final s in Section.values.take(6)) item(s),
          const Spacer(),
          const Divider(color: Tokens.navHover),
          const SizedBox(height: 8),
          item(Section.settings),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
            child: Text(
              '本机：$device',
              style: const TextStyle(fontSize: 12, color: Tokens.navInk3),
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

  static const _primary = [Section.projects, Section.quotes, Section.products];

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
                  Section.ask,
                  Section.suppliers,
                  Section.exchange,
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
          icon: Icon(Icons.folder_copy_outlined),
          label: '项目',
        ),
        NavigationDestination(icon: Icon(Icons.manage_search), label: '报价'),
        NavigationDestination(
          icon: Icon(Icons.inventory_2_outlined),
          label: '物料',
        ),
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
        const Icon(Icons.move_to_inbox, color: Tokens.accentDeep, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
        TextButton(onPressed: onOpen, child: const Text('去查看')),
      ],
    ),
  );
}
