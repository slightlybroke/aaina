import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';
import 'look_planner_page.dart';
import 'vanity_editor.dart';
import 'vto_page.dart';
import 'discovery_page.dart';

class VanityPage extends StatefulWidget {
  final AnalysisApi api;
  const VanityPage({super.key, required this.api});
  @override
  State<VanityPage> createState() => _VanityPageState();
}

class _VanityPageState extends State<VanityPage> {
  final search = TextEditingController();
  List<Map<String, dynamic>> items = [];
  List<String> categories = [];
  String category = '', appliedQuery = '';
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
        items = [];
        appliedQuery = search.text.trim();
      }
    });
    try {
      final uri = Uri(
        path: '/v1/vanity',
        queryParameters: {
          'q': appliedQuery,
          'category': category,
          'offset': more ? '${items.length}' : '0',
        },
      );
      final result = Map<String, dynamic>.from(
        await widget.api.get(uri.toString()),
      );
      final rows = (result['items'] as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
      if (mounted) {
        setState(() {
          items = more ? [...items, ...rows] : rows;
          categories = List<String>.from(result['categories']);
          hasMore = result['has_more'] == true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException ? e.message : 'Could not load your products. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> edit([Map<String, dynamic>? item]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => VanityEditor(api: widget.api, item: item),
      ),
    );
    if (saved == true && mounted) await load();
  }

  Future<void> openPlanner({bool vto = false, bool discovery = false}) async {
    final auth = widget.api.auth.auth;
    final owner = auth.currentUser?.id;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => StreamBuilder<AuthState>(
          stream: auth.onAuthStateChange,
          builder: (context, snapshot) =>
              owner != null && auth.currentUser?.id == owner
              ? (discovery
                    ? DiscoveryPage(api: widget.api)
                    : vto
                    ? VtoPage(api: widget.api)
                    : LookPlannerPage(api: widget.api))
              : Scaffold(
                  appBar: AppBar(title: const Text('Look planning')),
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

  Future<void> remove(Map<String, dynamic> item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this product?'),
        content: Text('Remove “${item['name']}” from your vanity permanently?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.write('DELETE', '/v1/vanity/${item['id']}');
      if (mounted) {
        setState(() => busy = false);
        await load();
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException ? e.message : 'Could not confirm deletion. Refresh your inventory before retrying.',
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
      title: const Text('Digital vanity'),
      actions: [
        IconButton(
          tooltip: 'Refresh products',
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
              'Your owned makeup products and the details you record. This is your inventory, not a discovery catalogue.',
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : openPlanner,
              icon: const Icon(Icons.palette_outlined),
              label: const Text('Plan a makeup look'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => openPlanner(vto: true),
              icon: const Icon(Icons.face_retouching_natural),
              label: const Text('Try makeup preview'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => openPlanner(discovery: true),
              icon: const Icon(Icons.search),
              label: const Text('Discover products'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : () => edit(),
              icon: const Icon(Icons.add),
              label: const Text('Add product'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: search,
              enabled: !busy,
              maxLength: 200,
              decoration: InputDecoration(
                labelText: 'Search your products',
                hintText: 'Name, brand, shade or notes',
                suffixIcon: IconButton(
                  tooltip: 'Search products',
                  onPressed: busy ? null : load,
                  icon: const Icon(Icons.search),
                ),
              ),
              onSubmitted: busy ? null : (_) => load(),
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              key: ValueKey(category),
              initialValue: category,
              decoration: const InputDecoration(labelText: 'Filter category'),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('All categories'),
                ),
                for (final c in {
                  ...categories,
                  if (category.isNotEmpty) category,
                }.toList()..sort())
                  DropdownMenuItem(
                    value: c,
                    child: Text(
                      c,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      category = value ?? '';
                      load();
                    },
            ),
            if (category.isNotEmpty || appliedQuery.isNotEmpty)
              TextButton(
                onPressed: busy
                    ? null
                    : () {
                        search.clear();
                        category = '';
                        load();
                      },
                child: const Text('Clear search and filters'),
              ),
            if (busy) const LinearProgressIndicator(),
            if (error != null) ...[
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: busy ? null : load,
                child: const Text('Retry loading products'),
              ),
            ],
            if (!busy && error == null && items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  category.isNotEmpty || appliedQuery.isNotEmpty
                      ? 'No products match this search. Try another search or clear your filters.'
                      : 'Your vanity is empty. Add a product you own to get started.',
                ),
              ),
            for (final item in items)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['name'],
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        (item['brand'] as String).isEmpty
                            ? 'Brand not recorded'
                            : item['brand'],
                      ),
                      Text('Category: ${item['category']}'),
                      Text(
                        (item['shade_name'] as String).isEmpty
                            ? 'Shade not recorded'
                            : 'Shade: ${item['shade_name']}',
                      ),
                      ExpansionTile(
                        title: const Text('Product details'),
                        children: [
                          for (final key in [
                            'shade_identifier',
                            'finish',
                            'undertone',
                            'notes',
                          ])
                            if ((item[key] as String).isNotEmpty)
                              ListTile(
                                title: Text(
                                  vanityFields[key]!.$1.replaceFirst(
                                    ' (optional)',
                                    '',
                                  ),
                                ),
                                subtitle: Text(item[key]),
                              ),
                          if ([
                            'shade_identifier',
                            'finish',
                            'undertone',
                            'notes',
                          ].every((k) => (item[k] as String).isEmpty))
                            const ListTile(
                              title: Text('No additional details recorded.'),
                            ),
                        ],
                      ),
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: busy ? null : () => edit(item),
                            child: const Text('Edit product'),
                          ),
                          TextButton(
                            onPressed: busy ? null : () => remove(item),
                            child: const Text('Delete product'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (hasMore && error == null)
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
