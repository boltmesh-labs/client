package com.boltmesh.boltmesh

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/// Process-level host for the app's own native tunnel channels.
///
/// Deliberately *not* owned by [MainActivity]: the app runs on a cached
/// [FlutterEngine] (see [MainActivity.provideFlutterEngine]) so the Dart
/// isolate — and with it the health tick that drives auto-heal (10s
/// foreground / 30s background) — keeps running after the task is swiped
/// away, while the plugin's
/// `VpnForegroundService` keeps the process alive. A detached Activity still
/// calls `cleanUpFlutterEngine`, so the channel handlers and the coroutine
/// scope they launch on live at process scope here; otherwise the Activity
/// teardown would silently kill background healing.
///
/// Own channel, never the VPN plugin's — that plugin is not forked. It serves
/// the in-process AmneziaWG host ([AndroidAwgHost]) plus the OS VPN consent
/// round-trip; there is no stock-plugin path left to serve, because every
/// Android rung runs on that one host (see `AndroidTunnelAdapter`).
internal object TunnelHost {
  private const val LOG_TAG = "BoltMeshTunnel"

  /// Backstop for a consent round-trip whose Activity died without delivering
  /// a result. [detachConsentHost] normally completes the waiter first, so this
  /// only bounds an unexpected death — it must stay generous, because the wait
  /// is a human reading a system dialog, not a wedged driver.
  private const val CONSENT_TIMEOUT_MS = 5 * 60_000L

  /// Process-lifetime scope: must outlive every Activity so a detached
  /// Activity cannot cancel in-flight consent work the cached engine still
  /// depends on.
  private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val main = Handler(Looper.getMainLooper())

  /// The only thread that enters libawg-go.so, and the scope for the four AWG
  /// handlers below ([register]'s `startAwg`/`stopAwg`/`statusAwg`/
  /// `killAwgGhost`).
  ///
  /// Android runs every rung on this one Go runtime: the stock plugin's
  /// libwg-go.so is never loaded (its attach-time backend construction is
  /// dropped by the source overlay in `android/build.gradle.kts`). Two
  /// initialized Go runtimes in one process replace each other's
  /// process-global signal handlers, so the app faulted on the stock↔AWG
  /// owner switch; see `tool/android-debug/README.md`.
  ///
  /// Keeping every libawg-go entry point on this private thread outlives that
  /// fix and still buys two things: it serializes the backend's unguarded
  /// handle map, and it keeps the native entry on one stable thread identity.
  /// Everything that enters libawg-go belongs here — including the vendored
  /// `VpnService`'s teardown, which the framework delivers on the main thread
  /// and which [runOnAwgThread] forwards. The consent round-trip, which
  /// touches no native code, stays on [ioScope].
  private val awgThread = Executors.newSingleThreadExecutor { r ->
    Thread(r, AndroidAwgHost.awgThreadName).apply { isDaemon = true }
  }
  private val awgScope =
    CoroutineScope(SupervisorJob() + awgThread.asCoroutineDispatcher())

  /// Runs [task] on the confined libawg-go thread (see [awgThread]).
  ///
  /// For a caller the framework runs off that thread — `VpnService.onDestroy`
  /// is delivered on the main thread — whose body still has to enter
  /// libawg-go. Entering it in place would put a second Java thread into the
  /// runtime, which is the one thing the confinement exists to prevent, so it
  /// is handed here instead. Public rather than `private` because the vendored
  /// `org.amnezia.awg.backend.GoBackend`'s service callback is the caller.
  fun runOnAwgThread(task: Runnable) {
    awgThread.execute(task)
  }

  /// The Activity currently able to service a VPN consent round-trip. Set and
  /// cleared by [MainActivity] because `startActivityForResult` needs an
  /// Activity and this object deliberately outlives every one of them (see the
  /// class docs).
  @Volatile private var consentHost: VpnConsentHost? = null

  /// The single in-flight consent round-trip. Android shows one VPN consent
  /// dialog at a time, so a concurrent request is rejected rather than queued:
  /// queueing would need a second deferred and buy nothing.
  private val pendingConsent = AtomicReference<CompletableDeferred<Boolean>?>(null)

  /// Hosts the OS VPN consent dialog. Implemented by [MainActivity]; kept as an
  /// interface so this object never holds an Activity reference itself.
  internal interface VpnConsentHost {
    /// The system consent Intent, or null when this app's VPN service is
    /// already authorized (or the platform has no consent step).
    fun prepareConsentIntent(): Intent?

    /// Shows [intent]. False when no Activity can show it, so the caller can
    /// fail fast instead of leaving a result nobody will deliver.
    fun launchConsent(intent: Intent): Boolean
  }

  /// Registers the Activity that can service consent requests. Called from
  /// every [MainActivity] instance, so a re-created Activity re-arms this.
  fun attachConsentHost(host: VpnConsentHost) {
    consentHost = host
  }

  /// Detaches [host] and fails any waiter it would have completed: the
  /// Activity dying takes the `startActivityForResult` result with it, so
  /// leaving the deferred pending would hang Dart's consent step forever.
  fun detachConsentHost(host: VpnConsentHost) {
    if (consentHost === host) consentHost = null
    pendingConsent.getAndSet(null)?.complete(false)
  }

  /// Delivers the user's answer to the consent dialog.
  fun onConsentResult(granted: Boolean) {
    pendingConsent.getAndSet(null)?.complete(granted)
  }

