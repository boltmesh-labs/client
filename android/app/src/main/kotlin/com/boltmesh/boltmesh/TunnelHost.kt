package com.boltmesh.boltmesh

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.wireguard.android.backend.Backend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import orban.group.wireguard_flutter.WireguardFlutterPlugin
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
/// Own handshake channel (never the VPN plugin's — it is not forked).
/// Contract: `getLastHandshake` returns the latest completed WireGuard
/// handshake as epoch seconds (double), or null when unknown (no handshake
/// yet, backend not ready, or any read failure). The owning backend is the
/// one whose `runningTunnelNames` is non-empty (the current plugin's, else
/// the pre-restart survivor in [SharedTunnel]): querying any other instance
/// returns empty stats because GoBackend matches tunnels by object identity.
internal object TunnelHost {
  private const val LOG_TAG = "BoltMeshTunnel"

  /// Well inside the 3s Dart-side health-read timeout.
  private const val HANDSHAKE_TIMEOUT_MS = 2_000L
  private const val BACKEND_TIMEOUT_MS = 2_000L

  /// Backstop for a consent round-trip whose Activity died without delivering
  /// a result. [detachConsentHost] normally completes the waiter first, so this
  /// only bounds an unexpected death — it must stay generous, because the wait
  /// is a human reading a system dialog, not a wedged driver.
  private const val CONSENT_TIMEOUT_MS = 5 * 60_000L

  /// Process-lifetime scope: must outlive every Activity so a detached
  /// Activity cannot cancel in-flight handshake/tunnel work the cached
  /// engine still depends on.
  private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val main = Handler(Looper.getMainLooper())

  /// The only thread that may enter libawg-go.so, and the scope for the four
  /// AWG handlers below ([startAwg][stopAwg][statusAwg][killAwgGhost]).
  ///
  /// Two Go runtimes live in this process — the stock plugin's libwg-go.so
  /// and our libawg-go.so — and a Go runtime binds the calling thread on
  /// first entry, so a thread that entered one runtime must never enter the
  /// other. The stock plugin runs its backend on the shared [Dispatchers.IO]
  /// pool, and so did these handlers: once the pool recycled a worker the
  /// stock backend had used, the first AWG JNI call read the stock runtime's
  /// thread state as its own and died with a SIGSEGV inside
  /// `runtime.cgocallback` (null + 0x38, identical PC on every native→AWG
  /// failover, no Go traceback because the runtime never engaged). This
  /// private thread only ever enters ours, which also serializes the
  /// backend's unguarded handle map. The stock-touching calls above it must
  /// stay on [ioScope]: running them here would pollute this thread for the
  /// stock runtime and crash in the other direction.
  private val awgThread = Executors.newSingleThreadExecutor { r ->
    Thread(r, AndroidAwgHost.awgThreadName).apply { isDaemon = true }
  }
  private val awgScope =
    CoroutineScope(SupervisorJob() + awgThread.asCoroutineDispatcher())

  /// Application context captured on the first [register]; used only to read
  /// the plugin's persisted `vpn_prefs` config.
  @Volatile private var appContext: Context? = null

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

