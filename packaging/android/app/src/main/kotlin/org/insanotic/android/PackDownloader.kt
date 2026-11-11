// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.os.StatFs
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.zip.CRC32
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream
import java.util.zip.ZipException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

class NoSpace(val needed: Long, val available: Long) : IOException("not enough free storage")

interface DownloadListener {
	/** bytes fetched so far and in total for this run */
	fun onProgress(done: Long, total: Long)

	/** a new pack is about to be fetched */
	fun onFile(name: String, index: Int, count: Int)
}

/**
 * Fetches the Xonotic 0.8.6 data packs out of the official release zip. The
 * zip itself is never stored: its central directory is read with HTTP Range
 * requests and each pack is streamed from its byte range straight into its
 * final file, inflated on the way if the zip deflated it, and checked against
 * the CRC32 in the directory. Music is optional.
 */
class PackDownloader(
	private val dataDir: File,
	private val withMusic: Boolean,
	private val listener: DownloadListener,
	private val url: String = GameData.RELEASE_URL,
) {
	private var done = 0L
	private var lastReport = 0L

	/** Throws [NoSpace] when the packs will not fit; cancel the calling coroutine to stop. */
	suspend fun run() = withContext(Dispatchers.IO) {
		val all = withRetries { RemoteZip.readCentralDirectory(url) }
		val todo = ArrayList<ZipItem>()
		var diskNeeded = 0L
		var toFetch = 0L
		var have = 0L
		for (e in all) {
			if (!wanted(e.name, withMusic))
				continue
			val out = File(dataDir, e.fileName)
			if (out.isFile && out.length() == e.usize)
				continue // finished by an earlier run
			val part = File(dataDir, e.fileName + ".part")
			val resumable = if (e.method == 0 && part.isFile) minOf(part.length(), e.csize) else 0L
			todo += e
			diskNeeded += e.usize - resumable
			toFetch += e.csize
			have += resumable
		}
		if (todo.isNotEmpty()) {
			val needed = diskNeeded + SLACK_BYTES
			val free = StatFs(dataDir.path).availableBytes
			if (free < needed)
				throw NoSpace(needed, free)
		}
		done = have
		todo.forEachIndexed { i, e ->
			listener.onFile(e.fileName, i + 1, todo.size)
			val base = done
			withRetries {
				done = base // an attempt that failed half way is counted again
				fetchEntry(e, File(dataDir, e.fileName), toFetch)
			}
		}
		listener.onProgress(done, toFetch)
	}

	/** Runs a network step, trying again after a pause when the connection drops. */
	private suspend fun <T> withRetries(step: suspend () -> T): T {
		var attempt = 1
		while (true) {
			try {
				return step()
			} catch (e: IOException) {
				if (e is NoSpace || attempt >= 5)
					throw e
				delay(2000L * attempt)
				attempt++
			}
		}
	}

	/**
	 * Fetches one entry through dest + ".part". A stored entry resumes from
	 * what the part file already holds; a deflated one starts over, because
	 * its inflater state cannot be rebuilt.
	 */
	private suspend fun fetchEntry(e: ZipItem, dest: File, total: Long) {
		if (e.method != 0 && e.method != 8)
			throw ZipException("unsupported compression method ${e.method} for ${e.name}")
		val part = File(dest.path + ".part")
		val crc = CRC32()
		var have = 0L
		if (e.method == 0 && part.isFile && part.length() <= e.csize) {
			FileInputStream(part).use { input ->
				val buf = ByteArray(64 * 1024)
				while (true) {
					val n = input.read(buf)
					if (n <= 0) break
					crc.update(buf, 0, n)
					have += n
				}
			}
		} else {
			part.delete()
		}
		done += have
		report(total, force = true)

		if (have < e.csize || e.method != 0) {
			val start = RemoteZip.dataStart(url, e)
			val c = RemoteZip.open(url, "bytes=${start + have}-${start + e.csize - 1}")
			try {
				if (c.responseCode != 206)
					throw IOException("HTTP ${c.responseCode} for ${e.fileName}")
				val raw = object : java.io.FilterInputStream(c.inputStream) {
					override fun read(b: ByteArray, off: Int, len: Int): Int {
						val n = super.read(b, off, len)
						if (n > 0) {
							done += n
							report(total, force = false)
						}
						return n
					}
				}
				val src = if (e.method == 0) raw else InflaterInputStream(raw, Inflater(true))
				FileOutputStream(part, e.method == 0 && have > 0).use { out ->
					val buf = ByteArray(64 * 1024)
					while (true) {
						coroutineContext.ensureActive()
						val n = src.read(buf)
						if (n <= 0) break
						out.write(buf, 0, n)
						crc.update(buf, 0, n)
					}
				}
			} finally {
				c.disconnect()
			}
		}
		report(total, force = true)
		if (part.length() != e.usize || crc.value != e.crc) {
			part.delete()
			throw IOException("damaged download of ${e.fileName}")
		}
		dest.delete()
		if (!part.renameTo(dest))
			throw IOException("cannot create $dest")
	}

	private fun report(total: Long, force: Boolean) {
		val now = System.nanoTime()
		if (force || now - lastReport > 200_000_000L) {
			lastReport = now
			listener.onProgress(done, total)
		}
	}

	companion object {
		/** room for filesystem overhead and the own pk3 */
		const val SLACK_BYTES = 50L * 1024 * 1024

		/** The pk3s to fetch: everything in data/ except the optional music and the compatibility packs. */
		fun wanted(entry: String, withMusic: Boolean): Boolean {
			if (!isDataPk3(entry))
				return false
			val n = entry.substringAfterLast('/')
			if ("music" in n)
				return withMusic
			return "nexcompat" !in n && "xoncompat" !in n
		}

		/** "Xonotic/data/xonotic-20230620-data.pk3" and "data/foo.pk3" match; nested dirs do not. */
		fun isDataPk3(entry: String): Boolean {
			if (!entry.endsWith(".pk3"))
				return false
			val parts = entry.split('/')
			return (parts.size == 2 || parts.size == 3) && parts[parts.size - 2] == "data"
		}
	}
}
