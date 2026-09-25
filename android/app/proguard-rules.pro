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

# androidx.test:runner's AndroidJUnitRunner.onCreate calls
# androidx.tracing.Trace, but the app never does, so R8 shrinks it away. The
# minified androidTest APK then treats the class as app-provided and omits it,
# so the release smoke-test runner crashes with NoClassDefFoundError in
# onCreate and `connectedReleaseAndroidTest` hangs with no test result. Keep it
# in the release APK; the runner resolves it from there at runtime.
-keep class androidx.tracing.** { *; }

# Same class of failure: AndroidJUnitRunner.registerTestStorage uses Kotlin's
# top-level lazy(), and the minified androidTest APK resolves kotlin.* from the
# app APK. The app's own Kotlin usage does not reach every stdlib entry point
# the runner needs, so R8 must not shrink them out.
-keep class kotlin.LazyKt { *; }

# WireGuardConnectSmokeTest parses a config through the shipped release APK.
# Production only reaches Config.parse() on the cold-start path, so R8 inlines
# it into TunnelHost and the test's call into the WireGuard model then dies with
# NoSuchMethodError. Keep the model the connect-path smoke test asserts on.
-keep class com.wireguard.config.** { *; }

# Do not add owner-class keeps here: production uses javaClass, and AGP applies
# the release mapping to androidTest class references.
