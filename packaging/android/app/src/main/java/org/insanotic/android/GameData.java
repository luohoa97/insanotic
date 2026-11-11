// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.os.StatFs;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.List;
import java.util.zip.ZipException;

/**
 * Where the game files live and how they get there.
 *
 * The APK carries only Insanotic's own files (compiled QC, Lua mods, cfgs) as
 * one pk3. The Xonotic 0.8.6 data packs (about 950 MB) come from the official
 * release zip, but the zip itself is never stored: its central directory is
 * read with HTTP Range requests and each pk3 is streamed from its byte range
 * straight into its final file (inflating on the way if the zip deflated it,
 * and checking the CRC32 against the central directory). That keeps the free
 * space needed close to the size of the packs. Music is optional.
 *
 * Fetching the packs on first run follows the idea of dixonSolutions/
 * Xonotic-Touch's Android port; this is an independent implementation.
 */
final class GameData {
	static final String RELEASE_URL = "https://dl.xonotic.org/xonotic-0.8.6.zip";
	/** the pk3 inside the APK assets; named to sort after every official pack so it wins */
	static final String OWN_PK3 = "zzz-insanotic-android.pk3";

	private static final String PACKS_MARKER = ".xonotic-0.8.6-packs";
	private static final String MUSIC_MARKER = ".xonotic-0.8.6-music";
	private static final String OWN_MARKER = ".insanotic-pk3-stamp";
	/** room for the .part file's directory entry, filesystem overhead and the own pk3 */
	private static final long SLACK_BYTES = 50L * 1024 * 1024;

	interface Progress {
		/** bytes fetched so far and in total for this run; total is never unknown */
		void onDownload(long done, long total);
		/** a new pack is about to be fetched */
		void onFile(String name, int index, int count);
		void onInstall();
	}

	static final class Cancelled extends IOException {
		Cancelled() {
			super("cancelled");
		}
	}

	private GameData() {
	}

	/** -basedir: large data goes to the app's external files dir (no permission needed). */
	static File baseDir(Context ctx) {
		File ext = ctx.getExternalFilesDir(null);
		File base = new File(ext != null ? ext : ctx.getFilesDir(), "xonotic");
		base.mkdirs();
		return base;
	}

	/** -userdir: configs, saves, downloads; private storage. */
	static File userDir(Context ctx) {
		File user = new File(ctx.getFilesDir(), "userdir");
		user.mkdirs();
		return user;
	}

	private static File dataDir(Context ctx) {
		File d = new File(baseDir(ctx), "data");
		d.mkdirs();
		return d;
	}

	static boolean packsInstalled(Context ctx) {
		return new File(dataDir(ctx), PACKS_MARKER).isFile();
	}

	/** True when the packs and this build's own pk3 are both in place. */
	static boolean isReady(Context ctx) {
		return packsInstalled(ctx) && ownPk3Current(ctx);
	}

