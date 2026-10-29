import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';
import 'gemini_look_page.dart';
import 'live_talk_page.dart';
import 'makeup_preferences_page.dart';
import 'beauty_memory_page.dart';
import 'education_page.dart';

class LookPlannerPage extends StatefulWidget {
  final AnalysisApi api;
  const LookPlannerPage({super.key, required this.api});
  @override
  State<LookPlannerPage> createState() => _LookPlannerPageState();
}

class _LookPlannerPageState extends State<LookPlannerPage> {
  final fields = {
    for (final name in [
      'occasion',
      'outfit',
      'preferred_shade',
      'preferred_finish',
      'categories',
      'excluded_categories',
    ])
      name: TextEditingController(),
  };
  String style = 'natural';
  bool busy = false;
  String? error;
  Map<String, dynamic>? result;
  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> categories(String key) => fields[key]!.text
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> openGemini({
    bool talk = false,
    bool preferences = false,
    bool memory = false,
    bool education = false,
  }) async {
    final auth = widget.api.auth.auth;
    final owner = auth.currentUser?.id;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => StreamBuilder<AuthState>(
          stream: auth.onAuthStateChange,
          builder: (context, snapshot) =>
              owner != null && auth.currentUser?.id == owner
              ? education
                    ? EducationPage(api: widget.api)
                    : memory
                    ? BeautyMemoryPage(api: widget.api)
                    : preferences
                    ? MakeupPreferencesPage(api: widget.api)
                    : talk
                    ? LiveTalkPage(api: widget.api)
                    : GeminiLookPage(api: widget.api)
              : Scaffold(
                  appBar: AppBar(title: const Text('Look conversation')),
                  body: const Center(
                    child: Text(
                      'Your account session changed. Go back and sign in again.',
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> generate() async {
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final response = await widget.api.write('POST', '/v1/looks/plan', {
        'style': style,
        for (final key in [
          'occasion',
          'outfit',
          'preferred_shade',
          'preferred_finish',
        ])
          key: fields[key]!.text.trim(),
        'categories': categories('categories'),
        'excluded_categories': categories('excluded_categories'),
      });
      if (mounted) {
        setState(() => result = Map<String, dynamic>.from(response));
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException
              ? e.message
              : 'Could not prepare the plan. Check your connection and retry.',
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
    appBar: AppBar(title: const Text('Plan a makeup look')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            OutlinedButton.icon(
              onPressed: busy ? null : () => openGemini(education: true),
              icon: const Icon(Icons.school_outlined),
              label: const Text('Learn ingredients and sunscreen'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => openGemini(memory: true),
              icon: const Icon(Icons.bookmark_outline),
              label: const Text('Beauty Memory'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => openGemini(preferences: true),
              icon: const Icon(Icons.tune),
              label: const Text('Saved makeup preferences'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => openGemini(),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Chat with Gemini'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => openGemini(talk: true),
              icon: const Icon(Icons.mic),
              label: const Text('Talk with Gemini — continuous voice'),
            ),
            const Text(
              'Build a category-based combination from products you own. This version matches recorded labels; it does not infer color harmony, skin suitability or wear time.',
            ),
            const SizedBox(height: 16),
            input('occasion', 'Occasion (optional context)', 300),
            input('outfit', 'Outfit (optional context)', 500),
            DropdownButtonFormField<String>(
              initialValue: style,
              decoration: const InputDecoration(
                labelText: 'Style / category plan',
              ),
              items: const [
                DropdownMenuItem(
                  value: 'natural',
                  child: Text('Natural: blush, mascara, lips'),
                ),
                DropdownMenuItem(
                  value: 'soft_glam',
                  child: Text('Soft glam: base, cheeks, eyes, lips'),
                ),
                DropdownMenuItem(
                  value: 'bold',
                  child: Text('Bold: eyes, liner, mascara, lips'),
                ),
                DropdownMenuItem(
                  value: 'custom',
                  child: Text('Custom categories'),
                ),
              ],
              isExpanded: true,
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      style = v!;
                      result = null;
                      error = null;
                    }),
            ),
            const SizedBox(height: 12),
            input(
              'categories',
              'Categories (comma-separated; overrides style roles)',
              500,
            ),
            input(
              'excluded_categories',
              'Exclude categories (comma-separated)',
              500,
            ),
            input('preferred_shade', 'Shade label to match (optional)', 120),
            const Text(
              'Shade text applies to lipstick, blush, eyeshadow and eyeliner. Blank means no shade restriction.',
            ),
            input('preferred_finish', 'Finish label to match (optional)', 80),
            const Text(
              'Finish text applies to every selected category. Missing labels are not treated as matches.',
            ),
            const SizedBox(height: 12),
            if (busy) const LinearProgressIndicator(),
            FilledButton(
              onPressed: busy ? null : generate,
              child: Text(
                error == null ? 'Build look plan' : 'Retry look plan',
              ),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (result != null) ...results(),
          ],
        ),
      ),
    ),
  );
  Widget input(String key, String label, int max) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey('look-$key'),
      controller: fields[key],
      enabled: !busy,
      onChanged: (_) {
        if (result != null || error != null) {
          setState(() {
            result = null;
            error = null;
          });
        }
      },
      maxLength: max,
      decoration: InputDecoration(labelText: label),
    ),
  );
  List<Widget> results() {
    final data = result!;
    return [
      const Divider(),
      Text('Your look plan', style: Theme.of(context).textTheme.headlineSmall),
      Text(
        '${data['inventory_count']} owned products considered · ${data['status']}',
      ),
      const Text(
        'This is a planning aid based on your entries, not an exact makeup preview. Your inventory is unchanged.',
      ),
      if (data['inventory_count'] == 0)
        const Text(
          'Your vanity is empty. Add a product in Digital vanity, then build a plan again.',
        ),
      for (final question in data['questions'] as List)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(question),
          ),
        ),
      for (final suggestion in data['suggestions'] as List)
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
                for (final reason in suggestion['reasons'] as List)
                  Text(reason),
                if ((suggestion['missing_fields'] as List).isNotEmpty)
                  Text(
                    'Missing details: ${(suggestion['missing_fields'] as List).join(', ')}. Add labels in Vanity for more specific matching.',
                  ),
              ],
            ),
          ),
        ),
      for (final gap in data['gaps'] as List)
        ListTile(
          title: Text('Gap: ${gap['category']}'),
          subtitle: Text(
            '${gap['reason']}${(gap['missing_fields'] as List? ?? []).isEmpty ? '' : ' Missing: ${(gap['missing_fields'] as List).join(', ')}'}',
          ),
        ),
      for (final limitation in data['limitations'] as List)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(limitation),
        ),
    ];
  }
}
