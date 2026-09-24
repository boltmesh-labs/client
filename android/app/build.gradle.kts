import java.io.FileInputStream
import java.util.Properties

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
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.boltmesh.boltmesh"
        // Pinned to the documented Android floor (API 24 / Android 7.0): the
        // Flutter 3.47 default, and above wireguard_flutter_plus's own
        // minSdkVersion 21. Pinning keeps the README's stated minimum from
        // silently drifting when the Flutter SDK bumps its default; revisit
        // together with the foreground-service contract in README.md.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // MainActivity's handshake reader (CompletableDeferred/await against the
    // wireguard_flutter_plus plugin's backend).
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.2")
    // Typed access to the same tunnel artifact the plugin uses
    // (GoBackend/Tunnel/Config). Must stay on the exact version the plugin
    // bundles so both load the same classes.
    implementation("com.wireguard.android:tunnel:1.0.20260102")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
