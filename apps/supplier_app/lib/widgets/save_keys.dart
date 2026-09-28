import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Ctrl+Enter (⌘+Enter on macOS) saves the form inside; Esc already closes
/// dialogs.
class SaveKeys extends StatelessWidget {
  const SaveKeys({super.key, required this.onSave, required this.child});
  final VoidCallback onSave;
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter, control: true): onSave,
      const SingleActivator(LogicalKeyboardKey.enter, meta: true): onSave,
      const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
          onSave,
    },
    child: child,
  );
}
