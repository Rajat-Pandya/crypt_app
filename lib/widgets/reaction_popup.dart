import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Centralized overlay coordinator for managing popup lifecycle.
/// 
/// Features:
/// - Single overlay at a time (prevents stacking)
/// - Proper cleanup and disposal
/// - Safe area and keyboard handling
/// - Smooth animations
class OverlayCoordinator {
  static OverlayCoordinator? _instance;
  static OverlayCoordinator get instance => _instance ??= OverlayCoordinator._();
  OverlayCoordinator._();

  OverlayEntry? _currentOverlay;
  VoidCallback? _onDismiss;
  bool _isShowing = false;

  bool get isShowing => _isShowing;

  /// Show an overlay widget, replacing any existing overlay.
  void show({
    required BuildContext context,
    required WidgetBuilder builder,
    VoidCallback? onDismiss,
    bool barrierDismissible = true,
  }) {
    // Dismiss any existing overlay first
    dismiss();

    _onDismiss = onDismiss;
    _isShowing = true;

    final overlay = Overlay.of(context);
    
    _currentOverlay = OverlayEntry(
      builder: (context) => _OverlayWrapper(
        builder: builder,
        barrierDismissible: barrierDismissible,
        onDismiss: dismiss,
      ),
    );

    overlay.insert(_currentOverlay!);
  }

  /// Dismiss the current overlay.
  void dismiss() {
    if (_currentOverlay != null) {
      _currentOverlay?.remove();
      _currentOverlay?.dispose();
      _currentOverlay = null;
      _isShowing = false;
      _onDismiss?.call();
      _onDismiss = null;
    }
  }

  /// Toggle overlay visibility.
  void toggle({
    required BuildContext context,
    required WidgetBuilder builder,
    VoidCallback? onDismiss,
    bool barrierDismissible = true,
  }) {
    if (_isShowing) {
      dismiss();
    } else {
      show(
        context: context,
        builder: builder,
        onDismiss: onDismiss,
        barrierDismissible: barrierDismissible,
      );
    }
  }
}

/// Wrapper widget for overlay with barrier and animations.
class _OverlayWrapper extends StatefulWidget {
  final WidgetBuilder builder;
  final bool barrierDismissible;
  final VoidCallback onDismiss;

  const _OverlayWrapper({
    required this.builder,
    required this.barrierDismissible,
    required this.onDismiss,
  });

  @override
  State<_OverlayWrapper> createState() => _OverlayWrapperState();
}

class _OverlayWrapperState extends State<_OverlayWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) {
      widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final padding = mediaQuery.padding;
    final viewInsets = mediaQuery.viewInsets;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Stack(
        children: [
          // Barrier
          if (widget.barrierDismissible)
            Positioned.fill(
              child: GestureDetector(
                onTap: _dismiss,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  color: Colors.black.withOpacity(0.2),
                ),
              ),
            ),
          // Content with safe area
          Padding(
            padding: EdgeInsets.only(
              top: padding.top,
              bottom: padding.bottom + viewInsets.bottom,
              left: padding.left,
              right: padding.right,
            ),
            child: widget.builder(context),
          ),
        ],
      ),
    );
  }
}

/// WhatsApp-style reaction popup with proper positioning and animations.
class ReactionPopup extends StatefulWidget {
  final GlobalKey anchorKey;
  final String currentReaction;
  final ValueChanged<String> onReactionSelected;
  final VoidCallback onDismiss;

  const ReactionPopup({
    super.key,
    required this.anchorKey,
    required this.currentReaction,
    required this.onReactionSelected,
    required this.onDismiss,
  });

  @override
  State<ReactionPopup> createState() => _ReactionPopupState();
}

class _ReactionPopupState extends State<ReactionPopup>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _slideAnimation;

  final List<String> _reactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    
    _scaleAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    );
    
    _slideAnimation = Tween<double>(begin: 20, end: 0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOut,
      ),
    );
    
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _selectReaction(String emoji) {
    HapticFeedback.mediumImpact();
    widget.onReactionSelected(emoji);
    _controller.reverse().then((_) {
      widget.onDismiss();
    });
  }

  Offset _calculatePosition() {
    final renderBox = widget.anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return Offset.zero;

    final anchorPosition = renderBox.localToGlobal(Offset.zero);
    final anchorSize = renderBox.size;
    final screenSize = MediaQuery.of(context).size;
    
    final popupWidth = 280.0;
    final popupHeight = 56.0;
    final padding = 8.0;

    // Center horizontally relative to anchor
    double left = anchorPosition.dx + (anchorSize.width / 2) - (popupWidth / 2);
    
    // Try to position above first
    double top = anchorPosition.dy - popupHeight - padding;
    
    // If would go off top, position below
    if (top < MediaQuery.of(context).padding.top + padding) {
      top = anchorPosition.dy + anchorSize.height + padding;
    }
    
    // Clamp horizontal position
    left = left.clamp(padding, screenSize.width - popupWidth - padding);
    
    return Offset(left, top);
  }

  @override
  Widget build(BuildContext context) {
    final position = _calculatePosition();
    
    return Stack(
      children: [
        Positioned(
          left: position.dx,
          top: position.dy,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Transform.translate(
                offset: Offset(0, _slideAnimation.value),
                child: Transform.scale(
                  scale: _scaleAnimation.value,
                  alignment: Alignment.bottomCenter,
                  child: child,
                ),
              );
            },
            child: Container(
              width: 280,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: _reactions.map((emoji) {
                    final isSelected = emoji == widget.currentReaction;
                    return _ReactionButton(
                      emoji: emoji,
                      isSelected: isSelected,
                      onTap: () => _selectReaction(emoji),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Individual reaction button with animation.
class _ReactionButton extends StatefulWidget {
  final String emoji;
  final bool isSelected;
  final VoidCallback onTap;

  const _ReactionButton({
    required this.emoji,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_ReactionButton> createState() => _ReactionButtonState();
}

class _ReactionButtonState extends State<_ReactionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.elasticOut,
      ),
    );
    
    if (widget.isSelected) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(_ReactionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelected != oldWidget.isSelected) {
      if (widget.isSelected) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: child,
          );
        },
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: Text(
            widget.emoji,
            style: const TextStyle(fontSize: 28),
          ),
        ),
      ),
    );
  }
}

/// Utility class for showing reaction popup.
class ReactionPopupUtils {
  static void show({
    required BuildContext context,
    required GlobalKey anchorKey,
    required String currentReaction,
    required ValueChanged<String> onReactionSelected,
  }) {
    HapticFeedback.mediumImpact();
    
    OverlayCoordinator.instance.show(
      context: context,
      builder: (context) => ReactionPopup(
        anchorKey: anchorKey,
        currentReaction: currentReaction,
        onReactionSelected: onReactionSelected,
        onDismiss: () => OverlayCoordinator.instance.dismiss(),
      ),
      barrierDismissible: true,
      onDismiss: () {},
    );
  }

  static void dismiss() {
    OverlayCoordinator.instance.dismiss();
  }
}
