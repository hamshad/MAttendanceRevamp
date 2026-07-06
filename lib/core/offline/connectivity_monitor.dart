import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityMonitor {
  final _connectivity = Connectivity();

  Stream<bool> get onlineStream => _connectivity.onConnectivityChanged
      .map((results) => results.any((r) => r != ConnectivityResult.none));

  Future<bool> get isOnline async {
    final results = await _connectivity.checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }
}
