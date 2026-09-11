/**
 * Devin rate-limit resume — pure logic, no imports (node --experimental-strip-types
 * loads it directly in tests/devin-provider-rate-limit-retry.test.sh).
 *
 * Why: "Reached overall message rate limit ... Your limit will reset in 9 minutes"
 * used to end the pi session: the worker died, lost its context, the seat was
 * benched for hours and intake respawned the packet from scratch on another
 * seat. Population 2026-09-10/11: 457 archived worker runs died, 114 on this
 * exact message, 144 Devin deaths after >5 min of real work. A minutes-scale
 * limit is a pause, not a death: wait it out and re-run the same packet in the
 * same session, bounded by pi-issue-run's hang watchdog (PI_HANG_TIMEOUT_S).
 */

export const DEVIN_RATE_LIMIT_RE = /reached overall message rate limit|message rate limit/i;

export function isDevinRateLimit(text: string): boolean {
	return DEVIN_RATE_LIMIT_RE.test(text);
}

/**
 * Seconds until the limit resets, from the provider's own wording, or null.
 * Accepts "reset(s) in 9 minutes" / "30 seconds" / "2 hours" / "1 day" and a
 * generic "retry after 480" (seconds). First match wins.
 */
export function parseDevinResetSeconds(text: string): number | null {
	const word = /resets?\s+in\s+(\d+)\s+(second|minute|hour|day)s?/i.exec(text);
	if (word) {
		const n = Number(word[1]);
		const unit = word[2].toLowerCase();
		const mult = unit === "second" ? 1 : unit === "minute" ? 60 : unit === "hour" ? 3600 : 86400;
		return n > 0 ? n * mult : null;
	}
	const retryAfter = /retry[\s_-]?after[^0-9]{0,20}(\d+)/i.exec(text);
	if (retryAfter) {
		const n = Number(retryAfter[1]);
		return n > 0 ? n : null;
	}
	return null;
}

export interface RetryPlanInput {
	attempt: number; // 1-based attempt that just failed
	maxAttempts: number;
	elapsedS: number; // seconds since the pi process started (process.uptime())
	watchdogS: number; // PI_HANG_TIMEOUT_S: pi-issue-run kills the whole session at this bound
	resetS: number | null; // parsed reset window, or null when the text carried none
	minWaitS: number;
	maxWaitS: number;
	minRunS: number; // do not resume unless at least this much run budget remains
	attemptTimeoutMsDefault: number;
}

export interface RetryPlan {
	retry: boolean;
	waitS: number;
	attemptTimeoutMs: number;
	reason: string;
}

const SLACK_S = 15; // provider clocks are coarse; land after the reset, not on it
const KILL_MARGIN_S = 60; // stay clear of the watchdog's own kill-after

export function planDevinRetry(i: RetryPlanInput): RetryPlan {
	const wanted = (i.resetS ?? i.minWaitS) + SLACK_S;
	const waitS = Math.min(i.maxWaitS, Math.max(i.minWaitS, wanted));
	if (i.resetS !== null && i.resetS > i.maxWaitS) {
		// An hours-scale window is a real quota wall: waiting the cap and retrying
		// would just hit it again. Die normally so the ledger benches the seat for
		// its advertised reset and intake re-seats the packet.
		return { retry: false, waitS, attemptTimeoutMs: 0, reason: `reset in ${i.resetS}s exceeds max wait ${i.maxWaitS}s` };
	}
	if (i.attempt >= i.maxAttempts) {
		return { retry: false, waitS, attemptTimeoutMs: 0, reason: `attempt ${i.attempt}/${i.maxAttempts} exhausted` };
	}
	const remainingS = i.watchdogS - i.elapsedS - waitS - KILL_MARGIN_S;
	if (remainingS < i.minRunS) {
		return {
			retry: false,
			waitS,
			attemptTimeoutMs: 0,
			reason: `watchdog budget: ${Math.max(0, Math.floor(remainingS))}s would remain after a ${waitS}s wait (< ${i.minRunS}s)`,
		};
	}
	return {
		retry: true,
		waitS,
		attemptTimeoutMs: Math.min(i.attemptTimeoutMsDefault, Math.floor(remainingS * 1000)),
		reason: `reset in ${i.resetS ?? "?"}s; ${Math.floor(remainingS)}s of run budget remains`,
	};
}
