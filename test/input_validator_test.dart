import 'package:flutter_test/flutter_test.dart';
import 'package:crypt_app/utils/input_validator.dart';

void main() {
  group('InputValidator', () {
    group('validateMessage', () {
      test('accepts valid message', () {
        expect(InputValidator.validateMessage('Hello!'), isNull);
      });

      test('rejects null', () {
        expect(InputValidator.validateMessage(null), isNotNull);
      });

      test('rejects empty after trim', () {
        expect(InputValidator.validateMessage('   '), isNotNull);
      });

      test('rejects too long', () {
        final longMsg = 'a' * 5001;
        expect(InputValidator.validateMessage(longMsg), isNotNull);
      });

      test('accepts at max length', () {
        final maxMsg = 'a' * 5000;
        expect(InputValidator.validateMessage(maxMsg), isNull);
      });

      test('accepts unicode message', () {
        expect(InputValidator.validateMessage('🔒 Hello 世界'), isNull);
      });
    });

    group('validateName', () {
      test('accepts valid name', () {
        expect(InputValidator.validateName('John Doe'), isNull);
      });

      test('rejects null', () {
        expect(InputValidator.validateName(null), isNotNull);
      });

      test('rejects empty', () {
        expect(InputValidator.validateName(''), isNotNull);
      });

      test('rejects too short', () {
        expect(InputValidator.validateName('A'), isNotNull);
      });

      test('rejects too long', () {
        final longName = 'A' * 51;
        expect(InputValidator.validateName(longName), isNotNull);
      });

      test('accepts name with hyphen', () {
        expect(InputValidator.validateName('Mary-Jane'), isNull);
      });

      test('accepts name with apostrophe', () {
        expect(InputValidator.validateName("O'Brien"), isNull);
      });

      test('accepts name with numbers', () {
        expect(InputValidator.validateName('User123'), isNull);
      });

      test('rejects special characters', () {
        expect(InputValidator.validateName('test<>'), isNotNull);
      });

      test('rejects emoji in name', () {
        expect(InputValidator.validateName('John🎉'), isNotNull);
      });
    });

    group('validateEmail', () {
      test('accepts valid email', () {
        expect(InputValidator.validateEmail('test@example.com'), isNull);
      });

      test('rejects null', () {
        expect(InputValidator.validateEmail(null), isNotNull);
      });

      test('rejects empty', () {
        expect(InputValidator.validateEmail(''), isNotNull);
      });

      test('rejects missing @', () {
        expect(InputValidator.validateEmail('testexample.com'), isNotNull);
      });

      test('rejects missing domain', () {
        expect(InputValidator.validateEmail('test@'), isNotNull);
      });

      test('rejects missing TLD', () {
        expect(InputValidator.validateEmail('test@example'), isNotNull);
      });

      test('accepts plus addressing', () {
        expect(InputValidator.validateEmail('test+tag@example.com'), isNull);
      });

      test('accepts dots in local part', () {
        expect(InputValidator.validateEmail('first.last@example.com'), isNull);
      });
    });

    group('sanitizeSearchQuery', () {
      test('trims whitespace', () {
        expect(InputValidator.sanitizeSearchQuery('  test  '), 'test');
      });

      test('strips zero-width characters', () {
        final query = 'test\u200B\u200Chidden';
        expect(InputValidator.sanitizeSearchQuery(query), 'testhidden');
      });

      test('truncates long query', () {
        final long = 'a' * 150;
        expect(InputValidator.sanitizeSearchQuery(long).length, 100);
      });

      test('preserves punctuation', () {
        expect(InputValidator.sanitizeSearchQuery("it's"), "it's");
      });
    });

    group('stripInvisible', () {
      test('removes zero-width characters', () {
        final text = 'hello\u200Bworld';
        expect(InputValidator.stripInvisible(text), 'helloworld');
      });

      test('trims whitespace', () {
        expect(InputValidator.stripInvisible('  hello  '), 'hello');
      });
    });
  });
}