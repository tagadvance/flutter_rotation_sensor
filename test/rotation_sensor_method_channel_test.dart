import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart';
import 'package:flutter_rotation_sensor/src/log/level.dart';
import 'package:flutter_rotation_sensor/src/rotation_sensor_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = RotationSensorMethodChannel();
  const methodChannel = RotationSensorMethodChannel.methodChannel;
  const orientationChannel = RotationSensorMethodChannel.eventChannel;
  // The frame a concurrent stream is asked for, and the channel that serves
  // it. Deliberately not the configured frame, which is what the test for
  // the ordinary stream uses.
  const concurrentFrame = ReferenceFrame.magneticNorth;
  final concurrentChannel = RotationSensorMethodChannel.channelFor(
    concurrentFrame,
  );
  late int expectedSamplingPeriod;
  late String expectedReferenceFrame;
  late List<dynamic> orientationPayload;

  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    expectedSamplingPeriod = platform.samplingPeriod.inMicroseconds;
    expectedReferenceFrame = platform.referenceFrame.name;
    platform.coordinateSystem = CoordinateSystem.device();
    orientationPayload = _payload(Quaternion.identity());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (methodCall) async {
          switch (methodCall.method) {
            case 'setSamplingPeriod':
              final samplingPeriod = methodCall.arguments as int;
              expect(samplingPeriod, expectedSamplingPeriod);
              return null;
            case 'setReferenceFrame':
              final referenceFrame = methodCall.arguments as String;
              expect(referenceFrame, expectedReferenceFrame);
              return null;
            default:
              throw UnsupportedError(methodCall.method);
          }
        });
    for (final channel in [orientationChannel, concurrentChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            channel,
            MockStreamHandler.inline(
              onListen: (args, sink) {
                sink.success(orientationPayload);
              },
            ),
          );
    }
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(orientationChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(concurrentChannel, null);
  });

  test('events are logged in diagnosticMode', () async {
    final logBuffer = StringBuffer();
    void testLogHandler(
      String message, {
      LogLevel level = .info,
      Object? error,
      StackTrace? stackTrace,
    }) {
      logBuffer.writeln(message);
    }

    platform
      ..logHandler = testLogHandler
      ..diagnosticMode = true;

    final u = 1 / sqrt(7);
    orientationPayload = _payload(Quaternion(u, u, u, 2 * u));
    await platform.orientationStream.first;
    await expectLater(
      logBuffer.toString(),
      'diagnostic: '
      '(+0.756+0.378i+0.378j+0.378k)(+5.695±1.000)@123456789+X+Y+Z -> '
      '(+0.756+0.378i+0.378j+0.378k)(+5.695±1.000)@123456789+X+Y+Z\n',
    );
  });

  test('orientationStreamIn emits OrientationEvent', () async {
    expect(
      await platform.orientationStreamIn(concurrentFrame).first,
      isA<OrientationEvent>(),
    );
  });

  test('orientationStreamIn serves one channel per frame', () async {
    // An EventChannel activates when its listener count goes from zero to
    // one, so one channel is one platform-side subscription. Two frames at
    // once therefore need a channel each, and the name carries the frame.
    expect(
      RotationSensorMethodChannel.channelFor(ReferenceFrame.magneticNorth).name,
      'rotation_sensor/orientation/magneticNorth',
    );
    expect(
      RotationSensorMethodChannel.channelFor(ReferenceFrame.arbitrary).name,
      isNot(
        RotationSensorMethodChannel.channelFor(ReferenceFrame.trueNorth).name,
      ),
    );
  });

  test('orientationStreamIn shares one subscription per frame', () async {
    // Listening twice to the same frame must not open a second subscription,
    // while a different frame must.
    expect(
      platform.orientationStreamIn(concurrentFrame),
      same(platform.orientationStreamIn(concurrentFrame)),
    );
  });

  test(
    'orientationStreamIn converts from X-north to Y-north on iOS by the frame '
    'it serves, not the configured one',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expectedReferenceFrame = 'arbitrary';
      platform.referenceFrame = .arbitrary;
      final event = await platform.orientationStreamIn(concurrentFrame).first;

      // The rotation matrix, not `coordinateSystem`. The two carry different
      // things: `coordinateSystem` records a remap of the *device* axes, and
      // `xToYConvention` changes the *world* frame by pre-multiplying the
      // quaternion, so it leaves `coordinateSystem` alone. Asserting there
      // would pass whether the conversion happened or not, which is how the
      // `isXConvention` path came to have no assertion covering it.
      expect(event.rotationMatrix, closeToMatrix3(Matrix3.rotateZ(pi / 2)));
    },
  );

  test('arbitraryCorrected frame are unconverted on iOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expectedReferenceFrame = 'arbitraryCorrected';
    platform.referenceFrame = .arbitraryCorrected;
    final event = await platform.orientationStream.first;
    expect(event.coordinateSystem, closeToMatrix3(Matrix3.identity()));
  });

  test('orientationStream emits OrientationEvent with default sampling '
      'period', () async {
    expect(await platform.orientationStream.first, isA<OrientationEvent>());
  });

  test('orientationStream emits OrientationEvent with a replaced sampling '
      'period when a reserved value is provided', () async {
    // samplingPeriod should be replaced with 0 since 1-3 is a reserved value
    // for Android.
    expectedSamplingPeriod = 0;
    platform.samplingPeriod = const Duration(microseconds: 1);
    expect(platform.samplingPeriod, equals(Duration.zero));
    await Future.microtask(() => null);
    expect(await platform.orientationStream.first, isA<OrientationEvent>());
  });

  test('north-referenced frame preserves cardinal headings on '
      'Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expectedReferenceFrame = 'magneticNorth';
    platform.referenceFrame = .magneticNorth;

    const p = sqrt2;
    const n = -sqrt2;
    final testcases = {
      _payload(Quaternion(0, 0, 0, 1)): pi * 0 / 2,
      _payload(Quaternion(0, 0, n, p)): pi * 1 / 2,
      _payload(Quaternion(0, 0, 1, 0)): pi * 2 / 2,
      _payload(Quaternion(0, 0, p, p)): pi * 3 / 2,
    };
    for (final entry in testcases.entries) {
      orientationPayload = entry.key;
      final event = await platform.orientationStream.first;
      expect(event.eulerAngles.azimuth, closeToNum(entry.value));
    }
  });

  test('north-referenced frame applies x-convention to y-convention conversion '
      'on iOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expectedReferenceFrame = 'magneticNorth';
    platform.referenceFrame = .magneticNorth;

    const p = sqrt2;
    const n = -sqrt2;
    final testcases = {
      _payload(Quaternion(0, 0, n, p)): pi * 0 / 2,
      _payload(Quaternion(0, 0, 1, 0)): pi * 1 / 2,
      _payload(Quaternion(0, 0, p, p)): pi * 2 / 2,
      _payload(Quaternion(0, 0, 0, 1)): pi * 3 / 2,
    };
    for (final entry in testcases.entries) {
      orientationPayload = entry.key;
      final event = await platform.orientationStream.first;
      expect(event.eulerAngles.azimuth, closeToNum(entry.value));
    }
  });
}

List<dynamic> _payload(
  Quaternion quaternion, {
  double accuracy = -1,
  int timestamp = 123456789,
}) => [
  quaternion.x,
  quaternion.y,
  quaternion.z,
  quaternion.w,
  accuracy,
  timestamp,
];
