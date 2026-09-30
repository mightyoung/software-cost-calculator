import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'theme.dart';

/// True once the desktop window draws its own title bar (Windows, macOS).
/// Tests and phones keep the system's.
var customTitleBar = false;

/// Hides the system title bar so the dark sidebar runs to the top edge.
/// macOS keeps its traffic lights over the sidebar; Windows gets caption
/// buttons in [TitleBar].
Future<void> initWindow() async {
  if (!Platform.isWindows && !Platform.isMacOS) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Folio',
      minimumSize: Size(960, 600),
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  customTitleBar = true;
}

/// Height of the drawn title bar strip.
const titleBarHeight = 32.0;

/// Room the sidebar leaves at the top: the macOS traffic lights sit there.
double get sidebarTopInset =>
    customTitleBar ? (Platform.isMacOS ? 28 : titleBarHeight - 14) : 0;

/// The strip above the page: drag to move, double-click to maximize; on
/// Windows the minimize, maximize and close buttons.
class TitleBar extends StatefulWidget {
  const TitleBar({super.key});

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> with WindowListener {
  var maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => maximized = false);

  @override
  Widget build(BuildContext context) {
    final brightness = Tokens.dark ? Brightness.dark : Brightness.light;
    return SizedBox(
      height: titleBarHeight,
      child: Row(
        children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          if (Platform.isWindows) ...[
            WindowCaptionButton.minimize(
              brightness: brightness,
              onPressed: windowManager.minimize,
            ),
            maximized
                ? WindowCaptionButton.unmaximize(
                    brightness: brightness,
                    onPressed: windowManager.unmaximize,
                  )
                : WindowCaptionButton.maximize(
                    brightness: brightness,
                    onPressed: windowManager.maximize,
                  ),
            WindowCaptionButton.close(
              brightness: brightness,
              onPressed: windowManager.close,
            ),
          ],
        ],
      ),
    );
  }
}
