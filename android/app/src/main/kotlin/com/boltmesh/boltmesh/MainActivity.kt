package com.boltmesh.boltmesh

import android.content.Context
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugins.GeneratedPluginRegistrant

/// Host Activity backed by a process-cached [FlutterEngine].
///
/// The engine (and therefore the Dart isolate) is intentionally *not*
/// destroyed with the Activity: when the task is swiped away while a tunnel is
/// up, the plugin's `VpnForegroundService` keeps the process alive, and the
/// surviving isolate keeps running the health tick that drives auto-heal
/// (10s foreground, 30s background — `conn_health.dart` / `conn_heal.dart`).
/// Re-launching the app reattaches to the same engine, so no cold-restore is
/// needed. A true process death still cold-starts normally
/// (`reconcileColdStart`).
///
/// The app's own native channels live in [TunnelHost], not here, precisely so
/// that a detached Activity's `cleanUpFlutterEngine` cannot tear them down.
class MainActivity : FlutterActivity() {
  override fun provideFlutterEngine(context: Context): FlutterEngine? {
    FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
    // Carry the launch shell args (debug VM service, tracing, …) the same way
    // the framework's own engine path does; `flutter run` relies on them.
    // autoRegisterPlugins=false: a host-provided engine skips the base
    // `configureFlutterEngine` (see FlutterActivity), so register explicitly
    // here — only at first creation, to avoid double registration on
    // re-attach. The Dart entrypoint is executed by the framework on the first
    // view run; `doInitialFlutterViewRun` is a no-op once Dart is executing.
    // Application context: this engine outlives the Activity and must not
    // retain it.
    val engine = FlutterEngine(
      context.applicationContext,
      FlutterShellArgs.fromIntent(intent).toArray(),
      false,
    )
    GeneratedPluginRegistrant.registerWith(engine)
    FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    Log.i(LOG_TAG, "created cached FlutterEngine id=$ENGINE_ID")
    return engine
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // Idempotent: runs on every attach so a re-attached engine keeps its
    // handshake/tunnel handlers after a detach.
    TunnelHost.register(flutterEngine, applicationContext)
  }

  /// The cached engine must outlive every Activity so background healing
  /// continues after a swipe-away.
  override fun shouldDestroyEngineWithHost(): Boolean = false

  override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    // No-op on purpose: channel handlers and their coroutine scope are
    // process-scoped (see [TunnelHost]). Tearing them down here would kill
    // background auto-heal while the cached engine is still alive.
  }

  private companion object {
    const val LOG_TAG = "BoltMeshTunnel"
    const val ENGINE_ID = "boltmesh_main"
  }
}
