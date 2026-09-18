/**
 * fleet-ops#3277: load handshake for Pi's stock subagent. FORK — KEEP.
 *
 * Forks: @earendil-works/pi-coding-agent 0.85.1
 *        examples/extensions/subagent/index.ts (1038 lines).
 * Why:   the stock extension prints no EXTLOAD-OK line, and the fleet's only
 *        proof that an extension really loaded is that handshake (a silently
 *        non-loading subagent means delegation quietly stops working). This
 *        wrapper adds the one line and re-exports the stock default, so the
 *        1038 lines of tool logic stay upstream and a pi upgrade updates them.
 * Every other file under subagent/ is a symlink to the shipped original.
 */
console.log("EXTLOAD-OK extension=subagent mode=print-safe");

export { default } from "/home/nish/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/subagent/index.ts";
