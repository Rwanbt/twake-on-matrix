import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:twake_chat/data/network/interceptor/authorization_interceptor.dart';

void main() {
  test('authorization request attaches a bearer token without logging it', () {
    const secret = 'SECRET_BEARER_TOKEN_NEVER_LOG';
    final interceptor = AuthorizationInterceptor()..accessToken = secret;
    final options = RequestOptions(path: '/disposable');
    final logger = Logs();
    final before = logger.outputEvents.length;

    interceptor.onRequest(options, RequestInterceptorHandler());
    expect(options.headers[HttpHeaders.authorizationHeader], 'Bearer $secret');
    final logged = logger.outputEvents
        .skip(before)
        .map((event) => event.toFormattedString())
        .join('\n');
    expect(logged, isNot(contains(secret)));
    expect(logged, isNot(contains('Bearer $secret')));

    final error = DioException(
      requestOptions: options,
      response: Response<dynamic>(requestOptions: options, statusCode: 401),
      error: 'Bearer $secret',
    );
    final beforeError = logger.outputEvents.length;
    interceptor.onError(error, ErrorInterceptorHandler());
    final errorLogs = logger.outputEvents
        .skip(beforeError)
        .map((event) => event.toFormattedString())
        .join('\n');
    expect(errorLogs, contains('HTTP 401'));
    expect(errorLogs, isNot(contains(secret)));
  });
}
