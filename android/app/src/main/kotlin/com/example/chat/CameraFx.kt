package com.example.chat

import android.graphics.Rect
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import org.webrtc.YuvHelper
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * Edits each camera frame before it is sent: brightness, black and white, and
 * covering faces. Frames arrive as I420, where Y is the light and U/V the color,
 * so brightness only touches Y and draining color only touches U and V.
 */
object CameraFx : LocalVideoTrack.ExternalVideoFrameProcessing {
    private const val DETECT_EVERY_MS = 150L

    /** Faces move and a detection can miss one, so a lost face stays covered this long. */
    private const val KEEP_FACE_MS = 1000L
    private const val MOSAIC_BLOCKS = 7

    @Volatile var brightness = 0f
    @Volatile var gray = 0f
    @Volatile var blurFaces = false
        set(value) {
            field = value
            if (!value) faces = emptyList()
        }

    @Volatile private var faces: List<Rect> = emptyList()
    @Volatile private var facesAt = 0L
    private val detecting = AtomicBoolean(false)
    private var lastDetect = 0L
    private var lutFor = 0f
    private val lut = ByteArray(256) { it.toByte() }

    private val detector by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setMinFaceSize(0.08f)
                .build(),
        )
    }

    override fun onFrame(frame: VideoFrame): VideoFrame {
        val b = brightness
        val g = gray
        val blur = blurFaces
        if (b == 0f && g == 0f && !blur) return frame
        return try {
            process(frame, b, g, blur)
        } catch (_: Throwable) {
            frame // a call with the plain picture beats a call that dies
        }
    }

    private fun process(frame: VideoFrame, b: Float, g: Float, blur: Boolean): VideoFrame {
        val src = frame.buffer.toI420() ?: return frame
        val w = src.width
        val h = src.height
        val out = JavaI420Buffer.allocate(w, h)
        YuvHelper.I420Copy(
            src.dataY, src.strideY, src.dataU, src.strideU, src.dataV, src.strideV,
            out.dataY, out.strideY, out.dataU, out.strideU, out.dataV, out.strideV,
            w, h,
        )
        src.release()

        val y = ByteArray(out.strideY * h)
        out.dataY.get(y)
        val chromaH = (h + 1) / 2
        val u = ByteArray(out.strideU * chromaH)
        val v = ByteArray(out.strideV * chromaH)
        out.dataU.get(u)
        out.dataV.get(v)

        // Looks for faces in the untouched picture, whatever the other settings do to it.
        if (blur) detect(y, w, h, out.strideY, frame.rotation)
        if (b != 0f) brighten(y, b)
        if (g != 0f) {
            drain(u, g)
            drain(v, g)
        }
        if (blur) {
            for (r in faces) {
                mosaic(y, out.strideY, w, h, r.left, r.top, r.right, r.bottom)
                mosaic(u, out.strideU, (w + 1) / 2, chromaH, r.left / 2, r.top / 2, r.right / 2, r.bottom / 2)
                mosaic(v, out.strideV, (w + 1) / 2, chromaH, r.left / 2, r.top / 2, r.right / 2, r.bottom / 2)
            }
        }

        write(out.dataY, y)
        write(out.dataU, u)
        write(out.dataV, v)
        return VideoFrame(out, frame.rotation, frame.timestampNs)
    }

    private fun write(to: ByteBuffer, data: ByteArray) {
        to.position(0)
        to.put(data)
    }

    private fun brighten(y: ByteArray, b: Float) {
        if (b != lutFor) {
            val shift = (b * 110).toInt()
            for (i in 0..255) lut[i] = (i + shift).coerceIn(0, 255).toByte()
            lutFor = b
        }
        for (i in y.indices) y[i] = lut[y[i].toInt() and 0xFF]
    }

    private fun drain(plane: ByteArray, g: Float) {
        val keep = ((1 - g) * 256).toInt()
        for (i in plane.indices) {
            plane[i] = (128 + (((plane[i].toInt() and 0xFF) - 128) * keep shr 8)).toByte()
        }
    }

    private fun detect(y: ByteArray, w: Int, h: Int, stride: Int, rotation: Int) {
        val now = System.currentTimeMillis()
        if (now - lastDetect < DETECT_EVERY_MS || !detecting.compareAndSet(false, true)) return
        lastDetect = now
        // Half size is plenty to find a face. ML Kit wants NV21; it only needs the light.
        val dw = (w / 2) and 1.inv()
        val dh = (h / 2) and 1.inv()
        val nv21 = ByteArray(dw * dh * 3 / 2)
        for (row in 0 until dh) {
            for (col in 0 until dw) nv21[row * dw + col] = y[row * 2 * stride + col * 2]
        }
        nv21.fill(128.toByte(), dw * dh, nv21.size)
        detector.process(InputImage.fromByteArray(nv21, dw, dh, rotation, InputImage.IMAGE_FORMAT_NV21))
            .addOnSuccessListener { found ->
                val time = System.currentTimeMillis()
                if (found.isNotEmpty()) {
                    faces = found.map { toFrame(it.boundingBox, dw, dh, rotation, w, h) }
                    facesAt = time
                } else if (time - facesAt > KEEP_FACE_MS) {
                    faces = emptyList()
                }
            }
            .addOnCompleteListener { detecting.set(false) }
    }

    /** From the upright picture ML Kit looked at back to the frame, a bit bigger than the face. */
    private fun toFrame(box: Rect, dw: Int, dh: Int, rotation: Int, w: Int, h: Int): Rect {
        val r = when (rotation) {
            90 -> Rect(box.top, dh - box.right, box.bottom, dh - box.left)
            180 -> Rect(dw - box.right, dh - box.bottom, dw - box.left, dh - box.top)
            270 -> Rect(dw - box.bottom, box.left, dw - box.top, box.right)
            else -> Rect(box)
        }
        val padX = r.width() * 3 / 10
        val padY = r.height() * 3 / 10
        return Rect(
            ((r.left - padX) * 2).coerceIn(0, w),
            ((r.top - padY) * 2).coerceIn(0, h),
            ((r.right + padX) * 2).coerceIn(0, w),
            ((r.bottom + padY) * 2).coerceIn(0, h),
        )
    }

    private fun mosaic(p: ByteArray, stride: Int, w: Int, h: Int, left: Int, top: Int, right: Int, bottom: Int) {
        val r = right.coerceAtMost(w)
        val b = bottom.coerceAtMost(h)
        val block = max(max(r - left, b - top) / MOSAIC_BLOCKS, 4)
        var y0 = top
        while (y0 < b) {
            val y1 = (y0 + block).coerceAtMost(b)
            var x0 = left
            while (x0 < r) {
                val x1 = (x0 + block).coerceAtMost(r)
                var sum = 0
                for (yy in y0 until y1) for (xx in x0 until x1) sum += p[yy * stride + xx].toInt() and 0xFF
                val count = (y1 - y0) * (x1 - x0)
                if (count > 0) {
                    val avg = (sum / count).toByte()
                    for (yy in y0 until y1) for (xx in x0 until x1) p[yy * stride + xx] = avg
                }
                x0 = x1
            }
            y0 = y1
        }
    }
}
