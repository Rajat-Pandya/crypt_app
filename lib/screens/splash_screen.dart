// lib/screens/splash_screen.dart
// Dedicated splash screen widget with fade animation
// Extracted from main.dart for better maintainability

import 'package:flutter/material.dart';
import '../services/startup_task_scheduler.dart';

/// A splash screen widget with fade animation that transitions to the main app.
/// 
/// Features:
/// - Displays for minimum 800ms
/// - Fade out animation (500ms)
/// - Triggers startup tasks after first frame
/// - Shows app logo, name, and loading indicator
/// 
/// Usage:
/// ```dart
/// SplashScreen(
///   child: MyHomePage(),
///   minDisplayDuration: Duration(milliseconds: 800),
///   fadeDuration: Duration(milliseconds: 500),
/// )
/// ```
class SplashScreen extends StatefulWidget {
  /// The widget to navigate to after splash screen
  final Widget child;
  
  /// Minimum time to display splash (default: 800ms)
  final Duration minDisplayDuration;
  
  /// Duration of fade out animation (default: 500ms)
  final Duration fadeDuration;
  
  /// Background color (default: Crypt blue #3B82F6)
  final Color backgroundColor;
  
  /// Logo icon (default: Icons.lock_outline)
  final IconData logoIcon;
  
  /// App name text (default: 'Crypt')
  final String appName;
  
  /// Logo size (default: 80)
  final double logoSize;
  
  /// App name font size (default: 32)
  final double appNameSize;
  
  /// Text color (default: white)
  final Color textColor;
  
  /// Loading indicator color (default: white)
  final Color indicatorColor;

  const SplashScreen({
    super.key,
    required this.child,
    this.minDisplayDuration = const Duration(milliseconds: 800),
    this.fadeDuration = const Duration(milliseconds: 500),
    this.backgroundColor = const Color(0xFF3B82F6),
    this.logoIcon = Icons.lock_outline,
    this.appName = 'Crypt',
    this.logoSize = 80,
    this.appNameSize = 32,
    this.textColor = Colors.white,
    this.indicatorColor = Colors.white,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: widget.fadeDuration,
    );

    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
      ),
    );

    // Show splash for minimum duration, then fade out
    Future.delayed(widget.minDisplayDuration, () {
      if (mounted) {
        // Trigger startup task scheduler after first frame renders
        WidgetsBinding.instance.addPostFrameCallback((_) {
          StartupTaskScheduler.onFirstFrameRendered();
        });

        _controller.forward().then((_) {
          // After fade animation, replace with actual app
          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) => widget.child,
              transitionDuration: Duration.zero,
            ),
          );
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: widget.backgroundColor,
        body: FadeTransition(
          opacity: _fadeAnimation,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.logoIcon,
                  size: widget.logoSize,
                  color: widget.textColor,
                ),
                const SizedBox(height: 24),
                Text(
                  widget.appName,
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: widget.appNameSize,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    color: widget.indicatorColor,
                    strokeWidth: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
