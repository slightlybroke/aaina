import 'package:flutter/material.dart';

import 'api.dart';

/// Independent loading: a report service error never blocks today's checklist.
class WeeklyReportsShortcut extends StatefulWidget {
  final AnalysisApi api;
  final Future<void> Function() open;
  const WeeklyReportsShortcut({
    super.key,
    required this.api,
    required this.open,
  });
  @override
  State<WeeklyReportsShortcut> createState() => _WeeklyReportsShortcutState();
}

class _WeeklyReportsShortcutState extends State<WeeklyReportsShortcut> {
  bool unread = false, failed = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = await widget.api.get('/v1/weekly-reports');
      if (mounted) {
        setState(() {
          unread = data['has_unread'] == true;
          failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    icon: Icon(
      unread ? Icons.notifications_active_outlined : Icons.summarize_outlined,
    ),
    label: Text(
      unread
          ? 'Weekly Beauty Brief - new report'
          : failed
          ? 'Weekly Beauty Brief - check availability'
          : 'Weekly Beauty Brief',
    ),
    onPressed: () async {
      await widget.open();
      if (mounted) await load();
    },
  );
}

class WeeklyReportsPage extends StatefulWidget {
  final AnalysisApi api;
  const WeeklyReportsPage({super.key, required this.api});
  @override
  State<WeeklyReportsPage> createState() => _WeeklyReportsPageState();
}

class _WeeklyReportsPageState extends State<WeeklyReportsPage> {
  List<dynamic> reports = [];
  Map<String, dynamic>? selected;
  bool busy = false, more = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> action(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException
              ? e.message
              : 'Could not load reports. Check your connection and retry.',
        );
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> fetch({bool next = false}) async {
    final data = await widget.api.get(
      '/v1/weekly-reports?offset=${next ? reports.length : 0}',
    );
    if (mounted) {
      setState(() {
        reports = [...(next ? reports : []), ...data['items']];
        more = data['has_more'] == true;
      });
    }
  }

  Future<void> load() => action(() => fetch());
  Future<void> chooseTimezone() async {
    Map? settings;
    await action(() async {
      settings = await widget.api.get('/v1/skincare/settings');
    });
    if (!mounted || settings == null) return;
    String selectedZone = settings!['timezone'];
    final zone = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Report tracking timezone'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              settings!['timezone_locked'] == true
                  ? 'Routine history fixes this timezone. Confirming also enables reports if you have not saved tracking settings before.'
                  : 'Use an IANA timezone such as Asia/Kolkata or UTC. Reports use its calendar week. This setting also controls daily routine dates.',
            ),
            TextFormField(
              initialValue: selectedZone,
              onChanged: (v) => selectedZone = v,
              enabled: settings!['timezone_locked'] != true,
              decoration: const InputDecoration(labelText: 'IANA timezone'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, selectedZone.trim()),
            child: const Text('Confirm timezone'),
          ),
        ],
      ),
    );
    if (zone == null || !mounted) return;
    await action(() async {
      await widget.api.write('PUT', '/v1/skincare/settings', {
        'timezone': zone,
      });
      await fetch();
    });
  }

  Future<void> open(String id) => action(() async {
    final report = await widget.api.get('/v1/weekly-reports/$id');
    if (mounted) setState(() => selected = Map<String, dynamic>.from(report));
  });
  Future<void> generate() => action(() async {
    final report = await widget.api.write(
      'POST',
      '/v1/weekly-reports/generate',
    );
    if (mounted) setState(() => selected = Map<String, dynamic>.from(report));
    await fetch();
  });
  Future<void> markRead() => action(() async {
    final report = await widget.api.write(
      'POST',
      '/v1/weekly-reports/${selected!['id']}/read',
    );
    if (mounted) setState(() => selected = Map<String, dynamic>.from(report));
    await fetch();
  });
  String score(dynamic n) => n is num ? n.toStringAsFixed(2) : 'Not available';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Weekly Beauty Brief')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'A calm look at your last completed Monday-Sunday week in your tracking timezone. Routines, saved skin analyses and your observations stay separate. No new scan or AI call is made.',
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: busy ? null : generate,
                  child: const Text('Prepare last week’s brief'),
                ),
                TextButton(
                  onPressed: busy ? null : load,
                  child: const Text('Refresh reports'),
                ),
                TextButton(
                  onPressed: busy ? null : chooseTimezone,
                  child: const Text('Set report timezone'),
                ),
              ],
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null) ...[
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: busy ? null : load,
                child: const Text('Retry loading reports'),
              ),
            ],
            if (!busy && reports.isEmpty)
              const Text(
                'No weekly reports yet. Set or confirm your report timezone, then prepare a brief. Automatic reports appear when the report worker is running.',
              ),
            if (selected != null) ...detail(),
            const SizedBox(height: 16),
            Text(
              'Report history',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final report in reports)
              Card(
                child: ListTile(
                  leading: Icon(
                    report['read_at'] == null
                        ? Icons.notifications_active_outlined
                        : Icons.task_alt,
                  ),
                  title: Text(
                    '${report['week_start']} to ${report['week_end']}',
                  ),
                  subtitle: Text(
                    '${report['timezone']} · ${report['read_at'] == null ? 'Unread' : 'Read'}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy ? null : () => open(report['id']),
                ),
              ),
            if (more)
              TextButton(
                onPressed: busy ? null : () => action(() => fetch(next: true)),
                child: const Text('Load older reports'),
              ),
          ],
        ),
      ),
    ),
  );
  List<Widget> detail() {
    final report = selected!, content = report['content'] as Map;
    final routine = content['routine'] as Map,
        skin = content['skin'] as Map,
        journal = content['journal'] as Map;
    final comparison = skin['comparison'] as Map?;
    return [
      const Divider(),
      Text(
        '${report['week_start']} to ${report['week_end']}',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      Text(
        'Timezone: ${report['timezone']} · Snapshot generated ${report['generated_at']}',
      ),
      if (report['read_at'] == null)
        TextButton(
          onPressed: busy ? null : markRead,
          child: const Text('Mark this report as read'),
        ),
      Text('Routine completion', style: Theme.of(context).textTheme.titleLarge),
      Text(
        '${routine['completed']} complete · ${routine['partial']} partial · ${routine['scheduled']} scheduled routine-days',
      ),
      Text(
        routine['adherence_percent'] == null
            ? 'No scheduled routine-days; adherence is not calculated.'
            : 'Completion: ${routine['adherence_percent']}%',
      ),
      for (final r in routine['routines'])
        Text(
          '${r['name']}: streak at week end ${r['current_streak']} · longest through week end ${r['longest_streak']} scheduled days',
        ),
      const SizedBox(height: 12),
      Text(
        'Saved skin analyses',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      Text('${skin['count']} saved analyses this week'),
      if (skin['latest'] != null)
        Text(
          'Latest overall score: ${score(skin['latest']['overall_score'])} / 100',
        ),
      Text(skin['message']),
      if (comparison != null) ...[
        Text(
          'Overall: ${score(comparison['first_score'])} → ${score(comparison['last_score'])} · change ${score(comparison['score_change'])} points',
        ),
        ExpansionTile(
          title: const Text('Comparable concern metrics'),
          children: [
            if ((comparison['metrics'] as List).isEmpty)
              const ListTile(
                title: Text('No matching regional scores available.'),
              ),
            for (final metric in comparison['metrics'])
              ListTile(
                title: Text(
                  '${metric['concern']} · ${metric['region'] ?? 'unregionalized'}',
                ),
                subtitle: Text(
                  [
                    for (final field in ['ui_score', 'raw_score'])
                      if (metric[field] != null)
                        '${field == 'ui_score' ? 'UI' : 'Raw'}: ${score(metric[field]['first'])} → ${score(metric[field]['last'])}',
                  ].join('\n'),
                ),
              ),
          ],
        ),
      ],
      const SizedBox(height: 12),
      Text('Your observations', style: Theme.of(context).textTheme.titleLarge),
      Text(
        '${journal['entries']} journal entries. These are user-reported, not AI findings.',
      ),
      for (final entry in (journal['concerns'] as Map).entries)
        Text('${entry.key}: ${entry.value} entries'),
      for (final entry in (journal['severity_counts'] as Map).entries)
        Text('${entry.key} severity: ${entry.value} entries'),
      for (final suggestion in content['suggestions'])
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(suggestion),
        ),
      Text(content['notes']),
      const Divider(),
    ];
  }
}
