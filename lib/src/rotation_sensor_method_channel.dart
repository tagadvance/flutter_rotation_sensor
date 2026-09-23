import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'environment.dart';
import 'math/axis3.dart';
import 'math/quaternion.dart';
import 'orientation_event.dart';
import 'rotation_sensor.dart';
import 'rotation_sensor_platform.dart';

/// An implementation of [RotationSensorPlatform] that uses method channels.
class RotationSensorMethodChannel extends RotationSensorPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  static const methodChannel = MethodChannel('rotation_sensor/method');

  /// The event channel used to receive orientation events from the native
  /// platform.
  @visibleForTesting
  static const eventChannel = EventChannel('rotation_sensor/orientation');

  /// The event channel used to receive magnetic-north referenced orientation
  /// events from the native platform, independent of the reference frame.
  @visibleForTesting
  static const headingChannel = EventChannel('rotation_sensor/heading');

  /// Determines whether the current platform is supported.
  static bool get isPlatformSupported =>
      !isWeb &&
      [
        TargetPlatform.android,
        TargetPlatform.iOS,
      ].contains(defaultTargetPlatform);

  Stream<OrientationEvent>? _orientationStream;

  /// A broadcast [Stream] of [OrientationEvent]s which emits events containing
  /// the orientation of the device from the device's rotation sensor.
  @override
  Stream<OrientationEvent> get orientationStream {
    if (_orientationStream != null) {
      return _orientationStream!;
    }
    setSamplingPeriod();
    setReferenceFrame();
    final broadcastStream = eventChannel.receiveBroadcastStream();
    return _orientationStream = broadcastStream.map(_onData);
  }

  OrientationEvent _onData(dynamic event) {
    final data = event as List<dynamic>;
    return transform(
      OrientationEvent(
        quaternion: Quaternion(data[0], data[1], data[2], data[3]),
        accuracy: data[4],
        timestamp: data[5],
      ),
      // Core Motion uses a world frame with X = north and Z = up.
      isXConvention:
          defaultTargetPlatform == TargetPlatform.iOS &&
          (referenceFrame == .magneticNorth || referenceFrame == .trueNorth),
    );
  }

  Stream<OrientationEvent>? _headingStream;

  /// A broadcast [Stream] of [OrientationEvent]s referenced to magnetic north
  /// regardless of [referenceFrame], so an application using the
  /// arbitrary frame can still observe an absolute heading.
  ///
  /// Currently implemented on the Android side only; on iOS this stream emits
  /// an error.
  @override
  Stream<OrientationEvent> get headingStream {
    if (_headingStream != null) {
      return _headingStream!;
    }
    setSamplingPeriod();
    final broadcastStream = headingChannel.receiveBroadcastStream();
    return _headingStream = broadcastStream.map((event) {
      final data = event as List<dynamic>;
      final orientationEvent = OrientationEvent(
        quaternion: Quaternion(data[0], data[1], data[2], data[3]),
        accuracy: data[4],
        timestamp: data[5],
      );
      // Core Motion uses a world frame with X = north and Z = up. Convert it
      // here to Y = north and Z = up to match Android and this package's
      // convention.
      return RotationSensor.coordinateSystem.apply(
        defaultTargetPlatform == TargetPlatform.iOS
            ? orientationEvent.remapCoordinateSystem(Axis3.Y, -Axis3.X)
            : orientationEvent,
      );
    });
  }

  @override
  @protected
  void setSamplingPeriod() {
    methodChannel.invokeMethod('setSamplingPeriod', samplingMicroseconds);
  }

  @override
  @protected
  void setReferenceFrame() {
    methodChannel.invokeMethod('setReferenceFrame', referenceFrame.name);
  }
}
