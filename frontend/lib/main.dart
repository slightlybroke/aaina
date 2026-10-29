import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'camera_capture.dart';
import 'photo_input.dart';
import 'skincare_home.dart';

const appName = String.fromEnvironment('APP_NAME', defaultValue: 'aaina');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  const api = String.fromEnvironment('API_BASE_URL');
  if (url.isEmpty || key.isEmpty || api.isEmpty) {
    runApp(
      const BeautyApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Configure the public Supabase URL/key and API_BASE_URL using --dart-define-from-file=.env.',
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }
  await Supabase.initialize(url: url, publishableKey: key);
  runApp(
    BeautyApp(
      home: AuthGate(client: Supabase.instance.client, apiUrl: api),
    ),
  );
}

class BeautyApp extends StatelessWidget {
  final Widget home;
  const BeautyApp({super.key, required this.home});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: appName,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff416d60)),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: home,
  );
}

class AuthGate extends StatelessWidget {
  final SupabaseClient client;
  final String apiUrl;
  const AuthGate({super.key, required this.client, required this.apiUrl});
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: client.auth.onAuthStateChange,
    builder: (context, snapshot) => client.auth.currentSession == null
        ? SignIn(client: client)
        : SkincareHome(
            key: ValueKey(client.auth.currentUser!.id),
            client: client,
            apiUrl: apiUrl,
          ),
  );
}

class SignIn extends StatefulWidget {
  final SupabaseClient client;
  const SignIn({super.key, required this.client});
  @override
  State<SignIn> createState() => _SignInState();
}

class _SignInState extends State<SignIn> {
  final email = TextEditingController(), password = TextEditingController();
  bool busy = false;
  String? message;
  Future<void> authenticate(bool register) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (register) {
        final result = await widget.client.auth.signUp(
          email: email.text.trim(),
          password: password.text,
        );
        if (result.session == null && mounted) {
          setState(() => message = 'Confirm your email, then sign in.');
        }
      } else {
        await widget.client.auth.signInWithPassword(
          email: email.text.trim(),
          password: password.text,
        );
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Unable to connect. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(appName)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/branding/aaina.png',
                  width: 112,
                  height: 112,
                  semanticLabel: 'aaina mirror logo',
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Understand your skin',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Sign in to keep your analysis history in your account.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            if (message != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(message!)),
            const SizedBox(height: 16),
            if (busy) const LinearProgressIndicator(),
            FilledButton(
              onPressed: busy ? null : () => authenticate(false),
              child: const Text('Sign in'),
            ),
            TextButton(
              onPressed: busy ? null : () => authenticate(true),
              child: const Text('Create account'),
            ),
          ],
        ),
      ),
    ),
  );
}

class ScanHome extends StatefulWidget {
  final SupabaseClient client;
  final String apiUrl;
  final AnalysisApi? api;
  final PhotoInput? photoInput;
  final WidgetBuilder? captureBuilder;
  const ScanHome({
    super.key,
    required this.client,
    required this.apiUrl,
    this.api,
    this.photoInput,
    this.captureBuilder,
  });
  @override
  State<ScanHome> createState() => _ScanHomeState();
}

