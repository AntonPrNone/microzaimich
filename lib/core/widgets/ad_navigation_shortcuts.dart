import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AdNavigationShortcuts extends StatefulWidget {
  const AdNavigationShortcuts({
    super.key,
    required this.child,
    required this.onPrevious,
    required this.onNext,
    this.canNavigatePrevious = true,
    this.canNavigateNext = true,
    this.autofocus = true,
  });

  final Widget child;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool canNavigatePrevious;
  final bool canNavigateNext;
  final bool autofocus;

  @override
  State<AdNavigationShortcuts> createState() => _AdNavigationShortcutsState();
}

class _AdNavigationShortcutsState extends State<AdNavigationShortcuts> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'ad-navigation-shortcuts');
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool _isTextInputFocused() {
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext == null) {
      return false;
    }
    if (focusedContext.widget is EditableText) {
      return true;
    }
    return focusedContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _isTextInputFocused()) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyA &&
        widget.canNavigatePrevious) {
      widget.onPrevious();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyD &&
        widget.canNavigateNext) {
      widget.onNext();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: true,
      onKeyEvent: _handleKey,
      child: widget.child,
    );
  }
}
