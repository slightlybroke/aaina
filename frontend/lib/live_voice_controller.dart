import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'live_audio.dart';

abstract class VoiceSocket {
  Stream<dynamic> get messages;
  void audio(Uint8List bytes);
  Future<void> close();
}

class AppVoiceSocket implements VoiceSocket {
  final WebSocketChannel channel;
  AppVoiceSocket(this.channel);
  static Future<VoiceSocket> connect(
    AnalysisApi api, {
    bool useSavedPreferences = false,
    bool useBeautyMemory = false,
  }) async {
    final headers = await api.headers();
    final uri = Uri.parse('${api.baseUrl}/v1/looks/live');
    final channel = WebSocketChannel.connect(
      uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws'),
    );
    try {
      await channel.ready.timeout(const Duration(seconds: 15));
      channel.sink.add(
        jsonEncode({
          'access_token': headers['Authorization']!.substring(7),
          'consent_version': 'gemini-live-v1',
          'use_saved_preferences': useSavedPreferences,
          'use_beauty_memory': useBeautyMemory,
        }),
      );
      return AppVoiceSocket(channel);
    } catch (_) {
      await channel.sink.close();
      rethrow;
    }
  }

  @override
  Stream<dynamic> get messages => channel.stream;
  @override
  void audio(Uint8List bytes) => channel.sink.add(bytes);
  @override
  Future<void> close() => channel.sink.close();
}

class LiveVoiceController extends ChangeNotifier {
  final LiveAudio audio;
  final Future<VoiceSocket> Function() connect;
  String status = 'idle';
  String? error;
  bool foreground = true;
  final List<Map<String, dynamic>> transcript = [];
  Map<String, dynamic>? plan;
  StreamSubscription<dynamic>? incoming;
  StreamSubscription<Uint8List>? microphone;
  VoiceSocket? socket;
  Completer<bool>? ready;
  Future<void> playback = Future.value();
  int generation = 0, audioGeneration = 0;
  bool disposed = false;
  Future<void>? stopping;
  int? userLine, assistantLine;
  LiveVoiceController({required this.audio, required this.connect});
  bool get active =>
      status == 'connecting' || status == 'listening' || status == 'stopping';
  void changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> start() async {
    if (active || disposed) return;
    if (!audio.supported) {
      error =
          'Continuous Talk is not available on this platform yet. Use Chat.';
      changed();
      return;
    }
    final epoch = ++generation;
    status = 'connecting';
    error = null;
    plan = null;
    transcript.clear();
    userLine = null;
    assistantLine = null;
    changed();
    try {
      final allowed = await audio.permission();
      if (disposed || epoch != generation) return;
      if (!allowed) {
        throw StateError(
          'Microphone permission was denied. Allow it in app settings or use Chat.',
        );
      }
      if (!foreground) {
        await stop();
        return;
      }
      await audio.prepare();
      if (disposed || epoch != generation) {
        await audio.stop();
        return;
      }
      final connected = await connect();
      if (disposed || epoch != generation) {
        await connected.close();
        return;
      }
      socket = connected;
      ready = Completer<bool>();
      incoming = connected.messages.listen(
        (event) => receive(event, epoch),
        onError: (_) =>
            fail('Voice connection failed. Start a new session or use Chat.'),
        onDone: () {
          if (active) {
            unawaited(
              stop(message: 'Session ended. Start a new session to continue.'),
            );
          }
        },
      );
      final accepted = await ready!.future.timeout(const Duration(seconds: 35));
      if (!accepted || disposed || epoch != generation) return;
      if (!foreground) {
        await stop();
        return;
      }
      final stream = await audio.capture();
      if (disposed || epoch != generation) {
        await audio.stop();
        return;
      }
      microphone = stream.listen(
        (bytes) {
          if (epoch == generation && active) {
            // Avoid large platform batches exceeding the relay frame budget.
            for (var offset = 0; offset < bytes.length; offset += 6400) {
              final end = offset + 6400 < bytes.length
                  ? offset + 6400
                  : bytes.length;
              socket?.audio(Uint8List.sublistView(bytes, offset, end));
            }
          }
        },
        onError: (_) =>
            fail('Microphone stopped unexpectedly. Restart Talk or use Chat.'),
      );
      status = 'listening';
      changed();
    } catch (e) {
      if (!disposed && epoch == generation) {
        await fail(
          e is StateError ? e.message : 'Could not start Talk. Check microphone permission, sign-in and Live model access.',
        );
      }
    }
  }

