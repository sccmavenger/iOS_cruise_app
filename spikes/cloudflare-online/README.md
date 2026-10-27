# Cloudflare online-games spike

This is throwaway code that answers one question: do our Swift game rules run on Cloudflare
Durable Objects? Results are in `docs/architecture/CLOUDFLARE-SPIKE-RESULTS.md`.

```bash
spikes/cloudflare-online/run.sh
```

The script does the following:

1. Downloads the swift.org 6.4.1 toolchain and Wasm SDK into `/tmp/cf-spike` (override with
   `WORK=`), checking the signature and checksum.
2. Copies the app's current rules from `iso_cruise_app/Games`.
3. Builds the native reference generator and the WebAssembly module.
4. Runs native-vs-WebAssembly parity.
5. Starts Cloudflare's local runtime (`wrangler dev`), then runs the pilot scenarios, a
   `kill -9` restart test and a 100-room load test.
6. Stops the runtime.

The copied rules files, `rules.wasm`, `node_modules` and `.wrangler` are generated and
gitignored. Nothing here is part of the app target.

Against the deployed test Worker (`npx wrangler deploy` from `worker/`):

```bash
cd spikes/cloudflare-online/worker
BASE=https://cruiselan-online-spike.dguilloryjr.workers.dev node scenarios.mjs all
BASE=https://cruiselan-online-spike.dguilloryjr.workers.dev node deploytest.mjs        # hibernation + deploy mid-game
BASE=https://cruiselan-online-spike.dguilloryjr.workers.dev node deploy-survival.mjs active
npx wrangler delete    # remove the test Worker when finished
```
