/// Turns what a person typed as a server address into the project's base address, or null if it is not one.
/// `xyz.supabase.co` becomes `https://xyz.supabase.co`; a trailing slash is dropped. `http://` is accepted
/// only when [allowInsecure] is set (development): Android blocks it in release builds anyway.
///
/// The scanner app has the same function; the two apps share no code except `credential_core`.
Uri? parseServerAddress(String input, {bool allowInsecure = false}) {
  var text = input.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
  if (!text.contains('://')) text = '${allowInsecure && _looksLocal(text) ? 'http' : 'https'}://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'https' && !(allowInsecure && uri.scheme == 'http')) return null;
  if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) return null;
  final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
  return uri.replace(path: path);
}

/// `192.168.1.5:8787`, `127.0.0.1:8787`, `localhost:8787`: a development server, which has no certificate.
bool _looksLocal(String text) => RegExp(r'^(localhost|\d{1,3}(\.\d{1,3}){3})(:\d+)?(/|$)').hasMatch(text);
