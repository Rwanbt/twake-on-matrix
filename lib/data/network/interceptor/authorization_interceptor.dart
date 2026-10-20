import 'dart:io';

import 'package:dio/dio.dart';
import 'package:matrix/matrix.dart';

class AuthorizationInterceptor extends InterceptorsWrapper {
  AuthorizationInterceptor();

  String? accessToken;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers[HttpHeaders.authorizationHeader] = _bearerToken;
    // Never log bearer credentials, even at verbose/debug SDK log levels.
    Logs().d('AuthorizationInterceptor::onRequest: authorization attached');
    super.onRequest(options, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 401) {
      Logs().wtf('AuthorizationInterceptor::onError: HTTP 401');
    } else {
      // DioException.error/requestOptions can contain Authorization headers.
      // Preserve the status and severity without serializing sensitive data.
      final status = err.response?.statusCode;
      Logs().e(
        'AuthorizationInterceptor::onError: HTTP ${status ?? 'unknown'}',
      );
    }
    super.onError(err, handler);
  }

  String get _bearerToken => 'Bearer $accessToken';
}
