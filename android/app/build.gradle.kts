import java.io.FileInputStream
import java.util.Properties
import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing reads `android/key.properties` (gitignored) when present and
// falls back to the debug key otherwise, so `flutter run --release` keeps
// working without a keystore. CI sets REQUIRE_RELEASE_SIGNING=true and refuses
// to build without it, so a tag never ships a debug-signed artifact.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword").forEach { key ->
        if (keystoreProperties.getProperty(key).isNullOrBlank()) {
            throw GradleException("android/key.properties is missing '$key'.")
        }
    }
}

val requireReleaseSigning =
    (System.getenv("REQUIRE_RELEASE_SIGNING")?.equals("true", ignoreCase = true) == true) ||
        (project.findProperty("requireReleaseSigning")?.toString()?.toBoolean() ?: false)
if (requireReleaseSigning && !hasReleaseSigning) {
    throw GradleException(
        "REQUIRE_RELEASE_SIGNING is set but android/key.properties was not found. " +
            "Provide the release keystore (see client/README.md) or unset REQUIRE_RELEASE_SIGNING.",
    )
}

android {
    namespace = "com.boltmesh.boltmesh"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    // The bridge smoke test must exercise the same minified variant that
    // is shipped, rather than the unminified debug APK.
    testBuildType = "release"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    defaultConfig {
        applicationId = "com.boltmesh.boltmesh"
        // Android 11 is the documented floor. It already provides the
        // java.time APIs used by WireGuard's config parser. Pinning keeps
        // the README's stated minimum from silently drifting when the
        // Flutter SDK bumps its default; revisit together with the
        // foreground-service contract in README.md.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // AWG uses the same Android TUN descriptor as the stock tunnel, but a
        // separate userspace Go device. Keep the ABI list aligned with the
        // architectures for which Gradle builds libawg-go.so below.
        ndk {
            abiFilters += setOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // Resolved against the app module, so CI writes the keystore to
                // android/app/upload-keystore.jks and stores "upload-keystore.jks".
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // TunnelHost's backend bridge uses a deliberately small reflection
            // ABI. Keep the release build minified while preserving the exact
            // field names in proguard-rules.pro.
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            testProguardFiles("proguard-rules-test.pro")
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // No keystore: debug keys, so `flutter run --release` works.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21
    }
}

flutter {
    source = "../.."
}

// Build the AWG JNI library from the pinned Go module instead of relying on a
// prebuilt .so or mutating the pub cache. The Android emulator and every APK
// variant therefore contain the same AWG engine, with all ABI outputs tracked
// as build products rather than checked-in binaries.
val awgNativeDir = rootProject.file("awg-native")
val awgJniLibsDir = layout.buildDirectory.dir("generated/awg/jniLibs")
val awgBuildScript = rootProject.file("../tool/build_awg_android.py")
val sdkProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.isFile) {
        FileInputStream(localPropertiesFile).use { load(it) }
    }
}
val androidSdkPath = sdkProperties.getProperty("sdk.dir")
    ?: System.getenv("ANDROID_SDK_ROOT")
    ?: System.getenv("ANDROID_HOME")
    ?: throw GradleException("Android SDK path is missing; run `flutter build apk` first")
val awgNdkVersion = android.ndkVersion
val awgNdkDir = file("$androidSdkPath/ndk/$awgNdkVersion")
android.sourceSets.getByName("main").jniLibs.srcDir(awgJniLibsDir.get().asFile)

val buildAwgAndroidNative = tasks.register<Exec>("buildAwgAndroidNative") {
    group = "build"
    description = "Build AmneziaWG's Android JNI libraries"
    inputs.dir(awgNativeDir)
    // The stream bridge imports the shared module, so a change there has to
    // rebuild the native library too, not just the Dart side.
    inputs.dir(rootProject.file("../stream"))
    inputs.file(awgBuildScript)
    inputs.property("goVersion", "1.26")
    inputs.property("ndkVersion", awgNdkVersion)
    outputs.dir(awgJniLibsDir)
    doFirst {
        check(awgNdkDir.isDirectory) {
            "Android NDK $awgNdkVersion is missing at $awgNdkDir"
        }
    }
    workingDir(rootProject.projectDir.parentFile)
    environment("ANDROID_NDK_HOME", awgNdkDir.absolutePath)
    commandLine(
        if (System.getProperty("os.name").lowercase().contains("windows")) "python" else "python3",
        awgBuildScript.absolutePath,
        awgNdkDir.absolutePath,
        awgJniLibsDir.get().asFile.absolutePath,
    )
}

tasks.named("preBuild").configure {
    dependsOn(buildAwgAndroidNative)
}

dependencies {
    // MainActivity's handshake reader (CompletableDeferred/await against the
    // wireguard_flutter_plus plugin's backend).
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // androidx.test:runner calls androidx.tracing.Trace from
    // AndroidJUnitRunner.onCreate. When the androidTest APK is minified it
    // treats androidx.tracing as a library provided by the app, so R8 must not
    // shrink it out of the release APK (see proguard-rules.pro) or the release
    // smoke-test runner dies with NoClassDefFoundError before reporting a
    // result and `connectedReleaseAndroidTest` hangs. Declared explicitly so a
    // transitive dependency bump cannot silently remove it again.
    implementation("androidx.tracing:tracing:2.0.3")
    // Typed access to the same tunnel artifact the plugin uses
    // (GoBackend/Tunnel/Config). Must stay on the exact version the plugin
    // bundles so both load the same classes.
    implementation("com.wireguard.android:tunnel:1.0.20260102")
    // AmneziaWG's Android backend is vendored from the official Apache-2.0
    // tunnel module; the JNI library is built from our pinned amneziawg-go.
    implementation("androidx.annotation:annotation:1.7.1")
    implementation("androidx.collection:collection:1.4.0")
    compileOnly("com.google.code.findbugs:jsr305:3.0.2")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    // `flutter pub get` writes GeneratedPluginRegistrant.java with every
    // method-channel plugin, including dev dependencies, but the Flutter Gradle
    // Plugin strips dev-dependency plugins from the release classpath (it adds
    // them only to non-release build types). The smoke tests compile the release
    // variant directly (testBuildType = "release") without a preceding
    // `flutter build`, so the registrant's reference to the dev-only
    // integration_test plugin needs that project on the release variant too.
    // `flutter build apk --release` rewrites the registrant without dev plugins
    // and R8 strips the now-unreferenced classes, so shipped APKs are unaffected.
    releaseApi(project(":integration_test"))
}
