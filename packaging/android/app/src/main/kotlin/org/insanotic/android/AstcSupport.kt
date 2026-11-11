// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.opengl.EGL14
import android.opengl.GLES20

/**
 * Whether the GPU takes ASTC textures: the repacked packs have them instead
 * of the S3TC ones, which phones would have to decode on the CPU. Asked of a
 * throwaway OpenGL ES context, once.
 */
object AstcSupport {
	private var answer: Boolean? = null

	@Synchronized
	fun available(): Boolean = answer ?: query().also { answer = it }

	private fun query(): Boolean {
		val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
		val version = IntArray(2)
		if (display == EGL14.EGL_NO_DISPLAY || !EGL14.eglInitialize(display, version, 0, version, 1))
			return false
		var context = EGL14.EGL_NO_CONTEXT
		var surface = EGL14.EGL_NO_SURFACE
		try {
			val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
			val count = IntArray(1)
			val attribs = intArrayOf(
				EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
				EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
				EGL14.EGL_NONE,
			)
			if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) || count[0] == 0)
				return false
			context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
				intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
			surface = EGL14.eglCreatePbufferSurface(display, configs[0],
				intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
			if (context == EGL14.EGL_NO_CONTEXT || surface == EGL14.EGL_NO_SURFACE
				|| !EGL14.eglMakeCurrent(display, surface, surface, context))
				return false
			return GLES20.glGetString(GLES20.GL_EXTENSIONS)?.contains("GL_KHR_texture_compression_astc_ldr") == true
		} finally {
			EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
			if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
			if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
		}
	}
}
