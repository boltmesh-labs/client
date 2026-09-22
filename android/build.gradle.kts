allprojects {
    repositories {
        google()
        mavenCentral()
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
