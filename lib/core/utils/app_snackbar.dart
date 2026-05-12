import 'package:flutter/material.dart';

final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>();

OverlayEntry? _activeSnackOverlay;

void showAppSnackBar(
  String message, {
  Color? backgroundColor,
}) {
  _activeSnackOverlay?.remove();

  final overlay = rootNavigatorKey.currentState?.overlay;
  if (overlay == null) {
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          backgroundColor: backgroundColor,
          content: Text(message),
        ),
      );
    return;
  }

  _activeSnackOverlay = OverlayEntry(
    builder: (context) {
      final theme = Theme.of(context);
      final bottomInset = MediaQuery.of(context).viewInsets.bottom;
      final surfaceColor =
          backgroundColor ?? theme.colorScheme.inverseSurface;
      final onSurfaceColor = theme.colorScheme.onInverseSurface;

      return IgnorePointer(
        child: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
              child: Material(
                color: Colors.transparent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: surfaceColor,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.26),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: onSurfaceColor,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(_activeSnackOverlay!);

  Future<void>.delayed(const Duration(seconds: 4), () {
    _activeSnackOverlay?.remove();
    _activeSnackOverlay = null;
  });
}
