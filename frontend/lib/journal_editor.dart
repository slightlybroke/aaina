import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';

const concernNames = [
  'dryness',
  'oiliness',
  'blemishes',
  'redness',
  'irritation',
  'texture',
  'sensitivity',
  'other',
];

class JournalEditor extends StatefulWidget {
  final AnalysisApi api;
  final Map<String, dynamic>? entry;
  const JournalEditor({super.key, required this.api, this.entry});
  @override
  State<JournalEditor> createState() => _JournalEditorState();
}

class _JournalEditorState extends State<JournalEditor> {
  late final String id;
  late final TextEditingController notes;
  late Set<String> concerns;
  String? severity, error;
  late DateTime observed;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    id = widget.entry?['id'] as String? ?? const Uuid().v4();
    notes = TextEditingController(
      text: widget.entry?['notes'] as String? ?? '',
    );
    concerns = Set<String>.from(widget.entry?['concerns'] as List? ?? []);
    severity = widget.entry?['severity'] as String?;
    observed =
        DateTime.tryParse(widget.entry?['observed_at'] as String? ?? '')
            ?.toUtc() ??
        DateTime.now().toUtc();
  }

  @override
  void dispose() {
    notes.dispose();
    super.dispose();
  }

  Future<void> chooseTime() async {
    final day = await showDatePicker(
      context: context,
      initialDate: observed,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().toUtc(),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(observed),
    );
    if (time != null && mounted) {
      setState(
        () => observed = DateTime.utc(
          day.year,
          day.month,
          day.day,
          time.hour,
          time.minute,
        ),
      );
    }
  }

  Future<void> save() async {
    if (concerns.isEmpty) {
      setState(() => error = 'Select at least one concern.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.api.write('PUT', '/v1/skincare/journal/$id', {
        'concerns': concerns.toList(),
        'severity': severity,
        'notes': notes.text.trim(),
        'observed_at': observed.toIso8601String(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException
              ? e.message
              : 'Could not save. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.entry == null ? 'Log skin concern' : 'Edit skin concern',
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Your observations, separate from YouCam findings. No photo required.',
            ),
            Wrap(
              spacing: 8,
              children: concernNames
                  .map(
                    (c) => FilterChip(
                      label: Text(c),
                      selected: concerns.contains(c),
                      onSelected: saving
                          ? null
                          : (yes) => setState(
                              () => yes ? concerns.add(c) : concerns.remove(c),
                            ),
                    ),
                  )
                  .toList(),
            ),
            DropdownButtonFormField<String>(
              initialValue: severity ?? 'none',
              decoration: const InputDecoration(
                labelText: 'Severity (optional)',
              ),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('Not specified')),
                DropdownMenuItem(value: 'mild', child: Text('Mild — slight')),
                DropdownMenuItem(
                  value: 'moderate',
                  child: Text('Moderate — noticeable'),
                ),
                DropdownMenuItem(
                  value: 'severe',
                  child: Text('Severe — very bothersome'),
                ),
              ],
              onChanged: saving
                  ? null
                  : (v) => setState(() => severity = v == 'none' ? null : v),
            ),
            if (severity == 'severe')
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'This journal cannot assess a reaction. Consider professional advice for severe irritation; do not use routine check-ins as a reason to continue an irritating product.',
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: notes,
              maxLength: 3000,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            TextButton(
              onPressed: saving ? null : chooseTime,
              child: Text(
                'Observation time (UTC): ${observed.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}',
              ),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (saving) const LinearProgressIndicator(),
            FilledButton(
              onPressed: saving ? null : save,
              child: const Text('Save observation'),
            ),
          ],
        ),
      ),
    ),
  );
}
