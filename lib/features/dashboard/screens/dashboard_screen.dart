import 'package:ELEODES/core/theme/app_theme.dart';
import 'package:ELEODES/shared/widgets/tab_header.dart';
import 'package:ELEODES/features/dashboard/widgets/animated_water_tank.dart';
import 'package:ELEODES/features/production/widgets/production_history_section.dart';
import 'package:ELEODES/features/production/widgets/production_comparison.dart';
import 'package:ELEODES/features/devices/screens/wifi_connection_screen.dart';
import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'package:ELEODES/features/notifications/services/notification_service.dart';
import 'package:ELEODES/features/dashboard/models/sensor_data.dart';
import 'package:ELEODES/features/devices/services/device_pairing_store.dart';
import 'package:ELEODES/core/settings/app_settings.dart';
import 'package:ELEODES/features/notifications/services/sensor_alert_evaluator.dart';
import 'package:ELEODES/features/dashboard/widgets/dashboard_topbar.dart';

class DashboardScreen extends StatefulWidget {
  final VoidCallback? onProceedToDevice;

  const DashboardScreen({super.key, this.onProceedToDevice});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  // ============================================================
  // FIREBASE
  // ============================================================

  final DatabaseReference _awgRef = FirebaseDatabase.instance.ref('AWG');

  final DatabaseReference _controlRef = FirebaseDatabase.instance.ref(
    'AWG/control',
  );

  StreamSubscription<DatabaseEvent>? _awgSubscription;
  StreamSubscription<DatabaseEvent>? _firebaseConnectionSubscription;
  bool _firebaseConnected = false;
  String? _listeningDeviceId;

  Timer? _connectionTimer;
  Timer? _uptimeTimer;

  // ============================================================
  // SERVICES
  // ============================================================

  final NotificationService _notificationService = NotificationService();

  // ============================================================
  // CONNECTION
  // ============================================================

  static const int _offlineTimeoutSeconds = 30;

  int? _lastSeenTimestamp;
  int? _lastReadingTimestamp;

  bool _hasReceivedFirebaseData = false;
  bool _machineConnected = false;

  // ============================================================
  // MACHINE
  // ============================================================

  bool _machineRunning = false;

  // ============================================================
  // UPTIME
  // ============================================================

  Duration _machineUptime = Duration.zero;
  final ValueNotifier<String> _uptimeText = ValueNotifier('00:00:00');

  DateTime? _uptimeStartTime;
  int? _uptimeStartTimestamp;

  String _firebaseUptime = '00:00:00';

  // ============================================================
  // SENSOR DATA
  // ============================================================

  SensorData? _sensorData;

  bool _hasPh = false;

  double _waterLevel = 0.0;
  double? _flowRate;
  bool _disconnectNotified = false;
  String _waterLevelLabel = 'EMPTY';

  // ============================================================
  // PRODUCTION
  // ============================================================

  List<double> _productionValues = List<double>.filled(7, 0.0);
  Map<String, double> _datedProduction = {};
  Map<String, double> _waterUsage = {};
  Map<String, DailyWeather> _weatherHistory = {};

  // ============================================================
  // NOTIFICATION FLAGS
  // ============================================================

  final SensorAlertEvaluator _alertEvaluator = SensorAlertEvaluator();
  double? _alertTemperature;
  double? _alertHumidity;
  double? _alertWaterLevel;
  double? _alertPh;
  bool _alertTankFull = false;

  // ============================================================
  // COLORS
  // ============================================================

  Color get _dashboardBackground =>
      AppTheme.background(context, const Color(0xFFD4FFED));

  Color get _cardBackground =>
      AppTheme.surface(context, const Color(0x40BBBBBB));

  static const Color _primaryGreen = Color(0xFF1DE3AB);

  Color get _darkText => AppTheme.text(context, const Color(0xFF090909));

  static const Color _stopRed = Color(0xBFFF6262);

  // ============================================================
  // LIFECYCLE
  // ============================================================

  @override
  void initState() {
    super.initState();

    AppSettings.instance.addListener(_checkAlerts);
    DevicePairingStore.instance.addListener(_restoreDeviceConnection);
    _restoreDeviceConnection();
    _firebaseConnectionSubscription = FirebaseDatabase.instance
        .ref('.info/connected')
        .onValue
        .listen((event) {
          _firebaseConnected = event.snapshot.value == true;
          _updateConnectionStatus();
        });
    _startConnectionChecker();
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_checkAlerts);
    DevicePairingStore.instance.removeListener(_restoreDeviceConnection);
    _firebaseConnectionSubscription?.cancel();
    _uptimeTimer?.cancel();
    _connectionTimer?.cancel();
    _awgSubscription?.cancel();
    _uptimeText.dispose();

