import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../core/wire/ros_compat.dart';

/// A snapshot of the latest IMU values (SI units) for previews.
class ImuSample {
  const ImuSample(this.accel, this.gyro, this.roll, this.pitch, this.yaw);
  final List<double> accel; // m/s^2
  final List<double> gyro; // rad/s
  final double roll, pitch, yaw; // rad
}

/// Publishes phone IMU (`sensor_msgs/Imu`) and GPS (`sensor_msgs/NavSatFix`)
/// to the brain device. Each stream is independently toggled and can run from any
/// app mode.
///
/// The caller supplies a [publish] sink (topic, msg) — wired to the brain
/// [WsClient]. Orientation is integrated cheaply from the gyroscope and
/// corrected toward gravity from the accelerometer (complementary filter), as
/// phones expose no absolute orientation through sensors_plus directly.
class SensorService {
  SensorService(this._publish);

  final void Function(String topic, Map<String, dynamic> msg) _publish;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<Position>? _gpsSub;
  Timer? _imuTimer;

  // Latest raw samples.
  List<double> _accel = [0, 0, 9.81];
  List<double> _gyro = [0, 0, 0];

  // Complementary-filter orientation estimate (roll, pitch, yaw).
  double _roll = 0, _pitch = 0, _yaw = 0;
  DateTime _lastImu = DateTime.now();

  bool _imuOn = false;
  bool _gpsOn = false;
  bool get imuOn => _imuOn;
  bool get gpsOn => _gpsOn;

  // Latest values + live streams for on-screen previews.
  final _imuController = StreamController<ImuSample>.broadcast();
  final _gpsController = StreamController<Position>.broadcast();
  ImuSample? lastImu;
  Position? lastGps;
  Stream<ImuSample> get imuStream => _imuController.stream;
  Stream<Position> get gpsStream => _gpsController.stream;

  // ----------------------------------------------------------------- IMU
  void startImu({int rateHz = 20}) {
    if (_imuOn) return;
    _imuOn = true;
    _accelSub = accelerometerEventStream().listen((e) {
      _accel = [e.x, e.y, e.z];
    });
    _gyroSub = gyroscopeEventStream().listen((e) {
      _gyro = [e.x, e.y, e.z];
    });
    final period = Duration(milliseconds: (1000 / rateHz).round());
    _lastImu = DateTime.now();
    _imuTimer = Timer.periodic(period, (_) => _publishImu());
  }

  void stopImu() {
    _imuOn = false;
    _imuTimer?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _imuTimer = null;
    _accelSub = null;
    _gyroSub = null;
  }

  void _publishImu() {
    final now = DateTime.now();
    final dt = now.difference(_lastImu).inMicroseconds / 1e6;
    _lastImu = now;
    if (dt <= 0 || dt > 1) return;

    // Integrate gyro.
    _roll += _gyro[0] * dt;
    _pitch += _gyro[1] * dt;
    _yaw += _gyro[2] * dt;

    // Correct roll/pitch toward gravity (complementary filter).
    final ax = _accel[0], ay = _accel[1], az = _accel[2];
    final accelRoll = math.atan2(ay, az);
    final accelPitch = math.atan2(-ax, math.sqrt(ay * ay + az * az));
    const alpha = 0.98;
    _roll = alpha * _roll + (1 - alpha) * accelRoll;
    _pitch = alpha * _pitch + (1 - alpha) * accelPitch;

    final q = quaternionFromEuler(_roll, _pitch, _yaw);
    _publish(
      RosTopics.imu,
      RosMessages.imu(
        orientation: vm.Quaternion(q.x, q.y, q.z, q.w),
        angularVelocity: _gyro,
        linearAcceleration: _accel,
      ),
    );
    lastImu = ImuSample(List.of(_accel), List.of(_gyro), _roll, _pitch, _yaw);
    if (!_imuController.isClosed) _imuController.add(lastImu!);
  }

  // ----------------------------------------------------------------- GPS
  Future<bool> startGps() async {
    if (_gpsOn) return true;
    final ok = await _ensureLocationPermission();
    if (!ok) return false;
    _gpsOn = true;
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen(_publishGps);
    return true;
  }

  void stopGps() {
    _gpsOn = false;
    _gpsSub?.cancel();
    _gpsSub = null;
  }

  void _publishGps(Position p) {
    _publish(
      RosTopics.gps,
      RosMessages.navSatFix(
        latitude: p.latitude,
        longitude: p.longitude,
        altitude: p.altitude,
        horizontalAccuracy: p.accuracy,
      ),
    );
    lastGps = p;
    if (!_gpsController.isClosed) _gpsController.add(p);
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  void dispose() {
    stopImu();
    stopGps();
    _imuController.close();
    _gpsController.close();
  }
}
