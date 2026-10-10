package com.example.conservation_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // LiteRT Java-API reference configuration for the measurement round (ADR 009).
    private val liteRtBench = LiteRtJavaBench()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine) // registers the generated plugins
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LITERT_BENCH_CHANNEL)
            .setMethodCallHandler { call, result -> liteRtBench.handle(call, result) }
    }

    override fun onDestroy() {
        liteRtBench.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val LITERT_BENCH_CHANNEL = "conservation_app/litert_java_bench"
    }
}
