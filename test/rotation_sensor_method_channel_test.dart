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
  const headingChannel = RotationSensorMethodChannel.headingChannel;
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
    for (final channel in [orientationChannel, headingChannel]) {
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
        .setMockStreamHandler(headingChannel, null);
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

  test('headingStream emits OrientationEvent', () async {
    expect(await platform.headingStream.first, isA<OrientationEvent>());
  });

  test(
    'headingStream is converted from X-north to Y-north on iOS even when the '
    'reference frame is arbitrary',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expectedReferenceFrame = 'arbitrary';
      platform.referenceFrame = .arbitrary;
      final event = await platform.headingStream.first;
      expect(event.coordinateSystem, closeToMatrix3(Matrix3.rotateZ(pi / 2)));
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
