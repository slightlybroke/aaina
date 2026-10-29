import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'live_audio.dart';
import 'live_voice_controller.dart';

class LiveTalkPage extends StatefulWidget {
  final AnalysisApi api;
  final LiveVoiceController? controller;
  const LiveTalkPage({super.key, required this.api, this.controller});
  @override
  State<LiveTalkPage> createState() => _LiveTalkPageState();
}

class _LiveTalkPageState extends State<LiveTalkPage>
    with WidgetsBindingObserver {
  late final LiveVoiceController voice;
  bool consent = false, useSavedPreferences = false, useMemory = false;
  @override
  void initState() {
    super.initState();
    voice =
        widget.controller ??
        LiveVoiceController(
          audio: NativeLiveAudio(),
          connect: () => AppVoiceSocket.connect(
            widget.api,
            useSavedPreferences: useSavedPreferences,
            useBeautyMemory: useMemory,
          ),
        );
    WidgetsBinding.instance.addObserver(this);
    voice.addListener(update);
  }

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A permission dialog can briefly mark an app inactive before any microphone exists.
    if (state == AppLifecycleState.inactive && voice.status == 'connecting') {
      return;
    }
    voice.background(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    voice.removeListener(update);
    voice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Talk with Gemini — Live')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Continuous voice: speak naturally, hear replies, and interrupt by speaking. Your words and Gemini’s responses appear below. Chat remains available by going back.',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I agree to stream microphone audio and relevant makeup metadata to Google Gemini under this app’s API account terms. API use may consume credits. No photos, skin records, journal or routine notes are shared automatically. Opted-in Beauty Memory can include your recorded observations.',
              ),
              value: consent,
              onChanged: (v) {
                setState(() => consent = v == true);
                if (!consent) unawaited(voice.stop());
              },
            ),
            const Text(
              'Microphone stays on only during an active session. Stop, leave this screen, or background the app to end it. This app saves no audio or transcript files. Google’s data terms apply. Transcript text may include generated speech cut off by an interruption.',
            ),
            SwitchListTile(
              title: const Text('Use shared Beauty Memory'),
              subtitle: const Text(
                'Relevant confirmed entries only. Voice does not automatically save memories.',
              ),
              value: useMemory,
              onChanged: voice.active
                  ? null
                  : (v) => setState(() => useMemory = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use saved makeup preferences'),
              subtitle: const Text(
                'Optional, read once when starting Talk. Stop and start again after editing or deleting preferences.',
              ),
              value: useSavedPreferences,
              onChanged: voice.active
                  ? null
                  : (v) => setState(() => useSavedPreferences = v),
            ),
            if ((voice.plan?['saved_preference_fields'] as List? ?? [])
                .isNotEmpty)
              Text(
                'Saved defaults applied: ${(voice.plan!['saved_preference_fields'] as List).map((f) => f.toString().replaceAll('_', ' ')).join(', ')}',
              ),
            const Text(
              'Live spoken styling suggestions are AI-generated and may be mistaken. Recorded-product cards are the source of inventory facts; no exact try-on or medical advice is provided.',
            ),
            if (!voice.audio.supported)
              const Text(
                'Live voice is not available on this platform yet. Use typed Chat; Android is the initial validation target.',
              ),
            const SizedBox(height: 12),
            Text(
              'Session: ${voice.status}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (voice.status == 'connecting') const LinearProgressIndicator(),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: consent && voice.audio.supported && !voice.active
                      ? voice.start
                      : null,
                  icon: const Icon(Icons.mic),
                  label: const Text('Start Talk'),
                ),
                OutlinedButton.icon(
                  onPressed: voice.active ? () => voice.stop() : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Talk'),
                ),
              ],
            ),
            if (voice.error != null)
              Text(
                voice.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const Divider(),
            Text(
              'Live transcript',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (voice.transcript.isEmpty)
              const Text(
                'Start Talk and speak. No microphone recording starts automatically.',
              ),
            for (final line in voice.transcript)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '${line['role'] == 'user' ? 'You' : 'Gemini'}${line['interrupted'] == true ? ' (interrupted)' : ''}: ${line['text']}',
                  ),
                ),
              ),
            if (voice.plan != null) ...[
              const Divider(),
              const Text('Recorded-product plan (backend verified)'),
              for (final entry in voice.plan!['suggestions'] as List)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${entry['category']}: ${entry['product']['name']}',
                        ),
                        for (final key in ['brand', 'shade_name', 'finish'])
                          Text(
                            '$key: ${(entry['product'][key] as String).isEmpty ? 'Not recorded' : entry['product'][key]}',
                          ),
                        for (final reason in entry['reasons'] as List)
                          Text(reason),
                      ],
                    ),
                  ),
                ),
              for (final gap in voice.plan!['gaps'] as List)
                Text('${gap['category']}: ${gap['reason']}'),
              for (final limitation in voice.plan!['limitations'] as List)
                Text(limitation),
            ],
          ],
        ),
      ),
    ),
  );
}
