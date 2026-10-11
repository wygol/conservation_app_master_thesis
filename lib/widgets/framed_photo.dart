import 'package:flutter/material.dart';

import 'capture_frame.dart';

/// A photograph with the model's field of view marked on it.
///
/// The frame is computed from the size the image actually DECODES to — read
/// from the image stream, not from the EXIF header — because that decoded
/// image is exactly what the model's preprocessing receives (lib/ml/
/// preprocess.dart decodes with the same engine). Whatever the decoder does
/// with an EXIF orientation, the frame shown is the square the model saw.
class FramedPhoto extends StatefulWidget {
  const FramedPhoto({
    super.key,
    required this.image,
    this.showFrame = true,
    this.borderRadius = 16,
    this.onTap,
  });

  final ImageProvider image;
  final bool showFrame;
  final double borderRadius;
  final VoidCallback? onTap;

  @override
  State<FramedPhoto> createState() => _FramedPhotoState();
}

class _FramedPhotoState extends State<FramedPhoto> {
  ImageStream? _stream;
  late final ImageStreamListener _listener =
      ImageStreamListener(_onImage, onError: _onError);
  Size? _size;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(FramedPhoto old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) {
      _size = null;
      _failed = false;
      _resolve();
    }
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool _) {
    if (!mounted) return;
    setState(() => _size = Size(info.image.width.toDouble(), info.image.height.toDouble()));
  }

  void _onError(Object _, StackTrace? _) {
    if (mounted) setState(() => _failed = true);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = _size;
    final Widget content;
    if (_failed) {
      content = AspectRatio(
        aspectRatio: 4 / 3,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.broken_image_outlined, color: scheme.outline, size: 40),
              const SizedBox(height: 8),
              Text('The photo could not be loaded',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      );
    } else if (size == null) {
      content = AspectRatio(
        aspectRatio: 3 / 4,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    } else {
      content = AspectRatio(
        aspectRatio: size.width / size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(image: widget.image, fit: BoxFit.cover, gaplessPlayback: true),
            if (widget.showFrame)
              CustomPaint(
                painter: CaptureFramePainter(
                  color: Colors.white,
                  strokeWidth: 3,
                  dimOutside: true,
                ),
              ),
          ],
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: widget.onTap, child: content),
      ),
    );
  }
}

/// Full-screen, zoomable view of a photo.
class PhotoViewerScreen extends StatelessWidget {
  const PhotoViewerScreen({super.key, required this.image, this.caption});

  final ImageProvider image;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: caption == null ? null : Text(caption!, style: const TextStyle(fontSize: 16)),
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image(image: image, fit: BoxFit.contain)),
      ),
    );
  }
}
