import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import 'love_bridge.dart';

/// 设备传感器桥接到 LOVE 游戏层。
///
/// LOVE 游戏通过 `host.sensor_start/stop` 控制传感器上报,
/// 通过 `host.on("sensor_accel", fn)` / `host.on("sensor_gyro", fn)` 消费数据。
class SensorBridge {
  SensorBridge._();
  static final SensorBridge instance = SensorBridge._();

  final Map<int, _Subscriptions> _subs = {};

  void start(int canvasId, Map<String, dynamic> opts) {
    stop(canvasId);

    final s = _Subscriptions();
    _subs[canvasId] = s;

    final ac = opts['accelerometer'] ?? opts['accel'];
    if (ac == true) {
      s.accelerometer = accelerometerEventStream()
          .listen((e) {
        _push(canvasId, 'sensor_accel', {'x': e.x, 'y': e.y, 'z': e.z});
      }, onError: (_) {});
    }

    final gy = opts['gyroscope'] ?? opts['gyro'];
    if (gy == true) {
      s.gyroscope = gyroscopeEventStream()
          .listen((e) {
        _push(canvasId, 'sensor_gyro', {'x': e.x, 'y': e.y, 'z': e.z});
      }, onError: (_) {});
    }
  }

  void stop(int canvasId) {
    final s = _subs.remove(canvasId);
    if (s == null) return;
    s.accelerometer?.cancel();
    s.gyroscope?.cancel();
  }

  void stopAll() {
    for (final id in _subs.keys.toList()) {
      stop(id);
    }
  }

  void _push(int canvasId, String type, Map<String, dynamic> data) {
    LoveBridge.instance.send(canvasId, {'type': type, 'data': data});
  }
}

class _Subscriptions {
  StreamSubscription? accelerometer;
  StreamSubscription? gyroscope;
}
