import 'package:flutter/material.dart';

/// Short, interruptible transitions; never animate every row in a data table.
abstract final class AppMotion {
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      WidgetsBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .reduceMotion;

  static Duration duration(BuildContext context, {int milliseconds = 180}) =>
      reduced(context) ? Duration.zero : Duration(milliseconds: milliseconds);
}

/// Keep native back gestures and platform transitions unless motion is reduced.
class AccessiblePageTransitions extends PageTransitionsBuilder {
  const AccessiblePageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduced(context)) return child;
    final native =
        const PageTransitionsTheme().builders[Theme.of(context).platform] ??
        const FadeUpwardsPageTransitionsBuilder();
    return native.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// Only the current page is mounted: no outgoing queries, timers or hit targets.
/// A transform avoids an opacity layer over large tables and keeps layout fixed.
class PageArrival extends StatefulWidget {
  const PageArrival({super.key, required this.identity, required this.child});
  final Object identity;
  final Widget child;

  @override
  State<PageArrival> createState() => _PageArrivalState();
}

class _PageArrivalState extends State<PageArrival>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) _controller.value = 1;
  }

  @override
  void didUpdateWidget(PageArrival oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _controller.duration = AppMotion.duration(context);
      if (AppMotion.reduced(context)) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _curve,
    child: KeyedSubtree(key: ValueKey(widget.identity), child: widget.child),
    builder: (_, child) => Transform.translate(
      offset: Offset(0, 6 * (1 - _curve.value)),
      child: child,
    ),
  );
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) => showDialog<T>(
  context: context,
  builder: builder,
  barrierDismissible: barrierDismissible,
  barrierColor: barrierColor,
  animationStyle: AppMotion.reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: Duration(milliseconds: 180),
          reverseDuration: Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
);

/// Unknown progress stays unknown. Reduced motion uses a static status label,
/// not a frozen spinner or a made-up completion percentage.
class TaskProgress extends StatelessWidget {
  const TaskProgress({super.key, this.compact = false, this.strokeWidth = 2});
  final bool compact;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) {
      return Semantics(
        label: '正在处理',
        child: compact
            ? Center(
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              )
            : const Text('正在处理…', style: TextStyle(fontSize: 12)),
      );
    }
    return compact
        ? CircularProgressIndicator(
            strokeWidth: strokeWidth,
            semanticsLabel: '正在处理',
          )
        : const LinearProgressIndicator(semanticsLabel: '正在处理');
  }
}
