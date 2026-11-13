// SPDX-License-Identifier: GPL-3.0-or-later
//
// Starts the Insanotic engine (insanotic.js / insanotic.wasm) in the page.
//
// The engine reads its game data from a virtual file system. This script
//   1. mounts two persistent (IndexedDB) directories: /game/data for packs and
//      /userdata for configs and saves,
//   2. downloads the packs listed in manifest.json that are not there yet,
//   3. lets the player add .pk3 files from an installed Xonotic,
//   4. starts the engine when "Play" is pressed (which also satisfies the
//      browser's rule that audio starts after a click).
//
// manifest.json: { "packs": [ { "name": "x.pk3", "url": "data/x.pk3", "size": 123 } ],
//                  "map": "dance", "args": [ ... ] }
// "map" (the map the packs hold) adds a "Quick match" button that starts it
// at once; Play opens the main menu.
// A different manifest can be given as ?manifest=<url>.
"use strict";
(function () {
	const $ = (id) => document.getElementById(id);
	const logEl = $("log"), statusEl = $("status"), bar = $("bar"), startBtn = $("start");
	const GAME = "/game", DATA = GAME + "/data", USER = "/userdata";
	let engine = null;

	function log(line) {
		logEl.textContent += line + "\n";
		logEl.scrollTop = logEl.scrollHeight;
	}
	function status(text) { statusEl.textContent = text; }
	function progress(done, total) {
		bar.hidden = !total;
		bar.max = total || 1;
		bar.value = done;
	}
	function mb(n) { return (n / 1048576).toFixed(1) + " MB"; }
	$("showlog").onclick = () => { logEl.style.display = logEl.style.display === "block" ? "none" : "block"; };

	function syncfs(populate) {
		return new Promise((resolve, reject) =>
			engine.FS.syncfs(populate, (err) => (err ? reject(err) : resolve())));
	}
	function have(name, size) {
		try {
			const st = engine.FS.stat(DATA + "/" + name);
			return !size || st.size === size;
		} catch (e) { return false; }
	}

	// download url into the file system, reporting progress
	async function download(pack) {
		const res = await fetch(pack.url);
		if (!res.ok) throw new Error(pack.url + ": HTTP " + res.status);
		const total = Number(res.headers.get("content-length")) || pack.size || 0;
		const chunks = [];
		let got = 0;
		const reader = res.body.getReader();
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			chunks.push(value);
			got += value.length;
			progress(got, total);
			status(pack.name + ": " + mb(got) + (total ? " / " + mb(total) : ""));
		}
		const bytes = new Uint8Array(got);
		let at = 0;
		for (const c of chunks) { bytes.set(c, at); at += c.length; }
		engine.FS.writeFile(DATA + "/" + pack.name, bytes);
	}

	async function stage() {
		const FS = engine.FS;
		FS.mkdirTree(DATA);
		FS.mkdirTree(USER);
		FS.mount(engine.IDBFS, {}, DATA);
		FS.mount(engine.IDBFS, {}, USER);
		await syncfs(true);

		const url = new URLSearchParams(location.search).get("manifest") || "manifest.json";
		let manifest = { packs: [], args: [] };
		try {
			const res = await fetch(url, { cache: "no-cache" });
			if (res.ok) manifest = await res.json();
			else log("no manifest (" + url + "): HTTP " + res.status);
		} catch (e) { log("manifest: " + e); }

		for (const pack of manifest.packs || []) {
			if (have(pack.name, pack.size)) continue;
			await download(pack);
			await syncfs(false);
		}
		progress(0, 0);
		return manifest;
	}

	$("pick").onchange = async (ev) => {
		startBtn.disabled = true;
		try {
			for (const file of ev.target.files) {
				status("Adding " + file.name + " (" + mb(file.size) + ")…");
				engine.FS.writeFile(DATA + "/" + file.name, new Uint8Array(await file.arrayBuffer()));
			}
			await syncfs(false);
			status("Added. Press Play.");
		} catch (e) {
			status("Could not add the files: " + e);
		}
		startBtn.disabled = false;
	};

	function start(manifest, extra) {
		const stage = $("stage"), canvas = $("canvas");
		$("panel").style.display = "none";
		stage.style.display = "block";
		const dpr = Math.min(window.devicePixelRatio || 1, 2);
		const w = Math.round(window.innerWidth * dpr), h = Math.round(window.innerHeight * dpr);
		const args = ["-xonotic", "-basedir", GAME, "-userdir", USER, "-nohome", "-nocurl",
			"+vid_fullscreen", "0", "+vid_width", String(w), "+vid_height", String(h)]
			.concat(manifest.args || [], extra || []);
		canvas.focus();
		engine.callMain(args);
		// run a console command in the engine (also what tests use)
		window.insanotic = {
			engine: engine,
			command: (text) => engine.ccall("Web_Command", null, ["string"], [text]),
			log: () => logEl.textContent,
		};
	}

	async function boot() {
		if (typeof InsanoticEngine !== "function") {
			status("The engine did not load (insanotic.js missing).");
			return;
		}
		engine = await InsanoticEngine({
			canvas: $("canvas"),
			print: log,
			printErr: log,
			locateFile: (path) => path,
		});
		try {
			const manifest = await stage();
			status("Ready.");
			startBtn.disabled = false;
			startBtn.onclick = () => start(manifest);
			if (manifest.map) {
				const quick = $("quick");
				quick.hidden = false;
				quick.disabled = false;
				quick.onclick = () => start(manifest, ["+map", manifest.map]);
			}
		} catch (e) {
			status("Setting up the game data failed: " + e);
			log(String(e && e.stack || e));
		}
	}
	boot();
})();
