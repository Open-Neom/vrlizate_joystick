/// Local reasons only; never contains transport URLs, tokens or error text.
enum VrControllerDisconnectReason {
  connectionClosed,
  transportError,
  inputLimitExceeded,
  replaced,
  serviceStopped,
}
