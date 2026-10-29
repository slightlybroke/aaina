import 'package:flutter/material.dart';

import 'api.dart';

class EducationPage extends StatefulWidget {
  final AnalysisApi api;
  const EducationPage({super.key, required this.api});
  @override
  State<EducationPage> createState() => _EducationPageState();
}

class _EducationPageState extends State<EducationPage> {
  final question = TextEditingController();
  String topic = 'sunscreen';
  bool consent = false, useAi = false, memory = false, busy = false;
  String? error;
  Map? result;
  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  void clear() => setState(() {
    result = null;
    error = null;
  });
  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final data = await widget.api.write('POST', '/v1/education/lesson', {
        'topic': topic,
        'question': question.text.trim(),
        'use_ai': useAi,
        'use_beauty_memory': useAi && memory,
        if (useAi && consent) 'consent_version': 'beauty-education-v1',
      });
      if (mounted) setState(() => result = data);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException
              ? e.message
              : 'Could not load the lesson. Retry.',
        );
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Learn your beauty')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Short, source-reviewed lessons. Choose reference mode to keep your question on this backend. Optional Gemini selection chooses relevant reviewed facts; it cannot diagnose or verify your products’ ingredients.',
            ),
            DropdownButtonFormField<String>(
              initialValue: topic,
              decoration: const InputDecoration(labelText: 'Topic'),
              items: const [
                DropdownMenuItem(
                  value: 'sunscreen',
                  child: Text('Sunscreen labels'),
                ),
                DropdownMenuItem(
                  value: 'salicylic_acid',
                  child: Text('Salicylic acid'),
                ),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      topic = v!;
                      clear();
                    },
            ),
            TextField(
              controller: question,
              enabled: !busy,
              maxLength: 600,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Question (optional)',
              ),
              onChanged: (_) => clear(),
            ),
            CheckboxListTile(
              title: const Text(
                'I agree to send this question and any opted-in shared memories to Google Gemini. API use may consume credits. No photos, routines or journal records are fetched.',
              ),
              value: consent,
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      consent = v == true;
                      if (!consent) {
                        useAi = false;
                        memory = false;
                      }
                      result = null;
                    }),
            ),
            SwitchListTile(
              title: const Text('Use Gemini to select relevant facts'),
              value: useAi,
              onChanged: busy || !consent
                  ? null
                  : (v) => setState(() {
                      useAi = v;
                      if (!v) memory = false;
                      result = null;
                    }),
            ),
            SwitchListTile(
              title: const Text('Use shared Beauty Memory'),
              value: memory,
              onChanged: busy || !useAi
                  ? null
                  : (v) => setState(() {
                      memory = v;
                      result = null;
                    }),
            ),
            if (busy) const LinearProgressIndicator(),
            FilledButton(
              onPressed: busy ? null : load,
              child: Text(error == null ? 'Show lesson' : 'Retry lesson'),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (result != null) ...[
              Text(
                result!['title'],
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text('Mode: ${result!["status"]}'),
              if (result!['status'] == 'reference_fallback')
                const Text(
                  'Gemini selection was unavailable or invalid. The reviewed reference lesson is shown instead.',
                ),
              for (final fact in result!['facts'])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(fact['text']),
                ),
              Text(result!['caution']),
              Text(result!['limitations']),
              for (final m in result!['memory_context'])
                Text('Shared context (${m["kind"]}): ${m["text"]}'),
              const Divider(),
              const Text('Sources (open or copy the URL in your browser)'),
              for (final source in result!['sources'])
                SelectableText('${source["title"]}\n${source["url"]}'),
              Text('Sources reviewed: ${result!["reviewed_at"]}'),
            ],
          ],
        ),
      ),
    ),
  );
}
