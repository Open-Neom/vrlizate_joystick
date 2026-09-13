import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _NetworkService extends VrRemoteControllerService {
  _NetworkService({required this.running, this.url})
    : super(sessionToken: 'network-test-token');

  final bool running;
  final String? url;
  int disposeCalls = 0;

  @override
  bool get isRunning => running;

  @override
  String? get serverUrl => url;

  @override
  void dispose() {
    disposeCalls++;
    super.dispose();
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    VrRemoteControllerService service, {
    ValueChanged<bool>? onCompleted,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RemoteControllerQrDialog(
          service: service,
          onCompleted: onCompleted,
        ),
      ),
    ),
  );

  testWidgets('running visor without LAN shows Wi-Fi guidance, never a QR', (
    tester,
  ) async {
    final service = _NetworkService(running: true);
    addTearDown(service.dispose);
    final outcomes = <bool>[];
    await mount(tester, service, onCompleted: outcomes.add);

    expect(find.byType(QrImageView), findsNothing);
    expect(find.textContaining('Conecta este visor a Wi-Fi'), findsOneWidget);
    expect(find.textContaining('punto de acceso'), findsOneWidget);
    expect(find.textContaining('vuelve a abrir el QR'), findsOneWidget);
    expect(find.textContaining('Los datos móviles no sirven'), findsOneWidget);
    expect(find.textContaining('No hay un visor activo'), findsNothing);
    await tester.tap(find.text('Cerrar'));
    await tester.pump();
    expect(outcomes, [false]);
    expect(service.isRunning, isTrue);
    expect(service.disposeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inactive service requests returning Home instead of blaming Wi-Fi',
    (tester) async {
      final service = _NetworkService(running: false);
      addTearDown(service.dispose);
      await mount(tester, service);

      expect(find.byType(QrImageView), findsNothing);
      expect(
        find.text('No hay un visor activo. Vuelve al Home e intenta de nuevo.'),
        findsOneWidget,
      );
      expect(find.textContaining('Conecta este visor a Wi-Fi'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'usable LAN URL generates its host and bound port in the app QR',
    (tester) async {
      final service = _NetworkService(
        running: true,
        url: 'http://192.168.100.12:8087/?token=network-test-token',
      );
      addTearDown(service.dispose);
      await mount(tester, service);
      await tester.pumpAndSettle();

      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      final invitation = Uri.parse((qr.key! as ValueKey<String>).value);
      expect(invitation.scheme, 'vrlizate');
      expect(invitation.host, 'pair');
      expect(invitation.queryParameters['host'], '192.168.100.12');
      expect(invitation.queryParameters['port'], '8087');
      expect(invitation.queryParameters['token'], service.sessionToken);
      expect(find.textContaining('Conecta este visor a Wi-Fi'), findsNothing);
      expect(find.textContaining('No hay un visor activo'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
