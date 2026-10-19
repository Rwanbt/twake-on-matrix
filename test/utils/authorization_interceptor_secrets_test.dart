import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:twake_chat/data/network/interceptor/authorization_interceptor.dart';

// Dio's public next() callback is the error propagation contract. A test
// handler can capture it without reading _BaseHandler.future (protected).
class _CapturingErrorHandler extends ErrorInterceptorHandler {
  DioException? forwardedError;

  @override
  void next(DioException error) {
    forwardedError = error;
  }
}

void main() {
  test(
    'authorization request attaches a bearer token without logging it',
    () {
      const secret = 'SECRET_BEARER_TOKEN_NEVER_LOG';
      final interceptor = AuthorizationInterceptor()..accessToken = secret;
      final options = RequestOptions(path: '/disposable');
      final logger = Logs();
      final before = logger.outputEvents.length;

      interceptor.onRequest(options, RequestInterceptorHandler());
      expect(
        options.headers[HttpHeaders.authorizationHeader],
        'Bearer $secret',
      );

      final error = DioException(
        requestOptions: options,
        response: Response<dynamic>(requestOptions: options, statusCode: 401),
        error: 'Bearer $secret',
      );
      final handler = _CapturingErrorHandler();
      interceptor.onError(error, handler);
      expect(handler.forwardedError, same(error));
      expect(handler.forwardedError?.response?.statusCode, 401);

      final logged = logger.outputEvents
          .skip(before)
          .map((event) => event.toFormattedString())
          .join('\n');
      expect(logged, contains('HTTP 401'));
      expect(logged, isNot(contains(secret)));
      expect(logged, isNot(contains('Bearer $secret')));
    },
  );
}
