import 'dart:convert';
import 'dart:math' as math;

/// State and autonomous directives shared by a connected **VRlizate Desktop**
/// computer (`Estación Faro`) with the Joystick smartphone via the Visor bridge
/// (or direct LAN link).
///
/// Allows the computer to:
/// 1. Offload the live Visor screen cast to the PC monitor (`castOffloadedToDesktop`),
///    freeing the Joystick's GPU, battery, and Wi-Fi airtime from video decoding.
/// 2. Offload local camera CV inference (`visionOffloadedToDesktop`) while the PC's
///    AI webcam maintains high-confidence body/hand lock, and re-enable it if lost.
/// 3. Boost Joystick input polling (`recommendedJoystickHz`) and trigger physical
///    safety haptic alerts (`hapticAlert`, e.g. desk proximity warning).
class VrDesktopBridgeState {
  static const String messageType = 'vrlizate.desktopBridge';
  static const int maxStationNameChars = 36;
  static const int maxSummaryChars = 96;

  const VrDesktopBridgeState({
    required this.revision,
    required this.stationConnected,
    this.stationName,
    this.castOffloadedToDesktop = false,
    this.visionOffloadedToDesktop = false,
    this.recommendedJoystickHz = 60,
    this.deskClearanceMeters,
    this.hapticAlert,
    this.activeDecisionSummary,
    this.topologyMode,
    this.substituteGyroWithPcVision = false,
  });

  const VrDesktopBridgeState.disconnected({this.revision = 0})
    : stationConnected = false,
      stationName = null,
      castOffloadedToDesktop = false,
      visionOffloadedToDesktop = false,
      recommendedJoystickHz = 60,
      deskClearanceMeters = null,
      hapticAlert = null,
      activeDecisionSummary = null,
      topologyMode = null,
      substituteGyroWithPcVision = false;

  final int revision;
  final bool stationConnected;
  final String? stationName;
  final bool castOffloadedToDesktop;
  final bool visionOffloadedToDesktop;
  final int recommendedJoystickHz;
  final double? deskClearanceMeters;
  final String? hapticAlert;
  final String? activeDecisionSummary;
  final String? topologyMode;
  final bool substituteGyroWithPcVision;

  static String? _cleanText(String? value, int maxLen) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.substring(0, math.min(trimmed.length, maxLen));
  }

  Map<String, Object?> toJson() => {
    'type': messageType,
    'rev': revision,
    'connected': stationConnected,
    if (_cleanText(stationName, maxStationNameChars) case final name?)
      'station': name,
    'castOffload': stationConnected && castOffloadedToDesktop,
    'visionOffload': stationConnected && visionOffloadedToDesktop,
    'hz': recommendedJoystickHz.clamp(30, 120),
    if (deskClearanceMeters != null && deskClearanceMeters!.isFinite)
      'deskM': double.parse(deskClearanceMeters!.toStringAsFixed(2)),
    if (_cleanText(hapticAlert, 32) case final alert?) 'haptic': alert,
    if (_cleanText(activeDecisionSummary, maxSummaryChars) case final summary?)
      'summary': summary,
    if (_cleanText(topologyMode, 36) case final mode?) 'mode': mode,
    if (stationConnected && substituteGyroWithPcVision) 'pcGyro': true,
  };

  String toJsonMessage() => jsonEncode(toJson());

  static VrDesktopBridgeState? tryParseMessage(Object? data) {
    if (data is! String || data.length > 1023) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic> || decoded['type'] != messageType) {
      return null;
    }
    return fromJson(decoded);
  }

  static VrDesktopBridgeState? fromJson(Map<String, dynamic> json) {
    final rev = json['rev'];
    final connected = json['connected'];
    if (rev is! int || rev < 0 || connected is! bool) return null;
    final rawDesk = json['deskM'];
    final deskM = (rawDesk is num && rawDesk.isFinite && rawDesk >= 0)
        ? rawDesk.toDouble()
        : null;
    final rawHz = json['hz'];
    final hz = (rawHz is int) ? rawHz.clamp(30, 120) : 60;
    return VrDesktopBridgeState(
      revision: rev,
      stationConnected: connected,
      stationName: _cleanText(json['station'] as String?, maxStationNameChars),
      castOffloadedToDesktop: connected && json['castOffload'] == true,
      visionOffloadedToDesktop: connected && json['visionOffload'] == true,
      recommendedJoystickHz: hz,
      deskClearanceMeters: deskM,
      hapticAlert: _cleanText(json['haptic'] as String?, 32),
      activeDecisionSummary: _cleanText(
        json['summary'] as String?,
        maxSummaryChars,
      ),
      topologyMode: _cleanText(json['mode'] as String?, 36),
      substituteGyroWithPcVision: connected && json['pcGyro'] == true,
    );
  }

  bool sameConfigurationAs(VrDesktopBridgeState other) =>
      stationConnected == other.stationConnected &&
      stationName == other.stationName &&
      castOffloadedToDesktop == other.castOffloadedToDesktop &&
      visionOffloadedToDesktop == other.visionOffloadedToDesktop &&
      recommendedJoystickHz == other.recommendedJoystickHz &&
      hapticAlert == other.hapticAlert &&
      activeDecisionSummary == other.activeDecisionSummary &&
      topologyMode == other.topologyMode &&
      substituteGyroWithPcVision == other.substituteGyroWithPcVision &&
      ((deskClearanceMeters == null && other.deskClearanceMeters == null) ||
          (deskClearanceMeters != null &&
              other.deskClearanceMeters != null &&
              (deskClearanceMeters! - other.deskClearanceMeters!).abs() <
                  0.03));
}
