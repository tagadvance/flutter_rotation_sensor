import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'environment.dart';
import 'math/quaternion.dart';
import 'orientation_event.dart';
import 'reference_frame.dart';
import 'rotation_sensor_platform.dart';

/// An implementation of [RotationSensorPlatform] that uses method channels.
class RotationSensorMethodChannel extends RotationSensorPlatform {
  @override
  String get implementationName => 'MethodChannel';

  /// The method channel used to interact with the native platform.
  @visibleForTesting
  static const methodChannel = MethodChannel('rotation_sensor/method');

  /// The event channel used to receive orientation events from the native
  /// platform.
  @visibleForTesting
  static const eventChannel = EventChannel('rotation_sensor/orientation');

  /// The event channel serving [frame], independent of the configured one.
  ///
  /// A channel each rather than one carrying the frame as an argument,
  /// because an [EventChannel] activates when its listener count goes from
  /// zero to one and deactivates when it returns to zero: one channel is one
  /// platform-side subscription, with its arguments fixed at the first
  /// listen. Frames have to be concurrent, so they need a channel each, and
  /// naming it after the frame means a frame added later needs no new
  /// constant here.
  @visibleForTesting
  static EventChannel channelFor(ReferenceFrame frame) =>
      EventChannel('rotation_sensor/orientation/${frame.name}');

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

  final Map<ReferenceFrame, Stream<OrientationEvent>> _framed = {};

  /// A broadcast [Stream] of [OrientationEvent]s measured from [frame],
  /// whatever the configured frame is.
  ///
  /// Cached per frame, so listening twice to the same frame shares one
  /// subscription and two frames do not.
  @override
  Stream<OrientationEvent> orientationStreamIn(ReferenceFrame frame) =>
      _framed.putIfAbsent(frame, () {
        setSamplingPeriod();
        return channelFor(frame).receiveBroadcastStream().map((event) {
          final data = event as List<dynamic>;
          return transform(
            OrientationEvent(
              quaternion: Quaternion(data[0], data[1], data[2], data[3]),
              accuracy: data[4],
              timestamp: data[5],
            ),
            // Core Motion uses a world frame with X = north and Z = up. The
            // frame this stream serves decides that, not the configured one.
            isXConvention:
                defaultTargetPlatform == TargetPlatform.iOS &&
                (frame == ReferenceFrame.magneticNorth ||
                    frame == ReferenceFrame.trueNorth),
          );
        });
      });

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
