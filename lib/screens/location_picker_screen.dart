import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/basemaps.dart';

/// Set a record's position by hand: move the map until the cross sits on the
/// spot. The fallback when there is no usable GPS fix — indoors, at the desk,
/// or for a record entered afterwards. The record then says so in
/// dwc:georeferenceProtocol ("position set by hand on a map").
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, required this.initial, this.initialZoom = 17});

  final LatLng initial;
  final double initialZoom;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  late LatLng _centre = widget.initial;
  Basemap _basemap = Basemap.fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set position on map'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: BasemapButton(
              value: _basemap,
              onChanged: (b) => setState(() => _basemap = b),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: widget.initial,
              initialZoom: widget.initialZoom,
              maxZoom: 21,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (camera, _) => setState(() => _centre = camera.center),
            ),
            children: [
              _basemap.layer(),
              _basemap.attributionWidget(),
            ],
          ),
          // The cross marks the map's centre — the position that will be used.
          IgnorePointer(
            child: Center(
              child: Icon(Icons.add, size: 44, color: theme.colorScheme.error, shadows: const [
                Shadow(color: Colors.white, blurRadius: 4),
              ]),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${_centre.latitude.toStringAsFixed(6)}, '
                      '${_centre.longitude.toStringAsFixed(6)}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(_centre),
                      icon: const Icon(Icons.check),
                      label: const Text('Use this position'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
