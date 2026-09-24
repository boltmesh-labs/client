# TunnelHost uses a small, private ABI with wireguard_flutter_plus.  Those
# fields are looked up by name, so R8 cannot see the accesses and would
# otherwise remove or rename them in the minified release APK. Keep these
# entries in sync with the pinned wireguard_flutter_plus/tunnel versions.
-keepclassmembers class orban.group.wireguard_flutter.WireguardFlutterPlugin {
    private com.wireguard.android.backend.Backend backend;
    private kotlinx.coroutines.CompletableDeferred futureBackend;
    private orban.group.wireguard_flutter.WireGuardTunnel tunnel;
    private com.wireguard.config.Config config;
    private java.lang.String tunnelName;
}

# GoBackend is also queried by field name to recover the object that owns the
# live TUN after an engine restart.  Keep only the two fields used by the
# bridge; the rest of the backend remains eligible for normal R8 shrinking.
-keepclassmembers class com.wireguard.android.backend.GoBackend {
    private com.wireguard.config.Config currentConfig;
    private com.wireguard.android.backend.Tunnel currentTunnel;
}

# Do not add owner-class keeps here: production uses javaClass, and AGP applies
# the release mapping to androidTest class references.
