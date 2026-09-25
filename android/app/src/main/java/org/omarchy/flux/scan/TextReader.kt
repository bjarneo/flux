package org.omarchy.flux.scan

import android.graphics.Bitmap
import android.graphics.Rect
import androidx.camera.core.ImageAnalysis
import androidx.camera.mlkit.vision.MlKitAnalyzer
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.util.concurrent.Executor

/**
 * Reads text from camera frames and images. The scan screen uses this
 * interface, so the text logic does not depend on ML Kit.
 */
interface TextReader : AutoCloseable {
    /**
     * Returns an analyzer for live camera frames. [onBlocks] gets the blocks
     * in the coordinates of the preview view, on [executor].
     */
    fun liveAnalyzer(executor: Executor, onBlocks: (List<ScanBlock>) -> Unit): ImageAnalysis.Analyzer

    /** Reads the text of a still image that is already upright. */
    fun read(bitmap: Bitmap, onDone: (Result<List<ScanBlock>>) -> Unit)
}

/** The ML Kit Latin text recognizer. The model is in the APK, so it works without a network. */
class MlKitTextReader : TextReader {
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

    override fun liveAnalyzer(executor: Executor, onBlocks: (List<ScanBlock>) -> Unit): ImageAnalysis.Analyzer =
        MlKitAnalyzer(listOf(recognizer), ImageAnalysis.COORDINATE_SYSTEM_VIEW_REFERENCED, executor) { result ->
            onBlocks(result.getValue(recognizer)?.toBlocks() ?: emptyList())
        }

    override fun read(bitmap: Bitmap, onDone: (Result<List<ScanBlock>>) -> Unit) {
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { onDone(Result.success(it.toBlocks())) }
            .addOnFailureListener { onDone(Result.failure(it)) }
    }

    override fun close() = recognizer.close()
}

private fun Rect?.toBox(): Box = if (this == null) Box(0, 0, 0, 0) else Box(left, top, right, bottom)

private fun Text.toBlocks(): List<ScanBlock> = textBlocks.map { block ->
    ScanBlock(block.lines.map { ScanLine(it.text, it.boundingBox.toBox()) }, block.boundingBox.toBox())
}
