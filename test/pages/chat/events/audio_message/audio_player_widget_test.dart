import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:twake_chat/pages/chat/events/audio_message/audio_player_widget.dart';
import 'package:twake_chat/widgets/matrix.dart';

// ignore: implementation_imports — TimelineChunk is not yet exported publicly
import 'package:matrix/src/models/timeline_chunk.dart';

import '../../../../fake_client.dart';

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _FakeMatrixState extends Fake implements MatrixState {
  final _audioPlayer = _FakeAudioPlayer();
  final _currentAudioStatus = ValueNotifier(AudioPlayerStatus.notDownloaded);
  final _voiceMessageEvent = ValueNotifier<Event?>(null);

  @override
  AudioPlayer get audioPlayer => _audioPlayer;

  @override
  ValueNotifier<AudioPlayerStatus> get currentAudioStatus =>
      _currentAudioStatus;

  @override
  ValueNotifier<Event?> get voiceMessageEvent => _voiceMessageEvent;

  void dispose() {
    _currentAudioStatus.dispose();
    _voiceMessageEvent.dispose();
  }
}

void main() {
  testWidgets('audio filename and duration respect the ambient 2x text scaler',
      (
    tester,
  ) async {
    final client = Client(
      'audio-player-test',
      httpClient: FakeMatrixApi(),
      database: MockDatabase(),
    );
    final room = Room(
      client: client,
      id: '!audio-player:example.org',
      membership: Membership.join,
    );
    final event = Event(
      senderId: '@alice:example.org',
      type: EventTypes.Message,
      room: room,
      eventId: r'$audio:example.org',
      content: {
        'body': 'voice-note.ogg',
        'msgtype': 'm.audio',
        'org.matrix.msc1767.audio': {'duration': 5000},
      },
      originServerTs: DateTime(2024, 1, 1, 12, 34),
    );
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    final matrixState = _FakeMatrixState();
    addTearDown(matrixState.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Provider<MatrixState>.value(
          value: matrixState,
          child: Scaffold(body: AudioPlayerWidget(event, timeline: timeline)),
        ),
      ),
    );
    await tester.pump();

    for (final label in ['voice-note.ogg', '00:05']) {
      expect(find.text(label), findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text(label),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.textScaler.scale(10), 20);
    }
    expect(tester.takeException(), isNull);
  });
}
