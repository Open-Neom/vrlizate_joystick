/// A classified provider failure, without exposing pairing credentials to UI.
///
/// Adapters should mark permission/configuration failures as non-retryable and
/// expired/rejected credentials as [isSessionExpired]. An expired session must
/// be paired again; retrying the same credentials cannot repair it.
class VrControllerConnectionException implements Exception {
  const VrControllerConnectionException(
    this.message, {
    this.canRetry = true,
    this.isSessionExpired = false,
  });

  final String message;
  final bool canRetry;
  final bool isSessionExpired;

  @override
  String toString() => 'VrControllerConnectionException: $message';
}
