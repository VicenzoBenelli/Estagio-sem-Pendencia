package br.com.estagiosempendencia.estagio_sem_pendencia

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "estagio_sem_pendencia/pdf_renderer"
        private const val EPHEMERAL_DIR_NAME = "esp_pdf_ephemeral"
        private const val DEFAULT_MAX_DIMENSION = 1280
        private const val MIN_ALLOWED_DIMENSION = 480
        private const val MAX_ALLOWED_DIMENSION = 2048

        /**
         * Calcula as dimensões alvo do bitmap preservando a proporção da página
         * e garantindo que nenhuma dimensão ultrapasse [maxDimension] e que não
         * ocorra upscale desnecessário: scale = min(1.0, maxDimension / maiorDimensao).
         */
        fun computeTargetBitmapDimensions(
            widthPt: Int,
            heightPt: Int,
            maxDimension: Int
        ): Pair<Int, Int> {
            val safeW = widthPt.coerceAtLeast(1)
            val safeH = heightPt.coerceAtLeast(1)
            val safeMax = maxDimension.coerceIn(MIN_ALLOWED_DIMENSION, MAX_ALLOWED_DIMENSION)
            val largestDimension = maxOf(safeW, safeH)
            val scale = min(1.0, safeMax.toDouble() / largestDimension.toDouble())
            val targetW = (safeW.toDouble() * scale).toInt().coerceIn(1, safeMax)
            val targetH = (safeH.toDouble() * scale).toInt().coerceIn(1, safeMax)
            return Pair(targetW, targetH)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pdfWorkerExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val renderGeneration = AtomicLong(0L)
    private val ephemeralStorageLock = Any()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val appCacheDir = applicationContext.cacheDir
        pdfWorkerExecutor.execute {
            cleanEphemeralPdfDir(appCacheDir)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call: MethodCall, rawResult: MethodChannel.Result ->
                val safeResult = MainThreadOnceResult(rawResult, mainHandler)
                when (call.method) {
                    "renderPdfDocument" -> handleRenderPdfDocument(call, safeResult)
                    "clearTemporaryPdfs" -> {
                        renderGeneration.incrementAndGet()
                        pdfWorkerExecutor.execute {
                            cleanEphemeralPdfDir(appCacheDir)
                            safeResult.success(true)
                        }
                    }
                    else -> safeResult.notImplemented()
                }
            }
    }

    private fun handleRenderPdfDocument(
        call: MethodCall,
        safeResult: MainThreadOnceResult
    ) {
        val bytes = call.argument<ByteArray>("bytes")
        val maxDimension = (call.argument<Int>("maxDimension") ?: DEFAULT_MAX_DIMENSION)
            .coerceIn(MIN_ALLOWED_DIMENSION, MAX_ALLOWED_DIMENSION)

        if (bytes == null || bytes.size < 5) {
            safeResult.error("INVALID_PDF", "Arquivo PDF vazio ou inválido.", null)
            return
        }

        val hasPdfHeader = bytes[0] == 0x25.toByte() && // %
            bytes[1] == 0x50.toByte() && // P
            bytes[2] == 0x44.toByte() && // D
            bytes[3] == 0x46.toByte() && // F
            bytes[4] == 0x2D.toByte() // -

        if (!hasPdfHeader) {
            safeResult.error("INVALID_PDF_SIGNATURE", "Assinatura %PDF- ausente.", null)
            return
        }

        val currentGeneration = renderGeneration.incrementAndGet()
        val appCacheDir = applicationContext.cacheDir
        val pdfBytesCopy = bytes.copyOf()

        try {
            pdfWorkerExecutor.execute {
                renderPdfOnWorkerThread(
                    bytes = pdfBytesCopy,
                    maxDimension = maxDimension,
                    expectedGeneration = currentGeneration,
                    baseCacheDir = appCacheDir,
                    safeResult = safeResult
                )
            }
        } catch (_: Exception) {
            pdfBytesCopy.fill(0)
            safeResult.error(
                "RENDER_EXECUTOR_UNAVAILABLE",
                "Não foi possível iniciar a renderização do PDF.",
                null
            )
        }
    }

    private fun renderPdfOnWorkerThread(
        bytes: ByteArray,
        maxDimension: Int,
        expectedGeneration: Long,
        baseCacheDir: File,
        safeResult: MainThreadOnceResult
    ) {
        var tempFile: File? = null
        var pfd: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null

        try {
            if (renderGeneration.get() != expectedGeneration) {
                safeResult.error(
                    "RENDER_CANCELLED",
                    "Renderização descartada por troca de documento ou encerramento de sessão.",
                    null
                )
                return
            }

            synchronized(ephemeralStorageLock) {
                val dir = File(baseCacheDir, EPHEMERAL_DIR_NAME)
                if (!dir.exists()) {
                    dir.mkdirs()
                }
                val candidate = File(dir, "pdf_${UUID.randomUUID()}.pdf")
                candidate.writeBytes(bytes)
                tempFile = candidate
            }

            pfd = ParcelFileDescriptor.open(tempFile, ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(pfd)

            val totalPages = renderer.pageCount
            if (totalPages <= 0) {
                safeResult.error(
                    "EMPTY_PDF_PAGES",
                    "O documento PDF não contém páginas renderizáveis.",
                    null
                )
                return
            }

            val renderedPages = ArrayList<Map<String, Any>>(totalPages)
            for (index in 0 until totalPages) {
                if (renderGeneration.get() != expectedGeneration) {
                    safeResult.error(
                        "RENDER_CANCELLED",
                        "Renderização interrompida por troca de documento ou encerramento de sessão.",
                        null
                    )
                    return
                }

                val page = renderer.openPage(index)
                try {
                    val widthPt = page.width.coerceAtLeast(1)
                    val heightPt = page.height.coerceAtLeast(1)
                    val (targetW, targetH) = computeTargetBitmapDimensions(
                        widthPt = widthPt,
                        heightPt = heightPt,
                        maxDimension = maxDimension
                    )

                    val bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                    try {
                        val canvas = Canvas(bitmap)
                        canvas.drawColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)

                        val out = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                        val pngBytes = out.toByteArray()

                        renderedPages.add(
                            mapOf(
                                "pageNumber" to (index + 1),
                                "widthPt" to widthPt,
                                "heightPt" to heightPt,
                                "bitmapWidth" to targetW,
                                "bitmapHeight" to targetH,
                                "pngBytes" to pngBytes
                            )
                        )
                    } finally {
                        bitmap.recycle()
                    }
                } finally {
                    page.close()
                }
            }

            if (renderGeneration.get() != expectedGeneration) {
                safeResult.error(
                    "RENDER_CANCELLED",
                    "Resultado descartado por troca de documento ou encerramento de sessão.",
                    null
                )
                return
            }

            safeResult.success(
                mapOf(
                    "pageCount" to totalPages,
                    "pages" to renderedPages
                )
            )
        } catch (_: SecurityException) {
            safeResult.error(
                "ENCRYPTED_OR_PROTECTED_PDF",
                "O PDF está protegido por senha ou restrito.",
                null
            )
        } catch (_: Exception) {
            safeResult.error(
                "CORRUPTED_PDF",
                "Não foi possível renderizar as páginas do documento PDF.",
                null
            )
        } finally {
            bytes.fill(0)
            try {
                renderer?.close()
            } catch (_: Exception) {
            }
            try {
                pfd?.close()
            } catch (_: Exception) {
            }
            tempFile?.let { file ->
                synchronized(ephemeralStorageLock) {
                    secureDeleteFile(file)
                }
            }
        }
    }

    private fun cleanEphemeralPdfDir(baseCacheDir: File) {
        synchronized(ephemeralStorageLock) {
            val dir = File(baseCacheDir, EPHEMERAL_DIR_NAME)
            if (dir.exists() && dir.isDirectory) {
                dir.listFiles()?.forEach { file ->
                    secureDeleteFile(file)
                }
            }
        }
    }

    private fun secureDeleteFile(file: File) {
        if (!file.exists()) return
        try {
            val len = file.length()
            if (len in 1..(10 * 1024 * 1024)) {
                RandomAccessFile(file, "rws").use { raf ->
                    val zeros = ByteArray(4096)
                    var remaining = len
                    raf.seek(0)
                    while (remaining > 0) {
                        val toWrite = minOf(remaining, zeros.size.toLong()).toInt()
                        raf.write(zeros, 0, toWrite)
                        remaining -= toWrite
                    }
                }
            }
        } catch (_: Exception) {
        } finally {
            try {
                file.delete()
            } catch (_: Exception) {
            }
        }
    }

    override fun onDestroy() {
        renderGeneration.incrementAndGet()
        val appCacheDir = applicationContext.cacheDir
        pdfWorkerExecutor.shutdownNow()
        cleanEphemeralPdfDir(appCacheDir)
        super.onDestroy()
    }

    private class MainThreadOnceResult(
        private val delegate: MethodChannel.Result,
        private val handler: Handler
    ) {
        private val completed = AtomicBoolean(false)

        fun success(value: Any?) {
            if (!completed.compareAndSet(false, true)) return
            postToMain { delegate.success(value) }
        }

        fun error(code: String, message: String?, details: Any?) {
            if (!completed.compareAndSet(false, true)) return
            postToMain { delegate.error(code, message, details) }
        }

        fun notImplemented() {
            if (!completed.compareAndSet(false, true)) return
            postToMain { delegate.notImplemented() }
        }

        private inline fun postToMain(crossinline action: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                action()
            } else {
                handler.post { action() }
            }
        }
    }
}
