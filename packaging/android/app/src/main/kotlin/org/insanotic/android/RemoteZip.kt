// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipException

/** One file in a zip's central directory. */
class ZipItem(val name: String, val method: Int, val crc: Long, val csize: Long, val usize: Long, val offset: Long) {
	val fileName: String get() = name.substringAfterLast('/')
}

/** Reads parts of a zip over HTTP with Range requests; nothing is ever stored as a whole. */
object RemoteZip {
	/** url -> where it redirected to, so parallel requests skip the redirect hop. */
	private val resolved = ConcurrentHashMap<String, String>()

	/** Opens url with a Range header (the caller checks the status). */
	fun open(url: String, range: String): HttpURLConnection {
		val cached = resolved[url]
		if (cached != null) {
			try {
				val c = follow(cached, range)
				if (c.responseCode in 200..299)
					return c
				c.disconnect()
			} catch (e: IOException) {
				// the mirror went away: ask the original address again
			}
			resolved.remove(url)
		}
		return follow(url, range, remember = url)
	}

	/** Follows redirects by hand so the Range header survives them. */
	private fun follow(start: String, range: String, remember: String? = null): HttpURLConnection {
		var u = start
		repeat(6) {
			val c = URL(u).openConnection() as HttpURLConnection
			c.instanceFollowRedirects = false
			c.connectTimeout = 20_000
			c.readTimeout = 30_000
			c.setRequestProperty("User-Agent", "Insanotic-Android")
			c.setRequestProperty("Accept-Encoding", "identity")
			c.setRequestProperty("Range", range)
			val code = c.responseCode
			if (code in intArrayOf(301, 302, 303, 307, 308)) {
				val loc = c.getHeaderField("Location")
				c.disconnect()
				u = URL(URL(u), loc ?: throw IOException("redirect without Location")).toString()
			} else {
				if (remember != null && u != remember && code in 200..299)
					resolved[remember] = u
				return c
			}
		}
		throw IOException("too many redirects")
	}

	fun fetchRange(url: String, from: Long, to: Long): ByteArray {
		val c = open(url, "bytes=$from-$to")
		try {
			if (c.responseCode != 206)
				throw IOException("HTTP ${c.responseCode} for a range request")
			val b = c.inputStream.use { it.readBytes() }
			if (b.size.toLong() != to - from + 1)
				throw IOException("short range response")
			return b
		} finally {
			c.disconnect()
		}
	}

	/** Reads the zip's file list from its last bytes. */
	fun readCentralDirectory(url: String): List<ZipItem> {
		// the end-of-central-directory record is within the last 64 KB + 22 bytes
		val c = open(url, "bytes=-65557")
		val tail: ByteArray
		val length: Long
		try {
			if (c.responseCode != 206)
				throw IOException("the server does not support partial downloads (HTTP ${c.responseCode})")
			length = totalFromContentRange(c.getHeaderField("Content-Range"))
			if (length <= 0)
				throw IOException("no size in Content-Range")
			tail = c.inputStream.use { it.readBytes() }
		} finally {
			c.disconnect()
		}
		val eocd = (tail.size - 22 downTo 0).firstOrNull { le32(tail, it) == 0x06054b50L }
			?: throw ZipException("not a zip file (no end of central directory)")
		val cdSize = le32(tail, eocd + 12)
		val cdOffset = le32(tail, eocd + 16)
		if (cdSize == 0xFFFFFFFFL || cdOffset == 0xFFFFFFFFL)
			throw ZipException("zip64 archives are not supported")
		val tailStart = length - tail.size
		val cd = if (cdOffset >= tailStart)
			tail.copyOfRange((cdOffset - tailStart).toInt(), (cdOffset - tailStart + cdSize).toInt())
		else
			fetchRange(url, cdOffset, cdOffset + cdSize - 1)
		val out = ArrayList<ZipItem>()
		var p = 0
		while (p + 46 <= cd.size && le32(cd, p) == 0x02014b50L) {
			val n = le16(cd, p + 28)
			val x = le16(cd, p + 30)
			val k = le16(cd, p + 32)
			out += ZipItem(
				name = String(cd, p + 46, n, Charsets.UTF_8),
				method = le16(cd, p + 10),
				crc = le32(cd, p + 16),
				csize = le32(cd, p + 20),
				usize = le32(cd, p + 24),
				offset = le32(cd, p + 42),
			)
			p += 46 + n + x + k
		}
		if (out.isEmpty())
			throw ZipException("empty central directory")
		return out
	}

	/**
	 * Where an entry's data starts: the local header repeats the name and has
	 * its own extra field, so its length can differ from the directory's.
	 */
	fun dataStart(url: String, e: ZipItem): Long {
		val lh = fetchRange(url, e.offset, e.offset + 29)
		if (le32(lh, 0) != 0x04034b50L)
			throw ZipException("bad local header for ${e.name}")
		return e.offset + 30 + le16(lh, 26) + le16(lh, 28)
	}

	private fun totalFromContentRange(header: String?): Long {
		// "bytes 0-9/12345"
		val slash = header?.lastIndexOf('/') ?: -1
		return if (slash < 0) -1 else header!!.substring(slash + 1).trim().toLongOrNull() ?: -1
	}

	private fun le16(b: ByteArray, o: Int) = (b[o].toInt() and 0xff) or ((b[o + 1].toInt() and 0xff) shl 8)
	private fun le32(b: ByteArray, o: Int) = (le16(b, o).toLong() or (le16(b, o + 2).toLong() shl 16)) and 0xFFFFFFFFL
}
