import 'package:flutter/material.dart';

import 'api.dart';

class AccountPage extends StatefulWidget {
  final AnalysisApi api;
  final Future<void> Function() signOut;

  const AccountPage({super.key, required this.api, required this.signOut});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  bool busy = true;
  bool requested = false;
  String? error;

  @override
  void initState() {
    super.initState();
    checkRequest();
  }

  Future<void> checkRequest({bool submit = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = submit
          ? await widget.api.write('POST', '/v1/account/deletion-request')
          : await widget.api.get('/v1/account/deletion-request');
      if (mounted) setState(() => requested = result['requested'] == true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not check the request. Refresh its status before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> requestDeletion() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request account deletion?'),
        content: const Text(
          'This requests permanent removal of your account and saved aaina data. '
          'The request stays pending while the aaina team processes it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Submit request'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await checkRequest(submit: true);
  }

  Future<void> signOut() async {
    setState(() => busy = true);
    try {
      await widget.signOut();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Could not sign out. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Privacy and data',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Your routines, journal, scan results, and vanity are saved to your account. '
              'Skin scans and try-on send photos to YouCam after consent. '
              'aaina schedules deletion of its temporary copies. YouCam handles its copies under its own terms. '
              'When you use Chat or Talk, Gemini receives your conversation and the context you choose to share.',
            ),
            const SizedBox(height: 24),
            Text(
              'Account deletion',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (busy) const LinearProgressIndicator(),
            if (requested) const Text('Your deletion request is pending.'),
            if (error != null) ...[
              Text(error!),
              TextButton(
                onPressed: busy ? null : checkRequest,
                child: const Text('Refresh request status'),
              ),
            ],
            if (!requested && error == null)
              OutlinedButton(
                onPressed: busy ? null : requestDeletion,
                child: const Text('Request account deletion'),
              ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: busy ? null : signOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    ),
  );
}