    super.dispose();
  }

  // ============================================================
  // FIREBASE LISTENER
  // ============================================================

  Future<void> _restoreDeviceConnection() async {
    final store = DevicePairingStore.instance;
    await store.initialize();
    if (!mounted) return;
    if (_listeningDeviceId == store.verifiedId && _hasReceivedFirebaseData) {
      return;
    }
    _listeningDeviceId = store.verifiedId;
    _disconnectNotified = false;
    _alertEvaluator.reset();
    _awgSubscription?.cancel();
    _awgSubscription = null;
    _uptimeTimer?.cancel();
    setState(() {
      _lastSeenTimestamp = null;
      _machineConnected = false;
      _hasReceivedFirebaseData = false;
      _lastReadingTimestamp = null;
      _sensorData = null;
      _datedProduction = {};
      _waterUsage = {};
      _weatherHistory = {};
      _waterLevel = 0;
      _flowRate = null;
      _machineRunning = false;
    });
    if (store.verifiedId != null) _listenToAwgData();
  }

  void _listenToAwgData() {
    _awgSubscription = _awgRef.onValue.listen(
      _handleAwgData,
      onError: _handleFirebaseError,
    );
  }

  void _handleAwgData(DatabaseEvent event) {
    if (!mounted || DevicePairingStore.instance.verifiedId == null) return;

    final value = event.snapshot.value;

    if (value is! Map) {
      _lastSeenTimestamp = null;
      setState(() {
        _hasReceivedFirebaseData = true;
        _machineConnected = false;
      });

      _uptimeTimer?.cancel();
      return;
    }

    final awgData = _mapFrom(value);
    final deviceData = _mapFrom(awgData['device']);
    if (deviceData['deviceId']?.toString().trim() !=
        DevicePairingStore.instance.verifiedId) {
      _lastSeenTimestamp = null;
      _updateConnectionStatus();
      return;
    }
    final liveData = _mapFrom(awgData['live']);

    final firstReading = !_hasReceivedFirebaseData;
    _hasReceivedFirebaseData = true;

    // ----------------------------------------------------------
    // LAST SEEN
    // ----------------------------------------------------------

    final newLastSeen = _asInt(liveData['lastSeen']);

    _lastSeenTimestamp = newLastSeen;
    _lastReadingTimestamp = newLastSeen;

    final connected = _calculateConnectionStatus();

    // ----------------------------------------------------------
    // WATER LEVEL
    // ----------------------------------------------------------

    final newWaterLevel = _asDouble(
      liveData['waterLevel'],
    ).clamp(0.0, 100.0).toDouble();

    final parsedFlowRate = double.tryParse(
      liveData['flowRate']?.toString() ?? '',
    );
    final newFlowRate =
        parsedFlowRate != null && parsedFlowRate.isFinite && parsedFlowRate >= 0
        ? parsedFlowRate
        : null;
    final newWaterLevelLabel = _normalizeWaterLevelLabel(
      liveData['waterLevelLabel'],
      newWaterLevel,
    );

    // ----------------------------------------------------------
    // HARVESTING
    // ----------------------------------------------------------

    final newHarvesting = _asBool(liveData['harvesting']) == true;

    // ----------------------------------------------------------
    // SENSOR DATA
    // ----------------------------------------------------------

    final newSensorData = SensorData(
      temperature: _asDouble(liveData['temperature']),
      humidity: _asDouble(liveData['humidity']),
      waterLevel: newWaterLevel,
      ph: _asDouble(liveData['ph']),
      system: newHarvesting,
    );

    final newHasPh = liveData.containsKey('ph');

    // ----------------------------------------------------------
    // TANK
    // ----------------------------------------------------------

    final newTankFull =
        _asBool(liveData['tankFull']) == true ||
        liveData['waterLevelLabel']?.toString().trim().toUpperCase() == 'FULL';

    // ----------------------------------------------------------
    // MACHINE
    // ----------------------------------------------------------

    final newMachineRunning = _asBool(liveData['relay']) == true;

    final machineData = _mapFrom(liveData['machine']);

    // ----------------------------------------------------------
    // UPTIME
    // ----------------------------------------------------------

    final newUptimeStart = _asInt(machineData['uptimeStart']);

    final newFirebaseUptime =
        liveData['uptime']?.toString().trim() ?? '00:00:00';

    // ----------------------------------------------------------
    // PRODUCTION HISTORY
    // ----------------------------------------------------------

    final newProductionValues = _readProductionHistory(awgData, liveData);
    final datedProduction = <String, double>{};
    final waterUsage = <String, double>{};
    _mapFrom(awgData['usageByDate']).forEach((key, value) {
      final liters = double.tryParse(value.toString());
      if (liters != null && liters.isFinite && liters >= 0) {
        waterUsage[key.toString()] = liters;
      }
    });
    final weatherHistory = <String, DailyWeather>{};
    _mapFrom(awgData['weatherByDate']).forEach((key, value) {
      if (value is Map)
        weatherHistory[key.toString()] = DailyWeather.fromMap(value);
    });
    _mapFrom(awgData['productionByDate']).forEach((key, value) {
      final liters = double.tryParse(value.toString());
      if (liters != null && liters.isFinite && liters >= 0) {
        datedProduction[key.toString()] = liters;
      }
    });

    // ----------------------------------------------------------
    // ALERTS
    // ----------------------------------------------------------

    _alertTemperature = double.tryParse(
      liveData['temperature']?.toString() ?? '',
    );
    _alertHumidity = double.tryParse(liveData['humidity']?.toString() ?? '');
    _alertWaterLevel = double.tryParse(
      (liveData['waterLevel'])?.toString() ?? '',
    );
    _alertPh = double.tryParse(liveData['ph']?.toString() ?? '');
    _alertTankFull = newTankFull;

    // ----------------------------------------------------------
    // UPDATE STATE
    // ----------------------------------------------------------

    _firebaseUptime = newFirebaseUptime;
    final displayChanged =
        firstReading ||
        _sensorData != newSensorData ||
        _flowRate != newFlowRate ||
        !mapEquals(_datedProduction, datedProduction) ||
        !mapEquals(_waterUsage, waterUsage) ||
        !mapEquals(_weatherHistory, weatherHistory) ||
        _waterLevelLabel != newWaterLevelLabel ||
        _hasPh != newHasPh ||
        _machineRunning != newMachineRunning ||
        _machineConnected != connected ||
        !listEquals(_productionValues, newProductionValues);
    if (displayChanged) {
      setState(() {
        _sensorData = newSensorData;

        _waterLevel = newWaterLevel;
        _flowRate = newFlowRate;
        _waterLevelLabel = newWaterLevelLabel;

        _hasPh = newHasPh;

        _machineRunning = newMachineRunning;
        _machineConnected = connected;

        _productionValues = newProductionValues;
        _datedProduction = datedProduction;
        _waterUsage = waterUsage;
        _weatherHistory = weatherHistory;
      });
    }
    _checkAlerts();

    // ----------------------------------------------------------
    // UPTIME
    // ----------------------------------------------------------

    if (newMachineRunning && newUptimeStart != null && newUptimeStart > 0) {
      _updateUptimeStart(newUptimeStart);
    } else if (!newMachineRunning) {
      _stopUptime();
    }

    if (!connected) {
      _uptimeTimer?.cancel();
    }
    _uptimeText.value = _displayUptime();
  }

  void _handleFirebaseError(Object error) {
    _lastSeenTimestamp = null;
    debugPrint('Firebase AWG listener error: $error');

    if (!mounted) return;

    setState(() {
      _hasReceivedFirebaseData = true;
      _machineConnected = false;
    });

    _uptimeTimer?.cancel();
  }

  // ============================================================
  // FIREBASE PARSING
  // ============================================================

  Map<dynamic, dynamic> _mapFrom(dynamic value) {
    if (value is Map) {
      return Map<dynamic, dynamic>.from(value);
    }

    return <dynamic, dynamic>{};
  }

  double _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(value?.toString().trim() ?? '') ?? 0.0;
  }

  int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    if (value is String) {
      final text = value.trim();

      if (text.isEmpty) {
        return null;
      }

      return int.tryParse(text);
    }

    return null;
  }

  bool? _asBool(dynamic value) {
    if (value is bool) {
      return value;
    }

    if (value is num) {
      return value != 0;
    }

    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case '1':
        case 'on':
          return true;

        case 'false':
        case '0':
        case 'off':
          return false;
      }
    }

    return null;
  }

  // ============================================================
  // WATER LEVEL
  // ============================================================

  String _normalizeWaterLevelLabel(dynamic value, double percentage) {
    if (value != null) {
      final label = value.toString().trim().toUpperCase();

      if (label == 'EMPTY') {
        return 'EMPTY';
      }

      if (label == 'FULL') {
        return 'FULL';
      }

      if (label == 'PARTLY FILLED' ||
          label == 'PARTLY FULL' ||
          label == 'PARTLY_FULL' ||
          label == 'PARTIAL' ||
          label == 'PARTIALLY FILLED') {
        return 'PARTLY FILLED';
      }
    }

    if (percentage <= 0) {
      return 'EMPTY';
    }

    if (percentage >= 100) {
      return 'FULL';
    }

    return 'PARTLY FILLED';
  }

  String _displayWaterLevelLabel() {
    switch (_waterLevelLabel) {
      case 'FULL':
        return 'Full';

      case 'PARTLY FILLED':
        return 'Partly filled';

      case 'EMPTY':
        return 'Empty';

      default:
        return 'Empty';
    }
  }

  // ============================================================
  // CONNECTION
  // ============================================================

  void _startConnectionChecker() {
    _updateConnectionStatus();

    _connectionTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _updateConnectionStatus(),
    );
  }

  void _updateConnectionStatus() {
    if (!mounted) return;

    final online = _calculateConnectionStatus();
    if (online) {
      _disconnectNotified = false;
    } else if (_firebaseConnected &&
        _hasReceivedFirebaseData &&
        DevicePairingStore.instance.verifiedId != null &&
        !_disconnectNotified) {
      _disconnectNotified = true;
      unawaited(
        NotificationService().sendDisconnectNotification().catchError((
          Object error,
        ) {
          debugPrint('Could not save connection notification: $error');
        }),
      );
    }

    if (online == _machineConnected) {
      return;
    }

    setState(() {
      _machineConnected = online;
    });

    if (online) _checkAlerts();
    if (!online) {
      _uptimeTimer?.cancel();
    }
  }

  bool _calculateConnectionStatus() {
    return DevicePairingStore.instance.verifiedId != null &&
        _firebaseConnected &&
        _isLastSeenRecent(_lastSeenTimestamp);
  }

  bool _isLastSeenRecent(int? timestamp) {
    if (timestamp == null || timestamp <= 0) {
      return false;
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    final difference = now - timestamp;

    // Protect against small clock differences.
    if (difference < 0) {
      return difference >= -5000;
    }

    return difference <= _offlineTimeoutSeconds * 1000;
  }

  // ============================================================
  // UPTIME
  // ============================================================

  void _updateUptimeStart(int timestamp) {
    if (timestamp <= 0) {
      return;
    }

    if (_uptimeStartTimestamp == timestamp) {
      if (_machineConnected && !(_uptimeTimer?.isActive ?? false)) {
        _startUptimeTimer();
      }
      _updateMachineUptime();
      return;
    }

    _uptimeStartTimestamp = timestamp;

    _uptimeStartTime = DateTime.fromMillisecondsSinceEpoch(timestamp);

    _startUptimeTimer();
  }

  void _startUptimeTimer() {
    _uptimeTimer?.cancel();

    _updateMachineUptime();

    _uptimeTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateMachineUptime(),
    );
  }

  void _updateMachineUptime() {
    if (!mounted || !_machineRunning || _uptimeStartTime == null) {
      return;
    }

    final elapsed = DateTime.now().difference(_uptimeStartTime!);

    if (elapsed.isNegative) {
      return;
    }

    _machineUptime = elapsed;
    _uptimeText.value = _displayUptime();
  }

  void _stopUptime() {
    _uptimeTimer?.cancel();
    _uptimeTimer = null;

    _uptimeStartTime = null;
    _uptimeStartTimestamp = null;
    _machineUptime = Duration.zero;
    _uptimeText.value = '00:00:00';
  }

  String _displayUptime() {
    if (!_machineRunning) {
      return '00:00:00';
    }

    if (_uptimeStartTime != null) {
      return _formatUptime(_machineUptime);
    }

    return _firebaseUptime.isNotEmpty ? _firebaseUptime : '00:00:00';
  }

  String _formatUptime(Duration duration) {
    final hours = duration.inHours;

    final minutes = duration.inMinutes.remainder(60);

    final seconds = duration.inSeconds.remainder(60);

    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // PRODUCTION HISTORY
  // ============================================================

  List<double> _readProductionHistory(
    Map<dynamic, dynamic> awgData,
    Map<dynamic, dynamic> liveData,
  ) {
    dynamic history = awgData['productionHistory'];

    history ??= awgData['production'];
    history ??= liveData['productionHistory'];

    if (history is! Map) {
      return List<double>.filled(7, 0.0);
    }

    final historyMap = Map<dynamic, dynamic>.from(history);

    final result = List<double>.filled(7, 0.0);

    const keys = ['M', 'T', 'W', 'TH', 'F', 'S', 'SUN'];

    // Support weekday names.
    for (int i = 0; i < keys.length; i++) {
      if (historyMap.containsKey(keys[i])) {
        result[i] = _asDouble(historyMap[keys[i]]);
      }
    }

    // Support numeric Firebase keys:
    // 0, 1, 2, 3, 4, 5, 6
    for (int i = 0; i < 7; i++) {
      final key = i.toString();

      if (historyMap.containsKey(key)) {
        result[i] = _asDouble(historyMap[key]);
      }
    }

    // Prevent negative production values.
    for (int i = 0; i < result.length; i++) {
      if (!result[i].isFinite || result[i] < 0) {
        result[i] = 0.0;
      }
    }

    return result;
  }

  // ============================================================
  // ALERTS
  // ============================================================

  void _checkAlerts() {
    final alerts = _alertEvaluator.evaluate(
      enabled: AppSettings.instance.sensorAlertsEnabled,
      online: _calculateConnectionStatus(),
      temperature: _alertTemperature,
      humidity: _alertHumidity,
      waterLevel: _alertWaterLevel,
      ph: _alertPh,
      tankFull: _alertTankFull,
    );
    for (final alert in alerts) {
      unawaited(
        _notificationService
            .addNotification(
              title: alert.title,
              message: alert.message,
              type: alert.type,
              systemAlert: true,
            )
            .catchError((Object error) {
              _alertEvaluator.retry(alert.key);
              debugPrint('Unable to deliver system alert: $error');
            }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: _dashboardBackground,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const TabHeader(child: DashboardTopBar()),
            const SizedBox(height: 5),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _buildDashboardContent(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // DASHBOARD CONTENT
  // ============================================================

  String _lastUpdateLabel() {
    final timestamp = _lastReadingTimestamp;
    if (timestamp == null || timestamp <= 0) {
      return 'Last update time unavailable';
    }
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final localizations = MaterialLocalizations.of(context);
    final day = localizations.formatMediumDate(date);
    final time = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date));
    return 'Last update: $day, $time';
  }

  Widget _buildDashboardContent() {
    if (DevicePairingStore.instance.verifiedId == null) {
      return _buildDeviceNotFoundScreen();
    }

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        if (!_machineConnected)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Device disconnected',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _sensorData == null
                        ? 'No readings received yet. Connect the device to Wi-Fi for live updates.'
                        : 'Showing the last received readings. These values will update when the device reconnects.',
                  ),
                  if (_sensorData != null) Text(_lastUpdateLabel()),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const WifiConnectionScreen(),
                      ),
                    ),
                    child: const Text('Set up device Wi-Fi'),
                  ),
                ],
              ),
            ),
          ),
        _buildMachineCard(),
        const SizedBox(height: 8),
        if (_sensorData != null) _buildSensorCards(),
        const SizedBox(height: 8),
        if (_sensorData != null) _buildProductionHistoryCard(),
        const SizedBox(height: 18),
        ],
      ),
    );
  }

  // ============================================================
  // DEVICE NOT FOUND SCREEN
  // ============================================================

  Widget _buildDeviceNotFoundScreen() {
    return Center(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.fromLTRB(17, 24, 17, 24),
          decoration: BoxDecoration(
            color: _cardBackground,
            borderRadius: BorderRadius.circular(25),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ------------------------------------------------
              // DEVICE NOT FOUND IMAGE
              // ------------------------------------------------
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: double.infinity,
                  height: 183,
                  child: Image.asset(
                    'assets/images/device_notfound.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),

              const SizedBox(height: 22),

              // ------------------------------------------------
              // ERROR TEXT
              // ------------------------------------------------
              Text(
                'ERROR: Device not found',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _darkText,
                ),
              ),

              const SizedBox(height: 20),

              // ------------------------------------------------
              // PROCEED BUTTON
              // ------------------------------------------------
              SizedBox(
                width: 189,
                height: 40,
                child: ElevatedButton(
                  onPressed: widget.onProceedToDevice,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryGreen,
                    foregroundColor: _darkText,
                    elevation: 0,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  child: Text(
                    'Proceed to Device',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: _darkText,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // MACHINE CARD
  // ============================================================

  Widget _buildMachineCard() {
    final percentage = _waterLevel.round();

    return Container(
      height: 205,
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 9),
      decoration: BoxDecoration(
        color: _cardBackground,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: Center(
              child: Text(
                'ESP 32:AWG DEVICE',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _darkText,
                ),
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 125, height: 125, child: _buildTankVisual()),
                const SizedBox(width: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(5, 2, 0, 1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _sensorData != null ? '$percentage%' : '--%',
                              style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                                color: _darkText,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                _sensorData != null
                                    ? _displayWaterLevelLabel()
                                    : 'No live data',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: _darkText,
                                ),
                              ),
                            ),
                          ],
                        ),
                        _buildConnectionStatus(),
                        _buildUptimeText(),
                        _buildMachineButton(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // CONNECTION STATUS
  // ============================================================

  Widget _buildConnectionStatus() {
    return Row(
      children: [
        Icon(
          _machineConnected ? Icons.wifi : Icons.wifi_off,
          size: 20,
          color: _machineConnected ? _primaryGreen : Colors.red,
        ),
        const SizedBox(width: 6),
        Text(
          _machineConnected ? 'Connected' : 'Disconnected',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: _machineConnected ? _primaryGreen : Colors.red,
          ),
        ),
        const SizedBox(width: 10),
        if (_machineConnected)
          Flexible(
            child: Text(
              _machineRunning ? '• Harvesting' : '• Stopped',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: _primaryGreen,
              ),
            ),
          ),
      ],
    );
  }

  // ============================================================
  // UPTIME TEXT
  // ============================================================

  Widget _buildUptimeText() {
    return ValueListenableBuilder<String>(
      valueListenable: _uptimeText,
      builder: (context, uptime, _) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: 'Device Uptime  :  ',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: _darkText,
                ),
              ),
              TextSpan(
                text: uptime,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _darkText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // START / STOP BUTTON
  // ============================================================

  Widget _buildMachineButton() {
    final disabled = !_machineConnected;

    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        width: 100,
        height: 29,
        child: ElevatedButton(
          onPressed: disabled ? null : _toggleMachine,
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: disabled
                ? Colors.grey.withOpacity(0.55)
                : _machineRunning
                ? _stopRed
                : _primaryGreen,
            foregroundColor: const Color(0xFF090909),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(25),
            ),
          ),
          child: Text(
            _machineRunning ? 'Stop' : 'Start',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // TANK VISUAL
  // ============================================================

  Widget _buildTankVisual() {
    return AnimatedWaterTank(percentage: _waterLevel, flowRate: _flowRate);
  }

  // ============================================================
  // SENSOR CARDS
  // ============================================================

  Widget _buildSensorCards() {
    final sensor = _sensorData!;

    return SizedBox(
      height: 73,
      child: Row(
        children: [
          Expanded(
            child: _compactSensorCard(
              title: 'Humidity',
              value: '${sensor.humidity.toStringAsFixed(0)}%',
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: _compactSensorCard(
              title: 'pH Level',
              value: _hasPh ? _formatPh(sensor.ph) : '--',
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: _compactSensorCard(
              title: 'Temperature',
              value: '${sensor.temperature.toStringAsFixed(0)}°',
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactSensorCard({
    required String title,
    required String value,
  }) {
    return Container(
      height: 73,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      decoration: BoxDecoration(
        color: _cardBackground,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          SizedBox(
            height: 17,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _darkText,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 28,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  color: _darkText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // PRODUCTION HISTORY
  // ============================================================

  Widget _buildProductionHistoryCard() {
    return ProductionHistorySection(
      records: _datedProduction,
      usageRecords: _waterUsage,
      weather: _weatherHistory,
      background: _cardBackground,
      foreground: _darkText,
    );
  }

  String _formatPh(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(1);
  }
  // ============================================================
  // START / STOP MACHINE
  // ============================================================

  Future<void> _toggleMachine() async {
    if (!_machineConnected) {
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ESP32 is offline.')));

      return;
    }

    final targetState = !_machineRunning;

    try {
      await _controlRef.update({
        'relay': targetState,
        'systemEnabled': targetState,
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(
            targetState
                ? 'Start command sent to ESP32.'
                : 'Stop command sent to ESP32.',
          ),
        ),
      );
    } catch (error) {
      debugPrint('Machine control error: $error');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send machine command.')),
      );
    }
  }
}
