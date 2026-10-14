import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

/// Enhanced centralized overlay coordinator for managing popup lifecycle.
/// 
/// Features:
/// - Single overlay at a time (prevents stacking)
/// - Proper cleanup and disposal
/// - Safe area and keyboard handling
/// - Smooth animations
/// - Keyboard-aware positioning
/// - Type-safe overlay management
class OverlayCoordinator {
  static OverlayCoordinator? _instance;
  static OverlayCoordinator get instance => _instance ??= OverlayCoordinator._();
  OverlayCoordinator._();

  OverlayEntry? _currentOverlay;
  OverlayType? _currentType;
  VoidCallback? _onDismiss;
  bool _isShowing = false;

  bool get isShowing => _isShowing;
  OverlayType? get currentType => _currentType;
  bool get isShowingReactions => _currentType == OverlayType.reaction;
  bool get isShowingEmoji => _currentType == OverlayType.emoji;

  /// Show an overlay widget, replacing any existing overlay.
  /// 
  /// [type] identifies the type of overlay for proper management
  void show({
    required BuildContext context,
    required WidgetBuilder builder,
    required OverlayType type,
    VoidCallback? onDismiss,
    bool barrierDismissible = true,
    Duration animationDuration = const Duration(milliseconds: 200),
  }) {
    // Dismiss any existing overlay first
    dismiss();

    _onDismiss = onDismiss;
    _isShowing = true;
    _currentType = type;

    final overlay = Overlay.of(context);
    
    _currentOverlay = OverlayEntry(
      builder: (context) => _OverlayWrapper(
        builder: builder,
        barrierDismissible: barrierDismissible,
        onDismiss: dismiss,
        animationDuration: animationDuration,
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
      _currentType = null;
      _onDismiss?.call();
      _onDismiss = null;
    }
  }

  /// Toggle overlay visibility.
  void toggle({
    required BuildContext context,
    required WidgetBuilder builder,
    required OverlayType type,
    VoidCallback? onDismiss,
    bool barrierDismissible = true,
  }) {
    if (_isShowing && _currentType == type) {
      dismiss();
    } else {
      show(
        context: context,
        builder: builder,
        type: type,
        onDismiss: onDismiss,
        barrierDismissible: barrierDismissible,
      );
    }
  }

  /// Dismiss if showing a specific type
  void dismissIfShowing(OverlayType type) {
    if (_currentType == type) {
      dismiss();
    }
  }
}

/// Types of overlays managed by the coordinator
enum OverlayType {
  reaction,
  emoji,
  menu,
  tooltip,
  custom,
}

/// Wrapper widget for overlay with barrier, animations, and keyboard handling.
class _OverlayWrapper extends StatefulWidget {
  final WidgetBuilder builder;
  final bool barrierDismissible;
  final VoidCallback onDismiss;
  final Duration animationDuration;

  const _OverlayWrapper({
    required this.builder,
    required this.barrierDismissible,
    required this.onDismiss,
    required this.animationDuration,
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
      duration: widget.animationDuration,
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return FadeTransition(
          opacity: _fadeAnimation,
          child: child,
        );
      },
      child: Stack(
        children: [
          // Barrier
          if (widget.barrierDismissible)
            Positioned.fill(
              child: GestureDetector(
                onTap: _dismiss,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  color: Colors.black.withOpacity(0.3),
                ),
              ),
            ),
          // Content
          _KeyboardSafeArea(
            child: widget.builder(context),
          ),
        ],
      ),
    );
  }
}

/// Widget that handles keyboard insets and safe area for overlays.
class _KeyboardSafeArea extends StatelessWidget {
  final Widget child;

  const _KeyboardSafeArea({required this.child});

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final padding = mediaQuery.padding;
    final viewInsets = mediaQuery.viewInsets;
    
    return Padding(
      padding: EdgeInsets.only(
        top: padding.top,
        bottom: math.max(padding.bottom, viewInsets.bottom),
        left: padding.left,
        right: padding.right,
      ),
      child: child,
    );
  }
}

