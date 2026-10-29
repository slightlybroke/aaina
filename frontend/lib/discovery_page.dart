import 'package:flutter/material.dart';

import 'api.dart';
import 'vanity_editor.dart';

class DiscoveryPage extends StatefulWidget {
  final AnalysisApi api;
  const DiscoveryPage({super.key, required this.api});
  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  final search = TextEditingController();
  String category = '', brand = '', applied = '';
  List<String> categories = [], brands = [];
  List<Map<String, dynamic>> rows = [];
  bool busy = false, hasMore = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      if (!more) {
        rows = [];
        applied = search.text.trim();
      }
    });
    try {
      final result = await widget.api.get(
        Uri(
          path: '/v1/discovery',
          queryParameters: {
            'q': applied,
            'category': category,
            'brand': brand,
            'offset': more ? '${rows.length}' : '0',
          },
        ).toString(),
      );
      if (mounted) {
        setState(() {
          final page = (result['items'] as List)
              .map((r) => Map<String, dynamic>.from(r))
              .toList();
          rows = more ? [...rows, ...page] : page;
          categories = List<String>.from(result['categories']);
          brands = List<String>.from(result['brands']);
          hasMore = result['has_more'] == true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException
              ? e.message
              : 'Catalogue unavailable. Check the connection and retry.',
        );
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> ownedCopy(Map<String, dynamic> product) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => VanityEditor(
          api: widget.api,
          initialValues: {
            for (final key in [
              'name',
              'brand',
              'category',
              'shade_name',
              'finish',
            ])
              key: product[key] ?? '',
          },
        ),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your owned copy was saved in Vanity. Catalogue records remain separate.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Discover products'),
      actions: [
        IconButton(
          tooltip: 'Refresh catalogue',
          onPressed: busy ? null : load,
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
              'A small, manually reviewed catalogue from official brand pages. It is not your owned inventory or a complete market search. Source regions may differ from yours.',
            ),
            const Text(
              'No live prices, stock or retailer integration. No verified exact product-to-VTO mapping. You may use generic makeup preview separately; it does not reproduce these products.',
            ),
            TextField(
              controller: search,
              enabled: !busy,
              onSubmitted: (_) => load(),
              decoration: InputDecoration(
                labelText: 'Search product, shade or brand words',
                helperText: 'Word search across the backend catalogue',
                suffixIcon: IconButton(
                  tooltip: 'Search catalogue',
                  onPressed: busy ? null : load,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('category:$category'),
              initialValue: category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('All categories'),
                ),
                ...categories.map(
                  (c) => DropdownMenuItem(value: c, child: Text(c)),
                ),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      category = v!;
                      load();
                    },
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('brand:$brand'),
              initialValue: brand,
              decoration: const InputDecoration(labelText: 'Brand'),
              items: [
                const DropdownMenuItem(value: '', child: Text('All brands')),
                ...brands.map(
                  (b) => DropdownMenuItem(value: b, child: Text(b)),
                ),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      brand = v!;
                      load();
                    },
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null) ...[
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: busy ? null : load,
                child: const Text('Retry catalogue'),
              ),
            ],
            if (!busy && error == null && rows.isEmpty)
              const Text(
                'No products found. Try another word or clear filters; this starter catalogue is intentionally small.',
              ),
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      search.clear();
                      category = '';
                      brand = '';
                      load();
                    },
              child: const Text('Clear catalogue filters'),
            ),
            for (final p in rows)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p['brand']} · ${p['name']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text('Category: ${p['category']}'),
                      Text(
                        'Shade: ${p['shade_name'].toString().isEmpty ? 'Not recorded' : p['shade_name']}',
                      ),
                      Text(
                        'Finish: ${p['finish'].toString().isEmpty ? 'Not recorded' : p['finish']}',
                      ),
                      const Text(
                        'Undertone / shade code: not recorded. Exact VTO mapping: unavailable.',
                      ),
                      Text(
                        'Manufacturer-listed metadata · source checked ${p['checked_on']} · ${p['source_region']}',
                      ),
                      const Text(
                        'Category is an editorial classification; source listing does not confirm current availability.',
                      ),
                      SelectableText(p['source_url'] ?? ''),
                      OutlinedButton(
                        onPressed: busy ? null : () => ownedCopy(p),
                        child: const Text('I own this — add to Vanity'),
                      ),
                    ],
                  ),
                ),
              ),
            if (hasMore)
              TextButton(
                onPressed: busy ? null : () => load(more: true),
                child: const Text('Load more products'),
              ),
          ],
        ),
      ),
    ),
  );
}
