// First launch: create an account, log in, or try the demo.
import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../auth/auth_api.dart';
import '../widgets/common.dart';

class WelcomeScreen extends StatefulWidget {
  /// true when opened from Setup (there's something to go back to)
  final bool fromSetup;
  const WelcomeScreen({super.key, this.fromSetup = false});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

enum _Page { welcome, login, signup, pending }

class _WelcomeScreenState extends State<WelcomeScreen> {
  _Page _page = _Page.welcome;
  final _email = TextEditingController(), _name = TextEditingController(), _pass = TextEditingController();
  late final _server = TextEditingController(text: app.serverUrl);
  bool _busy = false, _showServer = false, _hide = true;
  String? _err;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in [_email, _name, _pass, _server]) {
      c.dispose();
    }
    super.dispose();
  }

  void _go(_Page p) {
    _poll?.cancel();
    setState(() {
      _page = p;
      _err = null;
    });
  }

  Future<void> _done() async {
    await app.setWelcomed();
    if (!mounted) return;
    if (widget.fromSetup) {
      Navigator.of(context).pop(true);
    } else {
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  Future<void> _submit() async {
    app.serverUrl = _server.text;
    _server.text = app.serverUrl;
    final email = _email.text.trim(), pw = _pass.text;
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final api = app.auth;
      final r = _page == _Page.signup ? await api.signup(email, _name.text.trim(), pw) : await api.login(email, pw);
      if (r.pending) {
        _go(_Page.pending);
        _startPolling();
      } else {
        await app.signedInAs(r.token!, r.user);
        if (mounted) toast(context, _page == _Page.signup ? 'Welcome aboard, ${r.user.name}' : 'Signed in as ${r.user.name}');
        await _done();
      }
    } on AuthException catch (e) {
      // a pending account trying to log in
      if (e.status == 403 && e.message.contains('approved')) {
        _go(_Page.pending);
        _startPolling();
      } else {
        setState(() => _err = e.message);
      }
    } catch (e) {
      setState(() => _err = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _checkApproved(quiet: true));
  }

  Future<void> _checkApproved({bool quiet = false}) async {
    try {
      final r = await app.auth.checkApproved(_email.text.trim(), _pass.text);
      if (r != null) {
        _poll?.cancel();
        await app.signedInAs(r.token!, r.user);
        if (mounted) toast(context, 'Approved! Welcome aboard, ${r.user.name}');
        await _done();
      } else if (!quiet && mounted) {
        toast(context, 'Not approved yet');
      }
    } catch (e) {
      if (!quiet && mounted) toast(context, '$e', error: true);
    }
  }

  Future<void> _tryDemo() async {
    await app.setDemoMode(true);
    await _done();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: widget.fromSetup || _page != _Page.welcome
          ? AppBar(leading: BackButton(onPressed: () => _page == _Page.welcome ? Navigator.of(context).pop() : _go(_Page.welcome)))
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: switch (_page) {
                _Page.welcome => _welcome(t),
                _Page.login || _Page.signup => _form(t),
                _Page.pending => _pending(t),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _logo(ThemeData t) => Column(children: [
        Icon(Icons.sailing, size: 64, color: t.colorScheme.primary),
        const SizedBox(height: 8),
        RichText(
          text: TextSpan(style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: t.colorScheme.onSurface), children: [
            const TextSpan(text: 'Wake'),
            TextSpan(text: 'Back', style: TextStyle(color: t.colorScheme.primary)),
          ]),
        ),
      ]);

  Widget _welcome(ThemeData t) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _logo(t),
        const SizedBox(height: 8),
        Text('Record your sailing, replay your races, and share them with friends.',
            textAlign: TextAlign.center, style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 32),
        FilledButton(onPressed: () => _go(_Page.signup), style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)), child: const Text('Create account')),
        const SizedBox(height: 10),
        FilledButton.tonal(onPressed: () => _go(_Page.login), style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)), child: const Text('Log in')),
        const SizedBox(height: 24),
        OutlinedButton.icon(onPressed: _tryDemo, icon: const Icon(Icons.science_outlined), label: const Text('Try the demo')),
        const SizedBox(height: 6),
        Text('Pretend pucks and a demo race, nothing saved. Leave it any time from Setup.',
            textAlign: TextAlign.center, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        if (!widget.fromSetup) ...[
          const SizedBox(height: 24),
          TextButton(onPressed: _done, child: Text('Use without an account (just this phone and your pucks)', style: t.textTheme.bodySmall)),
        ],
      ]);

  Widget _form(ThemeData t) {
    final signup = _page == _Page.signup;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _logo(t),
      const SizedBox(height: 20),
      Text(signup ? 'Create your account' : 'Log in', style: t.textTheme.headlineSmall, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      if (signup)
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Your name', hintText: 'as your mates know you', prefixIcon: Icon(Icons.person_outline)),
        ),
      if (signup) const SizedBox(height: 10),
      TextField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email)),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _pass,
        obscureText: _hide,
        decoration: InputDecoration(
          labelText: 'Password',
          helperText: signup ? 'At least 8 characters' : null,
          prefixIcon: const Icon(Icons.key),
          suffixIcon: IconButton(icon: Icon(_hide ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _hide = !_hide)),
        ),
        onSubmitted: (_) => _busy ? null : _submit(),
      ),
      if (_err != null) ...[
        const SizedBox(height: 10),
        Text(_err!, style: TextStyle(color: t.colorScheme.error, fontWeight: FontWeight.w600)),
      ],
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _submit,
        style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
        child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(signup ? 'Create account' : 'Log in'),
      ),
      const SizedBox(height: 8),
      TextButton(onPressed: () => _go(signup ? _Page.login : _Page.signup), child: Text(signup ? 'Already have an account? Log in' : 'New here? Create an account')),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => setState(() => _showServer = !_showServer),
        child: Text('Advanced', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ),
      if (_showServer)
        TextField(
          controller: _server,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Server', helperText: 'Your own WakeBack server, if not the usual one', prefixIcon: Icon(Icons.dns_outlined)),
        ),
    ]);
  }

  Widget _pending(ThemeData t) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _logo(t),
        const SizedBox(height: 20),
        Icon(Icons.hourglass_top, size: 40, color: t.colorScheme.primary),
        const SizedBox(height: 12),
        Text('Waiting for approval', style: t.textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('Your account (${_email.text.trim()}) has been requested. Once it\'s approved you\'ll be signed in automatically; '
            'this screen checks every 20 seconds.',
            textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 20),
        FilledButton.tonal(onPressed: () => _checkApproved(), child: const Text('Check now')),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: _tryDemo, icon: const Icon(Icons.science_outlined), label: const Text('Try the demo meanwhile')),
      ]);
}
