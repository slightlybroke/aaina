import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';

class StepDraft {
  final String id;
  final TextEditingController name, product, notes;
  StepDraft([Map<String, dynamic>? step])
    : id = step?['id'] as String? ?? const Uuid().v4(),
      name = TextEditingController(text: step?['name'] as String? ?? ''),
      product = TextEditingController(text: step?['product'] as String? ?? ''),
      notes = TextEditingController(text: step?['notes'] as String? ?? '');
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name.text.trim(),
    'product': product.text.trim(),
    'notes': notes.text.trim(),
  };
  void dispose() {
    name.dispose();
    product.dispose();
    notes.dispose();
  }
}

class RoutineEditor extends StatefulWidget {
  final AnalysisApi api;
  final Map<String, dynamic>? routine;
  const RoutineEditor({super.key, required this.api, this.routine});
  @override
  State<RoutineEditor> createState() => _RoutineEditorState();
}

class _RoutineEditorState extends State<RoutineEditor> {
  final form = GlobalKey<FormState>();
  late final String id;
  late final TextEditingController name, description;
  late final List<StepDraft> steps;
  late Set<int> days;
  late String kind, status;
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    id = widget.routine?['routine_id'] as String? ?? const Uuid().v4();
    final definition =
        widget.routine?['latest_revision']?['definition']
            as Map<String, dynamic>? ??
        {};
    name = TextEditingController(text: definition['name'] as String? ?? '');
    description = TextEditingController(
      text: definition['description'] as String? ?? '',
    );
    kind = definition['kind'] as String? ?? 'morning';
    status = definition['status'] as String? ?? 'active';
    days = Set<int>.from(definition['days'] as List? ?? [1, 2, 3, 4, 5, 6, 7]);
    steps = (definition['steps'] as List? ?? [{}])
        .map((s) => StepDraft(Map<String, dynamic>.from(s)))
        .toList();
  }

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    for (final s in steps) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate() || days.isEmpty) {
      setState(
        () => error = 'Give each step a name and select at least one day.',
      );
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.api.write('PUT', '/v1/skincare/routines/$id', {
        'name': name.text.trim(),
        'description': description.text.trim(),
        'kind': kind,
        'status': status,
        'days': days.toList()..sort(),
        'steps': steps.map((s) => s.toJson()).toList(),
        'expected_revision': widget.routine?['latest_revision']?['id'],
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
      title: Text(widget.routine == null ? 'Create routine' : 'Edit routine'),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                widget.routine == null
                    ? 'Starts today in your tracking timezone.'
                    : 'You are editing the saved version for tomorrow. Today’s checklist will keep its original steps, even after saving or signing in again. Past records stay unchanged.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: name,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Routine name'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Enter a name' : null,
              ),
              TextFormField(
                controller: description,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: 'Routine type'),
                items: ['morning', 'evening', 'custom']
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: saving ? null : (v) => setState(() => kind = v!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: ['active', 'paused', 'archived']
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: saving ? null : (v) => setState(() => status = v!),
              ),
              const SizedBox(height: 12),
              const Text('Scheduled days'),
              Wrap(
                spacing: 6,
                children: List.generate(
                  7,
                  (i) => FilterChip(
                    label: Text(
                      ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i],
                    ),
                    selected: days.contains(i + 1),
                    onSelected: saving
                        ? null
                        : (selected) => setState(
                            () =>
                                selected ? days.add(i + 1) : days.remove(i + 1),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Steps — all listed steps are required for full completion.',
              ),
              for (var i = 0; i < steps.length; i++) stepCard(i),
              TextButton.icon(
                onPressed: saving || steps.length >= 30
                    ? null
                    : () => setState(() => steps.add(StepDraft())),
                icon: const Icon(Icons.add),
                label: const Text('Add step'),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (saving) const LinearProgressIndicator(),
              FilledButton(
                onPressed: saving ? null : save,
                child: Text(
                  widget.routine == null
                      ? 'Save routine'
                      : 'Save changes for tomorrow',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget stepCard(int i) => Card(
    key: ValueKey(steps[i].id),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text('Step ${i + 1}')),
              IconButton(
                tooltip: 'Move step up',
                onPressed: saving || i == 0
                    ? null
                    : () => setState(() {
                        final s = steps.removeAt(i);
                        steps.insert(i - 1, s);
                      }),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: 'Move step down',
                onPressed: saving || i == steps.length - 1
                    ? null
                    : () => setState(() {
                        final s = steps.removeAt(i);
                        steps.insert(i + 1, s);
                      }),
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton(
                tooltip: 'Delete step',
                onPressed: saving || steps.length == 1
                    ? null
                    : () => setState(() {
                        steps.removeAt(i).dispose();
                      }),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          TextFormField(
            controller: steps[i].name,
            maxLength: 100,
            decoration: const InputDecoration(labelText: 'Step name'),
            validator: (v) =>
                v == null || v.trim().isEmpty ? 'Enter a step name' : null,
          ),
          TextFormField(
            controller: steps[i].product,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'Product name (optional)',
            ),
          ),
          TextFormField(
            controller: steps[i].notes,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: 'Step notes (optional)',
            ),
          ),
        ],
      ),
    ),
  );
}
