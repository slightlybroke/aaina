import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';

class BeautyMemoryPage extends StatefulWidget {
  final AnalysisApi api;
  const BeautyMemoryPage({super.key, required this.api});
  @override
  State<BeautyMemoryPage> createState() => _BeautyMemoryPageState();
}

class _BeautyMemoryPageState extends State<BeautyMemoryPage> {
  final query = TextEditingController();
  List<dynamic> items = [];
  bool busy = false, more = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException
              ? e.message
              : 'Could not update memory. Retry or reload.',
        );
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> fetch({bool next = false}) async {
    final data = await widget.api.get(
      '/v1/beauty-memories?q=${Uri.encodeComponent(query.text.trim())}&offset=${next ? items.length : 0}',
    );
    if (mounted) {
      setState(() {
        items = [...(next ? items : []), ...data['items']];
        more = data['has_more'];
      });
    }
  }

  Future<void> load() => run(() => fetch());
  Future<void> edit([Map? item]) async {
    final id = item?['id'] ?? const Uuid().v4();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _MemoryEditor(
          item: item,
          saveValues: (values) async {
            await widget.api.write('PUT', '/v1/beauty-memories/$id', values);
          },
        ),
      ),
    );
    if (mounted) await load();
  }

  Future<void> confirm(Map item) async {
    final sharing = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Confirm reviewed observation'),
        content: Text(
          '${item["text"]}\nThis stays an ${item["kind"]}. Choose whether to allow relevant AI sharing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Confirm privately'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Confirm and allow sharing'),
          ),
        ],
      ),
    );
    if (sharing == null) return;
    await run(() async {
      await widget.api.write(
        'POST',
        '/v1/beauty-memories/${item["id"]}/confirm',
        {'expected_version': item['version'], 'share_with_ai': sharing},
      );
      await fetch();
    });
  }

  Future<void> remove(Map item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this memory?'),
        content: const Text(
          'Future sessions cannot retrieve it. Context already sent to Google cannot be recalled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await run(() async {
        await widget.api.write('DELETE', '/v1/beauty-memories/${item['id']}');
        await fetch();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Beauty Memory')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Review facts and uncertain observations you choose to remember. Saving does not enable AI sharing. Only confirmed, unexpired entries marked for sharing can be retrieved in an opted-in Chat or Talk session. No conversation history is stored.',
            ),
            FilledButton(
              onPressed: busy ? null : () => edit(),
              child: const Text('Add memory'),
            ),
            TextField(
              controller: query,
              decoration: InputDecoration(
                labelText: 'Search memories',
                suffixIcon: IconButton(
                  onPressed: busy ? null : load,
                  icon: const Icon(Icons.search),
                ),
              ),
              onSubmitted: (_) => load(),
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            TextButton(
              onPressed: busy ? null : load,
              child: const Text('Reload memories'),
            ),
            if (!busy && items.isEmpty)
              const Text('No memories found. Add one when useful.'),
            for (final item in items)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['text'],
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${item['category']} · ${item['kind']} · ${item['status']}',
                      ),
                      Text(
                        item['share_with_ai'] == true
                            ? 'AI sharing enabled'
                            : 'Private; AI sharing off',
                      ),
                      Text(
                        'Source: ${item['source']} · Updated ${item['updated_at']}',
                      ),
                      if ((item['source_quote'] ?? '').isNotEmpty)
                        Text('Source words: ${item['source_quote']}'),
                      if (item['expires_at'] != null)
                        Text('Expires: ${item['expires_at']}'),
                      if (item['sensitive'] == true)
                        const Text('Marked sensitive'),
                      if (item['status'] == 'pending')
                        TextButton(
                          onPressed: busy ? null : () => confirm(item),
                          child: const Text('Review and confirm'),
                        ),
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: busy ? null : () => edit(item),
                            child: const Text('Edit'),
                          ),
                          TextButton(
                            onPressed: busy ? null : () => remove(item),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (more)
              TextButton(
                onPressed: busy ? null : () => run(() => fetch(next: true)),
                child: const Text('Load more'),
              ),
          ],
        ),
      ),
    ),
  );
}

class _MemoryEditor extends StatefulWidget {
  final Map? item;
  final Future<void> Function(Map<String, dynamic>) saveValues;
  const _MemoryEditor({this.item, required this.saveValues});
  @override
  State<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<_MemoryEditor> {
  late final text = TextEditingController(text: widget.item?['text'] ?? '');
  late final quote = TextEditingController(
    text: widget.item?['source_quote'] ?? '',
  );
  late final expiry = TextEditingController(
    text: widget.item?['expires_at'] ?? '',
  );
  late String category = widget.item?['category'] ?? 'preference',
      kind = widget.item?['kind'] ?? 'fact';
  late bool sensitive = widget.item?['sensitive'] ?? false,
      share = widget.item?['share_with_ai'] ?? false;
  String? error;
  @override
  void dispose() {
    text.dispose();
    quote.dispose();
    expiry.dispose();
    super.dispose();
  }

  bool saving = false;
  Future<void> save() async {
    final date = expiry.text.trim();
    if (text.text.trim().isEmpty ||
        (category == 'event' && date.isEmpty) ||
        (date.isNotEmpty &&
            (DateTime.tryParse(date) == null ||
                !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(date)))) {
      setState(
        () => error = 'Enter memory text and, for events, an ISO date/time including Z or a timezone offset.',
      );
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.saveValues(<String, dynamic>{
        'text': text.text.trim(),
        'category': category,
        'kind': kind,
        'sensitive': sensitive,
        'share_with_ai': share,
        'source_quote': quote.text.trim(),
        'expires_at': date.isEmpty ? null : date,
        if (widget.item != null) 'expected_version': widget.item!['version'],
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException
              ? e.message
              : 'Save failed. Your draft is kept; retry.',
        );
      }
    }
    if (mounted) setState(() => saving = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Review memory')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Save only useful context. An inference remains uncertain after confirmation. Sensitive or uncertain entries require another review before AI sharing; edits request review again.',
        ),
        DropdownButtonFormField<String>(
          initialValue: category,
          decoration: const InputDecoration(labelText: 'Category'),
          items:
              ['preference', 'product_experience', 'routine_progress', 'event']
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text(v.replaceAll('_', ' ')),
                    ),
                  )
                  .toList(),
          onChanged: (v) => setState(() => category = v!),
        ),
        TextField(
          controller: text,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Memory text'),
        ),
        DropdownButtonFormField<String>(
          initialValue: kind,
          decoration: const InputDecoration(labelText: 'Certainty'),
          items: [
            'fact',
            'inference',
          ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
          onChanged: (v) => setState(() => kind = v!),
        ),
        SwitchListTile(
          title: const Text('Sensitive information'),
          value: sensitive,
          onChanged: (v) => setState(() => sensitive = v),
        ),
        SwitchListTile(
          title: const Text('Allow relevant AI sharing'),
          subtitle: const Text(
            'Still requires session opt-in. Uncertain or sensitive edits remain private until separately confirmed.',
          ),
          value: share,
          onChanged: (v) => setState(() => share = v),
        ),
        TextField(
          controller: quote,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Source words (optional)',
          ),
        ),
        TextField(
          controller: expiry,
          decoration: const InputDecoration(
            labelText: 'Expiry (required for events)',
            helperText: 'Example: 2026-11-03T18:00:00+05:30',
          ),
        ),
        if (error != null) Text(error!),
        FilledButton(
          onPressed: saving ? null : save,
          child: const Text('Save reviewed memory'),
        ),
      ],
    ),
  );
}
