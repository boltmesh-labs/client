package com.boltmesh.boltmesh

import android.content.Context
import android.content.Intent
import android.os.Build
import org.amnezia.awg.backend.GoBackend
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.config.Config
import org.amnezia.awg.GoBackend as AwgJni
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets

/// Process-lifetime owner for Android's in-process AmneziaWG backend.
///
/// Stock regions continue to use wireguard_flutter_plus. This host is used only
/// when the selected region's wg-quick config carries the AWG directives. The
/// upstream backend builds Android's VpnService TUN, starts the pinned
/// amneziawg-go device over that descriptor, and protects its UDP sockets from
/// being routed back into the VPN.
internal object AndroidAwgHost {
  private const val tunnelName = "boltmesh0"
  private const val foregroundServiceClass =
    "orban.group.wireguard_flutter.VpnForegroundService"

  private val lock = Any()
  private val tunnel = object : Tunnel {
    override fun getName(): String = tunnelName

    override fun onStateChange(newState: Tunnel.State) = Unit
  }

  @Volatile private var backend: GoBackend? = null
  @Volatile private var liveConfig: Config? = null

  /// The native stream bridge for the current start, or -1. Started before the
  /// engine so the loopback port the tunnel's peer points at is bound when the
  /// engine sends its first datagram, and stopped with the tunnel.
  @Volatile private var liveStreamHandle: Int = -1

  fun start(context: Context, wgQuickConfig: String, streamSpec: String? = null): Map<String, Any> = synchronized(lock) {
    val parsed = Config.parse(
      ByteArrayInputStream(wgQuickConfig.toByteArray(StandardCharsets.UTF_8)),
    )
    require(parsed.peers.size == 1) { "BoltMesh Android AWG requires one peer" }

    // The peer's hostname is resolved when the config is serialized for the engine:
    // `InetEndpoint.getResolved` looks it up (preferring v4) and renders the address,
    // because amneziawg-go's StdNetBind parses address literals only and would reject
    // a name outright. It is also where a lookup failure goes — the endpoint line is
    // then simply left out of the body, so the device would accept a peer with no
    // endpoint and report up while never handshaking, indistinguishable from a slow
    // path. Fail here instead, before the TUN exists, naming the host that could not
    // be found. The result is cached for a minute, so the serialization below reads it
    // rather than looking it up twice.
    val peer = parsed.peers.single()
    check(peer.endpoint.flatMap { it.resolved }.isPresent) {
      "BoltMesh Android AWG could not resolve " +
        peer.endpoint.map { "${it.host}:${it.port}" }.orElse("the configured endpoint")
    }

    val owner = backend ?: GoBackend(context.applicationContext).also { backend = it }
    var streamHandle = -1
    if (streamSpec != null) {
      streamHandle = AwgJni.awgStartStream(streamSpec)
      check(streamHandle > 0) { "AmneziaWG stream bridge did not start" }
    }
    try {
      val state = owner.setState(tunnel, Tunnel.State.UP, parsed)
      check(state == Tunnel.State.UP) { "AmneziaWG backend did not bring the tunnel up" }
      liveConfig = parsed
      liveStreamHandle = streamHandle
      startForegroundNotification(context.applicationContext)
      statusLocked(owner)
    } catch (failure: Throwable) {
      // Do not leave a live TUN behind if its keep-alive notification could not
      // be started or the backend only partially accepted the config.
      if (streamHandle > 0) {
        runCatching { AwgJni.awgStopStream(streamHandle) }
      }
      runCatching { owner.setState(tunnel, Tunnel.State.DOWN, null) }
      liveConfig = null
      liveStreamHandle = -1
      stopForegroundNotification(context.applicationContext)
      throw failure
    }
  }

  fun stop(context: Context): Map<String, Any> = synchronized(lock) {
    val streamHandle = liveStreamHandle
    liveStreamHandle = -1
    if (streamHandle > 0) {
      runCatching { AwgJni.awgStopStream(streamHandle) }
    }
    val owner = backend
    if (owner != null && owner.getState(tunnel) == Tunnel.State.UP) {
      owner.setState(tunnel, Tunnel.State.DOWN, null)
    }
    liveConfig = null
    stopForegroundNotification(context.applicationContext)
    disconnectedStatus()
  }

  fun status(): Map<String, Any> = synchronized(lock) {
    val owner = backend ?: return@synchronized disconnectedStatus()
    if (owner.getState(tunnel) != Tunnel.State.UP) {
      return@synchronized disconnectedStatus()
    }
    statusLocked(owner)
  }

  private fun statusLocked(owner: GoBackend): Map<String, Any> {
    val config = liveConfig
    val stats = owner.getStatistics(tunnel)
    val handshake = owner.getLastHandshake(tunnel).takeIf { it > 0L } ?: 0L
    val peer = config?.peers?.firstOrNull()
    val endpoint = peer?.endpoint?.orElse(null)?.let { "${it.host}:${it.port}" }.orEmpty()
    val values = mutableMapOf<String, Any>(
      "up" to true,
      "stage" to if (handshake > 0L) "connected" else "connecting",
      "lastHandshake" to handshake,
      "rxBytes" to stats.totalRx(),
      "txBytes" to stats.totalTx(),
    )
    if (peer != null) {
      values["publicKey"] = peer.publicKey.toBase64()
      values["endpoint"] = endpoint
    }
    return values
  }

  private fun disconnectedStatus(): Map<String, Any> = mapOf(
    "up" to false,
    "stage" to "disconnected",
    "lastHandshake" to 0L,
    "rxBytes" to 0L,
    "txBytes" to 0L,
  )

  private fun startForegroundNotification(context: Context) {
    val intent = Intent().setClassName(context, foregroundServiceClass)
      .setAction("START")
      .putExtra("vpnDisplayName", "BoltMesh VPN")
      .putExtra("awgTunnel", true)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      context.startForegroundService(intent)
    } else {
      context.startService(intent)
    }
  }

  private fun stopForegroundNotification(context: Context) {
    runCatching {
      context.startService(
        Intent().setClassName(context, foregroundServiceClass).setAction("STOP"),
      )
    }
  }
}
