import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';

/// WhatsApp-style animated message action bar.
///
/// Appears at the top of the chat when messages are selected.
/// Provides contextual actions based on selection count and type.
class MessageActionBar extends StatefulWidget implements PreferredSizeWidget {
  final int selectionCount;
  final bool hasSingleSelection;
  final bool hasMultipleSelection;
  final bool canReply;
  final bool canCopy;
  final bool canForward;
  final bool canDelete;
  final bool canStar;
  final bool areAllStarred;
  final VoidCallback onClose;
  final VoidCallback onReply;
  final VoidCallback onCopy;
  final VoidCallback onForward;
  final VoidCallback onDelete;
  final VoidCallback onStar;
  final VoidCallback? onInfo;

  const MessageActionBar({
    super.key,
    required this.selectionCount,
    required this.hasSingleSelection,
    required this.hasMultipleSelection,
    required this.canReply,
    required this.canCopy,
    required this.canForward,
    required this.canDelete,
    required this.canStar,
    required this.areAllStarred,
    required this.onClose,
    required this.onReply,
    required this.onCopy,
    required this.onForward,
    required this.onDelete,
    required this.onStar,
    this.onInfo,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<MessageActionBar> createState() => _MessageActionBarState();
}

class _MessageActionBarState extends State<MessageActionBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));

    _controller.forward();
  }

  @override
  void didUpdateWidget(MessageActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If selection count changed, animate
    if (oldWidget.selectionCount != widget.selectionCount) {
      // Quick pulse animation on count change
      _controller.forward(from: 0.8);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss(VoidCallback action) async {
    await _controller.reverse();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: Container(
          height: kToolbarHeight,
          decoration: BoxDecoration(
            color: colors.appBarBg,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SafeArea(
            child: Row(
              children: [
                // Close button
                _buildCloseButton(colors),
                
                // Selection count
                _buildSelectionCount(colors),
                
                const Spacer(),
                
                // Action buttons
                if (widget.canReply) _buildActionButton(
                  icon: Icons.reply,
                  label: 'Reply',
                  onTap: () => _dismiss(widget.onReply),
                  colors: colors,
                ),
                
                if (widget.canCopy) _buildActionButton(
                  icon: Icons.copy,
                  label: 'Copy',
                  onTap: () => _dismiss(widget.onCopy),
                  colors: colors,
                ),
                
                if (widget.canForward) _buildActionButton(
                  icon: Icons.forward,
                  label: 'Forward',
                  onTap: () => _dismiss(widget.onForward),
                  colors: colors,
                ),
                
                _buildActionButton(
                  icon: widget.areAllStarred ? Icons.star : Icons.star_border,
                  label: widget.areAllStarred ? 'Unstar' : 'Star',
                  onTap: () => _dismiss(widget.onStar),
                  colors: colors,
                  isActive: widget.areAllStarred,
                ),
                
                if (widget.onInfo != null && widget.hasSingleSelection)
                  _buildActionButton(
                    icon: Icons.info_outline,
                    label: 'Info',
                    onTap: () => _dismiss(widget.onInfo!),
                    colors: colors,
                  ),
                
                // Delete button (always last, in red)
                if (widget.canDelete) ...[
                  const SizedBox(width: 8),
                  _buildDeleteButton(colors),
                ],
                
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCloseButton(AppColors colors) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _dismiss(widget.onClose),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(
            Icons.close,
            color: colors.primaryText,
            size: 24,
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionCount(AppColors colors) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.8, end: 1.0).animate(animation),
            child: child,
          ),
        );
      },
      child: Text(
        '${widget.selectionCount}',
        key: ValueKey<int>(widget.selectionCount),
        style: TextStyle(
          color: colors.primaryText,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required AppColors colors,
    bool isActive = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Icon(
              icon,
              color: isActive ? colors.accent : colors.primaryText,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeleteButton(AppColors colors) {
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: 'Delete',
        child: InkWell(
          onTap: () => _dismiss(widget.onDelete),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.delete_outline,
                  color: Colors.red,
                  size: 22,
                ),
                if (widget.hasMultipleSelection) ...[
                  const SizedBox(width: 4),
                  Text(
                    '${widget.selectionCount}',
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Animated wrapper that shows/hides the action bar based on selection state
class AnimatedMessageActionBar extends StatelessWidget {
  final bool isVisible;
  final int selectionCount;
  final bool hasSingleSelection;
  final bool hasMultipleSelection;
  final bool canReply;
  final bool canCopy;
  final bool canForward;
  final bool canDelete;
  final bool canStar;
  final bool areAllStarred;
  final VoidCallback onClose;
  final VoidCallback onReply;
  final VoidCallback onCopy;
  final VoidCallback onForward;
  final VoidCallback onDelete;
  final VoidCallback onStar;
  final VoidCallback? onInfo;

  const AnimatedMessageActionBar({
    super.key,
    required this.isVisible,
    required this.selectionCount,
    required this.hasSingleSelection,
    required this.hasMultipleSelection,
    required this.canReply,
    required this.canCopy,
    required this.canForward,
    required this.canDelete,
    required this.canStar,
    required this.areAllStarred,
    required this.onClose,
    required this.onReply,
    required this.onCopy,
    required this.onForward,
    required this.onDelete,
    required this.onStar,
    this.onInfo,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      reverseDuration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axisAlignment: -1.0,
            child: child,
          ),
        );
      },
      child: isVisible
          ? MessageActionBar(
              key: const ValueKey('action_bar'),
              selectionCount: selectionCount,
              hasSingleSelection: hasSingleSelection,
              hasMultipleSelection: hasMultipleSelection,
              canReply: canReply,
              canCopy: canCopy,
              canForward: canForward,
              canDelete: canDelete,
              canStar: canStar,
              areAllStarred: areAllStarred,
              onClose: onClose,
              onReply: onReply,
              onCopy: onCopy,
              onForward: onForward,
              onDelete: onDelete,
              onStar: onStar,
              onInfo: onInfo,
            )
          : const SizedBox.shrink(
              key: ValueKey('empty'),
            ),
    );
  }
}

/// Bottom action bar for message actions (alternative to top bar)
/// Use this for a bottom sheet style action bar
class MessageBottomActionBar extends StatelessWidget {
  final int selectionCount;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onStar;
  final bool isStarred;
  final bool canCopy;

  const MessageBottomActionBar({
    super.key,
    required this.selectionCount,
    required this.onReply,
    required this.onForward,
    required this.onCopy,
    required this.onDelete,
    required this.onStar,
    required this.isStarred,
    required this.canCopy,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.cardBg,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildBottomAction(
                icon: Icons.reply,
                label: 'Reply',
                onTap: onReply,
                colors: colors,
              ),
              _buildBottomAction(
                icon: Icons.forward,
                label: 'Forward',
                onTap: onForward,
                colors: colors,
              ),
              if (canCopy)
                _buildBottomAction(
                  icon: Icons.copy,
                  label: 'Copy',
                  onTap: onCopy,
                  colors: colors,
                ),
              _buildBottomAction(
                icon: isStarred ? Icons.star : Icons.star_border,
                label: isStarred ? 'Unstar' : 'Star',
                onTap: onStar,
                colors: colors,
                isActive: isStarred,
              ),
              _buildBottomAction(
                icon: Icons.delete_outline,
                label: 'Delete',
                onTap: onDelete,
                colors: colors,
                isDestructive: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required AppColors colors,
    bool isActive = false,
    bool isDestructive = false,
  }) {
    final color = isDestructive
        ? Colors.red
        : isActive
            ? colors.accent
            : colors.primaryText;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
