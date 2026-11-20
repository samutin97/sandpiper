import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_exits.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/notifier/exit_choice_notifier.dart';

const _main = 'https://example.org/sub/main-token';
const _warp = 'https://example.org/sub/warp-token';
const _policyMain = 'v=1; t=auto:1,2';

String _b64(String text) => base64Url.encode(utf8.encode(text)).replaceAll('=', '');

String _pair({required String cur, required String alt, required String url}) =>
    'v=1;cur=$cur;alt=$alt;alt-url=${_b64(url)}';

/// What a subscription's server answers: a body and headers, or an HTTP status that is not a success.
class _Answer {
  const _Answer.ok(this.headers) : status = 200;
  const _Answer.status(this.status) : headers = const {};

  final int status;
  final Map<String, String> headers;
}

/// The subscriptions of a pair, in the process: no network.
class _Server extends DioHttpClient {
  _Server(this.answers) : super(timeout: const Duration(seconds: 1), userAgent: 'test', debug: false);

  final Map<String, _Answer> answers;

  /// The links asked for, in order.
  final asked = <String>[];

  @override
  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool tunnelOnly = false,
    ProgressCallback? onReceiveProgress,
  }) async {
    asked.add(url);
    final request = RequestOptions(path: url);
    final answer = answers[url];
    if (answer == null) {
      throw DioException(requestOptions: request, type: DioExceptionType.connectionError);
    }
    if (answer.status != 200) {
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: request, statusCode: answer.status),
      );
    }
    await File(path).writeAsString('{"outbounds":[]}');
    return Response(
      requestOptions: request,
      statusCode: 200,
      headers: Headers.fromMap({
        for (final e in answer.headers.entries) e.key: [e.value],
      }),
    );
  }
}

RemoteProfileEntity _profile({String? exitUrl, Map<String, dynamic>? headers}) => RemoteProfileEntity(
  id: 'p1',
  active: true,
  name: 'subscription',
  url: _main,
  lastUpdate: DateTime(2026, 11, 19),
  populatedHeaders: headers ?? {'profile-policy': _policyMain},
  userOverride: exitUrl == null ? null : UserOverride(exitUrl: exitUrl),
);

final _mainAnswer = _Answer.ok({
  'profile-exits': _pair(cur: 'main', alt: 'warp', url: _warp),
  'profile-policy': _policyMain,
});
final _warpAnswer = _Answer.ok({'profile-exits': _pair(cur: 'warp', alt: 'main', url: _main)});

