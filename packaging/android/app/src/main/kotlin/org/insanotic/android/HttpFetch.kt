// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import androidx.annotation.Keep
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * One HTTP or HTTPS download for the engine. libcurl.c has no libcurl on
 * Android and answers the curl calls with this class through JNI instead:
 * Android's own TLS stack checks the certificate against the system's
 * certificate authorities, and nothing has to be bundled.
 *
 * The transfer runs on its own thread and hands chunks over a small queue
 * (the thread waits when the engine is slow to take them); the engine polls
 * with [read] once per frame and never blocks.
 */
@Keep
class HttpFetch(
	private val url: String,
	private val referer: String?,
	private val userAgent: String?,
	private val resumeFrom: Long,
	private val headers: Array<String>,
	private val post: ByteArray?,
) {
	@Volatile var responseCode = 0
	@Volatile var contentLength = -1L
	@Volatile var contentType: String? = null
	@Volatile var error: String? = null
	@Volatile private var finished = false
	@Volatile private var cancelled = false
	private val queue = ArrayBlockingQueue<ByteArray>(16)
	private var pending: ByteArray? = null
	private var pendingAt = 0
	private var thread: Thread? = null

	fun start() {
		thread = Thread({ run() }, "insanotic-http").also {
			it.isDaemon = true
			it.start()
		}
	}

	fun cancel() {
		cancelled = true
		thread?.interrupt()
	}

	/**
	 * Copies what has arrived into [buf]: the number of bytes (0 when there is
	 * nothing yet), -1 when the download has ended well, -2 when it failed
	 * ([error] says how).
	 */
	fun read(buf: ByteArray): Int {
		var chunk = pending
		if (chunk == null) {
			chunk = queue.poll()
			pendingAt = 0
			if (chunk == null)
				return if (!finished) 0 else if (queue.isEmpty()) (if (error != null) -2 else -1) else read(buf)
		}
		val n = minOf(buf.size, chunk.size - pendingAt)
		System.arraycopy(chunk, pendingAt, buf, 0, n)
		pendingAt += n
		pending = if (pendingAt >= chunk.size) null else chunk
		return n
	}

	private fun run() {
		var c: HttpURLConnection? = null
		try {
			c = URL(url).openConnection() as HttpURLConnection
			c.instanceFollowRedirects = true
			c.connectTimeout = 20_000
			c.readTimeout = 45_000
			c.setRequestProperty("Accept-Encoding", "identity")
			if (!userAgent.isNullOrEmpty()) c.setRequestProperty("User-Agent", userAgent)
			if (!referer.isNullOrEmpty()) c.setRequestProperty("Referer", referer)
			if (resumeFrom > 0) c.setRequestProperty("Range", "bytes=$resumeFrom-")
			for (h in headers) {
				val i = h.indexOf(':')
				if (i > 0) c.setRequestProperty(h.substring(0, i).trim(), h.substring(i + 1).trim())
			}
			if (post != null) {
				c.requestMethod = "POST"
				c.doOutput = true
				c.setFixedLengthStreamingMode(post.size)
				c.outputStream.use { it.write(post) }
			}
			val code = c.responseCode
			if (resumeFrom > 0 && code == 200)
				throw IOException("the server ignored the range request")
			contentLength = c.contentLengthLong
			contentType = c.contentType
			responseCode = code
			val body = if (code >= 400) c.errorStream else c.inputStream
			if (body != null) body.use {
				val buf = ByteArray(32 * 1024)
				while (!cancelled) {
					val n = it.read(buf)
					if (n < 0) break
					if (n > 0 && !queue.offer(buf.copyOf(n), 60, TimeUnit.SECONDS))
						throw IOException("the game stopped taking data")
				}
			}
		} catch (e: Exception) {
			if (!cancelled)
				error = e.message ?: e.javaClass.simpleName
		} finally {
			c?.disconnect()
			finished = true
		}
	}
}
