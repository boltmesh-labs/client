allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// wireguard_flutter_plus:1.0.7 owns the WireGuard plugin, including its
// Android VpnForegroundService.  The service is not part of this repository,
// but its sticky/null-intent behavior is unsafe for this app: a process
// restart can recreate the service after the in-process TUN has died.  Build a
// source overlay with the reviewed service implementation instead of editing
// the pub cache in place.  The marker check makes a plugin upgrade fail loudly
// rather than silently shipping the old sticky implementation.
val wireguardPlugin = project(":wireguard_flutter_plus")
val wireguardSourceDir = wireguardPlugin.layout.projectDirectory.dir("src/main/kotlin")
val wireguardServiceTemplate = rootProject.file(
    "patches/wireguard_flutter_plus/VpnForegroundService.kt",
)
val patchedWireguardSourceDir = rootProject.layout.buildDirectory.dir(
    "wireguard_flutter_plus/patched-kotlin",
)
val prepareWireguardAndroid = tasks.register("prepareWireguardAndroid") {
    group = "build"
    description = "Apply BoltMesh's non-sticky WireGuard foreground service"
    inputs.dir(wireguardSourceDir)
    inputs.file(wireguardServiceTemplate)
    outputs.dir(patchedWireguardSourceDir)

    doLast {
        val outputDir = patchedWireguardSourceDir.get().asFile
        outputDir.deleteRecursively()
        wireguardSourceDir.asFile.copyRecursively(outputDir)

        val pluginSource = outputDir.resolve(
            "orban/group/wireguard_flutter/WireguardFlutterPlugin.kt",
        )
        check(pluginSource.isFile) {
            "wireguard_flutter_plus source layout changed; update the Android service patch"
        }
        val source = pluginSource.readText()
        val marker = "class VpnForegroundService : Service() {"
        val markerIndex = source.indexOf(marker)
        check(markerIndex >= 0) {
            "wireguard_flutter_plus VpnForegroundService marker changed; " +
                "review patches/wireguard_flutter_plus/VpnForegroundService.kt"
        }
        check(
            !Regex("(?m)^(class|object|interface|typealias|fun|val|var)\\s")
                .containsMatchIn(source.substring(markerIndex + marker.length)),
        ) {
            "wireguard_flutter_plus gained code after VpnForegroundService; " +
                "review the service patch boundary"
        }
        val replacement = wireguardServiceTemplate.readText()
        check(replacement.contains("return START_NOT_STICKY")) {
            "BoltMesh WireGuard service patch must not be sticky"
        }
        check(replacement.contains("if (intent?.action == ACTION_START)")) {
            "BoltMesh WireGuard service must ignore a null restart intent"
        }
        check(replacement.contains("setContentIntent(contentIntent)")) {
            "BoltMesh WireGuard notification must open the app"
        }
        check(replacement.contains("getLaunchIntentForPackage(packageName)")) {
            "BoltMesh WireGuard notification must target the app launcher"
        }
        check(replacement.contains("MAIN_ACTIVITY_CLASS")) {
            "BoltMesh WireGuard notification must retain a MainActivity fallback"
        }
        val onCreate = replacement
            .substringAfter("override fun onCreate()")
            .substringBefore("override fun onStartCommand")
        check(!onCreate.contains("startForeground(")) {
            "BoltMesh WireGuard service must not foreground from onCreate()"
        }
        pluginSource.writeText(source.substring(0, markerIndex) + replacement)
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// wireguard_flutter_plus:1.0.7 hardcodes compileSdkVersion 31 in its own
// android/build.gradle, but its transitive AndroidX deps (appcompat 1.6.1,
// core 1.13.1, lifecycle 2.7.0, ...) require compileSdk >= 34. The app itself
// follows flutter.compileSdkVersion (36 on Flutter 3.47).
//
// The bump below uses no AGP types (the plugin builds with its own pinned
// AGP 7.1.3/KGP 1.8.10, i.e. a different classloader than this script's
// AGP 9.1.0) and registers via gradle.beforeProject: AGP locks compileSdk in
// an afterEvaluate hook registered when the library plugin is applied, so any
// hook registered from subprojects/plugins.withId runs after the lock
// (AgpDslLockedException: "too late to set compileSdk"). Registering before
// the plugin script runs puts our afterEvaluate first, so the write lands
// before the lock.
// Revisit if the plugin ships a fixed release (then delete this).
gradle.beforeProject {
    afterEvaluate {
        // Target specifically the wireguard plugin subproject if isolated patching is preferred
        if (project.name != "wireguard_flutter_plus") return@afterEvaluate

        val android = extensions.findByName("android") as? groovy.lang.GroovyObject
            ?: return@afterEvaluate

        // Set compileSdk to 36
        try { android.setProperty("compileSdk", 36) } catch (_: Exception) {}
        try { android.setProperty("compileSdkVersion", 36) } catch (_: Exception) {}
    }
}

// The plugin's own build script appends src/main/kotlin during evaluation, so
// replace the main Kotlin task's source set after every project has been
// evaluated.  Its older AGP/KGP classloader also means the task API is accessed
// reflectively rather than linked against the app's plugin classes.
gradle.projectsEvaluated {
    val pluginProject = project(":wireguard_flutter_plus")
    checkNotNull(pluginProject.extensions.findByName("android")) {
        "wireguard_flutter_plus Android extension is missing; cannot apply service patch"
    }
    pluginProject.tasks.matching { task ->
        task.name in setOf(
            "compileDebugKotlin",
            "compileProfileKotlin",
            "compileReleaseKotlin",
        )
    }.configureEach {
        dependsOn(prepareWireguardAndroid)
        inputs.dir(patchedWireguardSourceDir)
        val getSources = javaClass.methods.firstOrNull {
            it.name == "getSources" && it.parameterCount == 0
        } ?: error("wireguard_flutter_plus Kotlin task has no sources")
        val sources = getSources.invoke(this)
        val setFrom = sources.javaClass.methods.firstOrNull {
            it.name == "setFrom" &&
                it.parameterCount == 1 &&
                it.parameterTypes[0] == Iterable::class.java
        } ?: error("wireguard_flutter_plus Kotlin sources cannot be replaced")
        val patchedSourceDir = patchedWireguardSourceDir.get().asFile
        setFrom.invoke(sources, listOf(patchedSourceDir))
        val getFiles = sources.javaClass.methods.firstOrNull {
            it.name == "getFiles" && it.parameterCount == 0
        } ?: error("wireguard_flutter_plus Kotlin sources cannot be inspected")
        @Suppress("UNCHECKED_CAST")
        val configuredFiles = getFiles.invoke(sources) as? Set<File>
        check(configuredFiles?.any { it.toPath().startsWith(patchedSourceDir.toPath()) } == true) {
            "wireguard_flutter_plus Kotlin task is missing the reviewed source overlay"
        }
        check(configuredFiles?.none { it.toPath().startsWith(wireguardSourceDir.asFile.toPath()) } == true) {
            "wireguard_flutter_plus Kotlin task still includes the hosted source"
        }
        // AGP may finalize the source collection after this callback. Reassert
        // the replacement immediately before compilation and verify the
        // resulting file set, so a late source-set update cannot ship the
        // hosted implementation.
        doFirst {
            val lateSources = getSources.invoke(this)
            val lateSetFrom = lateSources.javaClass.methods.firstOrNull {
                it.name == "setFrom" &&
                    it.parameterCount == 1 &&
                    it.parameterTypes[0] == Iterable::class.java
            } ?: error("wireguard_flutter_plus Kotlin sources cannot be replaced")
            lateSetFrom.invoke(lateSources, listOf(patchedSourceDir))
            val lateGetFiles = lateSources.javaClass.methods.firstOrNull {
                it.name == "getFiles" && it.parameterCount == 0
            } ?: error("wireguard_flutter_plus Kotlin sources cannot be inspected")
            @Suppress("UNCHECKED_CAST")
            val lateFiles = lateGetFiles.invoke(lateSources) as? Set<File>
            check(lateFiles?.any { it.toPath().startsWith(patchedSourceDir.toPath()) } == true) {
                "wireguard_flutter_plus Kotlin task lost the reviewed source overlay"
            }
            check(lateFiles?.none { it.toPath().startsWith(wireguardSourceDir.asFile.toPath()) } == true) {
                "wireguard_flutter_plus Kotlin task retained the hosted source"
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
