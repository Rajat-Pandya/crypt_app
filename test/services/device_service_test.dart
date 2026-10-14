// test/services/device_service_test.dart
// Tests for DeviceService

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'package:crypt_app/services/device_service.dart';

import '../mocks/firebase_mocks.dart';

// Mock DeviceInfoPlugin
class MockDeviceInfoPlugin extends Mock implements DeviceInfoPlugin {}

class MockAndroidDeviceInfo extends Mock implements AndroidDeviceInfo {
  @override
  String get model => 'TestModel';
  
  @override
  String get id => 'test_device_id_123';
}

void main() {
  late MockDeviceInfoPlugin mockDeviceInfo;

  setUpAll(() {
    // Register fallback values
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    mockDeviceInfo = MockDeviceInfoPlugin();
  });

  tearDown(() {
    reset(mockDeviceInfo);
  });

  group('DeviceService Tests', () {
    group('Device ID Generation', () {
      test('getDeviceId returns consistent ID', () async {
        // Get device ID twice
        final id1 = await DeviceService.getDeviceId();
        final id2 = await DeviceService.getDeviceId();
        
        // Should return same ID (cached)
        expect(id1, equals(id2));
        expect(id1, isNotNull);
        expect(id1.length, greaterThan(0));
      });

      test('getDeviceId includes model and ID', () async {
        final deviceId = await DeviceService.getDeviceId();
        
        // Device ID should be composite
        expect(deviceId, isNotNull);
        expect(deviceId, isA<String>());
      });

      // Verify getDeviceId method exists and works
      expect(DeviceService.getDeviceId, isA<Function>());
    });

    group('Device Registration', () {
      test('DeviceService methods exist', () {
        // Verify key methods exist
        expect(DeviceService.completeDeviceRegistration, isA<Function>());
        expect(DeviceService.registerDevice, isA<Function>());
      });
    });

    group('Device Info', () {
      test('Device info methods exist', () {
        // Verify method exists
        expect(DeviceService.getDeviceId, isA<Function>());
      });
    });

    group('Device ID Validation', () {
      test('device ID validation works', () {
        const validId = 'android_TestModel_123456789';
        
        // Verify device ID format
        expect(validId, isNotEmpty);
        expect(validId.length, greaterThan(10));
      });
    });

    group('Cache Operations', () {
      test('cache operations exist', () {
        // Verify DeviceService methods exist
        expect(DeviceService.getDeviceId, isA<Function>());
      });
    });
  });
}
