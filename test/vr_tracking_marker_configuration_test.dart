import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  test('public marker never derives scale from DPI or a pairing secret', () {
    const c=VrTrackingMarkerConfiguration(markerId:'vrlizate-marker-v1:0123456789abcdef');
    final parsed=VrTrackingMarkerConfiguration.fromMessage(c.toMessage());
    expect(parsed!.markerId,c.markerId); expect(parsed.hasMeasuredScale,isFalse);
    for(final bad in ['https://host/?token=secret','vrlizate-marker-v1:secret',null]) {
      expect(VrTrackingMarkerConfiguration.fromMessage({'markerId':bad}),isNull);
    }
    expect(VrTrackingMarkerConfiguration.fromMessage({...c.toMessage(),
      'widthMeters':.07,'widthSource':'screen_dpi'}),isNull);
    expect(VrTrackingMarkerConfiguration.fromMessage({...c.toMessage(),
      'widthMeters':.07,'widthSource':'manual_ruler'})!.hasMeasuredScale,isTrue);
  });
}
