// SPDX-License-Identifier: GPL-3.0-or-later
//
// Boots dist/ in headless Chromium (software WebGL), presses Play and prints
// what the engine says, so CI shows whether the wasm instantiates and runs.
// Without game data the engine stops with an error about it; that counts as
// booting. A JavaScript exception or a missing engine banner fails.
//
//   node test/smoke.mjs [dist-dir] [screenshot.png]
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import { chromium } from "playwright";

const dist = resolve(process.argv[2] || "dist");
const shot = process.argv[3] || "smoke.png";
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".json": "application/json", ".pk3": "application/zip" };

const server = createServer(async (req, res) => {
	try {
		const path = new URL(req.url, "http://x").pathname.replace(/\/$/, "/index.html");
		const body = await readFile(join(dist, path));
		res.writeHead(200, { "content-type": types[extname(path)] || "application/octet-stream" });
		res.end(body);
	} catch (e) {
		res.writeHead(404);
		res.end();
	}
}).listen(0);
const port = server.address().port;

const browser = await chromium.launch({
	args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
await page.goto(`http://127.0.0.1:${port}/`);
await page.waitForFunction(() => !document.getElementById("start").disabled, null, { timeout: 180000 });
console.log("status:", await page.textContent("#status"));
// WEB_MAP=<name>: use Quick match and wait until the engine reports that map
const map = process.env.WEB_MAP || "";
let mapLoaded = false;
if (map) {
	await page.waitForFunction(() => !document.getElementById("quick").hidden, null, { timeout: 10000 });
	await page.click("#quick");
	for (let i = 0; i < 36 && !mapLoaded; i++) {
		await page.waitForTimeout(10000);
		await page.evaluate(() => window.insanotic && window.insanotic.command("status"));
		await page.waitForTimeout(1000);
		mapLoaded = new RegExp("map:\\s+" + map + "\\b").test(await page.textContent("#log"));
	}
} else {
	await page.click("#start");
	await page.waitForTimeout(30000);
}
await page.screenshot({ path: shot });
const log = await page.textContent("#log");
console.log("---- engine output ----\n" + log + "\n---- page errors ----\n" + (errors.join("\n") || "(none)"));
await browser.close();
server.close();
const booted = /DarkPlaces|Insanotic|Game is|Xonotic|GL_RENDERER|video mode/i.test(log);
if (!booted) { console.error("no sign of the engine running"); process.exit(1); }
if (map && !mapLoaded) { console.error("the map " + map + " did not load"); process.exit(1); }
if (map) console.log("map loaded: " + map);
if (errors.length) process.exit(1);
