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

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.boltmesh.boltmesh"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
}