	private static String stamp(Context ctx) throws IOException {
		try {
			PackageInfo pi = ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0);
			return pi.versionName + "/" + pi.lastUpdateTime;
		} catch (Exception e) {
			throw new IOException(e);
		}
	}

	private static boolean ownPk3Current(Context ctx) {
		File marker = new File(dataDir(ctx), OWN_MARKER);
		File pk3 = new File(dataDir(ctx), OWN_PK3);
		try {
			return marker.isFile() && pk3.isFile() && readText(marker).equals(stamp(ctx));
		} catch (IOException e) {
			return false;
		}
	}

	/**
	 * Makes everything the game needs present. Blocking; call from a worker thread.
	 *
	 * @param withMusic also fetch the music pack (only looked at while the packs are missing)
	 */
	static void prepare(Context ctx, Progress progress, AtomicBoolean cancel, boolean withMusic) throws IOException {
		File data = dataDir(ctx);
		if (!packsInstalled(ctx)) {
			fetchPacks(data, progress, cancel, withMusic);
			writeText(new File(data, PACKS_MARKER), "xonotic-0.8.6\n");
			if (withMusic)
				writeText(new File(data, MUSIC_MARKER), "xonotic-0.8.6\n");
		}
		if (!ownPk3Current(ctx)) {
			progress.onInstall();
			installOwnPk3(ctx, data);
		}
	}

	static final class NoSpace extends IOException {
		final long needed, available;

		NoSpace(long needed, long available) {
			super("not enough free storage");
			this.needed = needed;
			this.available = available;
		}
	}

	private static void installOwnPk3(Context ctx, File data) throws IOException {
		File tmp = new File(data, OWN_PK3 + ".part");
		try (InputStream in = ctx.getAssets().open(OWN_PK3); OutputStream out = new FileOutputStream(tmp)) {
			copy(in, out);
		}
		File dst = new File(data, OWN_PK3);
		dst.delete();
		if (!tmp.renameTo(dst))
			throw new IOException("cannot install " + OWN_PK3);
		writeText(new File(data, OWN_MARKER), stamp(ctx));
	}

	// ------------------------------------------------------- remote zip access

	/** One file in the release zip's central directory. */
	static final class Entry {
		String name;
		int method;
		long crc, csize, usize, offset;

		String fileName() {
			return name.substring(name.lastIndexOf('/') + 1);
		}
	}

	/** Bytes fetched in this run, shared by every entry so progress is one bar. */
	private static final class Tally {
		long done, total, last;
		final Progress progress;

		Tally(Progress progress) {
			this.progress = progress;
		}

		void add(long n, boolean force) {
			done += n;
			long now = System.nanoTime();
			if (force || now - last > 200_000_000L) {
				last = now;
				progress.onDownload(done, total);
			}
		}
	}

	/** The pk3s to fetch: everything in data/ except the optional music and the compatibility packs. */
	static boolean wanted(String entry, boolean withMusic) {
		if (!isDataPk3(entry))
			return false;
		String n = entry.substring(entry.lastIndexOf('/') + 1);
		if (n.contains("music"))
			return withMusic;
		return !(n.contains("nexcompat") || n.contains("xoncompat"));
	}

	/** "Xonotic/data/xonotic-20230620-data.pk3" and "data/foo.pk3" match; nested dirs do not. */
	static boolean isDataPk3(String entry) {
		if (!entry.endsWith(".pk3"))
			return false;
		String[] parts = entry.split("/");
		return (parts.length == 2 || parts.length == 3) && parts[parts.length - 2].equals("data");
	}

	private static void fetchPacks(File data, Progress progress, AtomicBoolean cancel, boolean withMusic) throws IOException {
		List<Entry> all = withRetries(cancel, () -> readCentralDirectory(RELEASE_URL));
		List<Entry> todo = new ArrayList<>();
		long diskNeeded = 0, toFetch = 0, have = 0;
		for (Entry e : all) {
			if (!wanted(e.name, withMusic))
				continue;
			File out = new File(data, e.fileName());
			if (out.isFile() && out.length() == e.usize)
				continue; // finished by an earlier run
			File part = new File(data, e.fileName() + ".part");
			long resumable = e.method == 0 && part.isFile() ? Math.min(part.length(), e.csize) : 0;
			todo.add(e);
			diskNeeded += e.usize - resumable;
			toFetch += e.csize;
			have += resumable;
		}
		if (!todo.isEmpty()) {
			long needed = diskNeeded + SLACK_BYTES;
			long free = new StatFs(data.getPath()).getAvailableBytes();
			if (free < needed)
				throw new NoSpace(needed, free);
		}
		Tally tally = new Tally(progress);
		tally.total = toFetch;
		tally.done = have;
		int i = 0;
		for (Entry e : todo) {
			progress.onFile(e.fileName(), ++i, todo.size());
			final long base = tally.done;
			final File dest = new File(data, e.fileName());
			withRetries(cancel, () -> {
				tally.done = base; // an attempt that failed half way is counted again
				fetchEntry(RELEASE_URL, e, dest, tally, cancel);
				return null;
			});
		}
		tally.add(0, true);
	}

	private interface Attempt<T> {
		T run() throws IOException;
	}

	/** Runs a network step, trying again after a pause when the connection drops. */
	private static <T> T withRetries(AtomicBoolean cancel, Attempt<T> step) throws IOException {
		for (int attempt = 1; ; attempt++) {
			try {
				return step.run();
			} catch (Cancelled | NoSpace e) {
				throw e;
			} catch (IOException e) {
				if (attempt >= 5)
					throw e;
				for (int ms = 0; ms < 2000 * attempt; ms += 100) {
					if (cancel.get())
						throw new Cancelled();
					try {
						Thread.sleep(100);
					} catch (InterruptedException ie) {
						throw new Cancelled();
					}
				}
			}
		}
	}

	/** Reads the zip's file list from its last bytes; nothing else is downloaded. */
	private static List<Entry> readCentralDirectory(String url) throws IOException {
		// the end-of-central-directory record is within the last 64 KB + 22 bytes
		byte[] tail;
		long length;
		HttpURLConnection c = open(url, "bytes=-65557");
		try {
			if (c.getResponseCode() != 206)
				throw new IOException("the server does not support partial downloads (HTTP " + c.getResponseCode() + ")");
			length = totalFromContentRange(c.getHeaderField("Content-Range"));
			if (length <= 0)
				throw new IOException("no size in Content-Range");
			tail = readAll(c.getInputStream());
		} finally {
			c.disconnect();
		}
		int eocd = -1;
		for (int i = tail.length - 22; i >= 0; i--) {
			if (le32(tail, i) == 0x06054b50L) {
				eocd = i;
				break;
			}
		}
		if (eocd < 0)
			throw new ZipException("not a zip file (no end of central directory)");
		long cdSize = le32(tail, eocd + 12), cdOffset = le32(tail, eocd + 16);
		if (cdSize == 0xFFFFFFFFL || cdOffset == 0xFFFFFFFFL)
			throw new ZipException("zip64 archives are not supported");
		long tailStart = length - tail.length;
		byte[] cd;
		if (cdOffset >= tailStart) {
			cd = new byte[(int) cdSize];
			System.arraycopy(tail, (int) (cdOffset - tailStart), cd, 0, cd.length);
		} else {
			cd = fetchRange(url, cdOffset, cdOffset + cdSize - 1);
		}
		List<Entry> out = new ArrayList<>();
		int p = 0;
		while (p + 46 <= cd.length && le32(cd, p) == 0x02014b50L) {
			Entry e = new Entry();
			e.method = le16(cd, p + 10);
			e.crc = le32(cd, p + 16);
			e.csize = le32(cd, p + 20);
			e.usize = le32(cd, p + 24);
			int n = le16(cd, p + 28), x = le16(cd, p + 30), k = le16(cd, p + 32);
			e.offset = le32(cd, p + 42);
			e.name = new String(cd, p + 46, n, java.nio.charset.StandardCharsets.UTF_8);
			out.add(e);
			p += 46 + n + x + k;
		}
		if (out.isEmpty())
			throw new ZipException("empty central directory");
		return out;
	}

	/**
	 * Fetches one entry into dest through dest + ".part". A stored entry
	 * resumes from what the part file already holds; a deflated one starts
	 * over, because its inflater state cannot be rebuilt.
	 */
	private static void fetchEntry(String url, Entry e, File dest, Tally tally, AtomicBoolean cancel) throws IOException {
		if (e.method != 0 && e.method != 8)
			throw new ZipException("unsupported compression method " + e.method + " for " + e.name);
		File part = new File(dest.getPath() + ".part");
		java.util.zip.CRC32 crc = new java.util.zip.CRC32();
		long have = 0;
		if (e.method == 0 && part.isFile() && part.length() <= e.csize) {
			try (InputStream in = new FileInputStream(part)) {
				byte[] buf = new byte[64 * 1024];
				int n;
				while ((n = in.read(buf)) > 0) {
					crc.update(buf, 0, n);
					have += n;
				}
			}
		} else {
			part.delete();
		}
		tally.add(have, false);

		if (have < e.csize || e.method != 0) {
			// the local header repeats the name and has its own extra field, so
			// the data starts after however long those are
			byte[] lh = fetchRange(url, e.offset, e.offset + 29);
			if (le32(lh, 0) != 0x04034b50L)
				throw new ZipException("bad local header for " + e.name);
			long dataStart = e.offset + 30 + le16(lh, 26) + le16(lh, 28);
			HttpURLConnection c = open(url, "bytes=" + (dataStart + have) + "-" + (dataStart + e.csize - 1));
			try {
				if (c.getResponseCode() != 206)
					throw new IOException("HTTP " + c.getResponseCode() + " for " + e.fileName());
				InputStream raw = new CountingStream(c.getInputStream(), tally, cancel);
				InputStream src = e.method == 0 ? raw : new java.util.zip.InflaterInputStream(raw, new java.util.zip.Inflater(true));
				try (OutputStream out = new FileOutputStream(part, e.method == 0 && have > 0)) {
					byte[] buf = new byte[64 * 1024];
					int n;
					while ((n = src.read(buf)) > 0) {
						out.write(buf, 0, n);
						crc.update(buf, 0, n);
					}
				}
			} finally {
				c.disconnect();
			}
		}
		if (part.length() != e.usize || crc.getValue() != e.crc) {
			part.delete();
			throw new IOException("damaged download of " + e.fileName());
		}
		dest.delete();
		if (!part.renameTo(dest))
			throw new IOException("cannot create " + dest);
	}

	/** Counts the bytes that come off the network, and stops when cancelled. */
	private static final class CountingStream extends java.io.FilterInputStream {
		private final Tally tally;
		private final AtomicBoolean cancel;

		CountingStream(InputStream in, Tally tally, AtomicBoolean cancel) {
			super(in);
			this.tally = tally;
			this.cancel = cancel;
		}

		@Override
		public int read() throws IOException {
			byte[] one = new byte[1];
			return read(one, 0, 1) < 0 ? -1 : one[0] & 0xff;
		}

		@Override
		public int read(byte[] b, int off, int len) throws IOException {
			if (cancel.get())
				throw new Cancelled();
			int n = in.read(b, off, len);
			if (n > 0)
				tally.add(n, false);
			return n;
		}
	}

	private static byte[] fetchRange(String url, long from, long to) throws IOException {
		HttpURLConnection c = open(url, "bytes=" + from + "-" + to);
		try {
			if (c.getResponseCode() != 206)
				throw new IOException("HTTP " + c.getResponseCode() + " for a range request");
			byte[] b = readAll(c.getInputStream());
			if (b.length != to - from + 1)
				throw new IOException("short range response");
			return b;
		} finally {
			c.disconnect();
		}
	}

	private static byte[] readAll(InputStream in) throws IOException {
		try (InputStream i = in) {
			java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
			copy(i, bos);
			return bos.toByteArray();
		}
	}

	private static int le16(byte[] b, int o) {
		return (b[o] & 0xff) | (b[o + 1] & 0xff) << 8;
	}

	private static long le32(byte[] b, int o) {
		return (le16(b, o) | (long) le16(b, o + 2) << 16) & 0xFFFFFFFFL;
	}

	private static HttpURLConnection open(String url, String range) throws IOException {
		for (int hops = 0; hops < 6; hops++) {
			HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
			c.setInstanceFollowRedirects(false); // follow by hand so Range survives
			c.setConnectTimeout(20_000);
			c.setReadTimeout(30_000);
			c.setRequestProperty("User-Agent", "Insanotic-Android");
			c.setRequestProperty("Accept-Encoding", "identity");
			c.setRequestProperty("Range", range);
			int code = c.getResponseCode();
			if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
				String loc = c.getHeaderField("Location");
				c.disconnect();
				if (loc == null)
					throw new IOException("redirect without Location");
				url = new URL(new URL(url), loc).toString();
				continue;
			}
			return c;
		}
		throw new IOException("too many redirects");
	}

	private static long totalFromContentRange(String header) {
		// "bytes 0-9/12345"
		if (header == null)
			return -1;
		int slash = header.lastIndexOf('/');
		try {
			return slash < 0 ? -1 : Long.parseLong(header.substring(slash + 1).trim());
		} catch (NumberFormatException e) {
			return -1;
		}
	}

	// ----------------------------------------------------------------- helpers

	private static void copy(InputStream in, OutputStream out) throws IOException {
		byte[] buf = new byte[64 * 1024];
		int n;
		while ((n = in.read(buf)) > 0)
			out.write(buf, 0, n);
	}

	private static String readText(File f) throws IOException {
		try (InputStream in = new FileInputStream(f)) {
			java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
			copy(in, bos);
			return bos.toString("UTF-8");
		}
	}

	private static void writeText(File f, String text) throws IOException {
		try (OutputStream out = new FileOutputStream(f)) {
			out.write(text.getBytes("UTF-8"));
		}
	}
}
