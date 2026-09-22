package com.boltmesh.boltmesh

import android.content.Context
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import orban.group.wireguard_flutter.WireguardFlutterPlugin

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

  /// Process-lifetime scope: must outlive every Activity so a detached
  /// Activity cannot cancel in-flight handshake/tunnel work the cached
  /// engine still depends on.
  private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val main = Handler(Looper.getMainLooper())

  /// Application context captured on the first [register]; used only to read
  /// the plugin's persisted `vpn_prefs` config.
  @Volatile private var appContext: Context? = null

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
