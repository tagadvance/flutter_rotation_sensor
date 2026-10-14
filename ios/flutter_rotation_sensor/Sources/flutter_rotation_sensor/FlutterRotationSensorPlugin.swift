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
  private var sentErrorCodes: Set<String> = []

  /// A handler per reference frame, for the streams asked for by name.
  private var framedHandlers: [FramedStreamHandler] = []
  private var framedChannels: [FlutterEventChannel] = []

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
      let channel = FlutterEventChannel(
        name: "rotation_sensor/orientation/\(name)", binaryMessenger: registrar.messenger())
      channel.setStreamHandler(handler)
      instance.framedHandlers.append(handler)
      instance.framedChannels.append(channel)
    }
  }

  public init(eventChannel: FlutterEventChannel, motionManager: CMMotionManager) {
    self.eventChannel = eventChannel
    self.motionManager = motionManager
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    eventChannel.setStreamHandler(nil)
    eventSink = nil
    motionManager.stopDeviceMotionUpdates()
    for channel in framedChannels {
      channel.setStreamHandler(nil)
    }
    for handler in framedHandlers {
      handler.detach()
    }
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

  /// The event shape every orientation channel shares:
  /// [x, y, z, w, accuracy, timestamp ns]. Core Motion reports no accuracy,
  /// so it is always -1.
  static func rotationVector(from motion: CMDeviceMotion) -> [Any] {
    let quaternion = motion.attitude.quaternion
    return [
      quaternion.x,
      quaternion.y,
      quaternion.z,
      quaternion.w,
      -1.0,
      Int64((motion.timestamp * 1000000000).rounded())
    ]
  }

  /// Core Motion failures worth a stable code; anything else stays UNKNOWN.
  static func errorCode(_ error: Error) -> String {
    let nsError = error as NSError
    guard nsError.domain == CMErrorDomain else { return "UNKNOWN" }
    // CMError is a plain C enum, so its cases arrive as global constants.
    switch UInt32(nsError.code) {
    case CMErrorTrueNorthNotAvailable.rawValue: return "TRUE_NORTH_UNAVAILABLE"
    case CMErrorDeviceRequiresMovement.rawValue: return "REQUIRES_MOVEMENT"
    default: return "UNKNOWN"
    }
  }

  /// One operation at a time: a concurrent queue can run two samples at once
  /// and post them to the main queue out of order, handing the listener a
  /// timestamp that goes backwards.
  static func serialQueue() -> OperationQueue {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return queue
  }

  private func setSamplingPeriod(_ samplingPeriod: Int32) {
    guard samplingPeriod != Int32((motionManager.deviceMotionUpdateInterval * 1000000).rounded()) else { return }
    motionManager.deviceMotionUpdateInterval = Double(samplingPeriod) * 0.000001
    for handler in framedHandlers {
      handler.setSamplingPeriod(motionManager.deviceMotionUpdateInterval)
    }
  }

  private func setReferenceFrame(_ referenceFrame: String) {
    let referenceFrame = Self.referenceFrames[referenceFrame] ?? .xMagneticNorthZVertical
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
        let code = Self.errorCode(error)
        DispatchQueue.main.async {
          // Once per listen: a stuck source repeats its failure at the update
          // rate, and one event already says everything the next would.
          guard self.sentErrorCodes.insert(code).inserted else { return }
          self.eventSink?(FlutterError(code: code, message: error.localizedDescription, details: nil))
        }
      }
      return
    }
    let rotationVector = Self.rotationVector(from: motion)
    DispatchQueue.main.async {
      self.eventSink?(rotationVector)
    }
  }

  private func subscribe() {
    guard motionManager.isDeviceMotionAvailable else {
      eventSink?(FlutterError(code: "UNAVAILABLE", message: "Device motion unavailable", details: nil))
      return
    }
    guard CMMotionManager.availableAttitudeReferenceFrames().contains(referenceFrame) else {
      eventSink?(FlutterError(code: "UNAVAILABLE", message: "Reference frame unavailable", details: nil))
      return
    }
    sentErrorCodes = []
    motionManager.startDeviceMotionUpdates(
      using: referenceFrame, to: Self.serialQueue(), withHandler: handleDeviceMotion)
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
/// frames need a manager each. The manager is created on first listen, so an
/// unobserved frame never costs one.
class FramedStreamHandler: NSObject, FlutterStreamHandler {

  private let frame: CMAttitudeReferenceFrame
  private var motionManager: CMMotionManager?
  private var updateInterval: TimeInterval = 0.2
  private var eventSink: FlutterEventSink?
  private var sentErrorCodes: Set<String> = []

  init(frame: CMAttitudeReferenceFrame) {
    self.frame = frame
  }

  func setSamplingPeriod(_ interval: TimeInterval) {
    updateInterval = interval
    motionManager?.deviceMotionUpdateInterval = interval
  }

  func detach() {
    eventSink = nil
    motionManager?.stopDeviceMotionUpdates()
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    guard CMMotionManager.availableAttitudeReferenceFrames().contains(frame) else {
      return FlutterError(code: "UNAVAILABLE", message: "Reference frame unavailable", details: nil)
    }
    let motionManager = self.motionManager ?? CMMotionManager()
    self.motionManager = motionManager
    guard motionManager.isDeviceMotionAvailable else {
      return FlutterError(code: "UNAVAILABLE", message: "Device motion unavailable", details: nil)
    }
    motionManager.deviceMotionUpdateInterval = updateInterval
    eventSink = events
    sentErrorCodes = []
    motionManager.startDeviceMotionUpdates(
      using: frame, to: FlutterRotationSensorPlugin.serialQueue()
    ) { motion, error in
      guard let motion else {
        if let error {
          let code = FlutterRotationSensorPlugin.errorCode(error)
          DispatchQueue.main.async {
            // Once per listen: see handleDeviceMotion.
            guard self.sentErrorCodes.insert(code).inserted else { return }
            self.eventSink?(FlutterError(code: code, message: error.localizedDescription, details: nil))
          }
        }
        return
      }
      let rotationVector = FlutterRotationSensorPlugin.rotationVector(from: motion)
      DispatchQueue.main.async {
        self.eventSink?(rotationVector)
      }
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    sentErrorCodes = []
    motionManager?.stopDeviceMotionUpdates()
    return nil
  }
}
