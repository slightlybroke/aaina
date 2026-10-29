import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';

const vanityCategories = [
  'lipstick',
  'foundation',
  'blush',
  'eyeshadow',
  'mascara',
  'eyeliner',
  'other',
];
const vanityFields = {
  'name': ('Product name', 150),
  'brand': ('Brand (optional)', 150),
  'category': ('Category (optional, custom names welcome)', 80),
  'shade_name': ('Shade name (optional)', 120),
  'shade_identifier': ('Shade identifier (optional)', 80),
  'finish': ('Finish (optional)', 80),
  'undertone': ('Undertone (optional)', 80),
  'notes': ('Notes (optional)', 3000),
};

class VanityEditor extends StatefulWidget {
  final AnalysisApi api;
  final Map<String, dynamic>? item;
  final Map<String, dynamic>? initialValues;
  const VanityEditor({
    super.key,
    required this.api,
    this.item,
    this.initialValues,
  });
  @override
  State<VanityEditor> createState() => _VanityEditorState();
}

class _VanityEditorState extends State<VanityEditor> {
  final form = GlobalKey<FormState>();
  late final String id;
  late final Map<String, TextEditingController> fields;
  int? version;
  bool busy = false, attempted = false;
  String? error;
  @override
  void initState() {
    super.initState();
    id = widget.item?['id'] as String? ?? const Uuid().v4();
    version = widget.item?['version'] as int?;
    fields = {
      for (final key in vanityFields.keys)
        key: TextEditingController(
          text:
              (widget.item?[key] ?? widget.initialValues?[key]) as String? ??
              '',
        ),
    };
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  String message(Object e) => e is ApiException
      ? e.message
      : 'Could not confirm the request. Check your connection and retry.';
  Future<void> reload() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final item = Map<String, dynamic>.from(
        await widget.api.get('/v1/vanity/$id'),
      );
      if (mounted) {
        setState(() {
          for (final key in fields.keys) {
            fields[key]!.text = item[key] as String? ?? '';
          }
          version = item['version'] as int;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = message(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      attempted = true;
      error = null;
    });
    final data = <String, dynamic>{
      for (final key in fields.keys) key: fields[key]!.text.trim(),
      'expected_version': version,
    };
    if ((data['category'] as String).isEmpty) data['category'] = 'other';
    try {
      await widget.api.write('PUT', '/v1/vanity/$id', data);
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = message(e));
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
      title: Text(version == null ? 'Add product' : 'Edit product'),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Record a product you own. Only its name is required; leave unknown details blank.',
              ),
              const SizedBox(height: 16),
              for (final entry in vanityFields.entries) ...[
                TextFormField(
                  key: ValueKey('vanity-${entry.key}'),
                  controller: fields[entry.key],
                  enabled: !busy,
                  maxLength: entry.value.$2,
                  maxLines: entry.key == 'notes' ? 4 : 1,
                  decoration: InputDecoration(labelText: entry.value.$1),
                  validator: (value) =>
                      entry.key == 'name' &&
                          (value == null || value.trim().isEmpty)
                      ? 'Enter a product name.'
                      : null,
                ),
                if (entry.key == 'category')
                  Wrap(
                    spacing: 6,
                    children: vanityCategories
                        .map(
                          (c) => ActionChip(
                            label: Text(c),
                            onPressed: busy
                                ? null
                                : () => fields['category']!.text = c,
                          ),
                        )
                        .toList(),
                  ),
                const SizedBox(height: 12),
              ],
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (busy) const LinearProgressIndicator(),
              if (version != null || attempted)
                TextButton(
                  onPressed: busy ? null : reload,
                  child: const Text('Reload saved product (discards edits)'),
                ),
              FilledButton(
                onPressed: busy ? null : save,
                child: const Text('Save product'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