  /// Registers (or re-registers) the app's channels on [engine]. Idempotent:
  /// `configureFlutterEngine` runs on every Activity attach, so this may be
  /// called again after a detach → re-attach cycle. The handlers capture the
  /// engine, which is the same cached instance across cycles.
  fun register(engine: FlutterEngine, context: Context) {
    appContext = context.applicationContext
    MethodChannel(
      engine.dartExecutor.binaryMessenger,
      "com.boltmesh/handshake",
    ).setMethodCallHandler { call, result ->
      if (call.method != "getLastHandshake") {
        result.notImplemented()
        return@setMethodCallHandler
      }
      val plugin = pluginOf(engine)
      ioScope.launch {
        val secs = try {
          withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
            latestHandshakeSecs(plugin)
          }
        } catch (t: Throwable) {
          null
        }
        // MethodChannel results must be delivered on the main thread.
        main.post { result.success(secs) }
      }
    }
    // Ghost-aware tunnel channel. The plugin's `disconnect()` orphan branch
    // (`Running tunnels: []` → UP-then-DOWN with a stale cached config)
    // creates a *new* TUN instead of killing the surviving one, because a
    // re-attached engine owns a fresh GoBackend whose `runningTunnelNames`
    // is empty while the old backend still holds `tun0`. These helpers act
    // on the owning backend directly (same object identity), so Dart can
    // adopt-if-match or bounce cleanly without a reclaim-start.
    MethodChannel(
      engine.dartExecutor.binaryMessenger,
      "com.boltmesh/tunnel",
    ).setMethodCallHandler { call, result ->
      val plugin = pluginOf(engine)
      when (call.method) {
        "getRunningTunnels" -> {
          ioScope.launch {
            val names = try {
              withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
                owningBackendTunnel(plugin)?.first?.runningTunnelNames?.toList()
              } ?: emptyList()
            } catch (t: Throwable) {
              emptyList()
            }
            main.post { result.success(names) }
          }
        }
        "getActivePeer" -> {
          ioScope.launch {
            val peer = try {
              withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
                activePeer(plugin)
              }
            } catch (t: Throwable) {
              null
            }
            main.post { result.success(peer) }
          }
        }
        "killGhost" -> {
          ioScope.launch {
            val killed = try {
              withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) {
                killOwningTunnel(plugin)
              } ?: false
            } catch (t: Throwable) {
              false
            }
            main.post { result.success(killed) }
          }
        }
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
          val app = appContext ?: context.applicationContext
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
          val app = appContext ?: context.applicationContext
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
          val app = appContext ?: context.applicationContext
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
    // Reunite the cached engine with any surviving backend and refresh the
    // survivor snapshot. Best-effort on both counts.
    transplantSharedBackend(engine)
    ioScope.launch { refreshShared(engine) }
  }

  private fun pluginOf(engine: FlutterEngine): WireguardFlutterPlugin? =
    engine.plugins.get(WireguardFlutterPlugin::class.java) as? WireguardFlutterPlugin

  /// Obtains this app's OS VPN consent *before* the plugin's `start` runs.
  ///
  /// `wireguard_flutter_plus` asks for consent from inside `connect()` and
  /// only settles its Dart future once the user answers, but Dart bounds `start`
  /// with `TunnelTuning.opTimeout` (10s) to catch a wedged driver. A human
  /// reading the system dialog outlasts that budget, so the first connect after
  /// every fresh install failed with a bogus timeout and only worked on a
  /// second tap. Consenting here keeps the dialog out of the timed section: the
  /// plugin re-checks `VpnService.prepare` on every start and short-circuits
  /// once consent exists, so the user still sees exactly one dialog.
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

  /// Latest peer handshake across the owning tunnel, in epoch seconds, or
  /// null when the tunnel has no completed handshake yet (the "never
  /// handshook" evidence the health tick ages out) or any step is
  /// unavailable.
  ///
  /// Identity only: the plugin's `config` field is deliberately not required
  /// here. The plugin never re-assigns it on `connect` (and clears it on every
  /// disconnect), so after any reconnect it is null even though the tunnel is
  /// live — requiring it made every handshake read report "never".
  private suspend fun latestHandshakeSecs(
    plugin: WireguardFlutterPlugin?,
  ): Double? {
    val (backend, tunnel) = owningBackendTunnel(plugin) ?: return null
    return try {
      val stats = backend.getStatistics(tunnel)
      var newestMs = 0L
      for (key in stats.peers()) {
        val ms = stats.peer(key)?.latestHandshakeEpochMillis() ?: continue
        if (ms > newestMs) newestMs = ms
      }
      if (newestMs > 0) newestMs / 1000.0 else null
    } catch (t: Throwable) {
      null
    }
  }

  /// Identifying fields of the owning tunnel's single peer, or null when no
  /// tunnel is running. No private key material leaves the device: only the
  /// server public key, endpoint, and overlay address (enough for Dart to
  /// decide adopt-if-match vs clean bounce).
  private suspend fun activePeer(
    plugin: WireguardFlutterPlugin?,
  ): Map<String, String>? {
    val (_, _, config) = owningTriple(plugin) ?: return null
    return try {
      val peer = config.peers.firstOrNull() ?: return null
      val endpoint = peer.endpoint.orElse(null)
      mapOf(
        "publicKey" to peer.publicKey.toBase64(),
        "endpoint" to if (endpoint == null) "" else "${endpoint.host}:${endpoint.port}",
        "address" to (config.`interface`.addresses.firstOrNull()?.toString() ?: ""),
      )
    } catch (t: Throwable) {
      null
    }
  }

  /// Brings the owning tunnel DOWN using its own backend/tunnel pair
  /// (identity must match: GoBackend silently ignores DOWN for any other
  /// object). Returns true when no tunnel is running afterwards.
  ///
  /// The config is deliberately not required: GoBackend's DOWN branch passes
  /// null to `setStateInternal`, so a missing config must never suppress the
  /// kill.
  private suspend fun killOwningTunnel(plugin: WireguardFlutterPlugin?): Boolean {
    val (backend, tunnel) = owningBackendTunnel(plugin) ?: return true
    val dead = try {
      backend.setState(tunnel, Tunnel.State.DOWN, owningConfig(plugin, backend))
      backend.runningTunnelNames.isEmpty()
    } catch (t: Throwable) {
      backend.runningTunnelNames.isEmpty()
    }
    Log.i(LOG_TAG, "killGhost tunnel=${tunnel.getName()} down=$dead")
    return dead
  }

  /// The triple that actually owns the live TUN, pairing
  /// [owningBackendTunnel] with an independently resolved [owningConfig].
  private suspend fun owningTriple(
    plugin: WireguardFlutterPlugin?,
  ): Triple<Backend, Tunnel, Config>? {
    val (backend, tunnel) = owningBackendTunnel(plugin) ?: return null
    val config = owningConfig(plugin, backend) ?: return null
    return Triple(backend, tunnel, config)
  }

  /// The backend + tunnel that own the live TUN: the current plugin's when its
  /// backend reports running tunnels, else the pre-restart survivor.
  ///
  /// The owner is resolved from the object GoBackend itself holds
  /// ([backendTunnelOf]), never from the plugin's `tunnel` field: the plugin's
  /// engine-restart restore nulls that field and recreates a fresh
  /// `WireGuardTunnel` (`Tunnel object recreated for existing VPN connection`)
  /// while GoBackend keeps matching the pre-restart object by identity, so a
  /// DOWN through the plugin's field is a silent no-op and the stale peer keeps
  /// handshaking. The plugin's field is only accepted when GoBackend reports it
  /// UP. Refreshes [SharedTunnel] whenever the current plugin owns one.
  private suspend fun owningBackendTunnel(
    plugin: WireguardFlutterPlugin?,
  ): Pair<Backend, Tunnel>? {
    if (plugin != null) {
      try {
        val backend = awaitBackend(plugin)
        if (backend != null && backend.runningTunnelNames.isNotEmpty()) {
          val tunnel = backendTunnelOf(backend)
            ?: (pluginField(plugin, "tunnel") as? Tunnel)?.takeIf {
              backend.getState(it) == Tunnel.State.UP
            }
          if (tunnel != null) {
            SharedTunnel.save(
              backend,
              tunnel,
              owningConfig(plugin, backend),
              tunnelNameOf(plugin),
            )
            return backend to tunnel
          }
        }
      } catch (t: Throwable) {
        // Fall through to the survivor below.
      }
    }
    return SharedTunnel.runningBackendTunnel()
  }

  /// The live tunnel's config, resolved without trusting the plugin's `config`
  /// field: `connect` never re-assigns it (and `disconnect` clears it), so
  /// after any reconnect it is stale or null. Order: the last config the plugin
  /// persisted on connect (always current, even across a failover), then the
  /// plugin's field (engine-attach restore), then GoBackend's own live config,
  /// then the survivor's. The backend copy matters after a failed DOWN: the
  /// plugin has already deleted `vpn_prefs/last_used_config` and nulled its own
  /// field, while GoBackend still holds the config of the surviving tunnel.
  private fun owningConfig(
    plugin: WireguardFlutterPlugin?,
    backend: Backend? = null,
  ): Config? {
    savedConfig()?.let { return it }
    if (plugin != null) {
      (pluginField(plugin, "config") as? Config)?.let { return it }
    }
    if (backend != null) {
      backendConfigOf(backend)?.let { return it }
    }
    return SharedTunnel.config()
  }

  /// The last wg-quick config the plugin persisted on connect
  /// (`vpn_prefs/last_used_config`); null once disconnected or on any parse
  /// failure.
  private fun savedConfig(): Config? = try {
    val saved = appContext
      ?.getSharedPreferences("vpn_prefs", Context.MODE_PRIVATE)
      ?.getString("last_used_config", null)
    if (saved.isNullOrEmpty()) null else Config.parse(saved.byteInputStream())
  } catch (t: Throwable) {
    null
  }

  /// Reunites a re-attached engine with the surviving backend: without this
  /// the new plugin sees `Running tunnels: []` while the OS VPN is up, and
  /// its orphan UP-then-DOWN flaps a new TUN instead of killing the ghost.
  /// Best-effort and race-safe: when the new backend already completed, the
  /// Dart `killGhost` path (same object identity via [SharedTunnel]) still
  /// kills correctly.
  private fun transplantSharedBackend(engine: FlutterEngine) {
    try {
      val plugin = pluginOf(engine) ?: return
      val (backend, tunnel) = SharedTunnel.runningBackendTunnel() ?: return
      setPluginField(plugin, "backend", backend)
      setPluginField(plugin, "tunnel", tunnel)
      SharedTunnel.config()?.let { setPluginField(plugin, "config", it) }
      SharedTunnel.name()?.let { setPluginField(plugin, "tunnelName", it) }
      @Suppress("UNCHECKED_CAST")
      val future =
        pluginField(plugin, "futureBackend") as? CompletableDeferred<Backend>
          ?: return
      if (!future.isCompleted) future.complete(backend)
    } catch (t: Throwable) {
      // Transplant is an optimization; killGhost covers the missed race.
    }
  }

  private suspend fun refreshShared(engine: FlutterEngine) {
    try {
      val plugin = pluginOf(engine) ?: return
      val backend = awaitBackend(plugin) ?: return
      if (backend.runningTunnelNames.isEmpty()) return
      // Resolve the object GoBackend actually holds: the plugin's `tunnel`
      // field is replaced by its restore path and must never be cached as the
      // owner (a later DOWN through it silently no-ops).
      val tunnel = backendTunnelOf(backend)
        ?: (pluginField(plugin, "tunnel") as? Tunnel)?.takeIf {
          backend.getState(it) == Tunnel.State.UP
        }
        ?: return
      // The plugin's `config` field is null after any reconnect; fall back to
      // GoBackend's live config, then the survivor's cached copy.
      val config = pluginField(plugin, "config") as? Config
        ?: backendConfigOf(backend)
      SharedTunnel.save(backend, tunnel, config, tunnelNameOf(plugin))
    } catch (t: Throwable) {
      // Best-effort only.
    }
  }

  private suspend fun awaitBackend(plugin: WireguardFlutterPlugin): Backend? {
    val existing = pluginField(plugin, "backend") as? Backend
    if (existing != null) return existing
    @Suppress("UNCHECKED_CAST")
    val future =
      pluginField(plugin, "futureBackend") as? CompletableDeferred<Backend>
        ?: return null
    return try {
      withTimeoutOrNull(BACKEND_TIMEOUT_MS) { future.await() }
    } catch (t: Throwable) {
      null
    }
  }

  private fun tunnelNameOf(plugin: Any): String? = try {
    pluginField(plugin, "tunnelName") as? String
  } catch (t: Throwable) {
    null
  }

  // These string-based lookups are part of the release ABI; the matching R8
  // field-name keeps live in android/app/proguard-rules.pro; the release
  // smoke test guards them.
  private fun pluginField(plugin: Any, name: String): Any? = try {
    plugin.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(
      plugin,
    )
  } catch (t: Throwable) {
    null
  }

  private fun setPluginField(plugin: Any, name: String, value: Any?) {
    try {
      plugin.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(
        plugin,
        value,
      )
    } catch (t: Throwable) {
      // Best-effort transplant; killGhost covers the miss.
    }
  }
}

