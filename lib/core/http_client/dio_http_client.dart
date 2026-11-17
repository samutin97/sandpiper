import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';

import 'package:hiddify/core/http_client/app_traffic.dart';
import 'package:hiddify/utils/custom_loggers.dart';

class DioHttpClient with InfraLogger {
  late final Dio _dio;
  DioHttpClient({required Duration timeout, required this.userAgent, required bool debug}) {
    _dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        headers: {"User-Agent": userAgent},
      ),
    );
    // First, so the retries of a request carry it too: no request leaves with the user agent of
    // dart:io ("Dart/3.x (dart:io)"). Servers tell a sing-box client from a browser by it and
    // answer with what that client can parse; a Dart one gets a config meant for something else.
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final current = options.headers.entries
              .where((header) => header.key.toLowerCase() == 'user-agent')
              .map((header) => header.value?.toString() ?? '')
              .firstOrNull;
          if (current == null || current.trim().isEmpty || current.startsWith('Dart')) {
            options.headers.removeWhere((key, _) => key.toLowerCase() == 'user-agent');
            options.headers['User-Agent'] = userAgent;
          }
          handler.next(options);
        },
      ),
    );
    _dio.interceptors.add(
      RetryInterceptor(
        dio: _dio,
        retryDelays: const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 3)],
      ),
    );

    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        // what dart:io sends when a request has no user agent of its own, a redirect for one
        final client = HttpClient()..userAgent = userAgent;
        // H-03: the core's own proxy of this session, with its credentials, or none. Never a port
        // merely found open on 127.0.0.1, and never "PROXY ...; DIRECT": a proxy that fails does not
        // turn into a request around the tunnel.
        client.findProxy = (url) => trafficState.activeProxy?.findProxyDirective ?? "DIRECT";
        return client;
      },
    );

    if (debug) {
      // _dio.interceptors.add(LoggyDioInterceptor(requestHeader: true));
    }
  }

  String userAgent;

  /// Where the app's own requests go now; the connection notifier keeps it current.
  AppTrafficState trafficState = const AppTrafficState();

  void setTrafficState(AppTrafficState state) {
    if (state == trafficState) return;
    trafficState = state;
    loggy.debug("app traffic: $state");
  }

  /// [tunnelOnly]: the request is sent only through the tunnel (VPN or the core's proxy), else it
  /// fails with [NoTunnelException]; for requests that would show the real IP to a third party.
  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool tunnelOnly = false,
    ResponseType? responseType,
  }) {
    if (tunnelOnly && !trafficState.tunneled) return Future.error(const NoTunnelException());
    return _dio.get<T>(
      url,
      cancelToken: cancelToken,
      options: _options(url, userAgent: userAgent, credentials: credentials, responseType: responseType),
    );
  }

  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool tunnelOnly = false,
    ProgressCallback? onReceiveProgress,
  }) {
    if (tunnelOnly && !trafficState.tunneled) return Future.error(const NoTunnelException());
    return _dio.download(
      url,
      path,
      cancelToken: cancelToken,
      onReceiveProgress: onReceiveProgress,
      options: _options(url, userAgent: userAgent, credentials: credentials),
    );
  }

  Options _options(
    String url, {
    String? userAgent,
    ({String username, String password})? credentials,
    ResponseType? responseType,
  }) {
    final uri = Uri.parse(url);

    String? userInfo;
    if (credentials != null) {
      userInfo = "${credentials.username}:${credentials.password}";
    } else if (uri.userInfo.isNotEmpty) {
      userInfo = uri.userInfo;
    }

    String? basicAuth;
    if (userInfo != null) {
      basicAuth = "Basic ${base64.encode(utf8.encode(userInfo))}";
    }

    return Options(
      responseType: responseType,
      headers: {
        "User-Agent": userAgent ?? this.userAgent,
        if (basicAuth != null) "authorization": basicAuth,
        // "Accept": "application/json",
        // "Content-Type": "application/json",
      },
    );
  }
}
