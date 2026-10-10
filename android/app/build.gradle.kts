plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.conservation_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.conservation_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 rules for LiteRT (missing litert-gpu class; JNI-reached classes), ADR 009.
            proguardFiles("proguard-rules.pro")
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
    // The LiteRT runtime for BOTH bindings: tflite_flutter (FFI, C API) and the
    // Java API used by the "XNNPACK explicitly off" reference configuration
    // (LiteRtJavaBench.kt, ADR 009). tflite_flutter 0.12.1 declares litert and
    // litert-gpu 1.4.0; Gradle resolves each artifact to the highest declared
    // version, so these lines raise the plugin's runtime too - one native
    // runtime for both bindings.
    //
    // 1.4.2, not 1.4.0 (ADR 010): LiteRT 1.4.0's C API builds the interpreter
    // without the model's memory allocation, so weights stored outside the
    // FlatBuffer (buffer offsets - ai-edge-quantizer writes them for every model
    // above 256 KB, the thesis file included) load as empty tensors and the
    // first invoke fails ("Input tensor 87 lacks data", 2026-10-10). Fixed
    // upstream in LiteRT commit d17fd00; 1.4.2 is the first 1.4.x build with
    // the fix (checked in its machine code) and still ships
    // libtensorflowlite_jni.so with every C function tflite_flutter calls.
    // litert-gpu is pinned as well because its 1.4.0 POM requires litert-api
    // [1.4.0] exactly. Remove both lines once tflite_flutter bundles a fixed
    // runtime itself.
    implementation("com.google.ai.edge.litert:litert:1.4.2")
    implementation("com.google.ai.edge.litert:litert-gpu:1.4.2")
}
