import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/pages/chat/chat_input_row_send_btn.dart';
import 'package:twake_chat/presentation/mixins/audio_mixin.dart';
import 'package:twake_chat/utils/platform_infos.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('web voice recording controls expose actionable semantics', (
    tester,
  ) async {
    PlatformInfos.isTestingForWeb = true;
    addTearDown(() => PlatformInfos.isTestingForWeb = false);
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    final inputText = ValueNotifier('');
    final recordingState = ValueNotifier(AudioRecordState.initial);
    addTearDown(inputText.dispose);
    addTearDown(recordingState.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: ChatInputRowSendBtn(
            inputText: inputText,
            audioRecordStateNotifier: recordingState,
            onTap: () {},
            onTapRecorderWeb: () {},
            onDeleteRecorderWeb: () {},
            onFinishRecorderWeb: () {},
          ),
        ),
      ),
    );

    expect(find.byTooltip('Voice message'), findsOneWidget);
    final recordNode = tester.getSemantics(find.byTooltip('Voice message'));
    final recordData = recordNode.getSemanticsData();
    expect(recordData.tooltip, 'Voice message');
    expect(recordData.hasAction(SemanticsAction.tap), isTrue);
    expect(tester.getSize(find.byTooltip('Voice message')), const Size(44, 44));

    recordingState.value = AudioRecordState.recording;
    await tester.pump();

    expect(find.byTooltip('Delete'), findsOneWidget);
    expect(find.byTooltip('Send audio'), findsOneWidget);
    for (final label in ['Delete', 'Send audio']) {
      final controlFinder = find.byTooltip(label);
      final controlNode = tester.getSemantics(controlFinder);
      final data = controlNode.getSemanticsData();
      expect(data.tooltip, label);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
    }
    for (final label in ['Delete', 'Send audio']) {
      final size = tester.getSize(find.byTooltip(label));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    expect(tester.takeException(), isNull);
  });
}
