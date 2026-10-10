package com.example.conservation_app

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.TensorFlowLite
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Reference configuration of the on-device measurement round (ADR 009):
 * the LiteRT *Java* API with XNNPACK explicitly disabled
 * (`Interpreter.Options.setUseXNNPACK(false)`), one thread, batch 1.
 *
 * Why it exists: tflite_flutter (the binding the app uses) cannot switch off a
 * delegate the runtime may apply by default. This path can, so it yields a
 * guaranteed "no delegate" latency as in Howard et al.'s protocol and
 * cross-checks the tflite_flutter numbers on the same native runtime
 * (both load libtensorflowlite_jni.so from com.google.ai.edge.litert:litert).
 *
 * All interpreter work runs on ONE dedicated thread. Its kernel thread id is
 * returned to Dart, which pins that thread to a CPU core via sched_setaffinity
 * (Java has no affinity API). After every timed run the core the thread last
 * executed on is read from /proc, so the report can prove where it ran.
 */
class LiteRtJavaBench {
    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var worker: Handler? = null
    private var interpreter: Interpreter? = null
    private var modelBuffer: ByteBuffer? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> create(call, result)
            "run" -> run(call, result)
            "close" -> close(result)
            else -> result.notImplemented()
        }
    }

    private fun workerHandler(): Handler {
        worker?.let { return it }
        val t = HandlerThread("litert-java-bench")
        t.start()
        thread = t
        val h = Handler(t.looper)
        worker = h
        return h
    }

    private fun create(call: MethodCall, result: MethodChannel.Result) {
        val model = call.argument<ByteArray>("model")
        val threads = call.argument<Int>("threads") ?: 1
        val useXnnpack = call.argument<Boolean>("useXnnpack") ?: false
        if (model == null) {
            result.error("ARGUMENT", "model bytes missing", null)
            return
        }
        workerHandler().post {
            try {
                releaseInterpreter()
                val buffer = ByteBuffer.allocateDirect(model.size).order(ByteOrder.nativeOrder())
                buffer.put(model)
                buffer.rewind()
                val options = Interpreter.Options()
                    .setNumThreads(threads)
                    .setUseXNNPACK(useXnnpack)
                val started = System.nanoTime()
                val created = Interpreter(buffer, options)
                val createNanos = System.nanoTime() - started
                modelBuffer = buffer // must stay alive as long as the interpreter
                interpreter = created
                val info = hashMapOf<String, Any>(
                    "tid" to Process.myTid(),
                    "runtimeVersion" to runtimeVersion(),
                    "createNanos" to createNanos,
                    "threads" to threads,
                    "useXnnpack" to useXnnpack,
                    "inputShape" to created.getInputTensor(0).shape().toList(),
                    "outputShape" to created.getOutputTensor(0).shape().toList(),
                    "inputBytes" to created.getInputTensor(0).numBytes(),
                    "outputBytes" to created.getOutputTensor(0).numBytes()
                )
                main.post { result.success(info) }
            } catch (e: Throwable) {
                main.post { result.error("CREATE", e.toString(), null) }
            }
        }
    }

    private fun run(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<ByteArray>("input")
        val warmup = call.argument<Int>("warmup") ?: 20
        val runs = call.argument<Int>("runs") ?: 100
        val h = worker
        if (input == null || h == null) {
            result.error("STATE", "call create first and pass input bytes", null)
            return
        }
        h.post {
            val itp = interpreter
            if (itp == null) {
                main.post { result.error("STATE", "no interpreter", null) }
                return@post
            }
            try {
                val inBuf = ByteBuffer.allocateDirect(input.size).order(ByteOrder.nativeOrder())
                inBuf.put(input)
                val outBytes = itp.getOutputTensor(0).numBytes()
                val outBuf = ByteBuffer.allocateDirect(outBytes).order(ByteOrder.nativeOrder())
                repeat(warmup) {
                    inBuf.rewind()
                    outBuf.rewind()
                    itp.run(inBuf, outBuf)
                }
                val tid = Process.myTid()
                val nanos = LongArray(runs)
                val cpus = IntArray(runs)
                for (i in 0 until runs) {
                    inBuf.rewind()
                    outBuf.rewind()
                    itp.run(inBuf, outBuf)
                    // Native Invoke() only: LiteRT brackets the native run with
                    // System.nanoTime() after copying the input in.
                    nanos[i] = itp.lastNativeInferenceDurationNanoseconds ?: -1L
                    cpus[i] = lastCpu(tid)
                }
                outBuf.rewind()
                val logits = FloatArray(outBytes / 4)
                outBuf.asFloatBuffer().get(logits)
                val res = hashMapOf<String, Any>(
                    "tid" to tid,
                    "nativeNanos" to nanos,
                    "cpus" to cpus,
                    "logits" to logits
                )
                main.post { result.success(res) }
            } catch (e: Throwable) {
                main.post { result.error("RUN", e.toString(), null) }
            }
        }
    }

    private fun close(result: MethodChannel.Result) {
        val h = worker
        if (h == null) {
            result.success(null)
            return
        }
        h.post {
            releaseInterpreter()
            main.post { result.success(null) }
        }
    }

    /** Releases everything; called when the activity is destroyed. */
    fun shutdown() {
        val h = worker
        val t = thread
        worker = null
        thread = null
        h?.post { releaseInterpreter() }
        t?.quitSafely()
    }

    private fun releaseInterpreter() {
        interpreter?.close()
        interpreter = null
        modelBuffer = null
    }

    /** Field 39 ("processor") of /proc/self/task/<tid>/stat: last CPU used. */
    private fun lastCpu(tid: Int): Int = try {
        val stat = File("/proc/self/task/$tid/stat").readText()
        val fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ')
        fields[36].trim().toInt() // fields[0] is field 3 ("state")
    } catch (e: Throwable) {
        -1
    }

    private fun runtimeVersion(): String = try {
        TensorFlowLite.runtimeVersion()
    } catch (e: Throwable) {
        "unknown (${e.javaClass.simpleName})"
    }
}
