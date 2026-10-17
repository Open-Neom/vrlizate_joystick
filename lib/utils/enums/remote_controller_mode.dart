/// The legacy laser wire value remains readable; new controllers start in
/// joystick mode and expose their aiming pad inside that normal layout.
///
/// NES is an experience-selected layout using the existing state protocol:
/// visible A -> btnA, B -> btnX, Start -> btnY, Select -> btnL, Home -> btnB.
/// Its digital D-pad uses stickX/stickY (-1, 0, 1), with positive Y upwards.
enum RemoteControllerMode { joystick, laser, driving, nes }
