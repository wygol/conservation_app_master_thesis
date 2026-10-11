/// The background maps. Raster tiles straight from their publishers: no API
/// key, no tile server of our own, nothing to run (ADR 011).
///
/// basemap.at is Austria's official administrative basemap (CC BY 4.0), so it
/// shows paths, huts and terrain the way Austrian park staff know them — but
/// only inside Austria. OpenStreetMap covers the rest of the world. The URL
/// templates come from basemap.at's WMTS capabilities (TileMatrixSet
/// google3857, zoom 0–20; note the row-before-column order); maxNativeZoom 19
/// is the deepest level checked by hand at the test park (2026-10-11).
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

enum Basemap {
  grey(
    label: 'Grey (basemap.at)',
    url: 'https://mapsneu.wien.gv.at/basemap/bmapgrau/normal/google3857/{z}/{y}/{x}.png',
    attribution: 'basemap.at (CC BY 4.0)',
    maxNativeZoom: 19,
  ),
  standard(
    label: 'Standard (basemap.at)',
    url: 'https://mapsneu.wien.gv.at/basemap/geolandbasemap/normal/google3857/{z}/{y}/{x}.png',
    attribution: 'basemap.at (CC BY 4.0)',
    maxNativeZoom: 19,
  ),
  orthophoto(
    label: 'Aerial photo (basemap.at)',
    url: 'https://mapsneu.wien.gv.at/basemap/bmaporthofoto30cm/normal/google3857/{z}/{y}/{x}.jpeg',
    attribution: 'basemap.at (CC BY 4.0)',
    maxNativeZoom: 19,
  ),
  osm(
    label: 'OpenStreetMap',
    url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attribution: 'OpenStreetMap contributors',
    maxNativeZoom: 19,
  );

  const Basemap({
    required this.label,
    required this.url,
    required this.attribution,
    required this.maxNativeZoom,
  });

  final String label;
  final String url;
  final String attribution;
  final int maxNativeZoom;

  /// The default: grey keeps the coloured markers the loudest thing on screen.
  static const fallback = Basemap.grey;

  /// The tile layer. The user agent names the app, as OpenStreetMap's tile
  /// usage policy requires; it is the Android application id.
  TileLayer layer() => TileLayer(
        urlTemplate: url,
        maxNativeZoom: maxNativeZoom,
        userAgentPackageName: 'com.example.conservation_app',
      );

  /// Attribution is a licence condition for every one of these sources.
  Widget attributionWidget() => SimpleAttributionWidget(
        source: Text(attribution),
        backgroundColor: Colors.white.withValues(alpha: 0.8),
      );
}

/// A compact menu to switch the basemap.
class BasemapButton extends StatelessWidget {
  const BasemapButton({super.key, required this.value, required this.onChanged});

  final Basemap value;
  final ValueChanged<Basemap> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Basemap>(
      tooltip: 'Background map',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final b in Basemap.values)
          CheckedPopupMenuItem(value: b, checked: b == value, child: Text(b.label)),
      ],
      child: const _MapIconButtonFace(icon: Icons.layers_outlined),
    );
  }
}

/// The round white face of the map's floating buttons.
class _MapIconButtonFace extends StatelessWidget {
  const _MapIconButtonFace({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        shape: const CircleBorder(),
        elevation: 2,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Theme.of(context).colorScheme.onSurface),
        ),
      );
}

/// A floating round map button (44 px: a comfortable thumb target).
class MapIconButton extends StatelessWidget {
  const MapIconButton({super.key, required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon,
                  color: onPressed == null
                      ? Theme.of(context).disabledColor
                      : Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ),
      );
}
