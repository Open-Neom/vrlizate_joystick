import 'package:vrlizate/core/network/vr_pairing_payload.dart';

import '../../utils/constants/vr_joystick_constants.dart';
import '../../utils/constants/vr_joystick_translation_constants.dart';

final RegExp _pairingControlOrBidi = RegExp(
  r'[\x00-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060\u2066-\u2069\uFEFF]',
);
final RegExp _unsafeTargetHostChars = RegExp(r'[\s/\\@#?%\u3002\uFF0E\uFF61]');

/// Accepts canonical invitations and Flutter's path-only delivery of /pair.
/// Missing credentials or invalid enums are never repaired with defaults.
VrPairingPayload? tryParseVrPairingUri(String? raw) {
  if (raw == null || _pairingControlOrBidi.hasMatch(raw)) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 2048 ||
      _pairingControlOrBidi.hasMatch(trimmed)) {
    return null;
  }
  try {
    var uri = Uri.parse(trimmed);
    if (uri.scheme.isEmpty &&
        !uri.hasAuthority &&
        (uri.path == VrJoystickConstants.pathPair ||
            uri.path == VrJoystickConstants.pathPairRelative) &&
        !uri.hasFragment) {
      uri = Uri(
        scheme: VrJoystickConstants.schemeVrlizate,
        host: VrJoystickConstants.hostPair,
        query: uri.query,
      );
    }
    return VrPairingPayload.fromUri(uri);
  } on FormatException {
    return null;
  }
}

/// An authenticated native controller destination, without transport fallback.
class VrControllerConnectionTarget {
  final String host;
  final int port;
  final String token;
  final bool secure;

  const VrControllerConnectionTarget._({
    required this.host,
    required this.port,
    required this.token,
    this.secure = false,
  });

  Uri get webSocketUri => Uri(
    scheme: secure
        ? VrJoystickConstants.schemeWss
        : VrJoystickConstants.schemeWs,
    host: host,
    port: port,
    path: VrJoystickConstants.pathRoot,
    queryParameters: {VrJoystickConstants.queryToken: token},
  );

  factory VrControllerConnectionTarget.parse(
    String input, {
    String? pairedHost,
    int pairedPort = VrJoystickConstants.defaultServerPort,
    String? sessionToken,
    VrTransportType transportType = VrTransportType.localSocket,
  }) {
    if (_pairingControlOrBidi.hasMatch(input)) {
      throw const FormatException(
        VrJoystickTranslationConstants.errorPastePairingLink,
      );
    }
    final raw = input.trim();
    if (raw.isEmpty ||
        raw.length > 2048 ||
        _pairingControlOrBidi.hasMatch(raw)) {
      throw const FormatException(
        VrJoystickTranslationConstants.errorPastePairingLink,
      );
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      throw const FormatException(
        VrJoystickTranslationConstants.errorPastePairingLink,
      );
    }

    if (uri.scheme == VrJoystickConstants.schemeVrlizate ||
        uri.path == VrJoystickConstants.pathPair ||
        uri.path == VrJoystickConstants.pathPairRelative) {
      final payload = tryParseVrPairingUri(raw);
      if (payload == null) {
        throw const FormatException(
          VrJoystickTranslationConstants.errorInvalidPairingLink,
        );
      }
      _requireSupportedTransport(payload.transportType);
      return VrControllerConnectionTarget._(
        host: payload.host,
        port: payload.port,
        token: payload.sessionToken,
      );
    }

    if (VrJoystickConstants.webSchemes.contains(uri.scheme)) {
      final secure =
          uri.scheme == VrJoystickConstants.schemeHttps ||
          uri.scheme == VrJoystickConstants.schemeWss;
      final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
      final tokens = uri.queryParametersAll[VrJoystickConstants.queryToken];
      if (uri.host.isEmpty ||
          uri.host.length > 255 ||
          _unsafeTargetHostChars.hasMatch(uri.host) ||
          isBlockedVrPairingHost(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != VrJoystickConstants.pathRoot) ||
          tokens == null ||
          tokens.length != 1 ||
          tokens.single.trim().isEmpty ||
          tokens.single.length > 256 ||
          _pairingControlOrBidi.hasMatch(tokens.single) ||
          port < 1 ||
          port > 65535) {
        throw const FormatException(
          VrJoystickTranslationConstants.errorPasteFullLinkWithToken,
        );
      }
      return VrControllerConnectionTarget._(
        host: uri.host,
        port: port,
        token: tokens.single,
        secure: secure,
      );
    }

    _requireSupportedTransport(transportType);
    if (raw != pairedHost ||
        raw.length > 255 ||
        _unsafeTargetHostChars.hasMatch(raw) ||
        isBlockedVrPairingHost(raw) ||
        sessionToken == null ||
        sessionToken.trim().isEmpty ||
        sessionToken.length > 256 ||
        _pairingControlOrBidi.hasMatch(sessionToken)) {
      throw const FormatException(
        VrJoystickTranslationConstants.errorIpAloneDoesNotAuthorize,
      );
    }
    if (!pairedPort.isFinite || pairedPort < 1 || pairedPort > 65535) {
      throw const FormatException(
        VrJoystickTranslationConstants.errorInvalidVisorPort,
      );
    }
    return VrControllerConnectionTarget._(
      host: raw,
      port: pairedPort,
      token: sessionToken,
    );
  }

  static void _requireSupportedTransport(VrTransportType transport) {
    if (transport != VrTransportType.localSocket) {
      final label = transport == VrTransportType.bluetoothLe
          ? VrJoystickTranslationConstants.transportBluetoothLe
          : VrJoystickTranslationConstants.transportWifiDirect;
      throw UnsupportedError(
        '$label${VrJoystickTranslationConstants.errorPendingTransportSuffix}',
      );
    }
  }
}
