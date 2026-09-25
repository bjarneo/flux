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
private const val OUTPUT_ASPECT = 16f / 9f

/**
 * Draws camera frames into the encoder and into the phone preview. Both
 * targets get the same upright 16:9 frame, so the preview shows what the
 * computer gets. All GL work runs on 1 thread.
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

    private class Target(val surface: EGLSurface, val width: Int, val height: Int, val mirror: Boolean)
    private var preview: Target? = null
    private var encoder: Target? = null

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

    /**
     * Prepares GL and a camera texture of [size]. [onReady] gets the texture
     * that the camera writes to, on the GL thread.
     */
    fun start(size: Size, onReady: (SurfaceTexture) -> Unit) = handler.post {
        try {
            if (context == EGL14.EGL_NO_CONTEXT) setUpEgl()
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
    fun setPreview(texture: SurfaceTexture?, width: Int, height: Int, mirror: Boolean) = runSync {
        preview?.let { destroySurface(it.surface) }
        preview = null
        if (texture != null && context != EGL14.EGL_NO_CONTEXT) {
            preview = Target(createWindow(texture), width, height, mirror)
        }
    }

    /** Sends frames to [surface], or stops when it is null. It waits until done. */
    fun setEncoder(surface: Surface?, width: Int, height: Int) = runSync {
        encoder?.let { destroySurface(it.surface) }
        encoder = null
        if (surface != null && context != EGL14.EGL_NO_CONTEXT) {
            encoder = Target(createWindow(surface), width, height, mirror = false)
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
        encoder?.let { t ->
            draw(t, FrameGeometry.matrix(rotation, contentAspect, OUTPUT_ASPECT, t.mirror))
            EGLExt.eglPresentationTimeANDROID(display, t.surface, st.timestamp)
            EGL14.eglSwapBuffers(display, t.surface)
        }
        preview?.let { t ->
            draw(t, FrameGeometry.matrix(rotation, contentAspect, OUTPUT_ASPECT, t.mirror))
            EGL14.eglSwapBuffers(display, t.surface)
        }
    }

    private fun draw(t: Target, crop: FloatArray) {
        makeCurrent(t.surface)
        GLES20.glViewport(0, 0, t.width, t.height)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTex"), 1, false, texMatrix, 0)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uCrop"), 1, false, crop, 0)
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
        const val FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES sTex;
            varying vec2 vUv;
            void main() {
                gl_FragColor = texture2D(sTex, vUv);
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
