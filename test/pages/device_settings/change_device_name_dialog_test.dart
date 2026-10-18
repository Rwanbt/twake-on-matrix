import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linagora_design_flutter/linagora_design_flutter.dart';

import 'package:twake_chat/config/localizations/localization_service.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/pages/device_settings/change_device_name_dialog.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData(extensions: [LinagoraTextThemeExtension.material()]),
    locale: const Locale('en'),
    localizationsDelegates: const [
      L10n.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: LocalizationService.supportedLocales,
    home: Scaffold(body: child),
  );
}

const _errorMessage = "We couldn't save the changes. Try again later";

Future<void> _pumpView(
  WidgetTester tester, {
  String initialName = 'My laptop',
  required Future<void> Function(String) onSave,
}) {
  return tester.pumpWidget(
    _wrap(ChangeDeviceNameView(initialName: initialName, onSave: onSave)),
  );
}

Future<void> _pumpAndTapSave(
  WidgetTester tester, {
  required Future<void> Function(String) onSave,
  required String newName,
}) async {
  await _pumpView(tester, onSave: onSave);
  await tester.enterText(find.byType(TextField), newName);
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

Future<void> _prefillsInputWithCurrentDeviceName(WidgetTester tester) async {
  await _pumpView(tester, initialName: 'My laptop', onSave: (_) async {});

  expect(tester.takeException(), isNull);
  expect(find.text('My laptop'), findsOneWidget);
}

Future<void> _savingWithNonEmptyNameCallsOnSave(WidgetTester tester) async {
  String? savedName;
  await _pumpAndTapSave(
    tester,
    onSave: (name) async => savedName = name,
    newName: 'New name',
  );

  expect(savedName, 'New name');
}

Future<void> _savingEmptyNameIsNoOp(WidgetTester tester) async {
  var saveCalled = false;
  await _pumpAndTapSave(
    tester,
    onSave: (_) async => saveCalled = true,
    newName: '   ',
  );

  expect(saveCalled, isFalse);
  expect(find.byType(ChangeDeviceNameView), findsOneWidget);
  expect(
    tester.widget<LinagoraTextField>(find.byType(LinagoraTextField)).errorText,
    isNotEmpty,
  );
}

Future<void> _submittingWithKeyboardSavesExactlyOnce(
  WidgetTester tester,
) async {
  var calls = 0;
  String? submitted;
  await _pumpView(
    tester,
    onSave: (name) async {
      calls++;
      submitted = name;
    },
  );
  await tester.enterText(find.byType(TextField), '  Trusted laptop  ');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  expect(submitted, 'Trusted laptop');
  expect(calls, 1);
}

Future<void> _invalidKeyboardSubmitRetainsInput(WidgetTester tester) async {
  var calls = 0;
  await _pumpView(tester, onSave: (_) async => calls++);
  await tester.enterText(find.byType(TextField), '   ');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  expect(calls, 0);
  expect(find.byType(ChangeDeviceNameView), findsOneWidget);
  expect(
    tester.widget<TextField>(find.byType(TextField)).controller!.text,
    '   ',
  );
}

Future<void> _compactScreenKeepsDeviceNameKeyboardWorkflow(
  WidgetTester tester,
) async {
  // A narrow mobile viewport must keep the control usable and its field
  // accessible through the keyboard, not just render on desktop.
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  String? submitted;
  await _pumpView(tester, onSave: (name) async => submitted = name);
  await tester.pumpAndSettle();

  expect(tester.takeException(), isNull);
  expect(
    tester.getSize(find.byType(ChangeDeviceNameView)).width,
    lessThanOrEqualTo(320),
  );
  final field = tester.widget<TextField>(find.byType(TextField));
  expect(field.textInputAction, TextInputAction.done);

  await tester.enterText(find.byType(TextField), 'Compact phone');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  expect(submitted, 'Compact phone');
}

Future<void> _onSaveErrorKeepsModalOpenWithError(WidgetTester tester) async {
  await _pumpAndTapSave(
    tester,
    onSave: (_) async => throw Exception('network error'),
    newName: 'New name',
  );

  expect(find.text(_errorMessage), findsOneWidget);
  expect(find.text('New name'), findsOneWidget);
  expect(find.byType(ChangeDeviceNameView), findsOneWidget);
}

Future<void> _editingAfterErrorClearsErrorMessage(WidgetTester tester) async {
  await _pumpAndTapSave(
    tester,
    onSave: (_) async => throw Exception('network error'),
    newName: 'New name',
  );
  expect(find.text(_errorMessage), findsOneWidget);

  await tester.enterText(find.byType(TextField), 'New name 2');
  await tester.pump();

  expect(find.text(_errorMessage), findsNothing);
}

void main() {
  testWidgets(
    'prefills the input with the current device name',
    _prefillsInputWithCurrentDeviceName,
  );

  testWidgets(
    'saving with a non-empty name calls onSave with it',
    _savingWithNonEmptyNameCallsOnSave,
  );

  testWidgets(
    'saving an empty name is a no-op (does not call onSave)',
    _savingEmptyNameIsNoOp,
  );
  testWidgets(
    'the keyboard Done action saves one trimmed device name',
    _submittingWithKeyboardSavesExactlyOnce,
  );
  testWidgets(
    'invalid keyboard submission preserves the dialog and entered content',
    _invalidKeyboardSubmitRetainsInput,
  );

  testWidgets(
    'compact 320px layout permits accessible keyboard submission',
    _compactScreenKeepsDeviceNameKeyboardWorkflow,
  );

  testWidgets(
    'when onSave throws, the modal stays open, text is preserved, and the '
    'error message is shown',
    _onSaveErrorKeepsModalOpenWithError,
  );

  testWidgets(
    'editing after an error clears the error message',
    _editingAfterErrorClearsErrorMessage,
  );
}
