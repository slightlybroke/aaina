import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'aaina_brand.dart';
import 'skincare_home.dart';

String authRedirect({required bool recovery}) {
  if (kIsWeb) {
    final base = Uri.base;
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: base.path,
      query: recovery ? 'recovery=1' : null,
    ).toString();
  }
  return 'aaina://auth/${recovery ? 'recovery' : 'confirm'}';
}

class AuthGate extends StatefulWidget {
  final SupabaseClient client;
  final String apiUrl;

  const AuthGate({super.key, required this.client, required this.apiUrl});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final StreamSubscription<AuthState> subscription;
  bool recovering = false;
  bool recoveryComplete = false;
  String? linkError;

  @override
  void initState() {
    super.initState();
    subscription = widget.client.auth.onAuthStateChange.listen(
      (state) {
        setState(() {
          if (state.event == AuthChangeEvent.passwordRecovery) {
            recovering = true;
            recoveryComplete = false;
          }
          if (state.event == AuthChangeEvent.signedOut) recovering = false;
          linkError = null;
        });
      },
      onError: (Object error) {
        if (mounted) {
          setState(
            () => linkError = 'The email link could not be opened. Request a fresh link and open it on the same device and browser.',
          );
        }
      },
    );
  }

  @override
  void dispose() {
    unawaited(subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.client.auth.currentUser;
    if (recovering || recoveryComplete || user == null || linkError != null) {
      return AuthPage(
        key: ValueKey((recovering, recoveryComplete, linkError)),
        client: widget.client,
        initialMode: recovering
            ? AuthMode.newPassword
            : recoveryComplete || linkError != null
            ? AuthMode.signIn
            : AuthMode.welcome,
        initialMessage: recoveryComplete
            ? 'Password updated. Sign in with your new password.'
            : linkError,
        onPasswordUpdated: () async {
          await widget.client.auth.signOut(scope: SignOutScope.local);
          if (mounted) {
            setState(() {
              recovering = false;
              recoveryComplete = true;
            });
          }
        },
        onSignedIn: () => setState(() {
          recoveryComplete = false;
          linkError = null;
        }),
      );
    }
    return SkincareHome(
      key: ValueKey(user.id),
      client: widget.client,
      apiUrl: widget.apiUrl,
    );
  }
}

enum AuthMode { welcome, signIn, signUp, reset, newPassword }

class AuthPage extends StatefulWidget {
  final SupabaseClient client;
  final AuthMode initialMode;
  final String? initialMessage;
  final Future<void> Function() onPasswordUpdated;
  final VoidCallback onSignedIn;

  const AuthPage({
    super.key,
    required this.client,
    required this.initialMode,
    required this.onPasswordUpdated,
    required this.onSignedIn,
    this.initialMessage,
  });

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();
  late AuthMode mode = widget.initialMode;
  late String? notice = widget.initialMessage;
  bool busy = false;
  bool revealPassword = false;
  int preview = 0;

  void show(AuthMode destination, {String? message}) {
    setState(() {
      mode = destination;
      notice = message;
      password.clear();
      confirmation.clear();
      revealPassword = false;
    });
  }

