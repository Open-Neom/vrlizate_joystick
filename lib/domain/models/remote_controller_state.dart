import 'package:vector_math/vector_math.dart' as vm;

import '../../utils/enums/remote_controller_mode.dart';

/// Orientation, analog thumbstick and button state emitted by the remote smartphone controller.
class RemoteControllerState {
  final vm.Quaternion orientation;
  final vm.Vector3 angularVelocity;
  final bool isTriggerPressed;
  final bool isActionPressed;
  final bool btnA;
  final bool btnB;
  final bool btnX;
  final bool btnY;
  final bool btnL;
  final bool btnR;
  final bool btnGrip;
  final bool stickClick;
  final double stickX;
  final double stickY;

  /// Raw left-thumb contact near the outer rim, before the speed ramp.
  /// Null means a legacy sender/transport; hosts may then infer the rim from
  /// the conditioned stick magnitude. This is intent, not a turn command.
  final bool? moveAtEdge;
  final double touchX;
  final double touchY;
  final double turnRate;
  final double pitchRate;
  final double laserX;
  final double laserY;

  /// True only while a finger owns the head-relative touch aiming pad.
  final bool laserSlideActive;
  final bool recenter;

  /// Desired visibility of the viewer's controller feedback, not a toggle edge.
  /// Defaults visible for older clients. Safety releases preserve this setting;
  /// a new connection starts visible until its first complete JSON snapshot.
  final bool controllerVisible;

  /// Driving-only controls; positive steering turns right. Legacy defaults 0.
  final double steering;

  /// Calibrated screen inclination: forward positive, backward negative.
  /// Native senders only; old/browser clients and safety releases default 0.
  /// This is not [orientation], which belongs to touch laser aiming.
  final double drivingTilt;
  final double throttle;
  final double brake;
  final bool drivingPaused;

  /// Reports recent valid gyro samples, not whether the user chose gyro input.
  /// Legacy clients and released/timed-out states report false.
  final bool motionAvailable;

  /// Receiver-generated safety release (timeout, disconnect or replacement).
  /// Never accepted from the wire; hosts should require fresh neutral input.
  final bool isNeutralized;
  final double? rangeMeters;
  final String? searchQuery;
  final bool searchSubmitted;
  final RemoteControllerMode mode;
  final DateTime timestamp;

  RemoteControllerState({
    required this.orientation,
    vm.Vector3? angularVelocity,
    this.isTriggerPressed = false,
    this.isActionPressed = false,
    this.btnA = false,
    this.btnB = false,
    this.btnX = false,
    this.btnY = false,
    this.btnL = false,
    this.btnR = false,
    this.btnGrip = false,
    this.stickClick = false,
    this.stickX = 0.0,
    this.stickY = 0.0,
    this.moveAtEdge,
    this.touchX = 0.0,
    this.touchY = 0.0,
    double turnRate = 0.0,
    double pitchRate = 0.0,
    double? lookX,
    double? lookY,
    this.laserX = 0.0,
    this.laserY = 0.0,
    this.laserSlideActive = false,
    this.recenter = false,
    this.controllerVisible = true,
    this.steering = 0,
    this.drivingTilt = 0,
    this.throttle = 0,
    this.brake = 0,
    this.drivingPaused = false,
    this.motionAvailable = false,
    this.isNeutralized = false,
    this.rangeMeters,
    this.searchQuery,
    this.searchSubmitted = false,
    this.mode = RemoteControllerMode.joystick,
    DateTime? timestamp,
  }) : turnRate = lookX ?? turnRate,
       pitchRate = lookY ?? pitchRate,
       angularVelocity = angularVelocity ?? vm.Vector3.zero(),
       timestamp = timestamp ?? DateTime.now();

  double get lookX => turnRate;
  double get lookY => pitchRate;

  @override
  String toString() =>
      'RemoteControllerState(mode: ${mode.name}, stick: ($stickX, $stickY), '
      'turn: $turnRate, pitch: $pitchRate, laser: ($laserX, $laserY), slide: $laserSlideActive, recenter: $recenter, range: $rangeMeters, '
      'btnA: $btnA, btnB: $btnB, btnX: $btnX, btnY: $btnY, btnL: $btnL, btnR: $btnR, trigger: $isTriggerPressed, grip: $btnGrip, '
      'searchQuery: $searchQuery, searchSubmitted: $searchSubmitted)';
}
