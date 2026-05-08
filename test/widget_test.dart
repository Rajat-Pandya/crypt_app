import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crypt_app/main.dart';

void main() {
  group('CryptApp', () {
    testWidgets('renders app with correct theme', (WidgetTester tester) async {
      await tester.pumpWidget(const CryptApp());
      await tester.pumpAndSettle();

      expect(find.byType(MaterialApp), findsOneWidget);
    });

    testWidgets('has correct debug banner disabled', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const CryptApp());
      await tester.pumpAndSettle();

      final MaterialApp app = tester.widget(find.byType(MaterialApp));
      expect(app.debugShowCheckedModeBanner, isFalse);
    });

    testWidgets('supports both light and dark themes', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const CryptApp());
      await tester.pumpAndSettle();

      final MaterialApp app = tester.widget(find.byType(MaterialApp));
      expect(app.theme, isNotNull);
      expect(app.darkTheme, isNotNull);
    });
  });

  group('AppColors', () {
    test('light theme colors are defined', () {
      const lightColors = AppColors(
        screenBg: Color(0xFFF7F7F7),
        appBarBg: Color(0xFFF5F5F5),
        cardBg: Color(0xFFFFFFFF),
        inputBg: Color(0xFFEDEDED),
        primaryText: Color(0xFF111827),
        secondaryText: Color(0xFF6B7280),
        hintText: Color(0xFF9CA3AF),
        myBubble: Color(0xFFEFF6FF),
        theirBubble: Color(0xFFFFFFFF),
        myBubbleText: Color(0xFF1E40AF),
        theirBubbleText: Color(0xFF111827),
        borderColor: Color(0xFFE5E7EB),
        accent: Color(0xFF3B82F6),
        onlineGreen: Color(0xFF22C55E),
        divider: Color(0xFFE5E7EB),
      );

      expect(lightColors.screenBg, equals(const Color(0xFFF7F7F7)));
      expect(lightColors.accent, equals(const Color(0xFF3B82F6)));
    });

    test('dark theme colors are defined', () {
      const darkColors = AppColors(
        screenBg: Color(0xFF0F172A),
        appBarBg: Color(0xFF1E293B),
        cardBg: Color(0xFF1E293B),
        inputBg: Color(0xFF334155),
        primaryText: Color(0xFFF1F5F9),
        secondaryText: Color(0xFF94A3B8),
        hintText: Color(0xFF64748B),
        myBubble: Color(0xFF1D3461),
        theirBubble: Color(0xFF1E293B),
        myBubbleText: Color(0xFFBFDBFE),
        theirBubbleText: Color(0xFFF1F5F9),
        borderColor: Color(0xFF334155),
        accent: Color(0xFF3B82F6),
        onlineGreen: Color(0xFF22C55E),
        divider: Color(0xFF334155),
      );

      expect(darkColors.screenBg, equals(const Color(0xFF0F172A)));
      expect(darkColors.accent, equals(const Color(0xFF3B82F6)));
    });

    test('copyWith creates modified copy', () {
      const colors = AppColors(
        screenBg: Color(0xFFF7F7F7),
        appBarBg: Color(0xFFF5F5F5),
        cardBg: Color(0xFFFFFFFF),
        inputBg: Color(0xFFEDEDED),
        primaryText: Color(0xFF111827),
        secondaryText: Color(0xFF6B7280),
        hintText: Color(0xFF9CA3AF),
        myBubble: Color(0xFFEFF6FF),
        theirBubble: Color(0xFFFFFFFF),
        myBubbleText: Color(0xFF1E40AF),
        theirBubbleText: Color(0xFF111827),
        borderColor: Color(0xFFE5E7EB),
        accent: Color(0xFF3B82F6),
        onlineGreen: Color(0xFF22C55E),
        divider: Color(0xFFE5E7EB),
      );

      final modified = colors.copyWith(accent: const Color(0xFFFF0000));
      expect(modified.accent, equals(const Color(0xFFFF0000)));
      expect(modified.screenBg, equals(colors.screenBg));
    });

    test('lerp creates interpolated colors', () {
      const from = AppColors(
        screenBg: Color(0xFF000000),
        appBarBg: Color(0xFF000000),
        cardBg: Color(0xFF000000),
        inputBg: Color(0xFF000000),
        primaryText: Color(0xFF000000),
        secondaryText: Color(0xFF000000),
        hintText: Color(0xFF000000),
        myBubble: Color(0xFF000000),
        theirBubble: Color(0xFF000000),
        myBubbleText: Color(0xFF000000),
        theirBubbleText: Color(0xFF000000),
        borderColor: Color(0xFF000000),
        accent: Color(0xFF000000),
        onlineGreen: Color(0xFF000000),
        divider: Color(0xFF000000),
      );
      const to = AppColors(
        screenBg: Color(0xFFFFFFFF),
        appBarBg: Color(0xFFFFFFFF),
        cardBg: Color(0xFFFFFFFF),
        inputBg: Color(0xFFFFFFFF),
        primaryText: Color(0xFFFFFFFF),
        secondaryText: Color(0xFFFFFFFF),
        hintText: Color(0xFFFFFFFF),
        myBubble: Color(0xFFFFFFFF),
        theirBubble: Color(0xFFFFFFFF),
        myBubbleText: Color(0xFFFFFFFF),
        theirBubbleText: Color(0xFFFFFFFF),
        borderColor: Color(0xFFFFFFFF),
        accent: Color(0xFFFFFFFF),
        onlineGreen: Color(0xFFFFFFFF),
        divider: Color(0xFFFFFFFF),
      );

      final result = from.lerp(to, 0.5);
      expect(result.screenBg.r, closeTo(0.5, 0.01));
      expect(result.screenBg.g, closeTo(0.5, 0.01));
      expect(result.screenBg.b, closeTo(0.5, 0.01));
    });
  });
}
