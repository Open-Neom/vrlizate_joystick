import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:vrlizate/vrlizate.dart';

import 'virtual_thumbstick.dart';
import 'vr_pairing_link.dart';
import 'vr_remote_controller_service.dart';

/// Native Smartphone VR Controller & Joystick Screen.
///
/// Dual Modes:
/// 1. [RemoteControllerMode.joystick]: Virtual 2D analog thumbstick for smooth 3D walking/strafe
///    locomotion + ergonomic Gamepad button cluster (A, B, Trigger, Grip, Recenter).
/// 2. [RemoteControllerMode.laser]: 3DoF Gyroscope spatial laser aiming pointing ray.
///
/// Roles:
/// - Supports [isChildRole] when paired via canonical deep link `vrlizate://pair?...`
///   from a Parent Visor.
class PhoneControllerPage extends StatefulWidget {
  final RemoteControllerMode initialMode;
  final String? targetHost;
  final int targetPort;
  final String? sessionToken;
  final VrTransportType transportType;
  final bool autoConnect;
  final bool isChildRole;

  const PhoneControllerPage({
    super.key,
    this.initialMode = RemoteControllerMode.laser,
    this.targetHost,
    this.targetPort = 8080,
    this.sessionToken,
    this.transportType = VrTransportType.localSocket,
    this.autoConnect = false,
    this.isChildRole = false,
  });

  @override
  State<PhoneControllerPage> createState() => _PhoneControllerPageState();
}

