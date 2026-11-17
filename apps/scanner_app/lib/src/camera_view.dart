import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// The live camera, reading QR codes only. This is the one place that touches the camera plugin; the
/// rest of the app takes a [CameraBuilder] so that tests can supply a fake.
///
/// mobile_scanner uses the bundled ML Kit model on Android, so it reads codes with no network and no
/// Play Services download, which a gate scanner needs.
class CameraView extends StatefulWidget {
  const CameraView({super.key, required this.onCode});

  final void Function(String code) onCode;

  @override
  State<CameraView> createState() => _CameraViewState();
}

typedef CameraBuilder = Widget Function(BuildContext context, void Function(String code) onCode);

Widget defaultCameraBuilder(BuildContext context, void Function(String code) onCode) => CameraView(onCode: onCode);

class _CameraViewState extends State<CameraView> {
  final MobileScannerController _camera = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
  );

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _camera,
          onDetect: (capture) {
            for (final barcode in capture.barcodes) {
              final text = barcode.rawValue;
              if (text != null) widget.onCode(text);
            }
          },
          errorBuilder: (context, error) => _CameraError(error: error),
        ),
        // Above the saved-count panel at the bottom, where a thumb reaches it.
        Positioned(
          right: 20,
          bottom: 128 + MediaQuery.paddingOf(context).bottom,
          child: ValueListenableBuilder<MobileScannerState>(
            valueListenable: _camera,
            builder: (context, state, _) {
              if (state.torchState == TorchState.unavailable) return const SizedBox.shrink();
              final on = state.torchState == TorchState.on;
              return IconButton.filled(
                tooltip: on ? 'Torch off' : 'Torch on',
                iconSize: 28,
                style: IconButton.styleFrom(
                  fixedSize: const Size(60, 60),
                  // On a dark camera view a dark button vanishes: use a light ring and a lit fill when on.
                  backgroundColor: on ? Colors.white : Colors.white.withValues(alpha: 0.2),
                  foregroundColor: on ? Colors.black : Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: on ? 0 : 0.7), width: 2),
                ),
                icon: Icon(on ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded),
                onPressed: _camera.toggleTorch,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography, size: 64, color: Colors.white70),
              const SizedBox(height: 16),
              Text(
                denied ? 'Camera access is off' : "The camera can't start",
                style: const TextStyle(color: Colors.white, fontSize: 20),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                denied
                    ? 'Turn on the camera for this app in Settings → Apps → Campus Gate → Permissions, then reopen it.'
                    : 'Close other apps that use the camera, then reopen this one.',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
