import 'dart:async';
import 'dart:js_interop_unsafe';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:meta/meta.dart';
import 'package:web/web.dart';

import 'environment.dart';
import 'orientation_event.dart';
import 'reference_frame.dart';
import 'rotation_sensor_platform.dart';
import 'rotation_sensor_unsupported.dart';
import 'rotation_sensor_web_events_w3c.dart';
import 'rotation_sensor_web_events_webkit.dart';
import 'rotation_sensor_web_sensor_api.dart';

/// A web implementation of the [RotationSensorPlatform].
abstract class RotationSensorWeb extends RotationSensorPlatform {
  /// Determines whether the current platform is supported.
  static bool get isPlatformSupported => isWeb;

  /// Registers the web implementation of [RotationSensorPlatform] to flutter.
  static void registerWith(Registrar registrar) {
    if (window.has('Sensor')) {
      RotationSensorPlatform.instance = RotationSensorWebSensorApi();
    } else if (window.has('DeviceOrientationEvent')) {
      if (window.has('ondeviceorientationabsolute')) {
        RotationSensorPlatform.instance = RotationSensorWebEventsW3c();
      } else {
        RotationSensorPlatform.instance = RotationSensorWebEventsWebkit();
      }
    } else {
      RotationSensorPlatform.instance = RotationSensorUnsupported();
    }
  }

  @protected
  late StreamController<OrientationEvent> streamController =
      StreamController<OrientationEvent>.broadcast(
        onListen: subscribe,
        onCancel: unsubscribe,
      );

  /// A broadcast [Stream] of [OrientationEvent]s which emits events containing
  /// the orientation of the device from the device's rotation sensor.
  @override
  Stream<OrientationEvent> get orientationStream => streamController.stream;

  final Map<ReferenceFrame, RotationSensorWeb> _framed = {};

  /// A broadcast [Stream] of [OrientationEvent]s measured from [frame],
  /// whatever the configured frame is.
  ///
  /// Served by a second instance of this implementation with its own
  /// [referenceFrame], rather than by teaching one instance to hold two
  /// subscriptions. Everything a subscription needs is already instance
  /// state here: the controller, the listener, and which event or sensor it
  /// is attached to. A second instance is the same machinery pointed at the
  /// other frame, and it keeps the concurrent path and the ordinary path the
  /// same code.
  ///
  /// [newInstance] is what each implementation has to supply.
  @override
  Stream<OrientationEvent> orientationStreamIn(ReferenceFrame frame) {
    if (frame == referenceFrame) {
      return orientationStream;
    }

    return _framed
        .putIfAbsent(
          frame,
          () => newInstance()
            ..referenceFrame = frame
            ..coordinateSystem = coordinateSystem
            ..samplingPeriod = samplingPeriod,
        )
        .orientationStream;
  }

  /// Another of this implementation, for [orientationStreamIn] to point at a
  /// second frame.
  @protected
  RotationSensorWeb newInstance();

  @protected
  bool get absolute => switch (referenceFrame) {
    .arbitrary || .arbitraryCorrected => false,
    .magneticNorth || .trueNorth => true,
  };

  @protected
  void subscribe();

  @protected
  void unsubscribe();

  /// Closes the stream.
  void close() {
    streamController.close();
  }
}
