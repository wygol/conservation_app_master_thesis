/// Plant families of the model's label space — DOMAIN layer (CLAUDE.md §4).
///
/// The core (map, records) only knows "a category per record". That the
/// category is a botanical family, and where it comes from, lives here.
///
/// Source: labels.csv of the shipped model (1,004 classes, 106 families,
/// 498 genera). Checked on 2026-10-11: no genus maps to two families, and every
/// species label starts with its genus — so the genus of a scientific name
/// determines its family. The moss class is an aggregate whose "family" column
/// holds a description, not a family; it is left out rather than invented.
library;

import 'package:flutter/services.dart';

import '../../ml/labels.dart';
import '../../ml/offline_model.dart';

class PlantFamilies {
  PlantFamilies._(this._byGenus);

  final Map<String, String> _byGenus;

  factory PlantFamilies.fromLabels(Iterable<ModelLabel> labels) {
    final byGenus = <String, String>{};
    for (final l in labels) {
      if (l.rank == 'aggregate') continue;
      byGenus.putIfAbsent(l.genus, () => l.family);
    }
    return PlantFamilies._(byGenus);
  }

  static Future<PlantFamilies>? _loading;

  /// Loads the label table once per process (it is small; the model itself
  /// is not loaded for this).
  static Future<PlantFamilies> load() => _loading ??= () async {
        final text = await rootBundle.loadString(OfflineModelAssets.labels);
        return PlantFamilies.fromLabels(LabelTable.parse(text).labels);
      }();

  int get genusCount => _byGenus.length;

  /// The family of [scientificName], from its genus; null when the genus is
  /// not in the label space (or there is no name).
  String? familyOf(String? scientificName) {
    if (scientificName == null) return null;
    final words = scientificName.trim().split(RegExp(r'\s+'));
    if (words.isEmpty || words.first.isEmpty) return null;
    // A hybrid genus is written "× Genus".
    final genus = (words.first == '×' && words.length > 1) ? words[1] : words.first;
    return _byGenus[genus];
  }
}