/// The tunnel object GoBackend itself holds as `currentTunnel`, or null when
/// no tunnel is running or reflection fails. This is the only object its
/// identity-keyed `setState`/`getStatistics` accept for the live TUN — the
/// plugin's own `tunnel` field may be a replacement the backend ignores.
private fun backendTunnelOf(backend: Backend): Tunnel? = try {
  backend.javaClass.getDeclaredField("currentTunnel")
    .apply { isAccessible = true }.get(backend) as? Tunnel
} catch (t: Throwable) {
  null
}

/// GoBackend's own live `currentConfig`, or null when none/reflection fails.
private fun backendConfigOf(backend: Backend): Config? = try {
  backend.javaClass.getDeclaredField("currentConfig")
    .apply { isAccessible = true }.get(backend) as? Config
} catch (t: Throwable) {
  null
}

/// Pre-restart survivor: the exact GoBackend/Tunnel objects that own the live
/// TUN, plus the last config seen. GoBackend matches tunnels by object
/// identity, so only this pair can bring the ghost DOWN after an engine
/// re-attach. A null [save] config never clobbers a previously known one.
///
/// Process-global (unlike the old Activity-scoped copy): the cached engine
/// outlives the Activity, so the survivor must too.
private object SharedTunnel {
  @Volatile private var backend: Backend? = null
  @Volatile private var tunnel: Tunnel? = null
  @Volatile private var config: Config? = null
  @Volatile private var tunnelName: String? = null

  fun save(b: Backend, t: Tunnel, c: Config?, name: String?) {
    backend = b
    tunnel = t
    if (c != null) config = c
    if (!name.isNullOrEmpty()) tunnelName = name
  }

  fun config(): Config? = config

  fun name(): String? = tunnelName

  fun runningBackendTunnel(): Pair<Backend, Tunnel>? {
    val b = backend ?: return null
    return try {
      if (b.runningTunnelNames.isEmpty()) return null
      // Prefer the object GoBackend holds right now; the stored reference is a
      // fallback only when reflection is unavailable and it still reports UP.
      val t = backendTunnelOf(b)
        ?: tunnel?.takeIf { b.getState(it) == Tunnel.State.UP }
        ?: return null
      b to t
    } catch (t2: Throwable) {
      null
    }
  }
}
