import 'package:flutter/material.dart';

String? comparisonGroup(Map<String, dynamic> analysis) {
  if (analysis['api_version'] != '2.1' ||
      analysis['response_format'] != 'zip') {
    return null;
  }
  final metrics = analysis['metrics'];
  if (metrics is! List || metrics.isEmpty) return null;
  final concerns = metrics.whereType<Map>().map((m) => m['concern']).toSet();
  if (concerns.any((c) => c is! String || !c.startsWith('hd_'))) return null;
  final names = concerns.cast<String>().toList()..sort();
  return '2.1|zip|${names.join(',')}';
}

num? validScore(dynamic value) =>
    value is num && value.isFinite && value >= 1 && value <= 100 ? value : null;
String metricKey(Map metric) =>
    '${metric['concern']} · ${metric['region'] ?? 'unregionalized'}';
String scoreText(dynamic score) =>
    validScore(score)?.toStringAsFixed(2) ?? 'Not available';

class SavedAnalysis extends StatelessWidget {
  final Map<String, dynamic> analysis;
  const SavedAnalysis({super.key, required this.analysis});
  @override
  Widget build(BuildContext context) {
    final metrics = analysis['metrics'] is List
        ? analysis['metrics'] as List
        : const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Overall score: ${scoreText(analysis['overall_score'])} / 100',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('Saved at ${analysis['analyzed_at'] ?? 'unknown time'}'),
            const Text(
              'YouCam score: higher indicates more favorable visible characteristics. This is not a diagnosis.',
            ),
            ExpansionTile(
              title: Text('Available metrics (${metrics.length})'),
              children: [
                if (metrics.isEmpty)
                  const ListTile(title: Text('No concern metrics saved.')),
                for (final metric in metrics.whereType<Map>())
                  ListTile(
                    title: Text(metricKey(metric)),
                    subtitle: Text(
                      'UI: ${scoreText(metric['ui_score'])}   Raw: ${scoreText(metric['raw_score'])}',
                    ),
                  ),
              ],
            ),
            for (final warning
                in (analysis['warnings'] is List
                    ? analysis['warnings'] as List
                    : const []))
              Text('Provider note: $warning'),
          ],
        ),
      ),
    );
  }
}

class SkinProgress extends StatefulWidget {
  final List<Map<String, dynamic>> analyses;
  final VoidCallback? loadMore;
  const SkinProgress({super.key, required this.analyses, this.loadMore});
  @override
  State<SkinProgress> createState() => _SkinProgressState();
}

class _SkinProgressState extends State<SkinProgress> {
  final selected = <String>{};
  @override
  Widget build(BuildContext context) {
    final chosen =
        widget.analyses.where((a) => selected.contains(a['id'])).toList()..sort(
          (a, b) =>
              (DateTime.tryParse(a['analyzed_at'] as String? ?? '') ??
                      DateTime(0))
                  .compareTo(
                    DateTime.tryParse(b['analyzed_at'] as String? ?? '') ??
                        DateTime(0),
                  ),
        );
    final groups = chosen.map(comparisonGroup).toSet();
    final compatible =
        chosen.length >= 2 &&
        groups.length == 1 &&
        !groups.contains(null) &&
        chosen.every(
          (a) =>
              validScore(a['overall_score']) != null &&
              DateTime.tryParse(a['analyzed_at'] as String? ?? '') != null,
        );
    final common = <String, Map>{};
    if (compatible) {
      for (final metric in (chosen.first['metrics'] as List).whereType<Map>()) {
        common[metricKey(metric)] = metric;
      }
      for (final analysis in chosen.skip(1)) {
        final keys = (analysis['metrics'] as List)
            .whereType<Map>()
            .map(metricKey)
            .toSet();
        common.removeWhere((key, value) => !keys.contains(key));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Skin progress', style: Theme.of(context).textTheme.headlineSmall),
        const Text(
          'Lighting, camera, angle and other conditions affect comparisons. No analysis runs when you open this screen.',
        ),
        if (widget.analyses.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No saved analyses yet. Use Skin analysis when you are ready.',
            ),
          ),
        if (widget.analyses.length == 1)
          const Text(
            'One result saved. A comparison needs another compatible result.',
          ),
        if (widget.analyses.length > 1)
          const Text('Select two or more saved analyses to compare.'),
        if (chosen.length >= 2 && !compatible)
          const Text(
            'These results cannot be compared safely: analysis mode, version, available concerns or score data differ.',
          ),
        if (compatible) ...[
          Semantics(
            label:
                'Overall score trend for ${chosen.length} selected compatible analyses',
            child: SizedBox(
              height: 150,
              child: CustomPaint(painter: ScoreTrend(chosen)),
            ),
          ),
          const Text(
            'Trend uses saved overall scores, without a new scoring formula. Points are spaced by analysis time.',
          ),
          const Text('Shared metrics (first → last selected result):'),
          if (common.isEmpty) const Text('No shared concern regions.'),
          for (final key in common.keys)
            Builder(
              builder: (context) {
                final last = (chosen.last['metrics'] as List)
                    .whereType<Map>()
                    .firstWhere((m) => metricKey(m) == key);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '$key\nUI: ${scoreText(common[key]!['ui_score'])} → ${scoreText(last['ui_score'])}; Raw: ${scoreText(common[key]!['raw_score'])} → ${scoreText(last['raw_score'])}',
                  ),
                );
              },
            ),
        ],
        for (final analysis in widget.analyses) ...[
          if (widget.analyses.length > 1)
            CheckboxListTile(
              title: Text(
                'Compare ${analysis['analyzed_at'] ?? 'undated result'}',
              ),
              value: selected.contains(analysis['id']),
              onChanged: analysis['id'] == null
                  ? null
                  : (yes) => setState(
                      () => yes == true
                          ? selected.add(analysis['id'] as String)
                          : selected.remove(analysis['id']),
                    ),
            ),
          SavedAnalysis(analysis: analysis),
        ],
        if (widget.loadMore != null)
          TextButton(
            onPressed: widget.loadMore,
            child: const Text('Load older analyses'),
          ),
      ],
    );
  }
}

class ScoreTrend extends CustomPainter {
  final List<Map<String, dynamic>> points;
  ScoreTrend(this.points);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff416d60)
      ..strokeWidth = 2;
    final start = DateTime.parse(points.first['analyzed_at'])
        .millisecondsSinceEpoch;
    final end = DateTime.parse(points.last['analyzed_at'])
        .millisecondsSinceEpoch;
    Offset? previous;
    for (var i = 0; i < points.length; i++) {
      final t = DateTime.parse(points[i]['analyzed_at']).millisecondsSinceEpoch;
      final x =
          16 +
          (size.width - 32) *
              (end == start
                  ? i / (points.length - 1)
                  : (t - start) / (end - start));
      final point = Offset(
        x,
        size.height -
            16 -
            (size.height - 32) *
                (points[i]['overall_score'] as num).toDouble() /
                100,
      );
      if (previous != null) canvas.drawLine(previous, point, paint);
      canvas.drawCircle(point, 4, paint);
      previous = point;
    }
  }

  @override
  bool shouldRepaint(ScoreTrend oldDelegate) => true;
}