/// Positioning utilities for keyboard-safe overlay placement.
class OverlayPositioning {
  /// Calculate position for a popup relative to an anchor widget.
  /// 
  /// Handles:
  /// - Keyboard avoidance
  /// - Screen edge detection
  /// - Safe area insets
  /// - Preferred direction (above/below)
  static Offset calculatePosition({
    required BuildContext context,
    required GlobalKey anchorKey,
    required Size popupSize,
    Offset offset = const Offset(0, 8),
    PopupDirection preferredDirection = PopupDirection.above,
    bool avoidKeyboard = true,
  }) {
    final renderBox = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return Offset.zero;

    final anchorPosition = renderBox.localToGlobal(Offset.zero);
    final anchorSize = renderBox.size;
    
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final padding = mediaQuery.padding;
    final viewInsets = avoidKeyboard ? mediaQuery.viewInsets : EdgeInsets.zero;
    
    final safeTop = padding.top;
    final safeBottom = screenSize.height - padding.bottom - viewInsets.bottom;
    final safeLeft = padding.left;
    final safeRight = screenSize.width - padding.right;

    // Try preferred direction first
    Offset position;
    
    if (preferredDirection == PopupDirection.above) {
      // Position above anchor
      position = Offset(
        anchorPosition.dx + (anchorSize.width / 2) - (popupSize.width / 2),
        anchorPosition.dy - popupSize.height - offset.dy,
      );
      
      // If too close to top, flip to below
      if (position.dy < safeTop + 16) {
        position = Offset(
          anchorPosition.dx + (anchorSize.width / 2) - (popupSize.width / 2),
          anchorPosition.dy + anchorSize.height + offset.dy,
        );
      }
    } else {
      // Position below anchor
      position = Offset(
        anchorPosition.dx + (anchorSize.width / 2) - (popupSize.width / 2),
        anchorPosition.dy + anchorSize.height + offset.dy,
      );
      
      // If too close to bottom (considering keyboard), flip to above
      if (position.dy + popupSize.height > safeBottom - 16) {
        position = Offset(
          anchorPosition.dx + (anchorSize.width / 2) - (popupSize.width / 2),
          anchorPosition.dy - popupSize.height - offset.dy,
        );
      }
    }
    
    // Clamp horizontal position to safe area
    position = Offset(
      position.dx.clamp(safeLeft + 8, safeRight - popupSize.width - 8),
      position.dy.clamp(safeTop + 8, safeBottom - popupSize.height - 8),
    );
    
    return position;
  }
  
  /// Calculate position centered on screen
  static Offset calculateCenterPosition({
    required BuildContext context,
    required Size popupSize,
    double verticalOffset = 0,
  }) {
    final screenSize = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final viewInsets = MediaQuery.of(context).viewInsets;
    
    final safeHeight = screenSize.height - padding.top - padding.bottom - viewInsets.bottom;
    
    return Offset(
      (screenSize.width - popupSize.width) / 2,
      padding.top + (safeHeight - popupSize.height) / 2 + verticalOffset,
    );
  }
}

/// Direction for popup positioning
enum PopupDirection {
  above,
  below,
  auto,
}

/// WhatsApp-style reaction popup with proper positioning and animations.
class ReactionOverlay extends StatefulWidget {
  final GlobalKey anchorKey;
  final String? currentReaction;
  final ValueChanged<String?> onReactionSelected;
  final VoidCallback onDismiss;

  const ReactionOverlay({
    super.key,
    required this.anchorKey,
    this.currentReaction,
    required this.onReactionSelected,
    required this.onDismiss,
  });

  @override
  State<ReactionOverlay> createState() => _ReactionOverlayState();
}

