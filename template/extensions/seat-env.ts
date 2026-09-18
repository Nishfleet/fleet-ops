// seat-env.ts — the ONE credential root for Pi provider extensions (fleet-ops#7664).
//
// ~/.config/fleet-ops/seats/<seat>.env is the fleet's only seat-credential store
// (`export KEY=value`, one line). fleet2/etc was deleted with the control plane on
// 2026-08-23; two provider extensions and config/pi-models.json kept hardcoding it,
// so every direct Pi provider on the VPS resolved NO key while the seats ledger
// parked them as corpses. tests/no-dead-credential-paths.test.sh is the gate.
//
// This file is copied to <provider>-provider/seat-env.ts next to each
// index.ts (a top-level extensions/*.ts would be auto-loaded by Pi as an extension).
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const SEATS_DIR = process.env.FLEET_SEATS_DIR ?? join(homedir(), ".config", "fleet-ops", "seats");

export function seatEnvPath(seat: string): string {
	return join(SEATS_DIR, `${seat}.env`);
}

/** Load KEY=value lines (optional `export ` prefix, quotes stripped) into process.env; never overrides. */
export function loadSeatEnv(seat: string): boolean {
	const file = seatEnvPath(seat);
	if (!existsSync(file)) return false;
	for (const raw of readFileSync(file, "utf-8").split("\n")) {
		const line = raw.trim().replace(/^export\s+/, "");
		if (!line || line.startsWith("#")) continue;
		const eq = line.indexOf("=");
		if (eq <= 0) continue;
		const key = line.slice(0, eq).trim();
		let val = line.slice(eq + 1).trim();
		if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) val = val.slice(1, -1);
		if (!process.env[key]) process.env[key] = val;
	}
	return true;
}

/** Model list from ~/.pi/agent/models.json (a copy of config/pi-models.json): one declarative source, no duplicated arrays. */
export function modelsFromModelsJson<T extends object>(
	provider: string,
	defaults: T,
): Array<T & { id: string; name: string; contextWindow: number; maxTokens: number }> {
	const file = join(process.env.PI_AGENT_DIR ?? join(homedir(), ".pi", "agent"), "models.json");
	if (!existsSync(file)) return [];
	const list = JSON.parse(readFileSync(file, "utf-8"))?.providers?.[provider]?.models ?? [];
	return list.map((m: Record<string, unknown>) => ({ ...defaults, ...m }));
}
