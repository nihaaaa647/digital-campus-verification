import 'dart:io';

import 'package:flutter/services.dart';

/// An asset bundle that reads the app's asset files straight from the package folder. Widget tests use it
/// instead of `rootBundle`, whose process-wide cache does not survive across fake-async tests.
class DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}