class _ReactionOverlayState extends State<ReactionOverlay>
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

  void _selectReaction(String? emoji) {
    HapticFeedback.mediumImpact();
    widget.onReactionSelected(emoji);
    _controller.reverse().then((_) {
      widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    const popupSize = Size(280, 56);
    
    final position = OverlayPositioning.calculatePosition(
      context: context,
      anchorKey: widget.anchorKey,
      popupSize: popupSize,
      preferredDirection: PopupDirection.above,
      avoidKeyboard: true,
    );
    
    return Stack(
      children: [
        Positioned(
          left: position.dx,
          top: position.dy,
          width: popupSize.width,
          height: popupSize.height,
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
                    return _ReactionEmojiButton(
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

/// Individual reaction emoji button with animation.
class _ReactionEmojiButton extends StatefulWidget {
  final String emoji;
  final bool isSelected;
  final VoidCallback onTap;

  const _ReactionEmojiButton({
    required this.emoji,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_ReactionEmojiButton> createState() => _ReactionEmojiButtonState();
}

class _ReactionEmojiButtonState extends State<_ReactionEmojiButton>
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
  void didUpdateWidget(_ReactionEmojiButton oldWidget) {
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

/// Emoji picker overlay with keyboard-safe positioning.
class EmojiPickerOverlay extends StatelessWidget {
  final TextEditingController textController;
  final VoidCallback onDismiss;
  final double? bottomOffset;

  const EmojiPickerOverlay({
    super.key,
    required this.textController,
    required this.onDismiss,
    this.bottomOffset,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final keyboardHeight = mediaQuery.viewInsets.bottom;
    final bottomPadding = bottomOffset ?? keyboardHeight + 56; // 56 is typical input bar height
    
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottomPadding,
      child: Material(
        elevation: 8,
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SizedBox(
          height: 250,
          child: EmojiPicker(
            textEditingController: textController,
            config: Config(
              height: 250,
              checkPlatformCompatibility: true,
              emojiViewConfig: EmojiViewConfig(
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                columns: 8,
                emojiSizeMax: 28,
                verticalSpacing: 0,
                horizontalSpacing: 0,
                gridPadding: EdgeInsets.zero,
                recentsLimit: 28,
                replaceEmojiOnLimitExceed: false,
              ),
              skinToneConfig: const SkinToneConfig(),
              categoryViewConfig: CategoryViewConfig(
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                indicatorColor: Theme.of(context).colorScheme.primary,
              ),
              bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
              searchViewConfig: const SearchViewConfig(
                backgroundColor: Colors.transparent,
                buttonIconColor: Colors.grey,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Utility class for showing reaction popup.
class ReactionOverlayUtils {
  static void show({
    required BuildContext context,
    required GlobalKey anchorKey,
    String? currentReaction,
    required ValueChanged<String?> onReactionSelected,
  }) {
    HapticFeedback.mediumImpact();
    
    OverlayCoordinator.instance.show(
      context: context,
      type: OverlayType.reaction,
      builder: (context) => ReactionOverlay(
        anchorKey: anchorKey,
        currentReaction: currentReaction,
        onReactionSelected: onReactionSelected,
        onDismiss: () => OverlayCoordinator.instance.dismiss(),
      ),
      barrierDismissible: true,
    );
  }

  static void dismiss() {
    OverlayCoordinator.instance.dismissIfShowing(OverlayType.reaction);
  }
}

/// Utility class for showing emoji picker.
class EmojiPickerOverlayUtils {
  static void show({
    required BuildContext context,
    required TextEditingController textController,
    double? bottomOffset,
  }) {
    OverlayCoordinator.instance.show(
      context: context,
      type: OverlayType.emoji,
      builder: (context) => EmojiPickerOverlay(
        textController: textController,
        onDismiss: () => OverlayCoordinator.instance.dismiss(),
        bottomOffset: bottomOffset,
      ),
      barrierDismissible: true,
    );
  }

  static void dismiss() {
    OverlayCoordinator.instance.dismissIfShowing(OverlayType.emoji);
  }

  static void toggle({
    required BuildContext context,
    required TextEditingController textController,
    double? bottomOffset,
  }) {
    if (OverlayCoordinator.instance.isShowingEmoji) {
      dismiss();
    } else {
      show(
        context: context,
        textController: textController,
        bottomOffset: bottomOffset,
      );
    }
  }
}
