package net.tlserver6y.flutter_rotation_sensor

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.EventChannel.StreamHandler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class FlutterRotationSensorPlugin : FlutterPlugin, MethodCallHandler, SensorEventListener,
  StreamHandler {
  private companion object {
    /** Must match the names of the ReferenceFrame enum on the Dart side. */
    val REFERENCE_FRAMES = listOf(
      "arbitrary", "arbitraryCorrected", "magneticNorth", "trueNorth"
    )
  }

  private lateinit var methodChannel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private lateinit var framedChannels: Map<String, EventChannel>
  private lateinit var sensorManager: SensorManager
  private var eventSink: EventSink? = null

  /** A sink per reference frame, for the streams asked for by name. */
  private val framedSinks = mutableMapOf<String, EventSink>()
  private var samplingPeriod = 200000
  private var sensorType = Sensor.TYPE_ROTATION_VECTOR

  // === FlutterPlugin ===

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    val context = flutterPluginBinding.applicationContext
    sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    setupMethodChannel(flutterPluginBinding.binaryMessenger)
    setupEventChannels(flutterPluginBinding.binaryMessenger)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    teardownMethodChannel()
    teardownEventChannels()
  }

  private fun setupMethodChannel(messenger: BinaryMessenger) {
    methodChannel = MethodChannel(messenger, "rotation_sensor/method")
    methodChannel.setMethodCallHandler(this)
  }

  private fun teardownMethodChannel() {
    methodChannel.setMethodCallHandler(null);
  }

  /**
   * The channel serving the configured frame, plus one per frame that can be
   * asked for by name.
   *
   * A channel each rather than one carrying the frame as an argument, because
   * an event channel is one subscription: it activates when its listener
   * count goes from zero to one, with its arguments fixed at that first
   * listen. Frames have to be observable at the same time, so they need a
   * channel each.
   */
  private fun setupEventChannels(messenger: BinaryMessenger) {
    eventChannel = EventChannel(messenger, "rotation_sensor/orientation")
    eventChannel.setStreamHandler(this)
    framedChannels = REFERENCE_FRAMES.associateWith { frame ->
      EventChannel(messenger, "rotation_sensor/orientation/$frame").apply {
        setStreamHandler(object : StreamHandler {
          override fun onListen(arguments: Any?, events: EventSink) {
            framedSinks[frame] = events
            syncListeners()
          }

          override fun onCancel(arguments: Any?) {
            framedSinks.remove(frame)
            syncListeners()
          }
        })
      }
    }
  }

  private fun teardownEventChannels() {
    eventChannel.setStreamHandler(null)
    framedChannels.values.forEach { it.setStreamHandler(null) }
    eventSink = null
    framedSinks.clear()
    syncListeners()
  }

  // === MethodCallHandler ===

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "setSamplingPeriod" -> {
        val samplingPeriod = call.arguments as? Int ?: run {
          return result.error(
            "INVALID_ARGUMENTS",
            "Int samplingPeriod is required",
            null
          )
        }
        setSamplingPeriod(samplingPeriod)
        return result.success(null)
      }
      "setReferenceFrame" -> {
        val referenceFrame = call.arguments as? String ?: run {
          return result.error(
            "INVALID_ARGUMENTS",
            "String referenceFrame is required",
            null
          )
        }
        setReferenceFrame(referenceFrame)
        result.success(null);
      }
      else -> result.notImplemented()
    }
  }

  private fun setSamplingPeriod(samplingPeriod: Int) {
    if (samplingPeriod == this.samplingPeriod) return
    this.samplingPeriod = samplingPeriod
    syncListeners()
  }

  private fun setReferenceFrame(referenceFrame: String) {
    val sensorType = sensorTypeFor(referenceFrame)
    if (sensorType == this.sensorType) return
    this.sensorType = sensorType
    syncListeners()
  }

  /**
   * Android has no separate sensor for the corrected or true-north frames, so
   * each falls back to the one it is a refinement of, as it always has.
   */
  private fun sensorTypeFor(referenceFrame: String) = when (referenceFrame) {
    "arbitrary", "arbitraryCorrected" -> Sensor.TYPE_GAME_ROTATION_VECTOR
    else -> Sensor.TYPE_ROTATION_VECTOR
  }

  // === SensorEventListener ===

  override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}

  override fun onSensorChanged(event: SensorEvent) {
    val data = arrayListOf(
      event.values[0].toDouble(),
      event.values[1].toDouble(),
      event.values[2].toDouble(),
      event.values[3].toDouble(),
      // Estimated heading accuracy may not exist.
      event.values.getOrElse(4, { -1.0f }).toDouble(),
      event.timestamp,
    )
    if (event.sensor.type == sensorType) eventSink?.success(data)
    for ((frame, sink) in framedSinks) {
      if (event.sensor.type == sensorTypeFor(frame)) sink.success(data)
    }
  }

  // === StreamHandler ===

  override fun onListen(arguments: Any?, events: EventSink) {
    eventSink = events
    syncListeners()
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
    syncListeners()
  }

  /**
   * Registers this listener for exactly the sensors the active sinks need,
   * and no more. Two frames backed by the same sensor share one registration,
   * so asking for a frame the configured one already uses costs nothing.
   */
  private fun syncListeners() {
    sensorManager.unregisterListener(this)
    val sensorTypes = mutableSetOf<Int>()
    if (eventSink != null) sensorTypes.add(sensorType)
    framedSinks.keys.forEach { sensorTypes.add(sensorTypeFor(it)) }
    for (sensorType in sensorTypes) {
      val sensor = sensorManager.getDefaultSensor(sensorType)
      if (sensor == null) {
        reportUnavailable(sensorType)
        continue
      }
      sensorManager.registerListener(this, sensor, samplingPeriod)
    }
  }

  private fun reportUnavailable(sensorType: Int) {
    val report = { sink: EventSink ->
      sink.error(
        "UNAVAILABLE",
        "Sensor not found",
        "It seems that your device has no ${
          when (sensorType) {
            Sensor.TYPE_ROTATION_VECTOR -> "rotation vector sensor"
            Sensor.TYPE_GAME_ROTATION_VECTOR -> "game rotation vector sensor"
            else -> "needed sensor"
          }
        }."
      )
    }
    if (sensorType == this.sensorType) eventSink?.let(report)
    for ((frame, sink) in framedSinks) {
      if (sensorType == sensorTypeFor(frame)) report(sink)
    }
  }
}