  /// Registers (or re-registers) the app's channel on [engine]. Idempotent:
  /// `configureFlutterEngine` runs on every Activity attach, so this may be
  /// called again after a detach → re-attach cycle. The handlers capture the
  /// engine, which is the same cached instance across cycles.
  fun register(engine: FlutterEngine, context: Context) {
    MethodChannel(
      engine.dartExecutor.binaryMessenger,
      "com.boltmesh/tunnel",
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "requestVpnConsent" -> {
          requestVpnConsent(result)
        }
        "startAwg" -> {
          val wgQuickConfig = call.argument<String>("wgQuickConfig")
          if (wgQuickConfig.isNullOrEmpty()) {
            result.error("BAD_CONFIG", "AWG config is missing", null)
            return@setMethodCallHandler
          }
          // Present only on the stream rung: the validated transport spec the
          // native bridge dials the node with. Null on the plain AWG rung.
          val streamSpec = call.argument<String>("streamSpec")
          val app = context.applicationContext
          awgScope.launch {
            val reply = try {
              AndroidAwgHost.start(app, wgQuickConfig, streamSpec)
            } catch (t: Throwable) {
              Log.w(LOG_TAG, "AWG tunnel start failed (${t.javaClass.simpleName})")
              main.post {
                result.error("AWG_START_FAILED", "AmneziaWG tunnel could not start", null)
              }
              return@launch
            }
            main.post { result.success(reply) }
          }
        }
        "stopAwg" -> {
          val app = context.applicationContext
          awgScope.launch {
            val reply = try {
              AndroidAwgHost.stop(app)
            } catch (t: Throwable) {
              Log.w(LOG_TAG, "AWG tunnel stop failed (${t.javaClass.simpleName})")
              main.post {
                result.error("AWG_STOP_FAILED", "AmneziaWG tunnel could not stop", null)
              }
              return@launch
            }
            main.post { result.success(reply) }
          }
        }
        "statusAwg" -> {
          awgScope.launch {
            val reply = try {
              AndroidAwgHost.status()
            } catch (t: Throwable) {
              Log.i(LOG_TAG, "AWG status unavailable (${t.javaClass.simpleName})")
              null
            }
            main.post { result.success(reply) }
          }
        }
        "killAwgGhost" -> {
          val app = context.applicationContext
          awgScope.launch {
            val killed = try {
              AndroidAwgHost.stop(app)["up"] != true
            } catch (t: Throwable) {
              Log.w(LOG_TAG, "AWG ghost cleanup failed (${t.javaClass.simpleName})")
              false
            }
            main.post { result.success(killed) }
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  /// Obtains this app's OS VPN consent *before* a start runs.
  ///
  /// The AWG host's `VpnService` asks for consent from inside its start and only
  /// settles once the user answers, but Dart bounds that start with
  /// `TunnelTuning.opTimeout` (10s) to catch a wedged driver. A human reading
  /// the system dialog outlasts that budget, so the first connect after every
  /// fresh install failed with a bogus timeout and only worked on a second tap.
  /// Consenting here keeps the dialog out of the timed section: the platform
  /// re-checks `VpnService.prepare` on every start and short-circuits once
  /// consent exists, so the user still sees exactly one dialog.
  ///
  /// The plugin's own `checkVpnPermission` is unusable here — it stores its
  /// pending `MethodChannel.Result` in a field `onActivityResult` never
  /// completes, so that future hangs whenever consent is actually missing.
  private fun requestVpnConsent(result: MethodChannel.Result) {
    val host = consentHost
    if (host == null) {
      // Fail fast rather than hang: without an Activity there is no way to
      // show the dialog, and a pending deferred would never be completed.
      result.error(
        "NO_ACTIVITY",
        "No Activity is attached, so VPN consent cannot be requested",
        null,
      )
      return
    }
    val prepare = try {
      host.prepareConsentIntent()
    } catch (t: Throwable) {
      Log.w(LOG_TAG, "vpn consent prepare failed", t)
      null
    }
    // Already authorized (or nothing to authorize): answer immediately so Dart
    // never spends a round-trip on the common case.
    if (prepare == null) {
      result.success(true)
      return
    }
    val waiter = CompletableDeferred<Boolean>()
    if (!pendingConsent.compareAndSet(null, waiter)) {
      result.error(
        "CONSENT_BUSY",
        "A VPN consent request is already awaiting the user",
        null,
      )
      return
    }
    val launched = try {
      host.launchConsent(prepare)
    } catch (t: Throwable) {
      Log.w(LOG_TAG, "vpn consent launch failed", t)
      false
    }
    if (!launched) {
      pendingConsent.compareAndSet(waiter, null)
      result.error(
        "NO_ACTIVITY",
        "No Activity is available to show the VPN consent dialog",
        null,
      )
      return
    }
    Log.i(LOG_TAG, "vpn consent dialog shown, awaiting user")
    ioScope.launch {
      // No timeout on the normal path: the user decides how long this takes.
      // The bound only catches an Activity death that skipped
      // `detachConsentHost`.
      val granted = withTimeoutOrNull(CONSENT_TIMEOUT_MS) { waiter.await() } ?: false
      pendingConsent.compareAndSet(waiter, null)
      main.post { result.success(granted) }
    }
  }
}
