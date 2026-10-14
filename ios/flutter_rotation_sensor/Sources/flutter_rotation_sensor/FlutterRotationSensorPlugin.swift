import Flutter
import UIKit
import CoreMotion

public class FlutterRotationSensorPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  /// Must match the names of the ReferenceFrame enum on the Dart side.
  private static let referenceFrames: [String: CMAttitudeReferenceFrame] = [
    "arbitrary": .xArbitraryZVertical,
    "arbitraryCorrected": .xArbitraryCorrectedZVertical,
    "magneticNorth": .xMagneticNorthZVertical,
    "trueNorth": .xTrueNorthZVertical,
  ]

  private var eventChannel: FlutterEventChannel
  private let motionManager: CMMotionManager
  private var eventSink: FlutterEventSink?
  private var referenceFrame: CMAttitudeReferenceFrame = .xMagneticNorthZVertical

  /// A handler per reference frame, for the streams asked for by name.
  private var framedHandlers: [FramedStreamHandler] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(name: "rotation_sensor/method", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(name: "rotation_sensor/orientation", binaryMessenger: registrar.messenger())
    let motionManager = CMMotionManager()
    motionManager.deviceMotionUpdateInterval = 0.2
    let instance = FlutterRotationSensorPlugin(eventChannel: eventChannel, motionManager: motionManager)
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    // The channel serving the configured frame, plus one per frame that can
    // be asked for by name. A channel each rather than one carrying the frame
    // as an argument, because an event channel is one subscription: it
    // activates when its listener count goes from zero to one, with its
    // arguments fixed at that first listen. Frames have to be observable at
    // the same time, so they need a channel each.
    for (name, frame) in referenceFrames {
      let handler = FramedStreamHandler(frame: frame)
      instance.framedHandlers.append(handler)
      FlutterEventChannel(
        name: "rotation_sensor/orientation/\(name)", binaryMessenger: registrar.messenger()
      ).setStreamHandler(handler)
    }
  }

  public init(eventChannel: FlutterEventChannel, motionManager: CMMotionManager) {
    self.eventChannel = eventChannel
    self.motionManager = motionManager
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    eventChannel.setStreamHandler(nil)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setSamplingPeriod":
      guard let samplingPeriod = call.arguments as? Int32 else {
        result(FlutterError(
          code: "INVALID_ARGUMENTS",
          message: "Int32 samplingPeriod is required",
          details: nil
        ))
        return
      }
      setSamplingPeriod(samplingPeriod)
      result(nil)
    case "setReferenceFrame":
      guard let referenceFrame = call.arguments as? String else {
        result(FlutterError(
          code: "INVALID_ARGUMENTS",
          message: "String referenceFrame is required",
          details: nil
        ))
        return
      }
      setReferenceFrame(referenceFrame)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setSamplingPeriod(_ samplingPeriod: Int32) {
    guard samplingPeriod != Int32((motionManager.deviceMotionUpdateInterval * 1000000).rounded()) else { return }
    motionManager.deviceMotionUpdateInterval = Double(samplingPeriod) * 0.000001
    for handler in framedHandlers {
      handler.setSamplingPeriod(motionManager.deviceMotionUpdateInterval)
    }
  }

  private func setReferenceFrame(_ referenceFrame: String) {
    let referenceFrame: CMAttitudeReferenceFrame = switch referenceFrame {
    case "arbitrary": .xArbitraryZVertical
    case "arbitraryCorrected": .xArbitraryCorrectedZVertical
    case "magneticNorth": .xMagneticNorthZVertical
    case "trueNorth": .xTrueNorthZVertical
    default: .xMagneticNorthZVertical
    }
    guard referenceFrame != self.referenceFrame else { return }
    self.referenceFrame = referenceFrame
    resubscribe()
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    subscribe()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    unsubscribe()
    return nil
  }

  private func noListeners() -> Bool { eventSink == nil }

  private func handleDeviceMotion(motion: CMDeviceMotion?, error: Error?) {
    guard let motion else {
      if let error {
        eventSink?(FlutterError(code: "UNKNOWN", message: error.localizedDescription, details: nil))
      }
      return
    }
    let quaternion = motion.attitude.quaternion
    let rotationVector: [Any] = [
      quaternion.x,
      quaternion.y,
      quaternion.z,
      quaternion.w,
      -1.0,
      Int64((motion.timestamp * 1000000000).rounded())
    ]
    DispatchQueue.main.async {
      self.eventSink?(rotationVector)
    }
  }

  private func subscribe() {
    guard motionManager.isDeviceMotionAvailable else {
      eventSink?(FlutterError(code: "UNAVAILABLE", message: "Device motion unavailable", details: nil))
      return
    }
    motionManager.startDeviceMotionUpdates(using: referenceFrame, to: OperationQueue(), withHandler: handleDeviceMotion)
  }

  private func unsubscribe() {
    motionManager.stopDeviceMotionUpdates()
  }

  private func resubscribe() {
    if noListeners() { return }
    unsubscribe()
    subscribe()
  }
}

/// One frame's stream, backed by its own motion manager: Core Motion ties a
/// device-motion subscription to a single reference frame, so concurrent
/// frames need a manager each.
class FramedStreamHandler: NSObject, FlutterStreamHandler {

  private let frame: CMAttitudeReferenceFrame
  private let motionManager = CMMotionManager()
  private var eventSink: FlutterEventSink?

  init(frame: CMAttitudeReferenceFrame) {
    self.frame = frame
    motionManager.deviceMotionUpdateInterval = 0.2
  }

  func setSamplingPeriod(_ interval: TimeInterval) {
    motionManager.deviceMotionUpdateInterval = interval
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    guard motionManager.isDeviceMotionAvailable else {
      return FlutterError(code: "UNAVAILABLE", message: "Device motion unavailable", details: nil)
    }
    eventSink = events
    motionManager.startDeviceMotionUpdates(using: frame, to: OperationQueue()) { motion, error in
      guard let motion else {
        if let error {
          DispatchQueue.main.async {
            self.eventSink?(FlutterError(code: "UNKNOWN", message: error.localizedDescription, details: nil))
          }
        }
        return
      }
      let quaternion = motion.attitude.quaternion
      let rotationVector: [Any] = [
        quaternion.x,
        quaternion.y,
        quaternion.z,
        quaternion.w,
        -1.0,
        Int64((motion.timestamp * 1000000000).rounded())
      ]
      DispatchQueue.main.async {
        self.eventSink?(rotationVector)
      }
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    motionManager.stopDeviceMotionUpdates()
    return nil
  }
}
