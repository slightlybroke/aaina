import 'package:flutter/material.dart';

import 'api.dart';

class MakeupPreferencesPage extends StatefulWidget {
  final AnalysisApi api;
  const MakeupPreferencesPage({super.key, required this.api});
  @override
  State<MakeupPreferencesPage> createState() => _MakeupPreferencesPageState();
}

class _MakeupPreferencesPageState extends State<MakeupPreferencesPage> {
  final shade = TextEditingController(),
      finish = TextEditingController(),
      excluded = TextEditingController();
  bool busy = false;
  String? error, updated, notice;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    shade.dispose();
    finish.dispose();
    excluded.dispose();
    super.dispose();
  }

  String message(Object e) => e is ApiException
      ? e.message
      : 'Could not update preferences. Check the connection and retry.';
  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.api.get('/v1/makeup-preferences');
      if (mounted) {
        setState(() {
          shade.text = data['preferred_shade'];
          finish.text = data['preferred_finish'];
          excluded.text = (data['excluded_categories'] as List).join(', ');
          updated = data['updated_at'];
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final values = excluded.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (values.length > 12 || values.any((s) => s.length > 80)) {
        throw ApiException(
          'Use up to 12 category names, each at most 80 characters.',
        );
      }
      final data = await widget.api.write('PUT', '/v1/makeup-preferences', {
        'preferred_shade': shade.text.trim(),
        'preferred_finish': finish.text.trim(),
        'excluded_categories': values,
      });
      if (mounted) {
        setState(() {
          updated = data['updated_at'];
          notice = 'Preferences saved. Start a new opted-in Chat or Talk session to use them.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> remove() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete saved makeup preferences?'),
        content: const Text(
          'Future sessions will no longer retrieve them. Already shared Gemini context cannot be recalled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete preferences'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await widget.api.write('DELETE', '/v1/makeup-preferences');
      if (mounted) {
        setState(() {
          shade.clear();
          finish.clear();
          excluded.clear();
          updated = null;
          notice = 'Saved preferences deleted.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Saved makeup preferences')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Optional, explicitly confirmed preferences. Nothing is extracted automatically from chat. Save cosmetic labels only; do not enter medical, allergy or sensitive personal information here.',
            ),
            const Text(
              'These settings stay private until you enable their use in a consented Chat or Talk session. Only relevant makeup fields are shared with Gemini. Saved shade/finish fill missing requests; current shade/finish choices take precedence. Saved category exclusions always remain while this option is on. Switch it off to plan without them.',
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null) ...[
              Text(
                error!,
                style: TextStyle(color: Theme.of(c).colorScheme.error),
              ),
              TextButton(
                onPressed: busy ? null : load,
                child: const Text('Reload preferences'),
              ),
            ],
            if (updated == null)
              const Text('No saved preferences yet. All fields are optional.'),
            TextField(
              controller: shade,
              maxLength: 120,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Preferred shade label (optional)',
                helperText:
                    'Literal recorded shade text, not an inferred color match',
              ),
            ),
            TextField(
              controller: finish,
              maxLength: 80,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Preferred finish label (optional)',
              ),
            ),
            TextField(
              controller: excluded,
              maxLength: 970,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Excluded categories (comma separated)',
                helperText: 'Up to 12; use your recorded category names',
              ),
            ),
            if (updated != null)
              Text(
                'Source: explicitly saved profile · Updated ${DateTime.tryParse(updated!)?.toLocal() ?? updated}',
              ),
            if (notice != null) Text(notice!),
            FilledButton(
              onPressed: busy ? null : save,
              child: const Text('Save preferences'),
            ),
            TextButton(
              onPressed: busy || updated == null ? null : remove,
              child: const Text('Delete saved preferences'),
            ),
          ],
        ),
      ),
    ),
  );
}