void main() {
  late Directory dir;
  late String temp;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('exits_test');
    temp = '${dir.path}${Platform.pathSeparator}profile.tmp';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ProfileEntity> update(_Server server, RemoteProfileEntity profile, {ExitRole? switchTo}) async {
    final result = await ProfileParser(
      httpClient: server,
    ).updateRemoteEntity(rp: profile, tempFilePath: temp, switchTo: switchTo).run();
    return result.fold((failure) => throw failure, (entity) => entity);
  }

  Future<ProfileFailure> updateFails(_Server server, RemoteProfileEntity profile, {ExitRole? switchTo}) async {
    final result = await ProfileParser(
      httpClient: server,
    ).updateRemoteEntity(rp: profile, tempFilePath: temp, switchTo: switchTo).run();
    return result.fold((failure) => failure, (_) => fail('the update was to fail'));
  }

  group('an update of a profile', () {
    test('on its own link reads the pair and asks nothing else', () async {
      final server = _Server({_main: _mainAnswer});
      final updated = await update(server, _profile());
      expect(server.asked, [_main]);
      expect(updated.exits?.current, ExitRole.main);
      expect(updated.exits?.alternativeUrl, _warp);
      expect(updated.userOverride?.exitUrl, isNull);
    });

    test('on the pair updates that subscription, and keeps the way out and the home link', () async {
      final server = _Server({_warp: _warpAnswer});
      final updated = await update(server, _profile(exitUrl: _warp)) as RemoteProfileEntity;
      expect(server.asked, [_warp], reason: 'the home link is not asked');
      expect(updated.url, _main);
      expect(updated.userOverride?.exitUrl, _warp);
      expect(updated.exits?.current, ExitRole.warp);
    });

    test('a server that sends no pair is a profile with no choice, on its own link', () async {
      final server = _Server({_main: const _Answer.ok({})});
      expect((await update(server, _profile())).exits, isNull);
    });

    test('a pair that is not understood is dropped, not kept', () async {
      final server = _Server({
        _main: _Answer.ok({'profile-exits': 'v=2;cur=main;alt=warp;alt-url=${_b64(_warp)}'}),
      });
      final updated = await update(server, _profile(headers: {}));
      expect(updated.exits, isNull);
      expect(updated.populatedHeaders, isNot(contains(ProfileExits.headerName)));
    });

    test("the pair's link is kept in the headers only in the canonical form", () async {
      final server = _Server({
        _main: _Answer.ok({'profile-exits': ' V=1 ; CUR=Main ; Alt=Warp ; extra=1 ; alt-url=${_b64(_warp)} '}),
      });
      final updated = await update(server, _profile());
      expect(updated.populatedHeaders?[ProfileExits.headerName], _pair(cur: 'main', alt: 'warp', url: _warp));
    });
  });

  group('an update of a profile on the pair that is gone', () {
    test('not found: back to the home link, the way out main', () async {
      final server = _Server({_warp: const _Answer.status(404), _main: _mainAnswer});
      final updated = await update(server, _profile(exitUrl: _warp));
      expect(server.asked, [_warp, _main]);
      expect(updated.userOverride?.exitUrl, isNull);
      expect(updated.exits?.current, ExitRole.main);
      expect(ExitChoice.fellBack(_profile(exitUrl: _warp), updated), isTrue);
    });

    test('not allowed or gone: the same', () async {
      for (final status in [403, 410]) {
        final server = _Server({_warp: _Answer.status(status), _main: _mainAnswer});
        final updated = await update(server, _profile(exitUrl: _warp));
        expect(updated.userOverride?.exitUrl, isNull, reason: '$status');
      }
    });

    test('the server stopped sending the pair: the same', () async {
      final server = _Server({_warp: const _Answer.ok({}), _main: _mainAnswer});
      final updated = await update(server, _profile(exitUrl: _warp));
      expect(server.asked, [_warp, _main]);
      expect(updated.userOverride?.exitUrl, isNull);
    });

    test('the pair is not understood any more: the same', () async {
      final server = _Server({
        _warp: const _Answer.ok({'profile-exits': 'v=9'}),
        _main: _mainAnswer,
      });
      expect((await update(server, _profile(exitUrl: _warp))).userOverride?.exitUrl, isNull);
    });

    test('the ranking of the pair is not carried to the home link, and is read again', () async {
      final server = _Server({
        _warp: const _Answer.status(404),
        _main: _Answer.ok({'profile-exits': _pair(cur: 'main', alt: 'warp', url: _warp)}),
      });
      final updated = await update(server, _profile(exitUrl: _warp));
      expect(updated.populatedHeaders, isNot(contains('profile-policy')));
    });

    test('a server error or no network is a failed update, and the way out stays', () async {
      for (final answers in <Map<String, _Answer>>[
        {_warp: const _Answer.status(500), _main: _mainAnswer},
        {_warp: const _Answer.status(503), _main: _mainAnswer},
        {_main: _mainAnswer},
      ]) {
        final server = _Server(answers);
        await updateFails(server, _profile(exitUrl: _warp));
        expect(server.asked, [_warp], reason: 'no fall back on $answers');
      }
    });

    test('if the home link fails too, the update fails', () async {
      final server = _Server({_warp: const _Answer.status(404), _main: const _Answer.status(500)});
      await updateFails(server, _profile(exitUrl: _warp));
    });
  });

  group('the user takes the other way out', () {
    test('the pair is loaded, confirmed and stored with its link', () async {
      final server = _Server({_warp: _warpAnswer});
      final profile = _profile(
        headers: {'profile-exits': _pair(cur: 'main', alt: 'warp', url: _warp)},
      ).copyWith(userOverride: const UserOverride(exitUrl: _warp));
      final updated = await update(server, profile, switchTo: ExitRole.warp);
      expect(server.asked, [_warp]);
      expect(updated.userOverride?.exitUrl, _warp);
      expect(updated.exits?.current, ExitRole.warp);
      expect(updated.populatedHeaders, isNot(contains('profile-policy')), reason: 'the ranking was the main one');
    });

    test('back: the home link is loaded', () async {
      final server = _Server({_main: _mainAnswer});
      final updated = await update(server, _profile(), switchTo: ExitRole.main);
      expect(server.asked, [_main]);
      expect(updated.userOverride?.exitUrl, isNull);
    });

    test('a subscription that does not load fails the switch, with no fall back', () async {
      for (final answer in [const _Answer.status(404), const _Answer.status(500)]) {
        final server = _Server({_warp: answer, _main: _mainAnswer});
        final failure = await updateFails(server, _profile(exitUrl: _warp), switchTo: ExitRole.warp);
        expect(failure, isNot(isA<ProfileCancelByUserFailure>()));
        expect(server.asked, [_warp]);
      }
    });

    test('a subscription that is not the way out asked for fails the switch', () async {
      // asked for warp, the server says the link is main
      final server = _Server({_warp: _mainAnswer});
      expect(
        await updateFails(server, _profile(exitUrl: _warp), switchTo: ExitRole.warp),
        isA<ProfileExitUnavailableFailure>(),
      );
      // no pair at all
      final bare = _Server({_warp: const _Answer.ok({})});
      expect(
        await updateFails(bare, _profile(exitUrl: _warp), switchTo: ExitRole.warp),
        isA<ProfileExitUnavailableFailure>(),
      );
    });
  });

  group('what is sent to the core', () {
    String overrideOf(RemoteProfileEntity profile) => profile.profileOverride();
    Map<String, dynamic> decoded(String text) => jsonDecode(text) as Map<String, dynamic>;

    test('the way out in use, and never the pair or its link', () {
      final onMain = _profile(
        headers: {'profile-exits': _pair(cur: 'main', alt: 'warp', url: _warp)},
      );
      final text = overrideOf(onMain);
      expect(decoded(text)['exit-choice'], 'main');
      expect(text, isNot(contains('profile-exits')));
      expect(text, isNot(contains(_b64(_warp))));
      expect(text, isNot(contains('warp-token')));

      final onWarp = _profile(
        exitUrl: _warp,
        headers: {'profile-exits': _pair(cur: 'warp', alt: 'main', url: _main)},
      );
      expect(decoded(overrideOf(onWarp))['exit-choice'], 'warp');
      expect(overrideOf(onWarp), isNot(contains('warp-token')));
      expect(overrideOf(onWarp), isNot(contains('main-token')));
    });

    test('nothing without a pair', () {
      expect(decoded(overrideOf(_profile()))['exit-choice'], isNull);
    });

    test('a header cannot set it by itself', () {
      final text = overrideOf(_profile(headers: {'exit-choice': 'warp'}));
      expect(decoded(text)['exit-choice'], isNull);
    });
  });

  group('the headers of an answer', () {
    test('the pair comes only from the answer of the server, not from a text', () {
      final headers = ProfileParser.populateHeaders(
        content: '# profile-exits: v=1;cur=main;alt=warp;alt-url=${_b64(_warp)}\n{}',
      ).getOrElse((_) => throw StateError('no headers'));
      expect(headers, isNot(contains(ProfileExits.headerName)));
    });

    test('a pair that is not understood is dropped', () {
      for (final bad in ['v=2;cur=main;alt=warp;alt-url=${_b64(_warp)}', 'v=1;cur=main;alt=warp;alt-url=###']) {
        final headers = ProfileParser.populateHeaders(
          content: '{}',
          remoteHeaders: {'profile-exits': bad},
        ).getOrElse((_) => throw StateError('no headers'));
        expect(headers, isNot(contains(ProfileExits.headerName)), reason: bad);
      }
    });
  });

  test('which failures say the pair is gone', () {
    DioException http(int status) => DioException(
      requestOptions: RequestOptions(path: _warp),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: _warp),
        statusCode: status,
      ),
    );
    for (final status in [403, 404, 410]) {
      expect(ProfileParser.exitGone(ProfileFailure.unexpected(http(status))), isTrue, reason: '$status');
    }
    for (final status in [400, 401, 429, 500, 502, 503]) {
      expect(ProfileParser.exitGone(ProfileFailure.unexpected(http(status))), isFalse, reason: '$status');
    }
    expect(
      ProfileParser.exitGone(
        ProfileFailure.unexpected(
          DioException(
            requestOptions: RequestOptions(path: _warp),
            type: DioExceptionType.connectionTimeout,
          ),
        ),
      ),
      isFalse,
    );
    expect(ProfileParser.exitGone(const ProfileFailure.unexpected('x')), isFalse);
    expect(ProfileParser.exitGone(const ProfileFailure.cancelByUser()), isFalse);
    expect(ProfileParser.exitGone(const ProfileFailure.invalidUrl()), isFalse);
  });
}
