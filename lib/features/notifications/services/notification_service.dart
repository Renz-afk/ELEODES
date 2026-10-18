import 'notification_preferences.dart';
import 'notification_time.dart';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ELEODES/core/settings/app_settings.dart';

class NotificationService {
  // ============================================================
  // ANDROID NOTIFICATION CHANNEL
  // ============================================================

  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static bool _isInitialized = false;

  // ============================================================
  // FIREBASE NOTIFICATION REFERENCE
  // ============================================================

  late final DatabaseReference _notificationRef = FirebaseDatabase.instance.ref(
    "AWG/live/notification",
  );

  // ============================================================
  // COOLDOWN
  // ============================================================

  final Map<String, DateTime> _lastNotification = {};

  static const Duration disconnectCooldown = Duration(seconds: 30);

  static const Duration reminderCooldown = Duration(minutes: 10);

  static const Duration environmentCooldown = Duration(minutes: 3);

  // ============================================================
  // INITIALIZE
  // ============================================================

  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings),
    );

    final android = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    // Android 13+
    await android?.requestNotificationsPermission();

    _isInitialized = true;
  }

  // ============================================================
  // LOAD USER NOTIFICATION SETTINGS
  // ============================================================

  Future<bool> _notificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getBool("notification") ?? true;
  }

  Future<bool> _soundEnabled() async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getBool("sound") ?? true;
  }

  Future<bool> _vibrationEnabled() async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getBool("vibration") ?? false;
  }

  // ============================================================
  // NOTIFICATION STREAM
  // ============================================================

  Stream<List<Map<String, dynamic>>> get notificationStream {
    return _notificationRef.onValue.map((event) {
      final dynamic data = event.snapshot.value;

      if (data == null) {
        return [];
      }

      if (data is! Map) {
        return [];
      }

      final Map<dynamic, dynamic> map = Map<dynamic, dynamic>.from(data);

      final List<Map<String, dynamic>> notifications = [];

      map.forEach((key, value) {
        if (value is! Map) {
          return;
        }

        final Map<dynamic, dynamic> item = Map<dynamic, dynamic>.from(value);

        notifications.add({
          "id": key.toString(),

          "title": item["title"] ?? "",

          "message": item["message"] ?? "",

          "type": item["type"] ?? "info",

          "time": parseNotificationTime(item["time"])?.toIso8601String() ?? '',

          "read": item["read"] ?? false,
        });
      });

      // ------------------------------------------------------
      // NEWEST FIRST
      // ------------------------------------------------------

      notifications.sort(compareNotificationTimes);

      return notifications;
    });
  }

  // ============================================================
  // CHECK COOLDOWN
  // ============================================================

  bool _canSend(String key, Duration cooldown) {
    final DateTime? last = _lastNotification[key];

    if (last == null) {
      return true;
    }

    return DateTime.now().difference(last) >= cooldown;
  }

  void _updateTime(String key) {
    _lastNotification[key] = DateTime.now();
  }

  // ============================================================
  // ADD FIREBASE NOTIFICATION
  // ============================================================

  Future<void> addNotification({
    required String title,
    required String message,
    required String type,
    bool systemAlert = false,
  }) async {
    await AppSettings.instance.initialize();
    if (systemAlert && !AppSettings.instance.sensorAlertsEnabled) return;
    // ----------------------------------------------------------
    // Check if notifications are enabled.
    // ----------------------------------------------------------

    final bool enabled = await _notificationsEnabled();

    if (!enabled) {
      return;
    }

    // ----------------------------------------------------------
    // Prevent duplicate unread notifications.
    // ----------------------------------------------------------

    final DataSnapshot snapshot = await _notificationRef.get();

    if (snapshot.exists && snapshot.value is Map) {
      final Map<dynamic, dynamic> data = Map<dynamic, dynamic>.from(
        snapshot.value as Map,
      );

      for (final dynamic item in data.values) {
        if (item is! Map) {
          continue;
        }

        final Map<dynamic, dynamic> notification = Map<dynamic, dynamic>.from(
          item,
        );

        if (notification["title"] == title &&
            notification["message"] == message &&
            notification["read"] == false) {
          return;
        }
      }
    }

    // ----------------------------------------------------------
    // Save notification to Firebase.
    // ----------------------------------------------------------

    if (systemAlert && !AppSettings.instance.sensorAlertsEnabled) return;
    await _notificationRef.push().set({
      "title": title,
      "message": message,
      "type": type,
      "time": ServerValue.timestamp,
      "read": false,
    });

    // ----------------------------------------------------------
    // Show phone notification.
    // ----------------------------------------------------------

    await _showPhoneNotification(
      title: title,
      message: message,
      systemAlert: systemAlert,
    );
  }

  // ============================================================
  // SHOW PHONE NOTIFICATION
  // ============================================================

  Future<bool> _showPhoneNotification({
    required String title,
    required String message,
    bool systemAlert = false,
  }) async {
    await AppSettings.instance.initialize();
    if (systemAlert && !AppSettings.instance.sensorAlertsEnabled) return false;
    if (!await _notificationsEnabled()) return false;

    await initialize();
    final android = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (await android?.areNotificationsEnabled() == false) {
      throw StateError(
        'Allow ELEODES notifications in your phone settings, then retry.',
      );
    }

    final preferences = NotificationPreferences(
      sound: await _soundEnabled(),
      vibration: await _vibrationEnabled(),
    );
    // Recheck after asynchronous setup in case notifications were switched off.
    if (!await _notificationsEnabled()) return false;
    if (systemAlert && !AppSettings.instance.sensorAlertsEnabled) return false;
    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      title,
      message,
      NotificationDetails(android: preferences.androidDetails),
    );
    return true;
  }
  // ============================================================
  // ESP32 DISCONNECTED
  // ============================================================

  Future<void> sendDisconnectNotification() async {
    if (!_canSend("disconnect", disconnectCooldown)) {
      return;
    }

    _updateTime("disconnect");

    await addNotification(
      title: "AWG device disconnected",

      message:
          "No recent updates from your AWG device. Connect it to Wi-Fi and check its power to resume live readings.",

      type: "danger",
    );
  }

  // ============================================================
  // REMINDER / STATUS
  // ============================================================

  Future<void> sendReminder({
    required String title,
    required String message,
  }) async {
    final String key = "reminder_$title";

    if (!_canSend(key, reminderCooldown)) {
      return;
    }

    _updateTime(key);

    await addNotification(title: title, message: message, type: "maintenance");
  }

  // ============================================================
  // ENVIRONMENTAL ALERT
  // ============================================================

  Future<void> sendEnvironmentAlert({
    required String title,
    required String message,
    String type = "warning",
  }) async {
    await AppSettings.instance.initialize();
    if (!AppSettings.instance.sensorAlertsEnabled) return;
    if (!_canSend(title, environmentCooldown)) {
      return;
    }

    _updateTime(title);

    await addNotification(
      title: title,

      message: message,

      type: type,
      systemAlert: true,
    );
  }

  // ============================================================
  // MARK AS READ
  // ============================================================

  Future<void> markAsRead(String id) async {
    if (id.trim().isEmpty) {
      return;
    }

    await _notificationRef.child(id).update({"read": true});
  }

  // ============================================================
  // MARK ALL AS READ
  // ============================================================

  Future<void> markAllAsRead() async {
    final DataSnapshot snapshot = await _notificationRef.get();

    if (!snapshot.exists || snapshot.value is! Map) {
      return;
    }

    final Map<dynamic, dynamic> data = Map<dynamic, dynamic>.from(
      snapshot.value as Map,
    );

    for (final dynamic key in data.keys) {
      await _notificationRef.child(key.toString()).update({"read": true});
    }
  }

  // ============================================================
  // UNREAD COUNT
  // ============================================================

  // The badge only needs a count; avoid parsing and sorting the full feed.
  late final Stream<int> unreadCount = _notificationRef.onValue.map((event) {
    final data = event.snapshot.value;
    if (data is! Map) return 0;
    return data.values
        .where((item) => item is Map && item['read'] != true)
        .length;
  }).distinct();
  // ============================================================
  // DELETE ONE
  // ============================================================

  Future<void> deleteNotification(String id) async {
    if (id.trim().isEmpty) {
      return;
    }

    await _notificationRef.child(id).remove();
  }

  Future<void> deleteNotifications(Iterable<String> ids) async {
    final updates = <String, dynamic>{
      for (final id in ids)
        if (id.trim().isNotEmpty) id: null,
    };
    if (updates.isEmpty) return;
    await _notificationRef.update(updates);
  }

  // ============================================================
  // CLEAR ALL
  // ============================================================

  Future<void> clearNotifications() async {
    await _notificationRef.remove();
  }
}
