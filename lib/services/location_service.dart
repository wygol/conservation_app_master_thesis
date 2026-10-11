import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// One position fix, as the device reported it.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracyM,
    this.isMocked = false,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;

  /// The device's horizontal accuracy, in metres — what goes into
  /// dwc:coordinateUncertaintyInMeters. Null when the device gave none: an
  /// unknown uncertainty is stored as unknown, never as a guessed constant.
  final double? accuracyM;

  /// Android reports positions from a mock-location app as such.
  final bool isMocked;

  factory LocationFix.fromPosition(Position p) => LocationFix(
        latitude: p.latitude,
        longitude: p.longitude,
        timestamp: p.timestamp,
        accuracyM: p.hasAccuracy && p.accuracy > 0 ? p.accuracy : null,
        isMocked: p.isMocked,
      );

  /// A fix with a known accuracy beats one without; otherwise the smaller
  /// accuracy radius wins.
  bool isBetterThan(LocationFix other) {
    if (accuracyM == null) return false;
    if (other.accuracyM == null) return true;
    return accuracyM! < other.accuracyM!;
  }
}

enum LocationProblem { serviceDisabled, denied, deniedForever, failed }

/// Follows the position while a record is being made and keeps the BEST fix,
/// not the latest: standing at a plant, accuracy improves for a while after
/// the receiver wakes up, and the best fix is the one to record. "Refresh"
/// starts over (after moving to another plant, say).
///
/// Asks for the location permission when [start] is called — when a record
/// is begun, never at app start-up.
class LocationTracker extends ChangeNotifier {
  /// [keepBest] false follows the LATEST fix instead — for the map's "where
  /// am I" dot, which has to move with the person.
  LocationTracker({this.keepBest = true});

  final bool keepBest;
  LocationFix? _best;
  LocationProblem? _problem;
  String? _detail;
  bool _running = false;
  StreamSubscription<Position>? _sub;

  LocationFix? get best => _best;
  LocationProblem? get problem => _problem;
  String? get problemDetail => _detail;
  bool get running => _running;

  Future<void> start() async {
    await _sub?.cancel();
    _sub = null;
    _problem = null;
    _detail = null;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _fail(LocationProblem.serviceDisabled);
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _fail(LocationProblem.denied);
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _fail(LocationProblem.deniedForever);
        return;
      }
      _running = true;
      notifyListeners();
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
      ).listen(_onPosition, onError: (Object e) => _fail(LocationProblem.failed, '$e'));
    } catch (e) {
      _fail(LocationProblem.failed, '$e');
    }
  }

  /// Forget the best fix and look again.
  Future<void> refresh() {
    _best = null;
    notifyListeners();
    return start();
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    if (_running) {
      _running = false;
      notifyListeners();
    }
  }

  void _onPosition(Position p) {
    final fix = LocationFix.fromPosition(p);
    if (!keepBest || _best == null || fix.isBetterThan(_best!)) {
      _best = fix;
      notifyListeners();
    }
  }

  void _fail(LocationProblem problem, [String? detail]) {
    _sub?.cancel();
    _sub = null;
    _running = false;
    _problem = problem;
    _detail = detail;
    notifyListeners();
  }

  /// For the "open settings" buttons of the problem states.
  static Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
  static Future<bool> openAppSettings() => Geolocator.openAppSettings();

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
