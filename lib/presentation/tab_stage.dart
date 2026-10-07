import 'package:flutter/widgets.dart';

/// v0.6.4 §battery — WHICH TAB IS ON STAGE.
///
/// The shell keeps every screen alive in an [IndexedStack] (state retention
/// across tab switches: the dashboard keeps its graphs, the nodes list its
/// scroll position). "Alive" is not "visible": a Dart [Timer.periodic] inside
/// an offstage screen still fires, and every tick that calls `setState` still
/// runs a full rebuild nobody can see. The dashboard's 1 s clock and the
/// device-stats poll (3 s, reads /proc + battery) therefore burned battery
/// for the whole session while the user browsed the Nodes tab.
///
/// Each screen wraps itself in this scope via the shell and parks its timers
/// while `active` is false. Reading it registers an inherited dependency, so
/// flipping tabs re-runs [State.didChangeDependencies] — no listener leaks,
/// no manual bookkeeping.
///
/// Screens built OUTSIDE the shell (widget tests, pushed routes) see no scope
/// and stay active — the safe default, since nothing else drives them.
class TabStageScope extends InheritedWidget {
  const TabStageScope({
    super.key,
    required this.index,
    required this.active,
    required super.child,
  });

  /// Zero-based tab index this subtree belongs to.
  final int index;

  /// True only for the tab currently on stage.
  final bool active;

  /// Is the calling widget's tab on stage? Defaults to `true` when no scope
  /// is in the tree (standalone screens, tests).
  static bool activeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabStageScope>()?.active ??
      true;

  @override
  bool updateShouldNotify(TabStageScope oldWidget) =>
      oldWidget.index != index || oldWidget.active != active;
}