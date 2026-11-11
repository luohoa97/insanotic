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
import java.util.Enumeration;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipException;
import java.util.zip.ZipFile;

/**
 * Where the game files live and how they get there.
 *
 * The APK carries only Insanotic's own files (compiled QC, Lua mods, cfgs) as
 * one pk3. The Xonotic 0.8.6 data packs (about 1 GB) are downloaded once from
 * the official release zip, resuming a partial download if there is one, and
 * only data/*.pk3 is extracted from it. The idea of fetching the packs on
 * first run follows dixonSolutions/Xonotic-Touch's Android port; this is an
 * independent implementation.
 */
final class GameData {
	static final String RELEASE_URL = "https://dl.xonotic.org/xonotic-0.8.6.zip";
	/** the pk3 inside the APK assets; named to sort after every official pack so it wins */
	static final String OWN_PK3 = "zzz-insanotic-android.pk3";

	private static final String PACKS_MARKER = ".xonotic-0.8.6-packs";
	private static final String OWN_MARKER = ".insanotic-pk3-stamp";
	/** zip + extracted packs + slack; the release zip is a little over 1 GB */
	private static final long REQUIRED_BYTES = 2800L * 1024 * 1024;

	interface Progress {
		/** @param total -1 when unknown */
		void onDownload(long done, long total);
		void onExtract(String name, int index, int count);
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

	/** Makes everything the game needs present. Blocking; call from a worker thread. */
	static void prepare(Context ctx, Progress progress, java.util.concurrent.atomic.AtomicBoolean cancel) throws IOException {
		File data = dataDir(ctx);
		if (!packsInstalled(ctx)) {
			long free = new StatFs(data.getPath()).getAvailableBytes();
			File zip = new File(baseDir(ctx), "xonotic-0.8.6.zip");
			long have = zip.isFile() ? zip.length() : 0;
			if (free + have < REQUIRED_BYTES)
				throw new NoSpace(REQUIRED_BYTES, free + have);
			download(RELEASE_URL, zip, progress, cancel);
			extractPacks(zip, data, progress, cancel);
			writeText(new File(data, PACKS_MARKER), "xonotic-0.8.6\n");
			zip.delete();
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

	// ---------------------------------------------------------------- download

	/** Downloads url to dest, resuming dest + ".part" with an HTTP Range request. */
	private static void download(String url, File dest, Progress progress, java.util.concurrent.atomic.AtomicBoolean cancel) throws IOException {
		if (dest.isFile() && looksComplete(dest))
			return;
		File part = new File(dest.getPath() + ".part");
		for (int attempt = 0; ; attempt++) {
			long have = part.isFile() ? part.length() : 0;
			HttpURLConnection c = open(url, have);
			try {
				int code = c.getResponseCode();
				if (code == 416) {
					// asked for a range past the end: the part is complete or garbage
					long total = totalFromContentRange(c.getHeaderField("Content-Range"));
					if (total == have && have > 0)
						break;
					part.delete();
					if (attempt > 2)
						throw new IOException("HTTP 416");
					continue;
				}
				if (code != 200 && code != 206)
					throw new IOException("HTTP " + code + " from " + url);
				boolean append = code == 206 && have > 0;
				if (!append)
					have = 0; // server ignored the range, start over
				long len = c.getContentLengthLong();
				long total = len < 0 ? -1 : have + len;
				byte[] buf = new byte[64 * 1024];
				long last = 0;
				try (InputStream in = c.getInputStream(); FileOutputStream out = new FileOutputStream(part, append)) {
					int n;
					while ((n = in.read(buf)) > 0) {
						if (cancel.get())
							throw new Cancelled();
						out.write(buf, 0, n);
						have += n;
						long now = System.nanoTime();
						if (now - last > 200_000_000L) {
							last = now;
							progress.onDownload(have, total);
						}
					}
				}
				progress.onDownload(have, total);
				if (total >= 0 && have != total)
					throw new IOException("download ended early (" + have + " of " + total + ")");
				break;
			} finally {
				c.disconnect();
			}
		}
		dest.delete();
		if (!part.renameTo(dest))
			throw new IOException("cannot rename " + part);
	}

	private static boolean looksComplete(File zip) {
		try (ZipFile z = new ZipFile(zip)) {
			return z.size() > 0;
		} catch (IOException e) {
			zip.delete();
			return false;
		}
	}

	private static HttpURLConnection open(String url, long from) throws IOException {
		for (int hops = 0; hops < 6; hops++) {
			HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
			c.setInstanceFollowRedirects(false); // follow by hand so Range survives
			c.setConnectTimeout(20_000);
			c.setReadTimeout(30_000);
			c.setRequestProperty("User-Agent", "Insanotic-Android");
			if (from > 0)
				c.setRequestProperty("Range", "bytes=" + from + "-");
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
		// "bytes */12345" or "bytes 0-9/12345"
		if (header == null)
			return -1;
		int slash = header.lastIndexOf('/');
		try {
			return slash < 0 ? -1 : Long.parseLong(header.substring(slash + 1).trim());
		} catch (NumberFormatException e) {
			return -1;
		}
	}

	// ----------------------------------------------------------------- extract

	/** Extracts data/*.pk3 (whatever the top level directory is called) into dataDir. */
	private static void extractPacks(File zip, File dataDir, Progress progress, java.util.concurrent.atomic.AtomicBoolean cancel) throws IOException {
		try (ZipFile z = new ZipFile(zip)) {
			List<ZipEntry> packs = new ArrayList<>();
			for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements(); ) {
				ZipEntry ze = e.nextElement();
				if (!ze.isDirectory() && isDataPk3(ze.getName()))
					packs.add(ze);
			}
			if (packs.isEmpty())
				throw new ZipException("no data/*.pk3 in the release zip");
			int i = 0;
			for (ZipEntry ze : packs) {
				String name = ze.getName().substring(ze.getName().lastIndexOf('/') + 1);
				progress.onExtract(name, ++i, packs.size());
				File out = new File(dataDir, name);
				if (out.isFile() && out.length() == ze.getSize())
					continue; // already extracted by an earlier, interrupted run
				File tmp = new File(dataDir, name + ".part");
				try (InputStream in = z.getInputStream(ze); OutputStream os = new FileOutputStream(tmp)) {
					copyCancellable(in, os, cancel);
				}
				out.delete();
				if (!tmp.renameTo(out))
					throw new IOException("cannot create " + out);
			}
		} catch (ZipException e) {
			zip.delete(); // damaged download: the next try fetches it again
			throw e;
		}
	}

	/** "Xonotic/data/xonotic-20230620-data.pk3" and "data/foo.pk3" match; nested dirs do not. */
	static boolean isDataPk3(String entry) {
		if (!entry.endsWith(".pk3"))
			return false;
		String[] parts = entry.split("/");
		return (parts.length == 2 || parts.length == 3) && parts[parts.length - 2].equals("data");
	}

	// ----------------------------------------------------------------- helpers

	private static void copy(InputStream in, OutputStream out) throws IOException {
		byte[] buf = new byte[64 * 1024];
		int n;
		while ((n = in.read(buf)) > 0)
			out.write(buf, 0, n);
	}

	private static void copyCancellable(InputStream in, OutputStream out, java.util.concurrent.atomic.AtomicBoolean cancel) throws IOException {
		byte[] buf = new byte[64 * 1024];
		int n;
		while ((n = in.read(buf)) > 0) {
			if (cancel.get())
				throw new Cancelled();
			out.write(buf, 0, n);
		}
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