  Future<void> submit() async {
    if (busy || form.currentState?.validate() != true) return;
    setState(() {
      busy = true;
      notice = null;
    });
    final auth = widget.client.auth;
    final address = email.text.trim();
    try {
      switch (mode) {
        case AuthMode.welcome:
          break;
        case AuthMode.signIn:
          await auth.signInWithPassword(
            email: address,
            password: password.text,
          );
          if (mounted) widget.onSignedIn();
        case AuthMode.signUp:
          final result = await auth.signUp(
            email: address,
            password: password.text,
            emailRedirectTo: authRedirect(recovery: false),
          );
          if (mounted && result.session == null) {
            show(
              AuthMode.signIn,
              message:
                  'Check your email for a confirmation link, then sign in.',
            );
          }
        case AuthMode.reset:
          await auth.resetPasswordForEmail(
            address,
            redirectTo: authRedirect(recovery: true),
          );
          if (mounted) {
            show(
              AuthMode.signIn,
              message: 'If an account exists for that email, a reset link will arrive shortly. Open it on this device and browser.',
            );
          }
        case AuthMode.newPassword:
          await auth.updateUser(UserAttributes(password: password.text));
          if (mounted) await widget.onPasswordUpdated();
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => notice = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => notice =
              'Could not connect. Check your connection and try again.',
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
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: AainaWordmark(width: 160),
              ),
              const SizedBox(height: 32),
              if (mode == AuthMode.welcome)
                ...welcome(context)
              else
                authForm(context),
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> welcome(BuildContext context) {
    const features = [
      (
        Icons.face_retouching_natural,
        'Understand your skin',
        'Choose a photo for a skin scan and compare saved results over time.',
      ),
      (
        Icons.checklist,
        'Build a routine',
        'Create morning and evening rituals and check off each step.',
      ),
      (
        Icons.edit_note,
        'Keep a private journal',
        'Record how your skin feels and review your observations.',
      ),
      (
        Icons.inventory_2_outlined,
        'Make more of your makeup',
        'Organize your vanity and plan looks with products you own.',
      ),
    ];
    final (icon, title, description) = features[preview];
    final theme = Theme.of(context);
    return [
      Text(
        'Beauty, on your terms.',
        style: theme.textTheme.displaySmall?.copyWith(fontFamily: 'Georgia'),
      ),
      const SizedBox(height: 12),
      Text(
        'Understand your skin, build routines and make the most of what you own.',
        style: theme.textTheme.bodyLarge,
      ),
      const SizedBox(height: 24),
      Card(
        margin: EdgeInsets.zero,
        color: theme.colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(description),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Previous feature',
                    onPressed: preview == 0
                        ? null
                        : () => setState(() => preview--),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  IconButton(
                    tooltip: 'Next feature',
                    onPressed: preview == features.length - 1
                        ? null
                        : () => setState(() => preview++),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: () => show(AuthMode.signUp),
        child: const Text('Create account'),
      ),
      TextButton(
        onPressed: () => show(AuthMode.signIn),
        child: const Text('Sign in'),
      ),
    ];
  }

  Widget authForm(BuildContext context) {
    final newPassword = mode == AuthMode.newPassword;
    final reset = mode == AuthMode.reset;
    final create = mode == AuthMode.signUp;
    final setPassword = create || newPassword;
    final (title, action) = switch (mode) {
      AuthMode.signIn => ('Sign in to aaina', 'Sign in'),
      AuthMode.signUp => ('Create your account', 'Create account'),
      AuthMode.reset => ('Reset your password', 'Send reset link'),
      AuthMode.newPassword => ('Choose a new password', 'Save password'),
      AuthMode.welcome => throw StateError('Welcome has no form'),
    };
    return AutofillGroup(
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 20),
            if (!newPassword)
              TextFormField(
                controller: email,
                enabled: !busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (value) =>
                    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                        .hasMatch(value?.trim() ?? '')
                    ? null
                    : 'Enter a valid email address.',
                onFieldSubmitted: reset ? (_) => submit() : null,
              ),
            if (!reset) ...[
              if (!newPassword) const SizedBox(height: 12),
              TextFormField(
                controller: password,
                enabled: !busy,
                obscureText: !revealPassword,
                autofillHints: [
                  setPassword
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                decoration: InputDecoration(
                  labelText: newPassword ? 'New password' : 'Password',
                  suffixIcon: IconButton(
                    tooltip: revealPassword ? 'Hide password' : 'Show password',
                    onPressed: () =>
                        setState(() => revealPassword = !revealPassword),
                    icon: Icon(
                      revealPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Enter a password.';
                  }
                  if (setPassword && value.length < 8) {
                    return 'Use at least 8 characters.';
                  }
                  return null;
                },
                onFieldSubmitted: setPassword ? null : (_) => submit(),
              ),
              if (setPassword) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: confirmation,
                  enabled: !busy,
                  obscureText: !revealPassword,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(
                    labelText: 'Confirm password',
                  ),
                  validator: (value) => value == password.text
                      ? null
                      : 'The passwords must match.',
                  onFieldSubmitted: (_) => submit(),
                ),
              ],
            ],
            if (notice != null) ...[
              const SizedBox(height: 12),
              Semantics(liveRegion: true, child: Text(notice!)),
            ],
            const SizedBox(height: 16),
            if (busy) const LinearProgressIndicator(),
            FilledButton(onPressed: busy ? null : submit, child: Text(action)),
            if (mode == AuthMode.signIn)
              TextButton(
                onPressed: busy ? null : () => show(AuthMode.reset),
                child: const Text('Forgot password?'),
              ),
            if (!newPassword)
              TextButton(
                onPressed: busy
                    ? null
                    : () => show(reset ? AuthMode.signIn : AuthMode.welcome),
                child: Text(reset ? 'Back to sign in' : 'Back to welcome'),
              ),
          ],
        ),
      ),
    );
  }
}
