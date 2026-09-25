package org.omarchy.flux.webcam

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private const val TAG = "FluxWebcamGl"
private const val EGL_RECORDABLE_ANDROID = 0x3142

/**
 * Draws camera frames into the encoder and into the phone preview. Both
 * targets get the same upright frame with the same color adjustments, so
 * the preview shows what the computer gets. All GL work runs on 1 thread.
 */
class GlRenderer {
    private val thread = HandlerThread("flux-webcam-gl").apply { start() }
    private val handler = Handler(thread.looper)

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var texture = 0
    private var cameraTexture: SurfaceTexture? = null
    private var cameraSize = Size(1920, 1080)

    private class Target(val surface: EGLSurface, val width: Int, val height: Int)
    private var preview: Target? = null
    private var encoder: Target? = null

    // The preview that the screen gave. The screen can give it before GL is
    // ready, so start() attaches it when GL is ready.
    private var previewTexture: SurfaceTexture? = null
    private var previewWidth = 0
    private var previewHeight = 0

    private val texMatrix = FloatArray(16)
    private val quad: FloatBuffer = floatBuffer(
        // x, y, u, v for a triangle strip over the whole target.
        -1f, -1f, 0f, 0f,
        1f, -1f, 1f, 0f,
        -1f, 1f, 0f, 1f,
        1f, 1f, 1f, 1f,
    )

    /** The device orientation in degrees, from an OrientationEventListener. */
    @Volatile var deviceOrientation = 0
    @Volatile var sensorOrientation = 90
    @Volatile var front = false
    /** An extra clockwise rotation that the user picks, in steps of 90 degrees. */
    @Volatile var extraRotation = 0
    /** The width divided by the height of the output frame. */
    @Volatile var outputAspect = 16f / 9f
    /** Mirrors the output horizontally, for the computer and the preview. */
    @Volatile var mirror = false

    /** The color adjustments: brightness -1..1, contrast 0..2, saturation 0..2, warmth -1..1. */
    data class Color(val brightness: Float = 0f, val contrast: Float = 1f, val saturation: Float = 1f, val warmth: Float = 0f)
    @Volatile var color = Color()

    /**
     * Prepares GL and a camera texture of [size]. [onReady] gets the texture
     * that the camera writes to, on the GL thread.
     */
    fun start(size: Size, onReady: (SurfaceTexture) -> Unit) = handler.post {
        try {
            if (context == EGL14.EGL_NO_CONTEXT) setUpEgl()
            attachPreview()
            cameraSize = size
            val st = cameraTexture ?: SurfaceTexture(texture).also { st ->
                st.setOnFrameAvailableListener({ drawFrame() }, handler)
                cameraTexture = st
            }
            st.setDefaultBufferSize(size.width, size.height)
            onReady(st)
        } catch (e: Exception) {
            Log.w(TAG, "GL start failed", e)
        }
    }

    /** Shows frames on [texture], or stops the preview when it is null. It waits until done. */
    fun setPreview(texture: SurfaceTexture?, width: Int, height: Int) = runSync {
        preview?.let { destroySurface(it.surface) }
        preview = null
        previewTexture = texture
        previewWidth = width
        previewHeight = height
        attachPreview()
    }

    /** Draws into the preview that the screen gave, when GL is ready. */
    private fun attachPreview() {
        val texture = previewTexture ?: return
        if (preview != null || context == EGL14.EGL_NO_CONTEXT) return
        preview = runCatching { Target(createWindow(texture), previewWidth, previewHeight) }
            .onFailure { Log.w(TAG, "preview surface failed", it) }
            .getOrNull()
    }

    /** Sends frames to [surface], or stops when it is null. It waits until done. */
    fun setEncoder(surface: Surface?, width: Int, height: Int) = runSync {
        encoder?.let { destroySurface(it.surface) }
        encoder = null
        if (surface != null && context != EGL14.EGL_NO_CONTEXT) {
            encoder = Target(createWindow(surface), width, height)
        }
    }

    private fun drawFrame() {
        val st = cameraTexture ?: return
        makeCurrent(pbuffer)
        runCatching { st.updateTexImage() }.onFailure { return }
        st.getTransformMatrix(texMatrix)
        val natural = FrameGeometry.swapsAxes(texMatrix)
        val contentAspect = if (natural) cameraSize.height.toFloat() / cameraSize.width else cameraSize.width.toFloat() / cameraSize.height
        val rotation = FrameGeometry.uprightRotation(deviceOrientation, sensorOrientation, front, natural) + extraRotation
        val crop = FrameGeometry.matrix(rotation, contentAspect, outputAspect, mirror)
        val c = color
        encoder?.let { t ->
            draw(t, crop, c)
            EGLExt.eglPresentationTimeANDROID(display, t.surface, st.timestamp)
            EGL14.eglSwapBuffers(display, t.surface)
        }
        preview?.let { t ->
            draw(t, crop, c)
            EGL14.eglSwapBuffers(display, t.surface)
        }
    }

