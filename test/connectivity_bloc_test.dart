import 'package:flutter_test/flutter_test.dart';

import 'package:crypt_app/blocs/connectivity_bloc.dart';

void main() {
  group('ConnectivityBloc', () {
    late ConnectivityBloc connectivityBloc;

    setUp(() {
      connectivityBloc = ConnectivityBloc();
    });

    tearDown(() {
      connectivityBloc.close();
    });

    test('initial state is correct', () {
      expect(connectivityBloc.state.isOnline, isTrue);
      expect(connectivityBloc.state.isReconnecting, isFalse);
      expect(connectivityBloc.state.isInitialized, isFalse);
      expect(connectivityBloc.state.messagesSynced, equals(0));
      expect(connectivityBloc.state.queueMessageCount, equals(0));
    });

    test('ConnectivityInitialized sets isInitialized', () async {
      connectivityBloc.add(const ConnectivityInitialized());
      await Future.delayed(Duration.zero);
      expect(connectivityBloc.state.isInitialized, isTrue);
    });

    test('ConnectivityChanged updates isOnline', () async {
      connectivityBloc.add(const ConnectivityChanged(false));
      await Future.delayed(Duration.zero);
      expect(connectivityBloc.state.isOnline, isFalse);
    });

    test('state copyWith creates modified copy', () {
      final original = connectivityBloc.state;
      final modified = original.copyWith(
        isOnline: false,
        messagesSynced: 10,
      );
      expect(modified.isOnline, isFalse);
      expect(modified.messagesSynced, equals(10));
    });
  });
}
