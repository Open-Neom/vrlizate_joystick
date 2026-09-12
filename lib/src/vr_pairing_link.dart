import 'package:vrlizate/vrlizate.dart';

/// Accepts canonical invitations and Flutter's path-only delivery of /pair.
/// Missing credentials or invalid enums are never repaired with defaults.
VrPairingPayload? tryParseVrPairingUri(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    var uri = Uri.parse(raw.trim());
    if (uri.scheme.isEmpty &&
        !uri.hasAuthority &&
        (uri.path == '/pair' || uri.path == 'pair') &&
        !uri.hasFragment) {
      uri = Uri(scheme: 'vrlizate', host: 'pair', query: uri.query);
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
    scheme: secure ? 'wss' : 'ws',
    host: host,
    port: port,
    path: '/',
    queryParameters: {'token': token},
  );

  factory VrControllerConnectionTarget.parse(
    String input, {
    String? pairedHost,
    int pairedPort = 8080,
    String? sessionToken,
    VrTransportType transportType = VrTransportType.localSocket,
  }) {
    final raw = input.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null || raw.isEmpty) {
      throw const FormatException(
        'Pega el enlace de emparejamiento del visor.',
      );
    }

    if (uri.scheme == 'vrlizate' || uri.path == '/pair' || uri.path == 'pair') {
      final payload = tryParseVrPairingUri(raw);
      if (payload == null) {
        throw const FormatException(
          'El enlace de emparejamiento está incompleto o no es válido.',
        );
      }
      _requireSupportedTransport(payload.transportType);
      return VrControllerConnectionTarget._(
        host: payload.host,
        port: payload.port,
        token: payload.sessionToken,
      );
    }

    if (const ['http', 'https', 'ws', 'wss'].contains(uri.scheme)) {
      final secure = uri.scheme == 'https' || uri.scheme == 'wss';
      final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
      final tokens = uri.queryParametersAll['token'];
      if (uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          tokens == null ||
          tokens.length != 1 ||
          tokens.single.trim().isEmpty ||
          port < 1 ||
          port > 65535) {
        throw const FormatException(
          'Pega el enlace completo del visor, incluido su token.',
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
        'La IP sola no autoriza la conexión. Escanea el QR o pega el enlace del visor.',
      );
    }
    if (pairedPort < 1 || pairedPort > 65535) {
      throw const FormatException('El puerto del visor no es válido.');
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
          ? 'Bluetooth LE'
          : 'Wi-Fi Direct';
      throw UnsupportedError(
        '$label está pendiente de implementación. Usa el enlace Wi-Fi local del visor.',
      );
    }
  }
}
