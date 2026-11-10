import 'package:flutter/material.dart';

import '../auth/auth_api.dart';
import '../dock/store.dart';
import '../puck/puck_ble.dart';
import '../sync/server_sync.dart';

/// An error as a sentence a sailor can act on. Our own exceptions already carry one; a network failure
/// becomes "no internet / server not answering"; anything else is cut short.
String friendly(Object e) {
  if (e is AuthException) return e.message;
  if (e is SyncException) return e.message;
  if (e is PuckException) return e.message;
  if (e is DockError) return e.message;
  final d = '$e';
  const net = ['SocketException', 'Connection refused', 'Failed host lookup', 'TimeoutException', 'HandshakeException', 'ClientException', 'Connection reset', 'Network is unreachable'];
  if (net.any(d.contains)) return 'No internet on this network, or the server isn\'t answering. Check your signal and try again.';
  var short = d.replaceFirst(RegExp(r'^(Exception|StateError|FormatException|Bad state): '), '').trim();
  if (short.length > 120) short = '${short.substring(0, 117)}…';
  return 'Something went wrong: $short';
}

void toast(BuildContext context, String msg, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? Colors.red.shade800 : null,
    behavior: SnackBarBehavior.floating,
    duration: Duration(seconds: error ? 6 : 4),
  ));
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
      child: Text(text.toUpperCase(), style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary, letterSpacing: 1.2)),
    );
  }
}

class Hint extends StatelessWidget {
  final String text;
  const Hint(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text(text, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.35));
  }
}

/// A scrolling page of cards. On a phone it's a plain list. On a tablet, or a phone on its side, the cards sit in
/// a centred column no wider than [maxWidth], so lines of text stay readable instead of running the width of the
/// screen, while a swipe anywhere still scrolls.
class PageList extends StatelessWidget {
  static const double maxWidth = 720;
  final EdgeInsets padding;
  final List<Widget>? children;
  final int? itemCount;
  final NullableIndexedWidgetBuilder? itemBuilder;

  const PageList({super.key, this.padding = EdgeInsets.zero, required List<Widget> this.children})
      : itemCount = null,
        itemBuilder = null;

  const PageList.builder({super.key, this.padding = EdgeInsets.zero, required int this.itemCount, required NullableIndexedWidgetBuilder this.itemBuilder}) : children = null;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final spare = box.maxWidth - maxWidth - padding.horizontal;
        final side = spare > 0 ? spare / 2 : 0.0;
        final p = padding.copyWith(left: padding.left + side, right: padding.right + side);
        final kids = children;
        return kids != null ? ListView(padding: p, children: kids) : ListView.builder(padding: p, itemCount: itemCount, itemBuilder: itemBuilder!);
      });
}
