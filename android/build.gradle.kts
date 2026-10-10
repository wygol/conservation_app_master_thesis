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

// ---------------------------------------------------------------------------
// tflite_flutter 0.12.1 (on-device model, ADR 009) pins its Java target to 11
// but never sets a Kotlin JVM target. With AGP 9 and android.builtInKotlin=false
// (gradle.properties), Flutter applies the Kotlin Gradle Plugin to the plugin
// module, and its Kotlin target falls back to the build JDK (21). The first
// release build therefore stopped with (2026-10-10, see
// docs/measurements/2026-10-10_arm2_phone/raw/2026-10-10_103514/flutter_build.txt):
//   Execution failed for task ':tflite_flutter:compileReleaseKotlin'.
//   Inconsistent JVM-target compatibility detected for tasks
//   'compileReleaseJavaWithJavac' (11) and 'compileReleaseKotlin' (21).
// Same failure class as flutter_stripe issue #2486. Fix: align the plugin's
// Kotlin target with its own Java target (11). Scoped to this one module on
// purpose, so Kotlin's consistency check stays active everywhere else. Remove
// once tflite_flutter sets its Kotlin target itself.
// ---------------------------------------------------------------------------
subprojects {
    if (name == "tflite_flutter") {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
