import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:twake_chat/data/network/interceptor/authorization_interceptor.dart';

void main() {
  test(
    'authorization request attaches a bearer token without logging it',
    () async {
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
      final errorHandler = ErrorInterceptorHandler();
      interceptor.onError(error, errorHandler);
      // Dio's interceptor handler completes with the original error. Consume it
      // deterministically so the test does not produce an unhandled async error.
      await expectLater(errorHandler.future, throwsA(isA<DioException>()));
      final errorLogs = logger.outputEvents
          .skip(beforeError)
          .map((event) => event.toFormattedString())
          .join('\n');
      expect(errorLogs, contains('HTTP 401'));
      expect(errorLogs, isNot(contains(secret)));
    },
  );
}
