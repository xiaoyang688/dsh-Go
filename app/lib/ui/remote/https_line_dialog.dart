import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/https_launch_url.dart';
import '../../remote/relay/relay_backend.dart' show RelayHost;
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';

Future<void> showRemoteHttpsLine(BuildContext context, RelayHost host, RemoteHttpsScope scope) => showAppDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _HttpsLineDialog(host: host, scope: scope),
);

class _HttpsLineDialog extends ConsumerStatefulWidget {
  const _HttpsLineDialog({required this.host, required this.scope});

  final RelayHost host;
  final RemoteHttpsScope scope;

  @override
  ConsumerState<_HttpsLineDialog> createState() => _HttpsLineDialogState();
}

class _HttpsLineDialogState extends ConsumerState<_HttpsLineDialog> {
  final _url = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit({bool clear = false}) async {
    if (_busy) return;
    final input = clear ? null : _url.text;
    if (input != null && parseRemoteHttpsLaunchUrl(input) == null) {
      setState(() => _error = context.l10n.remoteHttpsInvalidUrl);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(remoteHttpsSettingsProvider).save(widget.scope, widget.host.id, input);
      if (mounted) Navigator.of(context).pop();
    } on RemoteHttpsSettingsException {
      if (mounted) setState(() => _error = context.l10n.remoteHttpsSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current =
        ref.watch(remoteHttpsScopeProvider) == widget.scope &&
        ref.watch(relayAccountProvider).asData?.value.hostById(widget.host.id) != null;
    final stored = current ? ref.watch(remoteHttpsLaunchUrlProvider(widget.host.id)) : const AsyncData<Uri?>(null);
    final configured = stored.asData?.value != null;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.remoteHttpsLine),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Text(widget.host.name),
              Text(l10n.remoteHttpsHelp),
              Text(
                !current
                    ? l10n.remoteHttpsScopeChanged
                    : stored.hasError
                    ? l10n.remoteHttpsReadFailed
                    : stored.isLoading
                    ? l10n.remoteHttpsLoading
                    : configured
                    ? l10n.remoteHttpsConfigured
                    : l10n.remoteHttpsUnconfigured,
              ),
              TextField(
                controller: _url,
                enabled: current && !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: l10n.remoteHttpsAuthorizationUrl,
                  hintText: 'https://host.example/dsh/',
                  errorText: _error,
                  errorMaxLines: 3,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
          if (current && (configured || stored.hasError))
            TextButton(onPressed: _busy ? null : () => _submit(clear: true), child: Text(l10n.remoteHttpsClear)),
          FilledButton(onPressed: current && !_busy ? _submit : null, child: Text(l10n.commonSave)),
        ],
      ),
    );
  }
}
