import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

enum PhotoOrigin { camera, gallery }

/// Why no photo came back, in words for the student.
class PhotoException implements Exception {
  const PhotoException(this.message);

  final String message;

  @override
  String toString() => 'PhotoException($message)';
}

/// Where the enrolment photo comes from. The server accepts a JPEG or PNG of 1 KB to 1.5 MB; the picker
/// below shrinks to a face-sized JPEG, far below that.
abstract interface class PhotoSource {
  /// The photo, or null if the student backed out.
  Future<Uint8List?> take(PhotoOrigin origin);
}

class DevicePhotoSource implements PhotoSource {
  DevicePhotoSource({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<Uint8List?> take(PhotoOrigin origin) async {
    try {
      final file = await _picker.pickImage(
        source: origin == PhotoOrigin.camera ? ImageSource.camera : ImageSource.gallery,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 900,
        maxHeight: 900,
        imageQuality: 82,
      );
      return file == null ? null : await file.readAsBytes();
    } on Exception catch (e) {
      throw PhotoException(e.toString());
    }
  }
}
