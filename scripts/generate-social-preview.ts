#!/usr/bin/env bun

/**
 * Social Preview Generator for MeterBar
 *
 * Generates a GitHub-style social preview image (1280x640).
 *
 * Usage:
 *   cd scripts && bun install && bun run social-preview
 *
 * Output:
 *   ../assets/social-preview.png
 */

import { chromium } from "playwright";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = resolve(__dirname, "..");

async function generateSocialPreview(): Promise<void> {
	console.log("🎬 Generating social preview...\n");

	const browser = await chromium.launch({ headless: true });

	const context = await browser.newContext({
		viewport: { width: 1280, height: 640 },
		deviceScaleFactor: 2,
		colorScheme: "dark",
	});

	const page = await context.newPage();

	const templatePath = resolve(ROOT_DIR, "assets", "social-preview-template.html");
	console.log(`📄 Loading: ${templatePath}`);
	await page.goto(`file://${templatePath}`, { waitUntil: "networkidle" });

	await page.waitForTimeout(1000);

	const outputPath = resolve(ROOT_DIR, "assets", "social-preview.png");
	console.log(`📸 Capturing screenshot...`);
	await page.screenshot({ path: outputPath, type: "png", animations: "disabled" });

	console.log(`✅ Saved: ${outputPath}`);
	await browser.close();
	console.log("\n🎉 Done!");
}

generateSocialPreview().catch((error) => {
	console.error("❌ Failed:", error);
	process.exit(1);
});
