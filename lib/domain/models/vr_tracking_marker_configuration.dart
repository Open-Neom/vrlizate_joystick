/// Public optical identity, scoped to an already authenticated controller link.
/// It is never a pairing credential or an authorization to execute an action.
class VrTrackingMarkerConfiguration {
  const VrTrackingMarkerConfiguration({required this.markerId, this.widthMeters});

  static const messageType = 'vrlizate.trackingMarker';
  static final _idPattern = RegExp(r'^vrlizate-marker-v1:[a-f0-9]{16}$');
  final String markerId;
  final double? widthMeters;
  bool get hasMeasuredScale => widthMeters != null;

  Map<String, Object?> toMessage() => {
    'type': messageType,
    'markerId': markerId,
    'widthMeters': widthMeters,
    'widthSource': widthMeters == null ? null : 'manual_ruler',
  };

  static VrTrackingMarkerConfiguration? fromMessage(Map<String, dynamic> json) {
    final id = json['markerId'];
    final width = json['widthMeters'];
    if (id is! String || !_idPattern.hasMatch(id)) return null;
    if (width != null &&
        (width is! num || !width.isFinite || width < .02 || width > .30 ||
            json['widthSource'] != 'manual_ruler')) {
      return null;
    }
    return VrTrackingMarkerConfiguration(
      markerId: id,
      widthMeters: (width as num?)?.toDouble(),
    );
  }
}
