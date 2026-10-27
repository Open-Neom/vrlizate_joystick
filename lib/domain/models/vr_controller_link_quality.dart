import 'package:flutter/foundation.dart';

import '../services/vr_controller_link.dart';

/// Active physical transport carrying continuous controller samples.
enum VrControllerFastTransport {
  /// Upgraded over shared 5 GHz or 6 GHz Wi-Fi / Hotspot (~2–4 ms one-way).
  udp5Ghz,

  /// Upgraded over shared 2.4 GHz Wi-Fi (~6–15 ms; shares band with BT).
  udp24Ghz,

  /// Single-PDU Bluetooth LE (MTU >= 28 + WRITE_WITHOUT_RESPONSE, ~8–11 ms).
  bleSinglePacket,

  /// Legacy fragmented Bluetooth LE (MTU 23 + WRITE_WITH_RESPONSE, ~35–70 ms).
  bleFragmented,
}

enum VrLinkAdvisorySeverity { info, suggestion, warning }

/// Non-intrusive, actionable performance recommendation derived from the live
/// Visor + Joystick + Radio + Audio combination.
@immutable
class VrLinkPerformanceAdvisory {
  const VrLinkPerformanceAdvisory({
    required this.code,
    required this.severity,
    required this.shortBadge,
    required this.message,
  });

  final String code;
  final VrLinkAdvisorySeverity severity;
  final String shortBadge;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is VrLinkPerformanceAdvisory &&
      other.code == code &&
      other.severity == severity &&
      other.shortBadge == shortBadge &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, severity, shortBadge, message);
}

/// Live link telemetry and capability negotiation state shared by Visor and
/// Joystick UIs.
@immutable
class VrControllerLinkQuality {
  const VrControllerLinkQuality({
    required this.transport,
    this.rttMs,
    this.oneWayEstimateMs,
    this.recommendedHz = 60,
    this.canCarryVideoCast = true,
    this.peerSupportsMotion = true,
    this.peerSupportsConcurrentCameras = false,
    this.peerDeviceClass,
    this.peerModel,
    this.advisory,
  });

  final VrControllerFastTransport transport;
  final double? rttMs;
  final double? oneWayEstimateMs;
  final int recommendedHz;
  final bool canCarryVideoCast;
  final bool peerSupportsMotion;
  final bool peerSupportsConcurrentCameras;
  final String? peerDeviceClass;
  final String? peerModel;
  final VrLinkPerformanceAdvisory? advisory;

  bool get isUdpUpgraded =>
      transport == VrControllerFastTransport.udp5Ghz ||
      transport == VrControllerFastTransport.udp24Ghz;

  String get compactBadgeLabel {
    final ms = oneWayEstimateMs != null
        ? '~${oneWayEstimateMs!.clamp(1, 99).round()} ms'
        : switch (transport) {
            VrControllerFastTransport.udp5Ghz => '~3 ms',
            VrControllerFastTransport.udp24Ghz => '~8 ms',
            VrControllerFastTransport.bleSinglePacket => '~10 ms',
            VrControllerFastTransport.bleFragmented => '~35 ms',
          };
    final prefix = switch (transport) {
      VrControllerFastTransport.udp5Ghz =>
        recommendedHz >= 120 ? 'Wi-Fi 5G Pro' : 'Wi-Fi 5G',
      VrControllerFastTransport.udp24Ghz => 'Wi-Fi 2.4G',
      VrControllerFastTransport.bleSinglePacket => 'BLE Directo',
      VrControllerFastTransport.bleFragmented => 'BLE',
    };
    return '$prefix · $ms';
  }

  @override
  bool operator ==(Object other) =>
      other is VrControllerLinkQuality &&
      other.transport == transport &&
      other.rttMs == rttMs &&
      other.oneWayEstimateMs == oneWayEstimateMs &&
      other.recommendedHz == recommendedHz &&
      other.canCarryVideoCast == canCarryVideoCast &&
      other.peerSupportsMotion == peerSupportsMotion &&
      other.peerSupportsConcurrentCameras == peerSupportsConcurrentCameras &&
      other.peerDeviceClass == peerDeviceClass &&
      other.peerModel == peerModel &&
      other.advisory == advisory;

  @override
  int get hashCode => Object.hash(
    transport,
    rttMs,
    oneWayEstimateMs,
    recommendedHz,
    canCarryVideoCast,
    peerSupportsMotion,
    peerSupportsConcurrentCameras,
    peerDeviceClass,
    peerModel,
    advisory,
  );
}

/// Optional interface implemented by hybrid/adaptive links so UIs can observe
/// live transport upgrades, latency, and capability-gated recommendations
/// without coupling to a concrete transport implementation.
abstract interface class VrObservableControllerLink
    implements VrControllerLink {
  ValueListenable<VrControllerLinkQuality> get linkQualityListenable;
}