  void receive(dynamic event, int epoch) {
    if (disposed || epoch != generation) return;
    if (event is List<int>) {
      final bytes = Uint8List.fromList(event);
      final audioEpoch = audioGeneration;
      playback = playback
          .then((_) async {
            if (!disposed &&
                epoch == generation &&
                audioEpoch == audioGeneration) {
              await audio.play(bytes);
            }
          })
          .catchError((_) {
            unawaited(fail('Audio playback failed. Stop Talk or use Chat.'));
          });
      return;
    }
    try {
      final data = jsonDecode(event as String) as Map<String, dynamic>;
      switch (data['type']) {
        case 'ready':
          if (data['input_rate'] != 16000 || data['output_rate'] != 24000) {
            throw const FormatException();
          }
          if (!(ready?.isCompleted ?? true)) ready!.complete(true);
        case 'error':
          unawaited(fail(data['message'] as String));
        case 'ended':
          unawaited(stop(message: data['message'] as String));
        case 'interrupted':
          audioGeneration++;
          if (assistantLine != null) {
            transcript[assistantLine!]['interrupted'] = true;
          }
          assistantLine = null;
          playback = playback
              .then((_) async {
                if (!disposed && epoch == generation) {
                  await audio.flush();
                }
              })
              .catchError((_) {
                unawaited(fail('Could not interrupt playback. Restart Talk.'));
              });
        case 'transcript':
          final role = data['role'];
          final text = data['text'];
          if ((role != 'user' && role != 'assistant') || text is! String) {
            throw const FormatException();
          }
          final index = role == 'user' ? userLine : assistantLine;
          if (index == null) {
            transcript.add({'role': role, 'text': text});
            if (role == 'user') {
              userLine = transcript.length - 1;
            } else {
              assistantLine = transcript.length - 1;
            }
          } else {
            transcript[index]['text'] = '${transcript[index]['text']}$text';
          }
          if (transcript.fold<int>(
                0,
                (n, line) => n + (line['text'] as String).length,
              ) >
              24000) {
            unawaited(
              stop(message: 'Transcript limit reached. Start a new session.'),
            );
          }
        case 'turn_complete':
          userLine = null;
          assistantLine = null;
        case 'plan':
          plan = Map<String, dynamic>.from(data['plan']);
        case 'tool_cancelled':
          break;
        default:
          throw const FormatException();
      }
      changed();
    } catch (_) {
      unawaited(fail('Invalid voice-session data. Restart Talk or use Chat.'));
    }
  }

  Future<void> fail(String message) async {
    await stop();
    if (!disposed) {
      status = 'error';
      error = message;
      changed();
    }
  }

  Future<void> stop({String? message}) {
    if (stopping != null) return stopping!;
    final done = Completer<void>();
    stopping = done.future;
    generation++;
    audioGeneration++;
    status = 'stopping';
    if (!(ready?.isCompleted ?? true)) ready!.complete(false);
    final mic = microphone;
    microphone = null;
    final sub = incoming;
    incoming = null;
    final ws = socket;
    socket = null;
    unawaited(() async {
      await Future.wait(
        <Future<void> Function()>[
          () async {
            await mic?.cancel();
          },
          audio.stop,
          () async {
            await sub?.cancel();
          },
          () async {
            await ws?.close().timeout(const Duration(seconds: 2));
          },
          () async {
            await playback;
          },
        ].map((cleanup) async {
          try {
            await cleanup().timeout(const Duration(seconds: 2));
          } catch (_) {
            error = 'Some audio resources could not close normally. Leave Talk and retry.';
          }
        }),
      );
      if (message != null) error = message;
      status = 'stopped';
      stopping = null;
      changed();
      done.complete();
    }());
    changed();
    return done.future;
  }

  void background(bool value) {
    foreground = value;
    if (!value && active) {
      unawaited(
        stop(
          message: 'Microphone stopped when the app left the foreground. Start Talk again to resume.',
        ),
      );
    }
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(stop().whenComplete(audio.dispose));
    super.dispose();
  }
}