class _ScanHomeState extends State<ScanHome> {
  late final AnalysisApi api =
      widget.api ?? AnalysisApi(widget.client, widget.apiUrl);
  late final PhotoInput photoInput = widget.photoInput ?? PhotoInput();
  Uint8List? image;
  String? retryKey, error;
  String? inputError, inputNotice;
  ImageSource? retrySource;
  Map<String, dynamic>? job;
  List<dynamic> history = [], jobs = [];
  bool consent = false, busy = false, loading = true, polling = false;
  bool selecting = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    unawaited(recoverSelection());
  }

  @override
  void dispose() {
    timer?.cancel();
    api.close();
    super.dispose();
  }

  void showError(Object e) {
    if (mounted) {
      setState(
        () => error = e is ApiException
            ? e.message
            : 'Unable to connect. Please retry.',
      );
    }
  }

  Future<void> refresh() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final results = await Future.wait([
        api.get('/v1/analyses'),
        api.get('/v1/jobs'),
      ]);
      if (mounted) {
        setState(() {
          history = results[0] as List;
          jobs = results[1] as List;
        });
      }
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> recoverSelection() async {
    setState(() => selecting = true);
    try {
      final bytes = await photoInput.recover();
      if (bytes != null && mounted) {
        acceptPhoto(bytes);
        setState(
          () => inputNotice = 'Your interrupted photo selection was recovered. Review it and confirm consent before uploading.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          inputError = photoInputMessage(e);
          retrySource = ImageSource.gallery;
        });
      }
    } finally {
      if (mounted) setState(() => selecting = false);
    }
  }

  void acceptPhoto(Uint8List bytes) {
    timer?.cancel();
    setState(() {
      image = bytes;
      retryKey = const Uuid().v4();
      job = null;
      error = null;
      inputError = null;
      inputNotice = null;
    });
  }

  Future<void> select(ImageSource source) async {
    if (!consent || busy || selecting) return;
    setState(() {
      selecting = true;
      inputError = null;
      inputNotice = null;
      retrySource = source;
    });
    try {
      Uint8List? bytes;
      if (source == ImageSource.gallery) {
        bytes = await photoInput.gallery();
      } else {
        final captured = await Navigator.of(context).push<XFile>(
          MaterialPageRoute(
            builder: widget.captureBuilder ?? (_) => const CameraCapture(),
          ),
        );
        if (captured != null) bytes = await photoInput.read(captured);
      }
      if (mounted && bytes != null) acceptPhoto(bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          image = null;
          retryKey = null;
          inputError = photoInputMessage(e);
        });
      }
    } finally {
      if (mounted) setState(() => selecting = false);
    }
  }

  Future<void> submit() async {
    if (!consent || image == null || retryKey == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final created = await api.submit(image!, retryKey!);
      if (!mounted) return;
      setState(() {
        job = created;
        image = null;
      });
      watch();
      await refresh();
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void watch() {
    timer?.cancel();
    unawaited(poll());
    timer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(poll()),
    );
  }

  Future<void> poll() async {
    if (polling || job == null) return;
    polling = true;
    final requestedJob = job!['id'];
    try {
      final current = await api.get('/v1/jobs/$requestedJob');
      if (!mounted || job?['id'] != requestedJob) return;
      setState(() {
        job = Map<String, dynamic>.from(current);
        error = null;
      });
      if (['completed', 'failed', 'expired'].contains(job!['status'])) {
        timer?.cancel();
        await refresh();
      }
    } catch (e) {
      showError(e);
    } finally {
      polling = false;
    }
  }

  Future<void> signOut() async {
    try {
      await widget.client.auth.signOut();
    } catch (e) {
      showError(e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(appName),
      actions: [
        TextButton(
          onPressed: busy ? null : signOut,
          child: const Text('Sign out'),
        ),
      ],
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'A closer look at your skin',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Use a clear, front-facing photo with even lighting, no glasses and a neutral expression. '
              'HD scans need at least 1080 pixels on the short side. Capture conditions can affect comparisons.',
            ),
            const SizedBox(height: 16),
            const Text(
              'Your photo is stored privately and sent to Perfect Corp / YouCam for analysis. '
              'Our temporary copy is scheduled for deletion after completion or failure, with a one-hour maximum target. '
              'Deletion retries are tracked; outages may delay deletion. Scores remain in your account. '
              'YouCam processes a separate copy under its own retention terms; app deletion does not delete that copy.',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: consent,
              onChanged: busy || selecting
                  ? null
                  : (value) => setState(() => consent = value ?? false),
              title: const Text(
                'I consent to uploading my photo and sending it to YouCam for AI skin analysis.',
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: !consent || busy || selecting
                      ? null
                      : () => select(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Choose photo'),
                ),
                if (!kIsWeb &&
                    (defaultTargetPlatform == TargetPlatform.android ||
                        defaultTargetPlatform == TargetPlatform.iOS))
                  OutlinedButton.icon(
                    onPressed: !consent || busy || selecting
                        ? null
                        : () => select(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Take photo'),
                  ),
              ],
            ),
            if (selecting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(
                  semanticsLabel: 'Preparing selected photo',
                ),
              ),
            if (inputNotice != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(inputNotice!),
              ),
            if (inputError != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(inputError!),
                      TextButton(
                        onPressed:
                            !consent || selecting || busy || retrySource == null
                            ? null
                            : () => select(retrySource!),
                        child: const Text('Retry photo selection'),
                      ),
                      const Text(
                        'You can also choose the other input method above.',
                      ),
                    ],
                  ),
                ),
              ),
            if (image != null && consent) ...[
              const SizedBox(height: 16),
              Image.memory(image!, height: 220, fit: BoxFit.contain),
              FilledButton(
                onPressed: busy || selecting || !consent ? null : submit,
                child: Text(
                  busy ? 'Uploading…' : 'Analyze photo / retry upload',
                ),
              ),
            ],
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(error!),
                      TextButton(
                        onPressed: () {
                          unawaited(refresh());
                          if (job != null) watch();
                        },
                        child: const Text('Retry connection'),
                      ),
                    ],
                  ),
                ),
              ),
            if (job != null) JobCard(job: job!, onRefresh: poll),
            if (job?['analysis'] is Map)
              ResultCard(analysis: Map<String, dynamic>.from(job!['analysis'])),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent scans',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: refresh,
                  tooltip: 'Refresh history',
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            if (!loading && jobs.isEmpty)
              const Text('No scans yet. Your first analysis will appear here.'),
            for (final item in jobs)
              ListTile(
                title: Text('Scan · ${item['status']}'),
                subtitle: Text('${item['created_at']}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  setState(() => job = Map<String, dynamic>.from(item));
                  watch();
                },
              ),
            const SizedBox(height: 24),
            Text(
              'Analysis history',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (!loading && history.isEmpty)
              const Text('Completed results will be saved here.'),
            for (final analysis in history)
              ResultCard(analysis: Map<String, dynamic>.from(analysis)),
            const SizedBox(height: 20),
            const Text(
              'AI estimates describe visible skin characteristics. They are not medical diagnoses or a measure of your worth.',
            ),
          ],
        ),
      ),
    ),
  );
}

