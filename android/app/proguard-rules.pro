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

# AmneziaWG's native JNI shim resolves these names directly. Keep the bridge
# class and native method symbols stable in minified release APKs. Keep the
# parser model as well: the Android release smoke test invokes its userspace
# serializer independently of the production backend call.
-keep class org.amnezia.awg.GoBackend { *; }
-keep class org.amnezia.awg.config.** { *; }

# AmneziaWgConnectSmokeTest asserts AndroidAwgHost's thread-confinement guard
# directly. Production reaches the host only through TunnelHost's channel
# lambdas, which R8 can inline past, so the test's call then dies with
# NoClassDefFoundError. Keep the host the confinement test asserts on.
-keep class com.boltmesh.boltmesh.AndroidAwgHost { *; }

# Do not add owner-class keeps here: AGP applies the release mapping to
# androidTest class references.
