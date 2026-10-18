import 'dart:convert';

import 'package:ELEODES/features/devices/services/device_auth_service.dart';
import 'package:ELEODES/features/devices/services/device_pairing_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DevicePairingStore store;
  late List<String> tokens;
  late int signedOut;
  Map<String, dynamic> claims() => {
    'awgRole': 'app',
    'awgDeviceId': 'Awg-1',
    'awgAuthVersion': 'v1',
  };
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = DevicePairingStore();
    await store.initialize();
    tokens = [];
    signedOut = 0;
  });
  DeviceAuthService service(
    http.Client client, {
    Uri? endpoint,
    Future<void> Function(String)? signIn,
    Future<Map<String, dynamic>?> Function()? readClaims,
  }) => DeviceAuthService(
    endpoint: endpoint ?? Uri.parse('https://verifier.example/pair'),
    client: client,
    store: store,
    establishSession:
        signIn ??
        (token) async {
          tokens.add(token);
        },
    readClaims: readClaims ?? () async => claims(),
    endSession: () async {
      signedOut++;
    },
  );
  http.Response success() => http.Response(
    jsonEncode({
      'deviceId': 'Awg-1',
      'deviceName': 'Existing AWG',
      'token': 'custom-token',
    }),
    200,
  );

  test(
    'same ID and secret establish a session before local pairing, without persisting either secret or token',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.query, isEmpty);
        expect(request.followRedirects, isFalse);
        expect(jsonDecode(request.body), {
          'deviceId': 'AWG-1',
          'deviceSecret': 'same-secret',
        });
        expect(store.verifiedId, isNull);
        return success();
      });
      await service(client).pair(' Awg-1 ', 'same-secret');
      expect(tokens, ['custom-token']);
      expect(store.verifiedId, 'Awg-1');
      expect(store.verifiedName, 'Existing AWG');
      expect(store.isConfigured, isFalse);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getKeys().map(prefs.get).join();
      expect(saved, isNot(contains('same-secret')));
      expect(saved, isNot(contains('custom-token')));
    },
  );

  test(
    'bad credentials, throttling, redirects and backend failure never authenticate or pair',
    () async {
      for (final status in [401, 429, 302, 503]) {
        final client = MockClient(
          (_) async => http.Response('private backend details', status),
        );
        await expectLater(
          service(client).pair('Awg-1', 'same-secret'),
          throwsA(isA<DevicePairingException>()),
        );
        expect(store.verifiedId, isNull);
        expect(tokens, isEmpty);
      }
    },
  );
  test('insecure URLs are rejected before transmitting credentials', () async {
    for (final url in [
      'http://verifier.example/pair',
      'https://user:secret@verifier.example/pair',
      'https://verifier.example/pair?secret=value',
    ]) {
      final client = MockClient((_) async {
        fail('Must not transmit credentials');
      });
      await expectLater(
        service(client, endpoint: Uri.parse(url)).pair('Awg-1', 'same-secret'),
        throwsA(isA<DevicePairingException>()),
      );
    }
  });
  test(
    'malformed responses and another device identity never authenticate',
    () async {
      for (final body in [
        'invalid',
        jsonEncode({'deviceId': 'Awg-2', 'deviceName': 'Other', 'token': 'x'}),
      ]) {
        await expectLater(
          service(
            MockClient((_) async => http.Response(body, 200)),
          ).pair('Awg-1', 'same-secret'),
          throwsA(isA<DevicePairingException>()),
        );
        expect(tokens, isEmpty);
        expect(store.verifiedId, isNull);
      }
    },
  );
  test(
    'failed token exchange or mismatched claims does not save pairing',
    () async {
      await expectLater(
        service(
          MockClient((_) async => success()),
          signIn: (_) async {
            throw StateError('unavailable');
          },
        ).pair('Awg-1', 'same-secret'),
        throwsA(isA<DevicePairingException>()),
      );
      expect(store.verifiedId, isNull);
      expect(signedOut, 1);
      await expectLater(
        service(
          MockClient((_) async => success()),
          readClaims: () async => {...claims(), 'awgDeviceId': 'Awg-2'},
        ).pair('Awg-1', 'same-secret'),
        throwsA(isA<DevicePairingException>()),
      );
      expect(store.verifiedId, isNull);
      expect(signedOut, 2);
    },
  );
  test(
    'legacy local pairing without a Firebase session must pair again',
    () async {
      await store.verify('Awg-1', 'Existing AWG');
      await service(
        MockClient((_) async => success()),
        readClaims: () async => null,
      ).restoreSession();
      expect(store.verifiedId, isNull);
      expect(signedOut, 1);
    },
  );
  test('matching restored session retains ID and Wi-Fi setup', () async {
    await store.verify('Awg-1', 'Existing AWG');
    await store.complete(id: 'Awg-1', name: 'Existing AWG', ssid: 'Home');
    await service(MockClient((_) async => success())).restoreSession();
    expect(store.deviceId, 'Awg-1');
    expect(store.wifiName, 'Home');
    expect(signedOut, 0);
  });
  test('disconnect clears authentication before forgetting pairing', () async {
    await store.verify('Awg-1', 'Existing AWG');
    store.beforeForget = () async {
      expect(store.verifiedId, 'Awg-1');
      signedOut++;
    };
    await store.forget();
    expect(signedOut, 1);
    expect(store.verifiedId, isNull);
  });
}
