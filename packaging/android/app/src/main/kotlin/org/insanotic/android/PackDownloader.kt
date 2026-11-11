// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import android.os.StatFs
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicIntegerArray
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.CRC32
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream
import java.util.zip.ZipException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class NoSpace(val needed: Long, val available: Long) : IOException("not enough free storage")

interface DownloadListener {
	/** bytes fetched so far and in total for this run */
	fun onProgress(done: Long, total: Long)

	/** a new pack is about to be fetched */
	fun onFile(name: String, index: Int, count: Int)

	/** a pack is complete and its checksum is being computed */
	fun onVerify(name: String)
}

/**
 * Fetches the Xonotic 0.8.6 data packs out of the official release zip. The
 * zip itself is never stored: its central directory is read with HTTP Range
 * requests and each pack is streamed from its byte range straight into its
 * final file, then checked against the CRC32 in the directory. Music is
 * optional.
 *
 * A pack that the zip stores uncompressed (the big ones) is cut into chunks
 * that [CONNECTIONS] connections fetch at once, writing at the chunk's own
 * offset. How far each chunk got is saved next to the .part file, so any
 * restart, of the app or of the whole process, continues from the bytes
 * already on disk. A deflated pack (the small fonts) is inflated as one
 * stream and starts over after an interruption.
 */