    private fun draw(t: Target, crop: FloatArray, c: Color) {
        makeCurrent(t.surface)
        GLES20.glViewport(0, 0, t.width, t.height)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTex"), 1, false, texMatrix, 0)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uCrop"), 1, false, crop, 0)
        GLES20.glUniform4f(GLES20.glGetUniformLocation(program, "uColor"), c.brightness, c.contrast, c.saturation, c.warmth)
        val pos = GLES20.glGetAttribLocation(program, "aPos")
        val uv = GLES20.glGetAttribLocation(program, "aUv")
        quad.position(0)
        GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(pos)
        quad.position(2)
        GLES20.glVertexAttribPointer(uv, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(uv)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun setUpEgl() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
        val attrs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, attrs, 0, configs, 0, 1, count, 0) && count[0] > 0) { "no EGL config" }
        config = configs[0]
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        pbuffer = EGL14.eglCreatePbufferSurface(display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        makeCurrent(pbuffer)
        program = buildProgram(VERTEX, FRAGMENT)
        val tex = IntArray(1)
        GLES20.glGenTextures(1, tex, 0)
        texture = tex[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    }

    private fun createWindow(window: Any): EGLSurface {
        val s = EGL14.eglCreateWindowSurface(display, config, window, intArrayOf(EGL14.EGL_NONE), 0)
        check(s != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed" }
        return s
    }

    private fun destroySurface(s: EGLSurface) {
        makeCurrent(pbuffer)
        EGL14.eglDestroySurface(display, s)
    }

    private fun makeCurrent(s: EGLSurface) {
        if (display != EGL14.EGL_NO_DISPLAY) EGL14.eglMakeCurrent(display, s, s, context)
    }

    /** Runs [block] on the GL thread and waits up to 2 seconds for it. */
    private fun runSync(block: () -> Unit) {
        if (Thread.currentThread() == thread) return block()
        val done = CountDownLatch(1)
        handler.post {
            try {
                block()
            } catch (e: Exception) {
                Log.w(TAG, "GL task failed", e)
            } finally {
                done.countDown()
            }
        }
        done.await(2, TimeUnit.SECONDS)
    }

    /** Frees GL and stops the thread. */
    fun release() {
        runSync {
            preview?.let { destroySurface(it.surface) }
            encoder?.let { destroySurface(it.surface) }
            preview = null
            previewTexture = null
            encoder = null
            cameraTexture?.release()
            cameraTexture = null
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, pbuffer)
                EGL14.eglDestroyContext(display, context)
                EGL14.eglTerminate(display)
            }
            display = EGL14.EGL_NO_DISPLAY
            context = EGL14.EGL_NO_CONTEXT
        }
        thread.quitSafely()
    }

    private companion object {
        const val VERTEX = """
            uniform mat4 uTex;
            uniform mat4 uCrop;
            attribute vec2 aPos;
            attribute vec2 aUv;
            varying vec2 vUv;
            void main() {
                gl_Position = vec4(aPos, 0.0, 1.0);
                vUv = (uTex * uCrop * vec4(aUv, 0.0, 1.0)).xy;
            }
        """
        // uColor holds brightness, contrast, saturation, and warmth. The
        // neutral values (0, 1, 1, 0) leave the image as it is.
        const val FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES sTex;
            uniform vec4 uColor;
            varying vec2 vUv;
            void main() {
                vec3 c = texture2D(sTex, vUv).rgb;
                c += uColor.x * 0.5;
                c = (c - 0.5) * uColor.y + 0.5;
                float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
                c = mix(vec3(l), c, uColor.z);
                c += vec3(0.08, 0.0, -0.08) * uColor.w;
                gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
            }
        """

        fun floatBuffer(vararg v: Float): FloatBuffer =
            ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(v); position(0) }

        fun buildProgram(vs: String, fs: String): Int {
            fun shader(type: Int, src: String): Int {
                val s = GLES20.glCreateShader(type)
                GLES20.glShaderSource(s, src)
                GLES20.glCompileShader(s)
                val ok = IntArray(1)
                GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
                check(ok[0] != 0) { "shader: " + GLES20.glGetShaderInfoLog(s) }
                return s
            }
            val p = GLES20.glCreateProgram()
            GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vs))
            GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fs))
            GLES20.glLinkProgram(p)
            val ok = IntArray(1)
            GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
            check(ok[0] != 0) { "link: " + GLES20.glGetProgramInfoLog(p) }
            return p
        }
    }
}
