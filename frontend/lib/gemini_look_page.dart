import 'package:flutter/material.dart';

import 'api.dart';

class GeminiLookPage extends StatefulWidget {
  final AnalysisApi api;
  const GeminiLookPage({super.key, required this.api});
  @override
  State<GeminiLookPage> createState() => _GeminiLookPageState();
}

class _GeminiLookPageState extends State<GeminiLookPage> {
  final input = TextEditingController();
  List<Map<String, String>> messages = [];
  bool consent = false,
      busy = false,
      useSavedPreferences = false,
      useMemory = false,
      rememberFinish = false;
  String? error;
  Map<String, dynamic>? result;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void clear() {
    setState(() {
      messages = [];
      result = null;
      error = null;
      input.clear();
    });
  }

  Future<void> send() async {
    if (!consent ||
        busy ||
        input.text.trim().isEmpty ||
        messages.length >= 10) {
      return;
    }
    final outgoing = [
      ...messages,
      {'role': 'user', 'text': input.text.trim()},
    ];
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final response = Map<String, dynamic>.from(
        await widget.api.converse({
          'consent_version': 'gemini-look-v1',
          'messages': outgoing,
          'use_saved_preferences': useSavedPreferences,
          'use_beauty_memory': useMemory,
          'remember_stable_preferences': rememberFinish,
        }),
      );
      final answer =
          '${response['reply']}\n${(response['questions'] as List).join('\n')}';
      if (mounted) {
        setState(() {
          messages = [
            ...outgoing,
            {
              'role': 'assistant',
              'text': answer.length > 1200 ? answer.substring(0, 1200) : answer,
            },
          ];
          result = response;
          input.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException ? e.message : 'Could not confirm the reply. Your message is kept; retry or use the manual planner.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Chat with Gemini'),
      actions: [
        IconButton(
          tooltip: 'New conversation',
          onPressed: busy ? null : clear,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Describe an occasion, outfit and makeup preferences. Gemini interprets your words; product facts and selection stay with your owned-inventory planner. This is not medical advice or an exact try-on.',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I agree to send this conversation and relevant makeup labels to Google Gemini under this app’s API account terms. API use may consume credits. No photos, skin results, journal notes or routines are shared automatically. Explicitly shared beauty memories may include observations you recorded.',
              ),
              value: consent,
              onChanged: busy
                  ? null
                  : (v) {
                      setState(() {
                        consent = v == true;
                        if (!consent) {
                          messages = [];
                          result = null;
                          error = null;
                        }
                      });
                    },
            ),
            const Text(
              'This app does not save chat history. The separate optional memory setting below can save a narrowly supported finish preference. Start a new conversation after five replies; leaving this screen clears its history. Google’s processing terms still apply.',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use saved makeup preferences'),
              subtitle: const Text(
                'Optional profile labels only. Changes apply to a new conversation; no automatic memory saving.',
              ),
              value: useSavedPreferences,
              onChanged: busy || messages.isNotEmpty
                  ? null
                  : (v) => setState(() => useSavedPreferences = v),
            ),
            SwitchListTile(
              title: const Text('Use shared Beauty Memory'),
              subtitle: const Text(
                'Only relevant, confirmed, unexpired entries you enabled for AI sharing.',
              ),
              value: useMemory,
              onChanged: busy || messages.isNotEmpty
                  ? null
                  : (v) => setState(() => useMemory = v),
            ),
            SwitchListTile(
              title: const Text('Remember clearly stated finish preferences'),
              subtitle: const Text(
                'Typed Chat only. For example: I prefer matte finishes. Stored privately with your exact words; other sentences are not captured.',
              ),
              value: rememberFinish,
              onChanged: busy || messages.isNotEmpty
                  ? null
                  : (v) => setState(() => rememberFinish = v),
            ),
            if (result?['memory_saved'] != null)
              const Text(
                'Finish preference remembered. Review its sharing setting in Beauty Memory.',
              ),
            if (result?['memory_save_error'] != null)
              Text(result!['memory_save_error']),
            for (final memory in result?['memory_context'] as List? ?? [])
              Text('Shared context (${memory["kind"]}): ${memory["text"]}'),
            if ((result?['plan']?['saved_preference_fields'] as List? ?? [])
                .isNotEmpty)
              Text(
                'Saved defaults applied: ${(result!['plan']['saved_preference_fields'] as List).map((f) => f.toString().replaceAll('_', ' ')).join(', ')}',
              ),
            for (final message in messages)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '${message['role'] == 'user' ? 'You' : 'Assistant'}: ${message['text']}',
                  ),
                ),
              ),
            if (messages.length >= 10)
              const Text(
                'Conversation limit reached. Start a new conversation to continue.',
              ),
            const SizedBox(height: 12),
            TextField(
              controller: input,
              maxLength: 1200,
              maxLines: 3,
              enabled: consent && !busy && messages.length < 10,
              decoration: const InputDecoration(
                labelText: 'Describe your look or answer the question',
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (busy) const LinearProgressIndicator(),
            FilledButton(
              onPressed:
                  consent &&
                      !busy &&
                      messages.length < 10 &&
                      input.text.trim().isNotEmpty
                  ? send
                  : null,
              child: Text(error == null ? 'Send to Gemini' : 'Retry message'),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            TextButton(
              onPressed: busy ? null : () => Navigator.maybePop(context),
              child: const Text('Back to manual planner'),
            ),
            if (result?['plan'] != null) ...planWidgets(),
          ],
        ),
      ),
    ),
  );
  List<Widget> planWidgets() {
    final plan = result!['plan'] as Map;
    final explanationById = {
      for (final e in result!['explanations'] as List)
        e['product_id']: e['reasons'],
    };
    return [
      const Divider(),
      Text(
        'Recorded-product plan',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      Text(
        'Candidates considered: ${plan['inventory_count']} · ${plan['status']}',
      ),
      if (plan['context'] is Map)
        ExpansionTile(
          title: const Text('Interpreted preferences — review these'),
          children: [
            for (final key in [
              'style',
              'categories',
              'excluded_categories',
              'preferred_shade',
              'preferred_finish',
              'occasion',
              'outfit',
            ])
              ListTile(
                title: Text(key.replaceAll('_', ' ')),
                subtitle: Text('${plan['context'][key] ?? ''}'),
              ),
          ],
        ),
      if (result!['ai_status'] == 'deterministic_fallback')
        const Text(
          'Gemini interpreted your request. The planner’s factual explanations are shown because AI explanation selection was unavailable.',
        ),
      for (final suggestion in plan['suggestions'] as List)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${suggestion['category']}: ${suggestion['product']['name']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final key in [
                  'brand',
                  'shade_name',
                  'shade_identifier',
                  'finish',
                  'undertone',
                ])
                  Text(
                    '${key.replaceAll('_', ' ')}: ${(suggestion['product'][key] as String).isEmpty ? 'Not recorded' : suggestion['product'][key]}',
                  ),
                for (final reason
                    in explanationById[suggestion['product']['id']] as List? ??
                        suggestion['reasons'] as List)
                  Text(reason),
              ],
            ),
          ),
        ),
      for (final gap in plan['gaps'] as List)
        ListTile(
          title: Text('Gap: ${gap['category']}'),
          subtitle: Text(gap['reason']),
        ),
      for (final limitation in plan['limitations'] as List)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(limitation),
        ),
    ];
  }
}
