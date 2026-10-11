import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/location_service.dart';
import '../services/prepared_photo.dart';
import '../widgets/capture_frame.dart';

/// What the camera hands back: the photo as taken (GPS removal happens next,
/// in [PreparedPhoto.prepare]).
class CapturedPhoto {
  const CapturedPhoto(this.bytes, this.origin, this.capturedAt);

  final Uint8List bytes;
  final PhotoOrigin origin;
  final DateTime? capturedAt;
}

/// The in-app camera. It exists — rather than handing over to the system
/// camera app — for one reason: only an in-app preview can show the square
/// the on-device model actually looks at (widgets/capture_frame.dart).
///
/// Resolution: the sensor's maximum. Until the thesis fixes how a field photo
/// is reduced before the model sees it (open question 1 to the thesis agent,
/// 2026-10-11), the model runs on the photo as taken — the 12 MP path that
/// was measured on the S22 (0.41–0.46 s, peak 473,089 kB; report §4).
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  String? _error;
  bool _permissionProblem = false;
  bool _busy = false;
  FlashMode _flash = FlashMode.off;
  Offset? _focusMark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  /// The camera is released while the app is in the background and opened
  /// again on return — the plugin's documented requirement.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (state == AppLifecycleState.inactive) {
      if (c == null || !c.value.isInitialized) return;
      _controller = null;
      c.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _init();
    }
  }

  Future<void> _init() async {
    setState(() {
      _error = null;
      _permissionProblem = false;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'This device has no camera. You can still pick a photo.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(back, ResolutionPreset.max, enableAudio: false);
      await controller.initialize();
      try {
        await controller.setFlashMode(_flash);
      } catch (_) {
        // No flash on this camera: the button simply does nothing visible.
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } on CameraException catch (e) {
      if (!mounted) return;
      final permission = e.code.toLowerCase().contains('access') ||
          e.code.toLowerCase().contains('permission');
      setState(() {
        _permissionProblem = permission;
        _error = permission
            ? 'The app may not use the camera. Allow it in the app\'s settings, '
                'or pick a photo from the gallery.'
            : 'The camera could not be opened (${e.code}: ${e.description}).';
      });
    }
  }

  Future<void> _shoot() async {
    final c = _controller;
    if (c == null || _busy || c.value.isTakingPicture) return;
    setState(() => _busy = true);
    try {
      final pressedAt = DateTime.now();
      final file = await c.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      Navigator.of(context).pop(CapturedPhoto(bytes, PhotoOrigin.camera, pressedAt));
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('The photo could not be taken (${e.description}).')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    Navigator.of(context).pop(CapturedPhoto(bytes, PhotoOrigin.gallery, null));
  }

  Future<void> _cycleFlash() async {
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    try {
      await _controller?.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {
      // Unsupported on this camera.
    }
  }

  Future<void> _focusAt(TapDownDetails d, BoxConstraints box) async {
    final c = _controller;
    if (c == null) return;
    final point = Offset(
      (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0),
      (d.localPosition.dy / box.maxHeight).clamp(0.0, 1.0),
    );
    setState(() => _focusMark = d.localPosition);
    try {
      if (c.value.focusPointSupported) await c.setFocusPoint(point);
      if (c.value.exposurePointSupported) await c.setExposurePoint(point);
    } catch (_) {
      // Best effort: not every camera supports metering points.
    }
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusMark = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Close',
                  color: Colors.white,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Flash',
                  color: Colors.white,
                  icon: Icon(switch (_flash) {
                    FlashMode.auto => Icons.flash_auto,
                    FlashMode.always => Icons.flash_on,
                    _ => Icons.flash_off,
                  }),
                  onPressed: c == null ? null : _cycleFlash,
                ),
              ],
            ),
            Expanded(
              child: Center(
                child: c == null
                    ? _placeholder()
                    : CameraPreview(
                        c,
                        child: LayoutBuilder(
                          builder: (context, box) => GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (d) => _focusAt(d, box),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                const CustomPaint(
                                  painter: CaptureFramePainter(color: Colors.white),
                                ),
                                if (_focusMark != null)
                                  Positioned(
                                    left: _focusMark!.dx - 28,
                                    top: _focusMark!.dy - 28,
                                    child: Container(
                                      width: 56,
                                      height: 56,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 1.5),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 12, 24, 4),
              child: Text(
                'Fill the square with the plant. The on-device model sees only '
                'what is inside it; the photo keeps the rest.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: 'Choose from the gallery',
                    iconSize: 30,
                    color: Colors.white,
                    icon: const Icon(Icons.photo_library_outlined),
                    onPressed: _busy ? null : _pickFromGallery,
                  ),
                  _ShutterButton(busy: _busy, onPressed: c == null ? null : _shoot),
                  const SizedBox(width: 48), // balances the gallery button
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    if (_error == null) return const CircularProgressIndicator(color: Colors.white);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 48),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            alignment: WrapAlignment.center,
            children: [
              if (_permissionProblem)
                OutlinedButton(
                  onPressed: LocationTracker.openAppSettings,
                  child: const Text('App settings'),
                ),
              OutlinedButton(onPressed: _init, child: const Text('Try again')),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Take photo',
        child: GestureDetector(
          onTap: busy ? null : onPressed,
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
            ),
            padding: const EdgeInsets.all(5),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: onPressed == null ? Colors.white24 : Colors.white,
              ),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : null,
            ),
          ),
        ),
      );
}
