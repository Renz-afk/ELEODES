import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;
import 'device_pairing_store.dart';

class DevicePairingException implements Exception {
  const DevicePairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Exchanges the existing QR credentials for a Firebase session. Neither the
/// secret nor the custom token is written to preferences or application logs.
class DeviceAuthService {
  DeviceAuthService({
    this.endpoint,
    this.client,
    DevicePairingStore? store,
    Future<void> Function(String)? establishSession,
    Future<Map<String, dynamic>?> Function()? readClaims,
    Future<void> Function()? endSession,
  }) : _store = store ?? DevicePairingStore.instance,
       _establishSession = establishSession ?? _firebaseSignIn,
       _readClaims = readClaims ?? _firebaseClaims,
       _endSession = endSession ?? _firebaseSignOut;

  static final instance = DeviceAuthService();
  final Uri? endpoint;
  final http.Client? client;
  final DevicePairingStore _store;
  final Future<void> Function(String) _establishSession;
  final Future<Map<String, dynamic>?> Function() _readClaims;
  final Future<void> Function() _endSession;

  static Future<void> _firebaseSignIn(String token) async {
    await FirebaseAuth.instance.signInWithCustomToken(token);
  }

  static Future<Map<String, dynamic>?> _firebaseClaims() async =>
      (await FirebaseAuth.instance.currentUser?.getIdTokenResult())?.claims;
  static Future<void> _firebaseSignOut() => FirebaseAuth.instance.signOut();

  Uri _endpoint() {
    if (endpoint != null) return endpoint!;
    const override = String.fromEnvironment('DEVICE_PAIRING_URL');
    return Uri.parse(
      override.isNotEmpty
          ? override
          : 'https://asia-southeast1-${Firebase.app().options.projectId}.cloudfunctions.net/pairAwgDevice',
    );
  }

  Future<void> restoreSession() async {
    await _store.initialize();
    if (_store.verifiedId == null) return;
    final claims = await _readClaims();
    if (!_matches(claims, _store.verifiedId!)) {
      await _endSession();
      await _store.forget();
    }
  }

  static bool _matches(Map<String, dynamic>? claims, String id) =>
      claims?['awgRole'] == 'app' &&
      claims?['awgDeviceId'] is String &&
      (claims!['awgDeviceId'] as String).trim().toUpperCase() ==
          id.trim().toUpperCase() &&
      claims['awgAuthVersion'] is String &&
      (claims['awgAuthVersion'] as String).isNotEmpty;

  Future<void> signOut() => _endSession();

  Future<void> pair(String rawId, String rawSecret) async {
    final id = rawId.trim().toUpperCase();
    final secret = rawSecret.trim();
    if (id.isEmpty ||
        id.length > 128 ||
        secret.isEmpty ||
        secret.length > 512) {
      throw const DevicePairingException(
        'Enter a valid Device ID and Device Secret.',
      );
    }
    final url = _endpoint();
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment) {
      throw const DevicePairingException(
        'Device verification is not configured securely.',
      );
    }
    final connection = client ?? http.Client();
    http.Response response;
    try {
      // Do not forward device credentials through HTTP redirects.
      final request = http.Request('POST', url)
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({'deviceId': id, 'deviceSecret': secret});
      response = await connection
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const DevicePairingException(
        'Could not reach device verification. Check your connection and retry.',
      );
    } finally {
      if (client == null) connection.close();
    }
    if (response.statusCode == 401) {
      throw const DevicePairingException('Invalid Device ID or Device Secret.');
    }
    if (response.statusCode == 429) {
      throw const DevicePairingException(
        'Too many pairing attempts. Please try again later.',
      );
    }
    if (response.statusCode != 200) {
      throw const DevicePairingException(
        'Device verification is unavailable. Please retry later.',
      );
    }
    String token;
    String name;
    String deviceId;
    try {
      final data = jsonDecode(response.body);
      if (data is! Map ||
          data['deviceId'] is! String ||
          (data['deviceId'] as String).trim().toUpperCase() != id ||
          data['deviceName'] is! String ||
          (data['deviceName'] as String).isEmpty ||
          data['token'] is! String ||
          (data['token'] as String).isEmpty) {
        throw const FormatException();
      }
      token = data['token'] as String;
      name = data['deviceName'] as String;
      deviceId = data['deviceId'] as String;
    } catch (_) {
      throw const DevicePairingException(
        'Invalid device verification response. Please retry later.',
      );
    }
    try {
      await _establishSession(token);
      if (!_matches(await _readClaims(), id)) {
        throw const DevicePairingException(
          'The device session could not be verified.',
        );
      }
      await _store.verify(deviceId, name);
    } catch (_) {
      // A partial exchange must not leave an authenticated but unpaired client.
      await _endSession();
      throw const DevicePairingException(
        'Could not establish secure device access. Please retry.',
      );
    }
  }
}
