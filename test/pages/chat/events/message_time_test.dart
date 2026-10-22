import 'package:twake_chat/config/localizations/localization_service.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/pages/chat/events/message_time.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_localized_locales/flutter_localized_locales.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

// ignore: implementation_imports — TimelineChunk is not yet exported publicly
import 'package:matrix/src/models/timeline_chunk.dart';

import '../../../fake_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'MessageTime timestamp and edited label use the ambient 2x text scaler',
    (tester) async {
      final client = Client(
        'message-time-test',
        httpClient: FakeMatrixApi(),
        database: MockDatabase(),
      );
      final room = Room(
        client: client,
        id: '!message-time:example.org',
        membership: Membership.join,
      );
      const eventId = r'$message:example.org';
      final event = Event(
        senderId: '@alice:example.org',
        type: EventTypes.Message,
        room: room,
        eventId: eventId,
        content: {'body': 'A message', 'msgtype': 'm.text'},
        originServerTs: DateTime(2024, 1, 1, 12, 34),
      );
      final edit = Event(
        senderId: '@alice:example.org',
        type: EventTypes.Message,
        room: room,
        eventId: r'$message-edit:example.org',
        content: {
          'body': '* An edited message',
          'msgtype': 'm.text',
          'm.new_content': {'body': 'An edited message', 'msgtype': 'm.text'},
          'm.relates_to': {
            'rel_type': RelationshipTypes.edit,
            'event_id': eventId,
          },
        },
        originServerTs: DateTime(2024, 1, 1, 12, 35),
      );
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: []),
      );
      timeline.addAggregatedEvent(edit);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            LocaleNamesLocalizationsDelegate(),
            L10n.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: LocalizationService.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: MessageTime(
              event: event,
              showSeenIcon: false,
              timeline: timeline,
              timelineOverlayMessage: false,
              room: room,
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('edited '), findsOneWidget);
      expect(find.text('12:35'), findsOneWidget);
      for (final label in ['edited ', '12:35']) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.text(label),
            matching: find.byType(RichText),
          ),
        );
        expect(paragraph.textScaler.scale(10), 20);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
