import 'package:vrlizate/vrlizate.dart';

import '../../utils/constants/vr_joystick_constants.dart';
import '../../utils/constants/vr_joystick_translation_constants.dart';

/// Accepts canonical invitations and Flutter's path-only delivery of /pair.
/// Missing credentials or invalid enums are never repaired with defaults.
VrPairingPayload? tryParseVrPairingUri(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    var uri = Uri.parse(raw.trim());
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
    final raw = input.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null || raw.isEmpty) {
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
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != VrJoystickConstants.pathRoot) ||
          tokens == null ||
          tokens.length != 1 ||
          tokens.single.trim().isEmpty ||
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
        sessionToken == null ||
        sessionToken.trim().isEmpty) {
      throw const FormatException(
        VrJoystickTranslationConstants.errorIpAloneDoesNotAuthorize,
      );
    }
    if (pairedPort < 1 || pairedPort > 65535) {
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
