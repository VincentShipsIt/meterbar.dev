# Product screenshots

Run the renderer from the repository root on a Mac with full Xcode and an available graphical session:

```sh
scripts/render-readme-screenshots.sh
```

It compiles the shared models and uses synthetic demo data and the official provider marks. It renders its own AppKit view buffers, so Screen Recording permission is not required and other applications are never captured. It writes both existing outputs, replacing their previous generated contents:

- `docs/screenshots/menubar.png`
- `docs/screenshots/widget-medium.png`

These two files are local screenshot artifacts. Generating them does not update or deploy the README image.

## Publish the README overview

The README embeds `https://meterbar.dev/product/overview.png`. That file lives in the separate `VincentShipsIt/landings` repository at `apps/meterbardev/public/product/overview.png`.

1. Generate the local screenshots above and retain both outputs for review.
2. Capture or compose the current Overview window using synthetic demo data. The two generated menu/widget crops are supporting images, not an Overview-window replacement.
3. Replace `apps/meterbardev/public/product/overview.png` in the landings repository with that reviewed Overview image.
4. Open and merge a landings PR through its normal checks. Its existing deployment pipeline publishes the asset; no local hosting CLI or environment-file changes are required.
5. After deployment, open the exact README image URL and verify its appearance and dimensions. GitHub may cache remote README images separately from the website.

Never publish real account names, tokens, personal projects, or private usage. Provider marks must come from the shipped official assets. No publishing, deployment, or copying into the landings repository happens automatically when the local renderer runs.
