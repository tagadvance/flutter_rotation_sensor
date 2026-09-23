import 'package:meta/meta.dart';

import 'coordinate_system.dart';
import 'orientation_event.dart';
import 'reference_frame.dart';
import 'rotation_sensor_method_channel.dart';
import 'rotation_sensor_platform.dart';
import 'rotation_sensor_web_events_w3c.dart';
import 'rotation_sensor_web_events_webkit.dart';
import 'rotation_sensor_web_sensor_api.dart';
import 'rotation_sensor_web_stub.dart'
    if (dart.library.js_interop_unsafe) 'rotation_sensor_web.dart';
import 'sensor_interval.dart';
import 'sensor_permission.dart';

/// Provides access to the device's rotation sensor, offering a real-time stream
/// of the device's orientation.
///
/// This class allows applications to retrieve a stream of [OrientationEvent]s
/// which include the device's orientation represented as a rotation matrix,
/// quaternion, and Euler angles (azimuth, pitch, roll).
@sealed
class RotationSensor {
  /// Determines whether the rotation sensor is in diagnostic mode. If enabled,
  /// the plugin logs more events for testing and debugging purposes.
  static bool get diagnosticMode =>
      RotationSensorPlatform.instance.diagnosticMode;

  static set diagnosticMode(bool value) =>
      RotationSensorPlatform.instance.diagnosticMode = value;

  /// Determines whether the current platform is supported.
  static bool get isPlatformSupported =>
      RotationSensorMethodChannel.isPlatformSupported ||
      RotationSensorWeb.isPlatformSupported;

  /// Indicates whether the current platform exposes a runtime permission flow.
  static bool get shouldRequestPermission =>
      RotationSensorPlatform.instance.shouldRequestPermission;

  /// Requests permission to access the orientation sensor, if needed.
  static Future<SensorPermission> requestPermission() =>
      RotationSensorPlatform.instance.requestPermission();

  /// A broadcast [Stream] of [OrientationEvent]s which emits events containing
  /// the orientation of the device from the device's rotation sensor.
  static Stream<OrientationEvent> get orientationStream =>
      RotationSensorPlatform.instance.orientationStream;

  /// A broadcast [Stream] of [OrientationEvent]s measured from [frame],
  /// whatever [referenceFrame] is set to.
  ///
  /// [orientationStream] serves the configured frame, and configuring it is a
  /// mode: setting [referenceFrame] reconfigures the one sensor, so a caller
  /// can observe one frame at a time. This serves a second frame alongside it.
  ///
  /// The motivating case is an application driving its display from
  /// [ReferenceFrame.arbitrary], which no magnetic disturbance can affect,
  /// while still observing an absolute heading to know which way it is
  /// pointing. Any pair works: the frames are independent.
  ///
  /// Each frame costs a sensor subscription, so listen to one only while it is
  /// wanted. Asking for the frame [referenceFrame] is already set to still
  /// opens a second subscription rather than sharing the first.
  static Stream<OrientationEvent> orientationStreamIn(ReferenceFrame frame) =>
      RotationSensorPlatform.instance.orientationStreamIn(frame);

  /// The [samplingPeriod] for the device's rotation sensor. The events may
  /// arrive at a rate faster or slower than the [samplingPeriod], which is only
  /// a hint to the system. The actual rate depends on the system's event queue
  /// and sensor hardware capabilities.
  ///
  /// Defaults to [SensorInterval.normalInterval]. It can be set to other
  /// predefined [SensorInterval] values or any [Duration] as needed to suit
  /// different use cases such as gaming or UI responsiveness. When changing
  /// this value, all existing listeners will be affected.
  static Duration get samplingPeriod =>
      RotationSensorPlatform.instance.samplingPeriod;

  static set samplingPeriod(Duration value) =>
      RotationSensorPlatform.instance.samplingPeriod = value;

  /// The world [ReferenceFrame] from which the azimuth is measured.
  ///
  /// Defaults to [ReferenceFrame.magneticNorth]. When changing this value, all
  /// existing listeners will be affected.
  static ReferenceFrame get referenceFrame =>
      RotationSensorPlatform.instance.referenceFrame;

  static set referenceFrame(ReferenceFrame value) =>
      RotationSensorPlatform.instance.referenceFrame = value;

  /// The [coordinateSystem] used for upcoming [OrientationEvent].
  ///
  /// Defaults to [DisplayCoordinateSystem]. When changing this value, all
  /// existing listeners will receive [OrientationEvent] in the new coordinate
  /// system.
  static CoordinateSystem get coordinateSystem =>
      RotationSensorPlatform.instance.coordinateSystem;

  static set coordinateSystem(CoordinateSystem value) =>
      RotationSensorPlatform.instance.coordinateSystem = value;

  static String get implementation => switch (RotationSensorPlatform.instance) {
    RotationSensorMethodChannel _ => 'MethodChannel',
    RotationSensorWebEventsW3c _ => 'WebEventsW3c',
    RotationSensorWebEventsWebkit _ => 'WebEventsWebkit',
    RotationSensorWebSensorApi _ => 'WebSensorApi',
    _ => 'Unknown',
  };

  RotationSensor._();
}
