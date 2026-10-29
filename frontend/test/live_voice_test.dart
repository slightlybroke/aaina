import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:beauty_intelligence/live_audio.dart';
import 'package:beauty_intelligence/live_voice_controller.dart';
import 'package:beauty_intelligence/live_talk_page.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show ClientStub;

class AudioFake implements LiveAudio {
  bool allow = true;
  @override
  bool supported = true;
  int captures = 0, stops = 0, flushes = 0, plays = 0;
  final mic = StreamController<Uint8List>.broadcast();
  Completer<bool>? permissionWait;
  @override
  Future<bool> permission() async =>
      permissionWait == null ? allow : await permissionWait!.future;
  @override
  Future<void> prepare() async {}
  @override
  Future<Stream<Uint8List>> capture() async {
    captures++;
    return mic.stream;
  }

  @override
  Future<void> play(Uint8List bytes) async {
    plays++;
  }

  @override
  Future<void> flush() async {
    flushes++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    await mic.close();
  }
}

class SocketFake implements VoiceSocket {
  late final StreamController<dynamic> stream;
  bool closed = false;
  final List<Uint8List> sent = [];
  SocketFake() {
    stream = StreamController<dynamic>(
      onListen: () => stream.add(
        jsonEncode({
          'type': 'ready',
          'input_rate': 16000,
          'output_rate': 24000,
        }),
      ),
    );
  }
  void event(Map<String, dynamic> e) => stream.add(jsonEncode(e));
  @override
  Stream<dynamic> get messages => stream.stream;
  @override
  void audio(Uint8List bytes) => sent.add(bytes);
  @override
  Future<void> close() async {
    closed = true;
    await stream.close();
  }
}

Future<void> tick() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('Permission denial never connects or captures', () async {
    final audio = AudioFake()..allow = false;
    var connects = 0;
    final c = LiveVoiceController(
      audio: audio,
      connect: () async {
        connects++;
        return SocketFake();
      },
    );
    await c.start();
    expect(connects, 0);
    expect(audio.captures, 0);
    expect(c.error, contains('permission'));
    c.dispose();
    await tick();
  });
  test('Continuous microphone, transcripts, interruption and stop release resources', () async {
    final audio = AudioFake();
    final socket = SocketFake();
    final c = LiveVoiceController(audio: audio, connect: () async => socket);
    await c.start();
    expect(c.status, 'listening');
    audio.mic.add(Uint8List(3200));
    await tick();
    expect(socket.sent.length, 1);
    socket.event({'type': 'transcript', 'role': 'user', 'text': 'A natural '});
    socket.event({'type': 'transcript', 'role': 'user', 'text': 'look'});
    socket.event({
      'type': 'transcript',
      'role': 'assistant',
      'text': 'Consider your recorded products.',
    });
    socket.stream.add(Uint8List(100));
    await tick();
    expect(audio.plays, 1);
    // Echo correction must retain double-talk; do not hide it by muting input.
    audio.mic.add(Uint8List(3200));
    await tick();
    expect(socket.sent.length, 2);
    socket.event({'type': 'interrupted'});
    await tick();
    expect(c.transcript[0]['text'], 'A natural look');
    expect(c.transcript[1]['interrupted'], true);
    expect(audio.flushes, 1);
    audio.mic.add(Uint8List(3200));
    await tick();
    expect(socket.sent.length, 3);
    await c.stop();
    expect(socket.closed, true);
    expect(audio.stops, greaterThan(0));
    expect(c.active, false);
    c.dispose();
    await tick();
  });
  test(
    'Stopping during permission request prevents a late microphone start',
    () async {
      final audio = AudioFake()..permissionWait = Completer<bool>();
      var connections = 0;
      final c = LiveVoiceController(
        audio: audio,
        connect: () async {
          connections++;
          return SocketFake();
        },
      );
      final start = c.start();
      await tick();
      await c.stop();
      audio.permissionWait!.complete(true);
      await start;
      expect(connections, 0);
      expect(audio.captures, 0);
      c.dispose();
      await tick();
    },
  );
  test('Background ends microphone session and never auto resumes', () async {
    final audio = AudioFake();
    final socket = SocketFake();
    final c = LiveVoiceController(audio: audio, connect: () async => socket);
    await c.start();
    c.background(false);
    await tick();
    expect(socket.closed, true);
    expect(c.active, false);
    c.background(true);
    expect(audio.captures, 1);
    c.dispose();
    await tick();
  });
  testWidgets(
    'Talk requires consent and Start; transcript remains visible after Stop',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final audio = AudioFake();
      final socket = SocketFake();
      final c = LiveVoiceController(audio: audio, connect: () async => socket);
      await tester.pumpWidget(
        BeautyApp(
          home: LiveTalkPage(
            api: AnalysisApi(ClientStub(), 'http://test'),
            controller: c,
          ),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start Talk'),
            )
            .onPressed,
        null,
      );
      expect(audio.captures, 0);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start Talk'));
      await tester.pumpAndSettle();
      socket.event({'type': 'transcript', 'role': 'user', 'text': 'Hello'});
      await tester.pumpAndSettle();
      expect(find.text('You: Hello'), findsOneWidget);
      await tester.tap(find.text('Stop Talk'));
      await tester.pump();
      expect(c.status, anyOf('stopping', 'stopped'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('You: Hello'), findsOneWidget);
      expect(
        socket.closed,
        true,
        reason: 'status=${c.status}, stops=${audio.stops}, error=${c.error}',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