class _PhoneControllerPageState extends State<PhoneControllerPage>
    with WidgetsBindingObserver {
  final TextEditingController _ipController = TextEditingController(
    text: '192.168.1.',
  );

  WebSocket? _socket;
  RawDatagramSocket? _udpListener;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _streamTimer;
  Timer? _connectionTimeout;
  Timer? _recenterResetTimer;
  Completer<WebSocket>? _pendingConnection;

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isForeground = true;
  bool _targetEdited = false;
  String? _discoveredHost;
  late int _targetPort;
  int _connectionGeneration = 0;
  VrControllerConnectionTarget? _lastTarget;
  String _status = 'Buscando visor en la red Wi-Fi...';

  late RemoteControllerMode _activeMode;

  // Dual Joystick state
  double _stickX = 0.0;
  double _stickY = 0.0;
  double _lookX = 0.0; // 360° Horizontal turn (yaw)
  double _lookY = 0.0; // 180° Vertical tilt (pitch)
  bool _recenterTriggered = false;

  // Shake detection state
  bool _shakeToRecenterEnabled = true;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime? _lastShakeTime;

  // Buttons state
  bool _triggerActive = false;
  bool _actionActive = false;
  bool _btnAActive = false;
  bool _btnBActive = false;
  bool _btnGripActive = false;

  // Gyroscope 3DoF state
  vm.Quaternion _orientation = vm.Quaternion.identity();
  final vm.Vector3 _angularVelocity = vm.Vector3.zero();
  DateTime? _lastGyroTime;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeMode = widget.initialMode;
    _targetPort = widget.targetPort;
    if (widget.targetHost != null && widget.targetHost!.isNotEmpty) {
      _ipController.text = widget.targetHost!;
    } else {
      _loadSavedIp();
    }
    if (widget.targetHost == null || widget.targetHost!.isEmpty) {
      _startUdpAutoDiscovery();
    }
    _startGyroTracking();
    _startShakeDetection();

    // Lock to horizontal (landscape) mode for ergonomic dual-hand controller gameplay
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    if (widget.autoConnect &&
        widget.targetHost != null &&
        widget.targetHost!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isConnected && !_isConnecting) {
          _connect();
        }
      });
    }
  }

  void _startShakeDetection() {
    try {
      _accelSub = accelerometerEventStream().listen(
        (AccelerometerEvent event) {
          if (!mounted || !_isForeground || !_shakeToRecenterEnabled) return;
          final mag = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
          final now = DateTime.now();
          // Shake requires vigorous acceleration (> 20 m/s^2, well above 1g = 9.8 m/s^2)
          if (mag > 20.0) {
            if (_lastShakeTime == null ||
                now.difference(_lastShakeTime!) > const Duration(milliseconds: 1200)) {
              _lastShakeTime = now;
              _onShakeDetected();
            }
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  void _onShakeDetected() {
    HapticFeedback.heavyImpact();
    _recenterController();
    if (mounted) {
      setState(() {
        _status = '¡Sacudida detectada! Ejes recentrados al frente';
      });
    }
  }

  Future<void> _loadSavedIp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('vrlizate_host_ip');
      if (mounted &&
          !_targetEdited &&
          _discoveredHost == null &&
          savedIp != null &&
          savedIp.isNotEmpty) {
        setState(() {
          _ipController.text = savedIp;
        });
      }
    } catch (_) {}
  }

  void _startUdpAutoDiscovery() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8081,
        reuseAddress: true,
        reusePort: true,
      );
      if (!mounted) {
        socket.close();
        return;
      }
      _udpListener = socket;
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (mounted &&
              _isForeground &&
              datagram != null &&
              datagram.data.length <= 2048 &&
              !_isConnected &&
              !_isConnecting &&
              !_targetEdited &&
              _discoveredHost == null) {
            try {
              final msg = utf8.decode(datagram.data);
              final json = jsonDecode(msg);
              if (json is Map<String, dynamic> &&
                  json['service'] == 'vrlizate_vr_host') {
                final port = json['port'];
                if (port is! int || port < 1 || port > 65535) return;
                // Discovery is an unauthenticated hint. Trust the datagram's
                // actual source for display, never its advertised IP/token.
                final hostIp = datagram.address.address;
                setState(() {
                  _discoveredHost = hostIp;
                  _targetPort = port;
                  _ipController.text = hostIp;
                  _status =
                      'Visor detectado ($hostIp:$port). Escanea su QR o pega su enlace para vincular.';
                });
              }
            } catch (_) {}
          }
        }
      });
    } catch (e) {
      debugPrint('[PhoneControllerPage] UDP listener notice: $e');
    }
  }

  void _startGyroTracking() {
    _gyroSub =
        gyroscopeEventStream(
          samplingPeriod: const Duration(milliseconds: 16),
        ).listen(
          (GyroscopeEvent event) {
            if (!mounted || !_isForeground) return;
            if (!event.x.isFinite ||
                !event.y.isFinite ||
                !event.z.isFinite ||
                event.x.abs() > 100 ||
                event.y.abs() > 100 ||
                event.z.abs() > 100) {
              return;
            }
            final now = DateTime.now();
            _angularVelocity.setValues(event.x, event.y, event.z);
            if (_lastGyroTime != null) {
              final dt = (now.difference(_lastGyroTime!).inMicroseconds) / 1e6;
              if (dt > 0 && dt < 0.2) {
                final omega = vm.Vector3(event.x, event.y, event.z);
                final angle = omega.length * dt;
                if (angle > 1e-4) {
                  final axis = omega.normalized();
                  final deltaQ = vm.Quaternion.axisAngle(axis, angle);
                  _orientation = (_orientation * deltaQ).normalized();
                }
              }
            }
            _lastGyroTime = now;
          },
          onError: (_) {
            _angularVelocity.setZero();
            _lastGyroTime = null;
          },
        );

    // Send state periodically at 60 FPS
    _streamTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _sendState();
    });
  }

  String get _transportLabel {
    if (_lastTarget != null) return 'Conexión Directa (Socket)';
    switch (widget.transportType) {
      case VrTransportType.bluetoothLe:
        return 'Bluetooth LE (pendiente)';
      case VrTransportType.wifiDirect:
        return 'Wi-Fi Direct (pendiente)';
      case VrTransportType.localSocket:
        return 'Conexión Directa (Socket)';
    }
  }

  Future<void> _connect() async {
    if (!mounted || !_isForeground || _isConnecting) return;
    late final VrControllerConnectionTarget target;
    try {
      target = VrControllerConnectionTarget.parse(
        _ipController.text,
        pairedHost: _lastTarget?.host ?? widget.targetHost,
        pairedPort: _lastTarget?.port ?? _targetPort,
        sessionToken: _lastTarget?.token ?? widget.sessionToken,
        transportType: _lastTarget == null
            ? widget.transportType
            : VrTransportType.localSocket,
      );
    } on FormatException catch (error) {
      setState(() => _status = error.message);
      return;
    } on UnsupportedError catch (error) {
      setState(() => _status = error.message ?? 'Transporte pendiente.');
      return;
    }
    final generation = ++_connectionGeneration;
    _releaseInputs(send: true);
    final previous = _socket;
    _socket = null;
    unawaited(previous?.close());
    setState(() {
      _isConnecting = true;
      _isConnected = false;
      _status = 'Conectando al visor ${target.host}:${target.port}...';
    });

    try {
      final socket = await _openSocket(target.webSocketUri, generation);
      if (!mounted || generation != _connectionGeneration) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      _lastTarget = target;
      _targetPort = target.port;
      _sequence = 0;
      _releaseInputs();
      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _status = widget.isChildRole
            ? '⚡ VINCULADO AL VISOR PADRE (${target.host}:${target.port})'
            : '⚡ CONECTADO AL VISOR';
      });
      unawaited(_rememberHost(target.host));
      HapticFeedback.heavyImpact();
      socket.listen(
        (data) {},
        onDone: () => _onDisconnected(socket),
        onError: (_) => _onDisconnected(socket),
        cancelOnError: true,
      );
      _sendState();
    } catch (e) {
      if (mounted && generation == _connectionGeneration) {
        _connectionGeneration++;
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          // Exceptions can contain the authenticated URL; don't echo secrets.
          _status =
              'No se pudo vincular. Verifica el enlace del visor y la red Wi-Fi.';
        });
      }
    }
  }

  Future<WebSocket> _openSocket(Uri uri, int generation) {
    final completion = Completer<WebSocket>();
    _pendingConnection = completion;
    _connectionTimeout = Timer(const Duration(seconds: 4), () {
      if (!completion.isCompleted) {
        _pendingConnection = null;
        _connectionTimeout = null;
        completion.completeError(
          TimeoutException('Controller connection timed out'),
        );
      }
    });
    unawaited(
      WebSocket.connect(uri.toString()).then<void>(
        (socket) {
          // Dart cannot cancel the underlying upgrade: close any late arrival.
          if (!mounted ||
              generation != _connectionGeneration ||
              completion.isCompleted) {
            unawaited(socket.close());
            return;
          }
          _connectionTimeout?.cancel();
          _connectionTimeout = null;
          _pendingConnection = null;
          completion.complete(socket);
        },
        onError: (Object error, StackTrace stack) {
          if (completion.isCompleted) return;
          _connectionTimeout?.cancel();
          _connectionTimeout = null;
          _pendingConnection = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  void _cancelPendingConnection() {
    _connectionGeneration++;
    _connectionTimeout?.cancel();
    _connectionTimeout = null;
    final completion = _pendingConnection;
    _pendingConnection = null;
    if (completion != null && !completion.isCompleted) {
      completion.completeError(StateError('Connection cancelled'));
    }
  }

  Future<void> _rememberHost(String host) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vrlizate_host_ip', host);
    } catch (_) {}
  }

  void _onDisconnected(WebSocket socket) {
    if (!mounted || !identical(_socket, socket)) return;
    _socket = null;
    _releaseInputs();
    setState(() {
      _isConnected = false;
      _isConnecting = false;
      _status =
          'Desconectado del visor. Puedes reconectar con el mismo enlace.';
    });
  }

  void _releaseInputs({bool send = false}) {
    _stickX = 0;
    _stickY = 0;
    _lookX = 0;
    _lookY = 0;
    _recenterTriggered = false;
    _triggerActive = false;
    _actionActive = false;
    _btnAActive = false;
    _btnBActive = false;
    _btnGripActive = false;
    _angularVelocity.setZero();
    _lastGyroTime = null;
    if (send) _sendState(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    if (!_isForeground) {
      _cancelPendingConnection();
      setState(() {
        _releaseInputs(send: true);
        _isConnecting = false;
      });
    } else {
      _lastGyroTime = null;
    }
  }

  void _sendState({bool force = false}) {
    final ws = _socket;
    if (ws != null &&
        ws.readyState == WebSocket.open &&
        _isConnected &&
        (_isForeground || force)) {
      final payload = jsonEncode({
        'sequence': _sequence++,
        'timestampUs': DateTime.now().microsecondsSinceEpoch,
        'qx': _orientation.x,
        'qy': _orientation.y,
        'qz': _orientation.z,
        'qw': _orientation.w,
        'wx': _angularVelocity.x,
        'wy': _angularVelocity.y,
        'wz': _angularVelocity.z,
        'stickX': _stickX,
        'stickY': _stickY,
        'tx': _stickX,
        'ty': _stickY,
        'lookX': _lookX,
        'lookY': _lookY,
        'turn': _lookX,
        'turnRate': _lookX,
        'pitchRate': _lookY,
        'lookPitch': _lookY,
        'recenter': _recenterTriggered,
        'rangeMeters': 0.55,
        'trigger': _triggerActive,
        'action': _actionActive,
        'btnA': _btnAActive,
        'btnB': _btnBActive,
        'btnGrip': _btnGripActive,
        'mode': _activeMode == RemoteControllerMode.laser ? 'laser' : 'joystick',
      });

      try {
        ws.add(payload);
      } catch (_) {
        _onDisconnected(ws);
      }
    }
  }

  void _recenterController() {
    setState(() {
      _orientation = vm.Quaternion.identity();
      _angularVelocity.setZero();
      _lastGyroTime = null;
      _recenterTriggered = true;
    });
    HapticFeedback.mediumImpact();
    _sendState(force: true);
    _recenterResetTimer?.cancel();
    _recenterResetTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() {
          _recenterTriggered = false;
        });
      } else {
        _recenterTriggered = false;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelPendingConnection();
    _releaseInputs(send: true);
    _isForeground = false;
    _udpListener?.close();
    _gyroSub?.cancel();
    _accelSub?.cancel();
    _streamTimer?.cancel();
    _recenterResetTimer?.cancel();
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      Zone.root.run(() {
        unawaited(socket.close());
      });
    }
    _ipController.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  void _showIpConfigDialog() => _openSettings();

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101528),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF00E5FF), width: 1.5),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.90,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.tune_rounded, color: Color(0xFF00E5FF), size: 22),
                              SizedBox(width: 8),
                              Text(
                                'AJUSTES DEL MANDO VR',
                                style: TextStyle(
                                  color: Color(0xFF00E5FF),
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.white70),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                      const Divider(color: Color(0xFF00E5FF), thickness: 0.5),
                      const SizedBox(height: 6),

                      // Section 1: Modo del Mando
                      const Text(
                        'MODO DE CONTROL',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: _buildSettingsModeCard(
                              title: 'JOYSTICK DUAL',
                              subtitle: 'Navegación + Vista 360°/180°',
                              icon: Icons.gamepad_rounded,
                              isSelected: _activeMode == RemoteControllerMode.joystick,
                              onTap: () {
                                setState(() => _activeMode = RemoteControllerMode.joystick);
                                setModalState(() {});
                                HapticFeedback.selectionClick();
                                _sendState();
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildSettingsModeCard(
                              title: 'PUNTERO LÁSER',
                              subtitle: '3DoF Giroscopio Espacial',
                              icon: Icons.flare_rounded,
                              isSelected: _activeMode == RemoteControllerMode.laser,
                              onTap: () {
                                setState(() => _activeMode = RemoteControllerMode.laser);
                                setModalState(() {});
                                HapticFeedback.selectionClick();
                                _sendState();
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Section 2: Conexión con Visor Padre
                      const Text(
                        'CONEXIÓN CON EL VISOR PADRE',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF080816),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _ipController,
                                    onChanged: (_) => _targetEdited = true,
                                    style: const TextStyle(color: Colors.white, fontSize: 13),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      filled: true,
                                      fillColor: const Color(0xFF101528),
                                      hintText: '192.168.1.XX:8080 o vrlizate://pair?...',
                                      hintStyle: const TextStyle(color: Colors.white30, fontSize: 11),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(color: Color(0xFF00E5FF)),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  onPressed: _isConnecting
                                      ? null
                                      : () {
                                          Navigator.of(ctx).pop();
                                          _connect();
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _isConnected
                                        ? const Color(0xFF10B981)
                                        : const Color(0xFF00E5FF),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  ),
                                  child: Text(
                                    _isConnected ? 'RECONECTAR' : 'CONECTAR',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Estado: $_status\nTransporte: $_transportLabel | Rol: ${widget.isChildRole ? "Mando Hijo (Enlace Directo)" : "Mando Independiente"}',
                              style: const TextStyle(color: Colors.white60, fontSize: 9.5),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Section 3: Gestos & Recentrado
                      const Text(
                        'GESTOS Y RECENTRADO',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _shakeToRecenterEnabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          'Recentrar con sacudida del celular',
                          style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        subtitle: const Text(
                          'Sacude enérgicamente el teléfono para centrar automáticamente el visor y el horizonte.',
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          setState(() => _shakeToRecenterEnabled = val);
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () {
                          _recenterController();
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.filter_center_focus_rounded, size: 16),
                        label: const Text('Recentrar Vista y Mandos Ahora'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF00E5FF),
                          side: const BorderSide(color: Color(0xFF00E5FF)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSettingsModeCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00E5FF).withValues(alpha: 0.15)
              : const Color(0xFF080816),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFF00E5FF) : Colors.white12,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? const Color(0xFF00E5FF) : Colors.white60,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected ? const Color(0xFF00E5FF) : Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 8.5),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle_rounded, color: Color(0xFF00E5FF), size: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080816),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101528),
        toolbarHeight: 40,
        titleSpacing: 10,
        title: const Row(
          children: [
            Icon(Icons.sports_esports_rounded, color: Color(0xFF00E5FF), size: 18),
            SizedBox(width: 8),
            Text(
              'MANDO 3DoF VRLIZATE',
              style: TextStyle(
                color: Color(0xFF00E5FF),
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        actions: [
          _buildConnectionPill(),
          const SizedBox(width: 2),
          IconButton(
            icon: const Icon(Icons.filter_center_focus_rounded, color: Color(0xFF00E5FF), size: 19),
            tooltip: 'Recentrar vista',
            onPressed: _recenterController,
          ),
          IconButton(
            icon: const Icon(Icons.settings_rounded, color: Color(0xFF00E5FF), size: 19),
            tooltip: 'Ajustes y Modo',
            onPressed: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isChildRole) ...[
                _buildChildRoleBanner(),
                const SizedBox(height: 4),
              ],

              // Active Controller Surface (Dual Joystick vs Laser)
              Expanded(
                child: _activeMode == RemoteControllerMode.joystick
                    ? _buildJoystickLayout()
                    : _buildLaserPointerLayout(),
              ),

              const SizedBox(height: 3),

              // Real-time Telemetry Bar
              _buildTelemetryBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChildRoleBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF00E5FF).withValues(alpha: 0.4),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
            blurRadius: 8,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.link_rounded,
              color: Color(0xFF00E5FF),
              size: 16,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Text(
                      'ROL: MANDO HIJO',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                    SizedBox(width: 6),
                    Text(
                      '· ENLACE DIRECTO',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                Text(
                  'Visor Padre: ${_lastTarget?.host ?? widget.targetHost ?? _discoveredHost ?? 'Sin vincular'}:$_targetPort ($_transportLabel)',
                  style: const TextStyle(color: Colors.white70, fontSize: 9.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: _isConnected
                  ? const Color(0xFF10B981).withValues(alpha: 0.2)
                  : const Color(0xFFFF9100).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _isConnected
                    ? const Color(0xFF10B981)
                    : const Color(0xFFFF9100),
              ),
            ),
            child: Text(
              _isConnected
                  ? 'SINCRONIZADO'
                  : (_isConnecting ? 'CONECTANDO' : 'SIN VINCULAR'),
              style: TextStyle(
                color: _isConnected
                    ? const Color(0xFF10B981)
                    : const Color(0xFFFF9100),
                fontSize: 8.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionPill() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _showIpConfigDialog,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isConnected
                    ? const Color(0xFF10B981).withValues(alpha: 0.5)
                    : Colors.white12,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isConnected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                  color: _isConnected
                      ? const Color(0xFF10B981)
                      : const Color(0xFFFF9100),
                  size: 13,
                ),
                const SizedBox(width: 4),
                Text(
                  _lastTarget?.host ??
                      (_ipController.text.isNotEmpty
                          ? _ipController.text
                          : 'Config IP'),
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
                const SizedBox(width: 2),
                const Icon(Icons.edit_rounded, color: Colors.white38, size: 11),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        ElevatedButton(
          onPressed: _isConnecting ? null : _connect,
          style: ElevatedButton.styleFrom(
            backgroundColor: _isConnected
                ? const Color(0xFF10B981)
                : const Color(0xFF00E5FF),
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: const Size(0, 30),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            _isConnected ? 'RECONECTAR' : 'CONECTAR',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 10.5,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }

  // ─── Modo Joystick Virtual Layout ────────────────────────────────────────

  Widget _buildJoystickLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double stickSize = min(constraints.maxHeight * 0.58, 142.0);
        final double btnHeight = min(constraints.maxHeight * 0.22, 48.0);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left Half: Top 2 Action Buttons (RT & Grip) + Navigation 3D Joystick
            Expanded(
              flex: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF101528).withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Top 2 Buttons: RT Gatillo & Grip
                    SizedBox(
                      height: btnHeight,
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildButton(
                              title: 'RT · GATILLO',
                              subtitle: 'Interactuar / Clic',
                              icon: Icons.touch_app_rounded,
                              isActive: _triggerActive,
                              colors: const [Color(0xFF00E5FF), Color(0xFF7C4DFF)],
                              onDown: () => setState(() => _triggerActive = true),
                              onUp: () => setState(() => _triggerActive = false),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildButton(
                              title: 'GRIP',
                              subtitle: 'Agarre',
                              icon: Icons.pan_tool_alt_rounded,
                              isActive: _btnGripActive,
                              colors: const [Color(0xFF334155), Color(0xFF1E293B)],
                              textColor: const Color(0xFF00E5FF),
                              onDown: () => setState(() => _btnGripActive = true),
                              onUp: () => setState(() => _btnGripActive = false),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    // Center: Navigation Thumbstick (Walk/Strafe 3D)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VirtualThumbstick(
                            size: stickSize,
                            knobRadius: 22.0,
                            onChanged: (x, y) {
                              _stickX = x;
                              _stickY = y;
                              _sendState();
                            },
                            onRelease: () {
                              _stickX = 0.0;
                              _stickY = 0.0;
                              _sendState();
                            },
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'NAVEGACIÓN 3D (DESPLAZAMIENTO)',
                            style: TextStyle(
                              color: Color(0xFF00E5FF),
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),
                  ],
                ),
              ),
            ),

            // Center Separator
            Container(
              width: 1.2,
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(1),
              ),
            ),

            // Right Half: Top 2 Action Buttons (A & B) + Look/Turn Joystick (360° Yaw & 180° Pitch)
            Expanded(
              flex: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF101528).withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Top 2 Buttons: A & B
                    SizedBox(
                      height: btnHeight,
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildButton(
                              title: 'A',
                              subtitle: 'Confirmar',
                              icon: Icons.check_circle_outline_rounded,
                              isActive: _btnAActive,
                              colors: const [Color(0xFF10B981), Color(0xFF00E5FF)],
                              onDown: () => setState(() => _btnAActive = true),
                              onUp: () => setState(() => _btnAActive = false),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildButton(
                              title: 'B',
                              subtitle: 'Atrás / Home',
                              icon: Icons.navigation_rounded,
                              isActive: _btnBActive,
                              colors: const [Color(0xFFFF007F), Color(0xFFFF9100)],
                              onDown: () => setState(() => _btnBActive = true),
                              onUp: () => setState(() => _btnBActive = false),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    // Center: Look/Turn Thumbstick (360° Horizontal & 180° Vertical)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VirtualThumbstick(
                            size: stickSize,
                            knobRadius: 22.0,
                            onChanged: (x, y) {
                              _lookX = x;
                              _lookY = y;
                              _sendState();
                            },
                            onRelease: () {
                              _lookX = 0.0;
                              _lookY = 0.0;
                              _sendState();
                            },
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'VISTA & GIRO (360° HORIZ / 180° VERT)',
                            style: TextStyle(
                              color: Color(0xFF00E5FF),
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildButton({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isActive,
    required List<Color> colors,
    Color textColor = Colors.white,
    required VoidCallback onDown,
    required VoidCallback onUp,
  }) {
    return GestureDetector(
      onTapDown: (_) {
        onDown();
        HapticFeedback.mediumImpact();
        _sendState();
      },
      onTapUp: (_) {
        onUp();
        _sendState();
      },
      onTapCancel: () {
        onUp();
        _sendState();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: isActive
              ? Border.all(color: Colors.white, width: 2)
              : Border.all(color: Colors.white10),
          boxShadow: [
            BoxShadow(
              color: colors.first.withValues(alpha: isActive ? 0.6 : 0.25),
              blurRadius: isActive ? 14 : 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: textColor, size: 20),
                  const SizedBox(height: 2),
                  Text(
                    title,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.7),
                      fontSize: 8.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── Modo Puntero Láser 3DoF Layout ──────────────────────────────────────

  Widget _buildLaserPointerLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left Side: Gyro Aiming Virtual Canvas
        Expanded(
          flex: 6,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF101528),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.5),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.screen_rotation_rounded,
                      size: 36,
                      color: Color(0xFF00E5FF),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'PUNTERO LÁSER 3D ACTIVO',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Mueve este teléfono en tu mano para apuntar en VR',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _recenterController,
                      icon: const Icon(Icons.gps_fixed_rounded, size: 14),
                      label: const Text(
                        'Recentrar Mira',
                        style: TextStyle(fontSize: 11),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF00E5FF),
                        side: const BorderSide(color: Color(0xFF00E5FF)),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 30),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        const SizedBox(width: 10),

        // Right Side: Action Buttons (Back / Trigger)
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildButton(
                  title: 'ATRÁS / HOME',
                  subtitle: 'Cerrar panel o volver',
                  icon: Icons.navigation_rounded,
                  isActive: _actionActive,
                  colors: const [Color(0xFFFF007F), Color(0xFFFF9100)],
                  onDown: () => setState(() => _actionActive = true),
                  onUp: () => setState(() => _actionActive = false),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                flex: 2,
                child: _buildButton(
                  title: 'GATILLO (CLIC)',
                  subtitle: 'Seleccionar pedestal',
                  icon: Icons.touch_app_rounded,
                  isActive: _triggerActive,
                  colors: const [Color(0xFF00E5FF), Color(0xFF7C4DFF)],
                  onDown: () => setState(() => _triggerActive = true),
                  onUp: () => setState(() => _triggerActive = false),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTelemetryBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF101528),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConnected
                        ? const Color(0xFF10B981)
                        : const Color(0xFFFF007F),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _isConnected
                          ? const Color(0xFF10B981)
                          : Colors.white70,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'NAV: (${_stickX.toStringAsFixed(1)}, ${_stickY.toStringAsFixed(1)}) | '
            'VISTA: (${_lookX.toStringAsFixed(1)}, ${_lookY.toStringAsFixed(1)}) | '
            'SACUDIR: ${_shakeToRecenterEnabled ? "ON" : "OFF"}',
            style: const TextStyle(
              color: Color(0xFF00E5FF),
              fontSize: 8.5,
              fontFamily: 'Courier',
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
