/**
 * fleet-ops#3277: load handshake for Pi's stock subagent.
 *
 * The example extension does not print EXTLOAD-OK. This wrapper is the
 * fleet-owned index.ts: one handshake line, then the stock default export.
 * install.sh restores it from MANIFEST after a pi reinstall. Do not copy
 * the stock tool into this repo.
 */
console.log("EXTLOAD-OK extension=subagent mode=print-safe");

export { default } from "/home/nish/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/subagent/index.ts";
