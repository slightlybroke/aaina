import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';
import 'journal_editor.dart';
import 'main.dart' show ScanHome, appName;
import 'routine_editor.dart';
import 'skin_progress.dart';
import 'vanity_page.dart';
import 'weekly_reports_page.dart';

class SkincareHome extends StatefulWidget {
  final SupabaseClient client;
  final String apiUrl;
  final AnalysisApi? api;
  const SkincareHome({
    super.key,
    required this.client,
    required this.apiUrl,
    this.api,
  });
  @override
  State<SkincareHome> createState() => _SkincareHomeState();
}

class _SkincareHomeState extends State<SkincareHome> {
  late final AnalysisApi api;
  Map<String, dynamic>? routines, history;
  List<Map<String, dynamic>> journal = [], analyses = [];
  int tab = 0;
  bool loading = true, busy = false, moreAnalyses = false, moreJournal = false;
  bool scanOpened = false;
  String? error, day;
  DateTimeRange? range;
  int loadGeneration = 0;
  @override
  void initState() {
    super.initState();
    api = widget.api ?? AnalysisApi(widget.client, widget.apiUrl);
    refresh();
  }

  @override
  void dispose() {
    if (widget.api == null) api.close();
    super.dispose();
  }

  List<Map<String, dynamic>> maps(dynamic rows) =>
      (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
  Future<void> refresh() async {
    final generation = ++loadGeneration;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final responses = await Future.wait([
        api.get('/v1/skincare/routines${day == null ? '' : '?day=$day'}'),
        api.get(
          '/v1/skincare/history${range == null ? '' : '?start=${date(range!.start)}&end=${date(range!.end)}'}',
        ),
        api.get('/v1/skincare/journal'),
        api.get('/v1/analyses'),
      ]);
      if (mounted && generation == loadGeneration) {
        setState(() {
          routines = Map<String, dynamic>.from(responses[0]);
          history = Map<String, dynamic>.from(responses[1]);
          journal = maps(responses[2]);
          analyses = maps(responses[3]);
          moreJournal = journal.length == 50;
          moreAnalyses = analyses.length == 50;
        });
      }
    } catch (e) {
      if (mounted && generation == loadGeneration) {
        setState(
          () => error = e is ApiException ? e.message : 'Unable to load your tracking data. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted && generation == loadGeneration) {
        setState(() => loading = false);
      }
    }
  }

  String date(DateTime value) => value.toIso8601String().substring(0, 10);
  Future<void> action(
    Future<void> Function() operation, {
    bool reload = true,
  }) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
      if (mounted && reload) await refresh();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException
              ? e.message
              : 'Could not confirm the save. Reload and retry safely.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> editRoutine([Map<String, dynamic>? routine]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => RoutineEditor(api: api, routine: routine),
      ),
    );
    if (saved == true && mounted) {
      await refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              routine == null ? 'Routine created for today.' : 'Changes saved for tomorrow in your tracking timezone. Today’s checklist stays unchanged.',
            ),
          ),
        );
      }
    }
  }

  Future<void> editJournal([Map<String, dynamic>? entry]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => JournalEditor(api: api, entry: entry),
      ),
    );
    if (saved == true && mounted) await refresh();
  }

  Future<void> openVanity({bool reports = false}) async {
    final owner = widget.client.auth.currentUser?.id;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => StreamBuilder<AuthState>(
          stream: widget.client.auth.onAuthStateChange,
          builder: (context, snapshot) =>
              owner != null && widget.client.auth.currentUser?.id == owner
              ? reports
                    ? WeeklyReportsPage(api: api)
                    : VanityPage(api: api)
              : Scaffold(
                  appBar: AppBar(title: const Text('Digital vanity')),
                  body: const Center(
                    child: Text(
                      'Your account session changed. Go back and sign in again.',
                    ),
                  ),
                ),
        ),
      ),
    );
    if (reports && mounted) await refresh();
  }

  Future<void> timezone() async {
    final controller = TextEditingController(
      text: routines?['timezone'] as String? ?? 'UTC',
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tracking timezone'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Choose an IANA timezone before your first routine. It stays fixed afterward to preserve daily history. Examples: Asia/Kolkata, America/New_York, UTC.',
            ),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'IANA timezone'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save timezone'),
          ),
        ],
      ),
    );
    // Dialog route may animate out before its controller can be disposed safely.
    if (value != null && mounted) {
      await action(() async {
        await api.write('PUT', '/v1/skincare/settings', {'timezone': value});
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  Future<void> selectDay() async {
    final today = DateTime.parse(routines!['today']);
    final selected = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(day ?? routines!['today']),
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (selected != null && mounted) {
      day = date(selected);
      await refresh();
    }
  }

  Future<void> selectRange() async {
    final today = DateTime.parse(routines!['today']);
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: today,
      initialDateRange:
          range ??
          DateTimeRange(
            start: today.subtract(const Duration(days: 29)),
            end: today,
          ),
    );
    if (selected != null && mounted) {
      range = selected;
      await refresh();
    }
  }

  Future<void> loadOlder(bool isJournal) async {
    await action(() async {
      final offset = isJournal ? journal.length : analyses.length;
      final rows = maps(
        await api.get(
          isJournal
              ? '/v1/skincare/journal?offset=$offset'
              : '/v1/analyses?offset=$offset',
        ),
      );
      if (mounted) {
        setState(() {
          if (isJournal) {
            journal.addAll(rows);
            moreJournal = rows.length == 50;
          } else {
            analyses.addAll(rows);
            moreAnalyses = rows.length == 50;
          }
        });
      }
    }, reload: false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: tab == 4
        ? null
        : AppBar(
            title: const Text(appName),
            actions: [
              IconButton(
                tooltip: 'Digital vanity',
                onPressed: openVanity,
                icon: const Icon(Icons.inventory_2_outlined),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: loading || busy ? null : refresh,
                icon: const Icon(Icons.refresh),
              ),
              TextButton(
                onPressed: () => widget.client.auth.signOut(),
                child: const Text('Sign out'),
              ),
            ],
          ),
    body: IndexedStack(
      index: tab == 4 ? 1 : 0,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (loading || busy) const LinearProgressIndicator(),
                if (error != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Text(error!),
                          TextButton(
                            onPressed: loading || busy ? null : refresh,
                            child: const Text('Retry loading'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!loading && error == null && routines != null) ...[
                  Text(
                    'Tracking timezone: ${routines!['timezone']} · Today: ${routines!['today']}',
                  ),
                  if (routines!['timezone_locked'] != true)
                    TextButton(
                      onPressed: busy ? null : timezone,
                      child: const Text('Choose tracking timezone'),
                    ),
                  const SizedBox(height: 16),
                  if (tab == 0) ...dashboard(),
                  if (tab == 1) ...routinePage(),
                  if (tab == 2) ...journalPage(),
                  if (tab == 3)
                    SkinProgress(
                      analyses: analyses,
                      loadMore: moreAnalyses && !busy
                          ? () => loadOlder(false)
                          : null,
                    ),
                ],
              ],
            ),
          ),
        ),
        if (scanOpened) ScanHome(client: widget.client, apiUrl: widget.apiUrl),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) {
        final leavingScan = tab == 4 && v != 4;
        setState(() {
          tab = v;
          if (v == 4) scanOpened = true;
        });
        if (v != 4 && (day != null || leavingScan)) {
          day = null;
          refresh();
        }
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Today'),
        NavigationDestination(icon: Icon(Icons.checklist), label: 'Routines'),
        NavigationDestination(icon: Icon(Icons.edit_note), label: 'Journal'),
        NavigationDestination(icon: Icon(Icons.show_chart), label: 'Progress'),
        NavigationDestination(icon: Icon(Icons.face), label: 'Skin analysis'),
      ],
    ),
  );
  List<Widget> dashboard() {
    final todayRows = day == null
        ? maps(routines!['routines'])
              .where((r) => r['scheduled'] == true)
              .toList()
        : <Map<String, dynamic>>[];
    return [
      WeeklyReportsShortcut(
        key: ValueKey(loadGeneration),
        api: api,
        open: () => openVanity(reports: true),
      ),
      OutlinedButton.icon(
        onPressed: openVanity,
        icon: const Icon(Icons.inventory_2_outlined),
        label: const Text('Open digital vanity'),
      ),
      Text(
        'Today’s routines',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      if (todayRows.isEmpty)
        const Text(
          'No scheduled routines today. Create a routine or review your schedule.',
        ),
      for (final routine in todayRows) routineCard(routine),
      TextButton(
        onPressed: busy ? null : () => editRoutine(),
        child: const Text('Create routine'),
      ),
      ...summary(),
      FilledButton.tonal(
        onPressed: busy ? null : () => editJournal(),
        child: const Text('Log a skin concern'),
      ),
      const SizedBox(height: 16),
      if (analyses.isEmpty) ...[
        const Text('No skin analyses yet.'),
        TextButton(
          onPressed: () => setState(() => tab = 4),
          child: const Text('Open skin analysis'),
        ),
      ] else ...[
        const Text('Most recent skin analysis'),
        SavedAnalysis(analysis: analyses.first),
      ],
      TextButton(
        onPressed: () => setState(() => tab = 3),
        child: const Text('View skin progress'),
      ),
    ];
  }

  List<Widget> routinePage() => [
    Wrap(
      spacing: 8,
      children: [
        FilledButton(
          onPressed: busy ? null : () => editRoutine(),
          child: const Text('Create routine'),
        ),
        TextButton(
          onPressed: busy ? null : selectDay,
          child: Text('Check-ins for ${routines!['date']}'),
        ),
        if (day != null)
          TextButton(
            onPressed: () {
              day = null;
              refresh();
            },
            child: const Text('Back to today'),
          ),
      ],
    ),
    if ((routines!['routines'] as List).isEmpty)
      const Text('No routines yet. Build your own steps from scratch.'),
    for (final routine in maps(routines!['routines'])) routineCard(routine),
    ...summary(),
    ExpansionTile(
      title: const Text('Completion history (scheduled routine days)'),
      children: [
        for (final state in maps(history!['days']))
          ListTile(
            title: Text(
              '${state['local_date']} · ${state['definition']['name']}',
            ),
            subtitle: Text(
              '${state['completion']} · ${(state['completed_steps'] as List).length}/${(state['definition']['steps'] as List).length} steps',
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: busy
                ? null
                : () {
                    day = state['local_date'];
                    refresh();
                  },
          ),
        if ((history!['days'] as List).isEmpty)
          const ListTile(title: Text('No scheduled days in this period.')),
      ],
    ),
  ];
  List<Widget> summary() {
    final value = history!['summary'] as Map;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Adherence · ${value['start']} to ${value['end']}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '${value['completed']}/${value['scheduled']} scheduled routines completed · ${value['partial']} partial',
              ),
              Text(
                value['adherence_percent'] == null
                    ? 'No scheduled opportunities in this period.'
                    : '${value['adherence_percent']}% completed',
              ),
              for (final streak in value['routines'] as List)
                Builder(
                  builder: (context) {
                    final found = maps(routines!['routines'])
                        .where((r) => r['routine_id'] == streak['routine_id']);
                    final name = found.isEmpty
                        ? 'Routine'
                        : found.first['definition']['name'];
                    return Text(
                      '$name: streak ${streak['current_streak']}, best ${streak['longest_streak']} scheduled days (through ${value['end']})',
                    );
                  },
                ),
              const Text(
                'All steps must be complete. Unscheduled and paused days do not break streaks. Today has until midnight; missing past days do. Edits start tomorrow.',
              ),
              TextButton(
                onPressed: busy ? null : selectRange,
                child: const Text('Choose summary period'),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget routineCard(Map<String, dynamic> routine) {
    final definition = routine['definition'] as Map;
    final done = Set<String>.from(routine['completed_steps'] as List);
    final revision = routine['latest_revision'] as Map;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${definition['name']} · ${definition['kind']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Edit routine',
                  onPressed: busy ? null : () => editRoutine(routine),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            if ((definition['description'] as String? ?? '').isNotEmpty)
              Text(definition['description']),
            Text(
              routine['scheduled'] == true
                  ? '${routine['completion']} · ${routine['local_date']}'
                  : 'Not scheduled for this date · ${definition['status']}',
            ),
            if (revision['id'] != routine['revision_id']) ...[
              Text(
                'This checklist keeps the steps scheduled for ${routine['local_date']}. Your edit is saved below.',
              ),
              ExpansionTile(
                title: Text(
                  'Saved version · starts ${revision['effective_from']}',
                ),
                subtitle: Text(
                  '${revision['definition']['name']} · ${(revision['definition']['steps'] as List).length} steps · ${revision['definition']['status']}',
                ),
                children: [
                  for (final step in revision['definition']['steps'] as List)
                    ListTile(
                      title: Text(step['name']),
                      subtitle: Text(
                        [step['product'], step['notes']]
                            .whereType<String>()
                            .where((s) => s.isNotEmpty)
                            .join('\n'),
                      ),
                    ),
                ],
              ),
            ],
            for (final step in definition['steps'] as List)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(step['name']),
                subtitle: Text(
                  [
                    step['product'],
                    step['notes'],
                  ].whereType<String>().where((s) => s.isNotEmpty).join('\n'),
                ),
                value: done.contains(step['id']),
                onChanged: busy || routine['scheduled'] != true
                    ? null
                    : (yes) => action(() async {
                        final updated = {...done};
                        yes == true
                            ? updated.add(step['id'])
                            : updated.remove(step['id']);
                        await api.write(
                          'PUT',
                          '/v1/skincare/routines/${routine['routine_id']}/checkins',
                          {
                            'local_date': routine['local_date'],
                            'revision_id': routine['revision_id'],
                            'completed_steps': updated.toList()..sort(),
                          },
                        );
                      }),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> journalPage() => [
    Text('Skin journal', style: Theme.of(context).textTheme.headlineSmall),
    const Text(
      'Private, user-reported observations. These are not AI findings or diagnoses.',
    ),
    FilledButton(
      onPressed: busy ? null : () => editJournal(),
      child: const Text('Log a skin concern'),
    ),
    if (journal.isEmpty)
      const Text('No observations yet. You can log a concern without a photo.'),
    for (final entry in journal)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text((entry['concerns'] as List).join(', ')),
              Text(
                '${entry['severity'] ?? 'Severity not specified'} · ${entry['observed_at']}',
              ),
              if ((entry['notes'] as String? ?? '').isNotEmpty)
                Text(entry['notes']),
              Wrap(
                children: [
                  TextButton(
                    onPressed: busy ? null : () => editJournal(entry),
                    child: const Text('Edit observation'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final yes = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Delete this observation?'),
                                content: const Text(
                                  'This removes this journal entry permanently.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (yes == true && mounted) {
                              await action(() async {
                                await api.write(
                                  'DELETE',
                                  '/v1/skincare/journal/${entry['id']}',
                                );
                              });
                            }
                          },
                    child: const Text('Delete observation'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    if (moreJournal)
      TextButton(
        onPressed: busy ? null : () => loadOlder(true),
        child: const Text('Load older observations'),
      ),
  ];
}
