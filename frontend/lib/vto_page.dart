import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'camera_capture.dart';
import 'photo_input.dart';

class VtoPage extends StatefulWidget {
  final AnalysisApi api;
  final PhotoInput? photoInput;
  final WidgetBuilder? captureBuilder;
  const VtoPage({
    super.key,
    required this.api,
    this.photoInput,
    this.captureBuilder,
  });
  @override
  State<VtoPage> createState() => _VtoPageState();
}

class _VtoPageState extends State<VtoPage> {
  late final PhotoInput input =
      widget.photoInput ??
      PhotoInput(
        prepare: (bytes) => preparePhoto(
          bytes,
          minimumSide: 100,
          maximumWidth: 1919,
          maximumHeight: 1079,
        ),
      );
  final color = TextEditingController(text: '#B5445C');
  bool consent = false, busy = false, loading = false;
  String mode = 'lip_color', template = '', retryKey = '';
  int intensity = 60;
  String? error, templateError;
  Uint8List? image, preview;
  String? previewJob;
  Timer? previewExpiry;
  List<Map<String, dynamic>> jobs = [], templates = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    color.dispose();
    forgetPreview();
    image = null;
    super.dispose();
  }

  void forgetPreview() {
    previewExpiry?.cancel();
    previewExpiry = null;
    final old = preview;
    if (old != null) unawaited(MemoryImage(old).evict());
    preview = null;
    previewJob = null;
  }

  String message(Object e) => e is ApiException
      ? e.message
      : 'Could not complete this request. Check the connection and retry.';
  Map<String, dynamic> get options => {
    'mode': mode,
    'color': color.text.trim(),
    'intensity': intensity,
    'template_id': mode == 'look' ? template : '',
  };

  void changed() {
    setState(() {
      retryKey = '';
      forgetPreview();
    });
  }

  Future<void> load() async {
    if (loading || busy) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final rows = await widget.api.get('/v1/vto/jobs');
      if (mounted) {
        setState(
          () => jobs = (rows as List)
              .map((j) => Map<String, dynamic>.from(j))
              .toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    }
    try {
      final rows = await widget.api.get('/v1/vto/templates');
      if (mounted) {
        setState(() {
          templates = (rows as List)
              .map((r) => Map<String, dynamic>.from(r))
              .toList();
          templateError = null;
          if (!templates.any((r) => r['id'] == template)) template = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => templateError = message(e));
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> select(bool camera) async {
    if (!consent || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      Uint8List? bytes;
      if (camera) {
        final file = await Navigator.push<XFile>(
          context,
          MaterialPageRoute(
            builder: widget.captureBuilder ?? (_) => const CameraCapture(),
          ),
        );
        if (file != null) bytes = await input.read(file);
      } else {
        bytes = await input.gallery();
      }
      if (mounted && bytes != null) {
        setState(() {
          image = bytes;
          retryKey = '';
          forgetPreview();
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = photoInputMessage(e));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> submit() async {
    if (busy || !consent || image == null) return;
    if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(color.text.trim()) ||
        (mode == 'look' && template.isEmpty)) {
      setState(
        () => error = mode == 'look'
            ? 'Choose a listed Look template.'
            : 'Use a color such as #B5445C.',
      );
      return;
    }
    retryKey = retryKey.isEmpty ? const Uuid().v4() : retryKey;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final job = await widget.api.submitVto(image!, retryKey, options);
      if (mounted) {
        setState(() {
          jobs = [job, ...jobs.where((j) => j['id'] != job['id'])];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              '${message(e)} Refresh jobs before retrying. Retry keeps the same request key.',
        );
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> showPreview(Map<String, dynamic> job) async {
    setState(() {
      busy = true;
      error = null;
      forgetPreview();
    });
    try {
      final bytes = await widget.api.vtoPreview(job['id']);
      if (mounted) {
        setState(() {
          preview = bytes;
          previewJob = job['id'];
          final expiry = DateTime.tryParse(job['expires_at'] ?? '');
          if (expiry != null) {
            final remaining = expiry.difference(DateTime.now());
            previewExpiry = Timer(
              remaining.isNegative ? Duration.zero : remaining,
              () {
                if (mounted) setState(forgetPreview);
              },
            );
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    }
    if (mounted) setState(() => busy = false);
  }

  bool available(Map<String, dynamic> job) {
    final expiry = DateTime.tryParse(job['expires_at'] ?? '');
    return job['status'] == 'completed' &&
        job['result_cleanup'] != 'deleted' &&
        expiry != null &&
        expiry.isAfter(DateTime.now());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Makeup preview'),
      actions: [
        IconButton(
          tooltip: 'Refresh VTO jobs',
          onPressed: busy || loading ? null : load,
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
              'Try a generic matte lip color or a provider-designed Look. This is a simulated image, not an exact match to a product in your Vanity. Lighting and camera conditions affect appearance.',
            ),
            const Text(
              'Sources and previews are private on our backend. Source deletion starts when processing ends; both expire one hour after upload. Cleanup runs through the worker and failures are tracked. Perfect Corp processing/retention terms also apply.',
            ),
            if (loading || busy) const LinearProgressIndicator(),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I consent to sending this selected face image to Perfect Corp / YouCam for makeup preview. I have permission to use it; API credits may be consumed.',
              ),
              value: consent,
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      consent = v == true;
                      if (!consent) {
                        image = null;
                        forgetPreview();
                        retryKey = '';
                      }
                    }),
            ),
            DropdownButtonFormField<String>(
              initialValue: mode,
              decoration: const InputDecoration(labelText: 'Preview type'),
              items: const [
                DropdownMenuItem(
                  value: 'lip_color',
                  child: Text('Matte lip color'),
                ),
                DropdownMenuItem(
                  value: 'look',
                  child: Text('Curated Look template'),
                ),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      mode = v!;
                      changed();
                    },
            ),
            if (mode == 'lip_color') ...[
              TextField(
                controller: color,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Generic color (#RRGGBB)',
                ),
                onChanged: (_) => changed(),
              ),
              Text('Color intensity: $intensity / 100'),
              Slider(
                value: intensity.toDouble(),
                min: 1,
                max: 100,
                divisions: 99,
                label: '$intensity',
                onChanged: busy
                    ? null
                    : (v) {
                        intensity = v.round();
                        changed();
                      },
              ),
              const Text(
                'Original lip shape; automatic skin smoothing is explicitly disabled.',
              ),
            ] else ...[
              if (templateError != null) Text('Templates: $templateError'),
              if (templates.isEmpty)
                const Text(
                  'No templates available. Refresh or switch to lip color.',
                ),
              DropdownButtonFormField<String>(
                key: ValueKey(template),
                initialValue: template.isEmpty ? null : template,
                decoration: const InputDecoration(
                  labelText: 'Provider Look (first 20)',
                ),
                items: templates
                    .map(
                      (r) => DropdownMenuItem<String>(
                        value: r['id'],
                        child: Text(r['title']),
                      ),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (v) {
                        template = v ?? '';
                        changed();
                      },
              ),
              const Text(
                'A curated Look may include multiple makeup/beautification effects. It is independent of your owned products.',
              ),
            ],
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: consent && !busy ? () => select(false) : null,
                  child: const Text('Choose photo'),
                ),
                if (!kIsWeb)
                  OutlinedButton(
                    onPressed: consent && !busy ? () => select(true) : null,
                    child: const Text('Take photo'),
                  ),
              ],
            ),
            if (image != null) ...[
              const Text('Selected photo — not uploaded until you submit'),
              Image.memory(image!, height: 220, fit: BoxFit.contain),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        image = null;
                        retryKey = '';
                      }),
                child: const Text('Remove selected photo'),
              ),
            ],
            FilledButton(
              onPressed: consent && image != null && !busy && !loading
                  ? submit
                  : null,
              child: Text(
                retryKey.isEmpty ? 'Create preview' : 'Retry same request',
              ),
            ),
            const Divider(),
            const Text('Recent preview jobs'),
            if (jobs.isEmpty && !loading)
              const Text(
                'No previews yet. Choose an effect and a photo to begin.',
              ),
            for (final j in jobs)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${j['options']?['mode'] ?? 'VTO'} · ${j['status']}',
                      ),
                      Text(
                        'Expires: ${DateTime.tryParse(j['expires_at'] ?? '')?.toLocal() ?? 'unknown'}',
                      ),
                      if (j['error_code'] != null)
                        Text(
                          j['error_code'] == 'submission_unknown'
                              ? 'Submission outcome is unknown. It will not be automatically repeated; starting a new request may consume credits.'
                              : 'Processing failed: ${j['error_code']}. Check image dimensions, face visibility, and provider access before starting a new request.',
                        ),
                      if ([
                        'uploading',
                        'pending',
                        'submitting',
                        'processing',
                      ].contains(j['status']))
                        const Text(
                          'Processing — refresh to check progress. Refresh never submits a new task.',
                        ),
                      if (available(j))
                        TextButton(
                          onPressed: busy ? null : () => showPreview(j),
                          child: const Text('View private preview'),
                        ),
                      if (j['status'] == 'completed' && !available(j))
                        const Text('Preview retention ended.'),
                      if (j['id'] == previewJob && preview != null)
                        Image.memory(
                          preview!,
                          height: 300,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Text(
                            'Preview could not be displayed. Refresh and retry.',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const Text(
              'A new photo or changed effect starts a new request. Retrying unchanged input reuses its request key. No analysis or preview is created just by opening this screen.',
            ),
          ],
        ),
      ),
    ),
  );
}