class JobCard extends StatelessWidget {
  final Map<String, dynamic> job;
  final VoidCallback onRefresh;
  const JobCard({super.key, required this.job, required this.onRefresh});
  @override
  Widget build(BuildContext context) {
    final state = job['status'];
    final active = !['completed', 'failed', 'expired'].contains(state);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Analysis: $state',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (active) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const Text(
                'You can return later. This job is saved to your account.',
              ),
            ],
            if (job['error_code'] != null)
              Text(jobError('${job['error_code']}')),
            if (state == 'failed' || state == 'expired')
              const Text(
                'Choose a photo again to deliberately start a new scan. This may use additional credits.',
              ),
            Text('Temporary photo cleanup: ${job['cleanup_status']}'),
            TextButton(onPressed: onRefresh, child: const Text('Check status')),
          ],
        ),
      ),
    );
  }
}

String jobError(String code) => switch (code) {
  'error_src_face_too_small' => 'Your face is too small in the photo for analysis. Use a closer, front-facing portrait that still meets the image resolution requirement.',
  'submission_unknown' => 'Submission could not be confirmed. We did not automatically submit again. Contact the operator before starting another scan.',
  'error_no_face' => 'No face was detected. Try a clear front-facing photo.',
  'error_pose' => 'Face the camera directly and try again.',
  'missing_overall_score' => 'YouCam did not return the required overall score. No replacement score was calculated.',
  'unapproved_asset_host' =>
    'The provider returned an asset host that needs operator verification.',
  'job_expired' =>
    'The analysis timed out. It was not automatically resubmitted.',
  _ =>
    'Analysis could not finish ($code). Check with the operator before starting another scan.',
};

class ResultCard extends StatelessWidget {
  final Map<String, dynamic> analysis;
  const ResultCard({super.key, required this.analysis});
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Overall score · ${(analysis['overall_score'] as num).toStringAsFixed(1)} / 100',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text('${analysis['analyzed_at'] ?? ''}'),
          const Text(
            'Higher scores indicate more favorable visible characteristics in YouCam’s scoring system. '
            'Concern UI scores are adjusted by YouCam; raw scores are shown separately.',
          ),
          const SizedBox(height: 12),
          for (final metric in analysis['metrics'] as List)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '${metric['concern'].toString().replaceFirst('hd_', '').replaceAll('_', ' ')}'
                '${metric['region'] == null ? '' : ' · ${metric['region']}'}'
                '\nUI: ${metric['ui_score'] ?? 'Unavailable'}   Raw: ${metric['raw_score'] ?? 'Unavailable'}',
              ),
            ),
          if ((analysis['warnings'] as List? ?? []).isNotEmpty)
            Text(
              'Some requested data was unavailable: ${(analysis['warnings'] as List).join(', ')}',
            ),
        ],
      ),
    ),
  );
}
