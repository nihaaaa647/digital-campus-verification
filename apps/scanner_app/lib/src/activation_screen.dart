import 'package:campus_ui/campus_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Turns whatever is typed into `XXXX-XXXX`: capitals and digits only, a hyphen after the fourth, at most 8.
class ActivationCodeFormatter extends TextInputFormatter {
  const ActivationCodeFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final letters = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final kept = letters.length > 8 ? letters.substring(0, 8) : letters;
    final text = kept.length > 4 ? '${kept.substring(0, 4)}-${kept.substring(4)}' : kept;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// Where a guard types the code the admin gave them. Calls [onSubmit] with the server address and the code;
/// it returns what to tell the guard if it did not work, or null if it did (the parent then replaces this screen).
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key, required this.initialServer, required this.onSubmit, this.onCancel, this.notice});

  final String initialServer;
  final Future<String?> Function(String server, String code) onSubmit;

  /// Present when the scanner can still scan without activating (it already has keys); returns to scanning.
  final VoidCallback? onCancel;

  /// A line above the form, for example why the guard is here.
  final String? notice;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  late final TextEditingController _server;
  final TextEditingController _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.initialServer)..addListener(_changed);
    _code.addListener(_changed);
  }

  void _changed() => setState(() {});

  bool get _ready => _server.text.trim().isNotEmpty && _code.text.replaceAll('-', '').length == 8 && !_busy;

  Future<void> _submit() async {
    if (!_ready) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    String? problem;
    try {
      problem = await widget.onSubmit(_server.text.trim(), _code.text);
    } catch (_) {
      problem = 'Something went wrong. Try again.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(alignment: Alignment.centerLeft, child: BrandMark(icon: Icons.vpn_key_rounded, size: 56)),
                  const SizedBox(height: 20),
                  Text('Activate this scanner', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    widget.notice ?? 'Ask the admin for a one-time code for this gate, then enter it here with the server address.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _server,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://your-project.supabase.co', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _code,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: const [ActivationCodeFormatter()],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 4, fontFeatures: [FontFeature.tabularFigures()]),
                    decoration: const InputDecoration(labelText: 'Activation code', hintText: 'XXXX-XXXX', border: OutlineInputBorder()),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(CampusTheme.radiusInner)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_error!, style: TextStyle(color: scheme.onErrorContainer, fontSize: 15, height: 1.35))),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _ready ? _submit : null,
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3))
                        : const Text('Activate scanner'),
                  ),
                  if (widget.onCancel != null) ...[
                    const SizedBox(height: 8),
                    TextButton(onPressed: _busy ? null : widget.onCancel, child: const Text('Not now')),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