class PackDownloader(
	private val dataDir: File,
	private val withMusic: Boolean,
	private val listener: DownloadListener,
	private val url: String = GameData.RELEASE_URL,
	private val assetsUrl: String = GameData.ASSETS_URL,
	private val useRepacked: Boolean = true,
) {
	private val done = AtomicLong()

	/** Throws [NoSpace] when the packs will not fit; cancel the calling coroutine to stop. */
	suspend fun run() = withContext(Dispatchers.IO) {
		val all = repacked() ?: withRetries { RemoteZip.readCentralDirectory(url) }
		val todo = ArrayList<ZipItem>()
		var diskNeeded = 0L
		var toFetch = 0L
		var have = 0L
		for (e in all) {
			if (!wanted(e.name, withMusic))
				continue
			if (finished(e))
				continue // finished by an earlier run
			val resumable = if (e.method == 0) ChunkState.load(stateFile(e), partFile(e), e.csize).total() else 0L
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
		done.set(have)
		coroutineScope {
			val ticker = launch {
				while (true) {
					listener.onProgress(done.get(), toFetch)
					delay(250)
				}
			}
			todo.forEachIndexed { i, e ->
				listener.onFile(e.fileName, i + 1, todo.size)
				val base = done.get() - resumableBytes(e)
				withRetries {
					// what an attempt fetched before failing is on disk (stored) or lost (deflated)
					done.set(base + resumableBytes(e))
					fetchEntry(e)
				}
			}
			ticker.cancel()
			listener.onProgress(done.get(), toFetch)
		}
	}

	private fun urlOf(e: ZipItem): String = e.url ?: url

	/**
	 * The Android pack set from the Insanotic release (zstd entries, Opus
	 * sound, ASTC textures: a smaller download, and less to decode and hold
	 * in memory), when the device can use it and the release is reachable;
	 * null means the official packs. The manifest has one line per pack:
	 * asset name, size, CRC32 in hex, and the name to install it under.
	 */
	private suspend fun repacked(): List<ZipItem>? {
		if (!useRepacked || !AstcSupport.available())
			return null
		return try {
			RemoteZip.fetchText("$assetsUrl/manifest-android.txt").lineSequence()
				.map { it.trim().split(' ') }
				.filter { it.size == 4 }
				.map { (asset, size, crc, name) ->
					ZipItem("data/$name", 0, crc.toLong(16), size.toLong(), size.toLong(), 0, "$assetsUrl/$asset")
				}.toList().ifEmpty { null }
		} catch (e: IOException) {
			null // not published (yet) or no connection to GitHub: the official packs
		}
	}

	private fun partFile(e: ZipItem) = File(dataDir, e.fileName + ".part")
	private fun stateFile(e: ZipItem) = File(dataDir, e.fileName + ".part.state")
	// a repacked pack is not the size of the official one, and a pack the player
	// already has (the official one, say) is never replaced
	private fun finished(e: ZipItem): Boolean =
		File(dataDir, e.fileName).let { it.isFile && (e.url != null || it.length() == e.usize) }

	private fun resumableBytes(e: ZipItem): Long =
		if (e.method == 0) ChunkState.load(stateFile(e), partFile(e), e.csize).total() else 0L

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

	private suspend fun fetchEntry(e: ZipItem) {
		when (e.method) {
			0 -> fetchStored(e)
			8 -> fetchDeflated(e)
			else -> throw ZipException("unsupported compression method ${e.method} for ${e.name}")
		}
	}

	// ----------------------------------------------------------------- stored

	private suspend fun fetchStored(e: ZipItem) {
		val part = partFile(e)
		val state = ChunkState.load(stateFile(e), part, e.csize)
		val start = RemoteZip.dataStart(urlOf(e), e)
		val todo = AtomicInteger(0)
		RandomAccessFile(part, "rw").use { file ->
			val channel = file.channel
			try {
				coroutineScope {
					val saver = launch {
						while (true) {
							delay(1000)
							state.save()
						}
					}
					val workers = (0 until minOf(CONNECTIONS, state.chunks)).map {
						launch {
							while (true) {
								val i = todo.getAndIncrement()
								if (i >= state.chunks)
									break
								fetchChunk(e, start, state, i, channel)
							}
						}
					}
					workers.forEach { it.join() }
					saver.cancel()
				}
			} finally {
				state.save() // also when cancelled: this is what a restart resumes from
			}
		}
		listener.onVerify(e.fileName)
		verifyAndPublish(e, part)
	}

	/** Fetches chunk i of a stored entry, from wherever an earlier run left off. */
	private suspend fun fetchChunk(e: ZipItem, start: Long, state: ChunkState, i: Int, channel: java.nio.channels.FileChannel) {
		val chunkStart = i.toLong() * ChunkState.CHUNK
		val size = state.sizeOf(i)
		var failures = 0
		val buf = ByteArray(64 * 1024)
		while (state.pos(i) < size) {
			coroutineContext.ensureActive()
			val from = chunkStart + state.pos(i)
			try {
				val c = RemoteZip.open(urlOf(e), "bytes=${start + from}-${start + chunkStart + size - 1}")
				try {
					coroutineScope {
						// reads block, so cancelling means closing the connection
						val hook = launch {
							try {
								awaitCancellation()
							} finally {
								c.disconnect()
							}
						}
						try {
							if (c.responseCode != 206)
								throw IOException("HTTP ${c.responseCode} for ${e.fileName}")
							c.inputStream.use { input ->
								while (state.pos(i) < size) {
									val n = input.read(buf, 0, minOf(buf.size.toLong(), size - state.pos(i)).toInt())
									if (n < 0)
										throw IOException("connection closed early")
									val bb = ByteBuffer.wrap(buf, 0, n)
									var at = chunkStart + state.pos(i)
									while (bb.hasRemaining())
										at += channel.write(bb, at)
									state.advance(i, n)
									done.addAndGet(n.toLong())
									failures = 0
								}
							}
						} finally {
							hook.cancel()
						}
					}
				} finally {
					c.disconnect()
				}
			} catch (ex: IOException) {
				coroutineContext.ensureActive()
				if (++failures >= 8)
					throw ex
				delay(1000L * failures)
			}
		}
	}

	private suspend fun verifyAndPublish(e: ZipItem, part: File) {
		val crc = CRC32()
		FileInputStream(part).use { input ->
			val buf = ByteArray(256 * 1024)
			while (true) {
				coroutineContext.ensureActive()
				val n = input.read(buf)
				if (n <= 0) break
				crc.update(buf, 0, n)
			}
		}
		if (part.length() != e.usize || crc.value != e.crc) {
			part.delete()
			stateFile(e).delete()
			throw IOException("damaged download of ${e.fileName}")
		}
		publish(e, part)
		stateFile(e).delete()
	}

	// ---------------------------------------------------------------- deflated

	private suspend fun fetchDeflated(e: ZipItem) {
		val part = partFile(e)
		part.delete()
		val start = RemoteZip.dataStart(urlOf(e), e)
		val crc = CRC32()
		val c = RemoteZip.open(urlOf(e), "bytes=$start-${start + e.csize - 1}")
		try {
			if (c.responseCode != 206)
				throw IOException("HTTP ${c.responseCode} for ${e.fileName}")
			val raw = object : java.io.FilterInputStream(c.inputStream) {
				override fun read(b: ByteArray, off: Int, len: Int): Int {
					val n = super.read(b, off, len)
					if (n > 0)
						done.addAndGet(n.toLong())
					return n
				}
			}
			FileOutputStream(part).use { out ->
				val buf = ByteArray(64 * 1024)
				val src = InflaterInputStream(raw, Inflater(true))
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
		if (part.length() != e.usize || crc.value != e.crc) {
			part.delete()
			throw IOException("damaged download of ${e.fileName}")
		}
		publish(e, part)
	}

	private fun publish(e: ZipItem, part: File) {
		val dest = File(dataDir, e.fileName)
		dest.delete()
		if (!part.renameTo(dest))
			throw IOException("cannot create $dest")
	}

	companion object {
		/** parallel connections for one pack */
		const val CONNECTIONS = 6

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

/**
 * How many bytes of each fixed-size chunk of a stored entry are on disk,
 * saved beside the .part file. A state that does not fit the part file (or
 * none) means starting the entry over.
 */
class ChunkState private constructor(private val file: File, private val csize: Long, private val done: AtomicIntegerArray) {
	val chunks: Int get() = done.length()

	fun pos(i: Int): Long = done.get(i).toLong()

	fun sizeOf(i: Int): Long = minOf(CHUNK, csize - i * CHUNK)

	fun advance(i: Int, n: Int) {
		done.addAndGet(i, n)
	}

	fun total(): Long = (0 until chunks).sumOf { pos(it) }

	@Synchronized
	fun save() {
		val tmp = File(file.path + ".tmp")
		DataOutputStream(FileOutputStream(tmp)).use { out ->
			out.writeInt(MAGIC)
			out.writeLong(csize)
			out.writeInt(chunks)
			for (i in 0 until chunks)
				out.writeInt(done.get(i))
		}
		tmp.renameTo(file)
	}

	companion object {
		const val CHUNK = 8L * 1024 * 1024
		private const val MAGIC = 0x4e53434b

		fun load(file: File, part: File, csize: Long): ChunkState {
			val count = ((csize + CHUNK - 1) / CHUNK).toInt().coerceAtLeast(1)
			val fresh = ChunkState(file, csize, AtomicIntegerArray(count))
			if (!part.isFile || !file.isFile) {
				part.delete()
				file.delete()
				return fresh
			}
			try {
				DataInputStream(FileInputStream(file)).use { input ->
					if (input.readInt() != MAGIC || input.readLong() != csize || input.readInt() != count)
						throw IOException("state does not match")
					val loaded = ChunkState(file, csize, AtomicIntegerArray(count))
					for (i in 0 until count) {
						val p = input.readInt()
						if (p < 0 || p > loaded.sizeOf(i))
							throw IOException("bad position")
						loaded.done.set(i, p)
					}
					return loaded
				}
			} catch (e: IOException) {
				part.delete()
				file.delete()
				return fresh
			}
		}
	}
}
