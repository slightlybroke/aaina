import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart' hide IosAudioCategory;

abstract class LiveAudio {
  bool get supported;
  Future<bool> permission();
  Future<void> prepare();
  Future<Stream<Uint8List>> capture();
  Future<void> play(Uint8List bytes);
  Future<void> flush();
  Future<void> stop();
  Future<void> dispose();
}

class NativeLiveAudio implements LiveAudio {
  final recorder = AudioRecorder();
  bool prepared = false;
  int lifecycle = 0;
  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  @override
  Future<bool> permission() => recorder.hasPermission();
  @override
  Future<void> prepare() async {
    final epoch = lifecycle;
    await FlutterPcmSound.setLogLevel(LogLevel.none);
    await FlutterPcmSound.setup(
      sampleRate: 24000,
      channelCount: 1,
      iosAudioCategory: IosAudioCategory.playAndRecord,
    );
    if (epoch != lifecycle) {
      await FlutterPcmSound.release();
      return;
    }
    prepared = true;
  }

  @override
  Future<Stream<Uint8List>> capture() => recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      streamBufferSize: 3200,
      androidConfig: AndroidRecordConfig(
        manageBluetooth: false,
        audioSource: AndroidAudioSource.voiceCommunication,
        speakerphone: true,
        audioManagerMode: AudioManagerMode.modeInCommunication,
      ),
    ),
  );
  @override
  Future<void> play(Uint8List bytes) async {
    if (!prepared) return;
    await FlutterPcmSound.feed(
      PcmArrayInt16(bytes: ByteData.sublistView(bytes)),
    );
  }

  @override
  Future<void> flush() async {
    if (!prepared) return;
    final epoch = lifecycle;
    prepared = false;
    await FlutterPcmSound.release();
    if (epoch == lifecycle) await prepare();
  }

  @override
  Future<void> stop() async {
    lifecycle++;
    try {
      await recorder.stop();
    } finally {
      if (prepared) {
        prepared = false;
        await FlutterPcmSound.release();
      }
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      await recorder.dispose();
    }
  }
}
