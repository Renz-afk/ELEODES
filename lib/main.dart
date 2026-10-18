import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'package:ELEODES/app/app.dart';
import 'package:ELEODES/core/settings/app_settings.dart';
import 'package:ELEODES/features/devices/services/device_pairing_store.dart';
import 'package:ELEODES/features/devices/services/device_auth_service.dart';
import 'package:ELEODES/features/notifications/services/notification_service.dart';
import 'package:ELEODES/firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DevicePairingStore.instance.initialize();
  await AppSettings.instance.initialize();

  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  DevicePairingStore.instance.beforeForget = DeviceAuthService.instance.signOut;
  await NotificationService().initialize();
  runApp(const AWGApp());
}
