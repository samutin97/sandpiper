import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/app_traffic.dart';

/// H-02/H-03: when the app's own requests (subscription updates) count as going through the tunnel.
void main() {
  const proxy = LocalProxyRoute(port: 23456, username: 'abcdefgh', password: 'xxxxxxxxxxxxxxxx');

  test('VPN mode with a core that protects its sockets: through the tunnel while connected', () {
    expect(const AppTrafficState(connected: true, vpnMode: true, appInsideVpn: true).tunneled, isTrue);
    expect(const AppTrafficState(vpnMode: true, appInsideVpn: true).tunneled, isFalse);
  });

  test('VPN mode with an app kept out of its VPN (official core): not through the tunnel', () {
    expect(const AppTrafficState(connected: true, vpnMode: true).tunneled, isFalse);
  });

  test('proxy mode: through the core proxy of the session only', () {
    expect(const AppTrafficState(connected: true, proxy: proxy).tunneled, isTrue);
    expect(const AppTrafficState(connected: true, proxy: proxy).activeProxy, proxy);
    expect(const AppTrafficState(connected: true).tunneled, isFalse);
    expect(const AppTrafficState(proxy: proxy).activeProxy, isNull);
    // in VPN mode the system routes the requests: no proxy
    expect(const AppTrafficState(connected: true, vpnMode: true, appInsideVpn: true, proxy: proxy).activeProxy, isNull);
  });

  test('the proxy directive carries the credentials of the session', () {
    expect(proxy.findProxyDirective, 'PROXY abcdefgh:xxxxxxxxxxxxxxxx@127.0.0.1:23456');
  });
}