/// Evaluates Visor + Joystick + Radio + Audio state and produces an honest,
/// non-intrusive suggestion only when a meaningfully better setup exists.
abstract final class VrLinkPerformanceAdvisor {
  static VrLinkPerformanceAdvisory? evaluate({
    required VrControllerFastTransport transport,
    Map<String, Object?>? visorSummary,
    Map<String, Object?>? joystickSummary,
  }) {
    final visorClass = visorSummary?['cls'] as String?;
    final joystickClass = joystickSummary?['cls'] as String?;
    final joystickModel = joystickSummary?['model'] as String?;
    final visorWifiOn = visorSummary?['wifiOn'] == true;
    final joystickWifiOn = joystickSummary?['wifiOn'] == true;
    final visorFreq = visorSummary?['freqMhz'] as int?;
    final joystickFreq = joystickSummary?['freqMhz'] as int?;
    final visorWifi5 = visorSummary?['wifi5'] != false;
    final joystickWifi5 = joystickSummary?['wifi5'] != false;
    final visorAudio = visorSummary?['audio'] as String?;
    final joystickAudio = joystickSummary?['audio'] as String?;

    // 1. Role inversion warning: Entry-tier phone acting as Visor while a
    //    stronger Flagship/Mid phone is only acting as Joystick.
    if (visorClass == 'entry' &&
        (joystickClass == 'flagship' || joystickClass == 'mid')) {
      final name = (joystickModel != null && joystickModel.isNotEmpty)
          ? joystickModel
          : 'el teléfono mando';
      return VrLinkPerformanceAdvisory(
        code: 'swap_visor_joystick_roles',
        severity: VrLinkAdvisorySeverity.warning,
        shortBadge: 'Mejor visor disponible',
        message:
            'Tu mando ($name) tiene mayor potencia gráfica que el visor actual. '
            'Úsalo como Visor para ganar nitidez y fluidez VR.',
      );
    }

    final btClassicAudio =
        visorAudio == 'bluetoothA2dp' || joystickAudio == 'bluetoothA2dp';
    final any24Ghz =
        (visorFreq != null && visorFreq >= 2400 && visorFreq < 2500) ||
        (joystickFreq != null && joystickFreq >= 2400 && joystickFreq < 2500);

    // 2. 2.4 GHz Wi-Fi colliding with Bluetooth radio / Bluetooth A2DP audio.
    if (transport == VrControllerFastTransport.udp24Ghz ||
        (any24Ghz && btClassicAudio)) {
      if (visorWifi5 && joystickWifi5) {
        return const VrLinkPerformanceAdvisory(
          code: 'upgrade_wifi_24ghz_to_5ghz',
          severity: VrLinkAdvisorySeverity.warning,
          shortBadge: 'Sugerencia · Red 5 GHz',
          message:
              'Wi-Fi 2.4 GHz comparte antena con Bluetooth. Conecta ambos '
              'teléfonos a una red 5 GHz para bajar a ~3 ms y estabilizar el audio.',
        );
      }
    }

    // 3. BLE active while both phones are on Wi-Fi (different SSIDs or router
    //    Client Isolation preventing direct UDP upgrade).
    if (!identical(transport, VrControllerFastTransport.udp5Ghz) &&
        !identical(transport, VrControllerFastTransport.udp24Ghz)) {
      if (visorWifiOn && joystickWifiOn) {
        final bothAlready5Ghz =
            (visorFreq != null && visorFreq >= 4900) &&
            (joystickFreq != null && joystickFreq >= 4900);
        final visorStaAp = visorSummary?['staAp'] == true;
        return VrLinkPerformanceAdvisory(
          code: 'align_same_5ghz_wifi',
          severity: VrLinkAdvisorySeverity.suggestion,
          shortBadge: 'Modo ~3 ms disponible',
          message: bothAlready5Ghz && visorStaAp
              ? 'BLE 1-pkt activo (~10 ms). Tu router bloquea tráfico directo; '
                    'activa Hotspot Wi-Fi 5 GHz del visor para ~3 ms sin perder Internet.'
              : 'Mando activo por BLE (~10 ms), pero los teléfonos están en redes '
                    'distintas o aisladas. Conéctalos a la misma red Wi-Fi 5 GHz para '
                    'activar enlace híbrido (~3 ms).',
        );
      }
      if (visorSummary != null &&
          joystickSummary != null &&
          (visorWifiOn != joystickWifiOn) &&
          visorWifi5 &&
          joystickWifi5) {
        return const VrLinkPerformanceAdvisory(
          code: 'connect_second_phone_wifi',
          severity: VrLinkAdvisorySeverity.suggestion,
          shortBadge: 'Sugerencia · Wi-Fi 5 GHz',
          message:
              'Uno de los teléfonos no está en Wi-Fi. Si conectas ambos a la '
              'misma red 5 GHz, el mando conmuta solo de ~10 ms a ~3 ms.',
        );
      }
      if (transport == VrControllerFastTransport.bleFragmented) {
        return const VrLinkPerformanceAdvisory(
          code: 'ble_fragmented_basic',
          severity: VrLinkAdvisorySeverity.warning,
          shortBadge: 'Enlace BLE básico',
          message:
              'Enlace BLE fragmentado activo. Conecta ambos teléfonos a una red '
              'Wi-Fi 5 GHz común para máxima respuesta (~3 ms).',
        );
      }
    }

    // 4. Optimal 5 GHz UDP active, gentle audio latency tip if using A2DP.
    if (transport == VrControllerFastTransport.udp5Ghz &&
        visorAudio == 'bluetoothA2dp') {
      return const VrLinkPerformanceAdvisory(
        code: 'a2dp_audio_latency_hint',
        severity: VrLinkAdvisorySeverity.info,
        shortBadge: 'Audio BT clásico',
        message:
            'Mando óptimo en 5 GHz (~3 ms). Para eliminar también los ~150 ms '
            'del audio Bluetooth clásico, usa audífonos USB-C o LE Audio.',
      );
    }

    return null;
  }
}
