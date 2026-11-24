import 'package:connectivity_plus/connectivity_plus.dart';

/// Reports whether the device has a network connection. A connection does
/// not guarantee the cloud is reachable; sync handles that separately.
abstract class ConnectivityMonitor {
  Future<bool> isOnline();

  /// Emits whenever connectivity changes (true = connected).
  Stream<bool> get onlineChanges;
}

class ConnectivityPlusMonitor implements ConnectivityMonitor {
  ConnectivityPlusMonitor([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  @override
  Future<bool> isOnline() async =>
      _hasNetwork(await _connectivity.checkConnectivity());

  @override
  Stream<bool> get onlineChanges =>
      _connectivity.onConnectivityChanged.map(_hasNetwork).distinct();
}
