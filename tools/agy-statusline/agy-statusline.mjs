import { createHash } from 'node:crypto';
import {
  closeSync,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const DEFAULT_LEDGER_FILE = join(
  homedir(),
  '.gemini',
  'antigravity-cli',
  'statusline-ledger.json',
);

const LEDGER_VERSION = 2;
const CYCLE_RESET_TOLERANCE_MS = 120_000;
const MIN_CALIBRATION_DROP = 0.005; // 0.5% consistent weekly drop required before extrapolating
const MIN_BATCH_DROP = 0.002; // 0.2% minimum drop per paired batch to smooth step quantization
const PENDING_DROP_WINDOW_MS = 120_000; // 2m window to pair quota-first drops with local spend
const PENDING_USD_WINDOW_MS = 600_000; // 10m window for local spend waiting on quota refresh
const UPWARD_RESET_TOLERANCE = 0.002; // >0.2% upward jump within same reset_time signals account switch
const MAX_POOL_SLOTS = 12;
const MAX_BATCH_SAMPLES = 12;
const MAX_TRACKED_SESSIONS = 500;

const SLOW_PHASE_MS = 90_000;
const LOOP_MIN_HOPS = 10;
const LOOP_MIN_ELAPSED_MS = 120_000;
const LOOP_HARD_HOPS = 16;
const BURN_FLOOR_USD = 0.8;
const BURN_WEEKLY_SHARE = 0.03;
const BURN_FALLBACK_USD = 1.5;
const ALERT_IDLE_TTL_MS = 600_000;
const WARN_PRIORITY = { LOOP: 3, TOOL: 2, THK: 2, WRK: 2, BURN: 1 };

const ACTIVE_AGENT_STATES = new Set(['thinking', 'working', 'tool_use', 'reviewing']);

const LOCK_STALE_MS = 3_000;
const LOCK_WAIT_MS = 500;
const LOCK_SLEEP_BUF = new Int32Array(new SharedArrayBuffer(4));

const ANSI = {
  reset: '\x1b[0m',
  dim: '\x1b[2m',
  redBold: '\x1b[1;31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  cyan: '\x1b[36m',
  cyanDim: '\x1b[2;36m',
};

const clamp01 = (v) => Math.max(0, Math.min(1, v));
const pctStr = (frac, decimals = 1) => `${(clamp01(frac) * 100).toFixed(decimals)}%`;
const isPlainObject = (v) => Boolean(v) && typeof v === 'object' && !Array.isArray(v);
const toFiniteNumber = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

export function stripAnsi(str) {
  return String(str).replace(/\x1b\[[0-9;]*m/g, '');
}

function paint(text, code, useColor) {
  return useColor && code ? `${code}${text}${ANSI.reset}` : text;
}

function formatDuration(seconds, withSeconds = false) {
  const s = Math.max(0, Math.floor(seconds));
  if (s >= 86_400) return `${Math.floor(s / 86_400)}d${Math.floor((s % 86_400) / 3600)}h`;
  if (s >= 3600) return `${Math.floor(s / 3600)}h${Math.floor((s % 3600) / 60)}m`;
  if (s >= 60) {
    const m = Math.floor(s / 60);
    const rem = s % 60;
    return withSeconds && rem > 0 ? `${m}m${rem}s` : `${m}m`;
  }
  return withSeconds ? `${s}s` : '0m';
}

function formatUsdCompact(usd) {
  if (usd >= 100) return `$${usd.toFixed(0)}`;
  if (usd >= 10) return `$${usd.toFixed(1)}`;
  return `$${usd.toFixed(2)}`;
}

function formatEstUsd(usd, round, isTotal) {
  if (round) return `$${usd.toFixed(0)}`;
  if (isTotal) return usd >= 10 ? `$${usd.toFixed(0)}` : `$${usd.toFixed(1)}`;
  return usd >= 10 ? `$${usd.toFixed(1)}` : `$${usd.toFixed(2)}`;
}

function pickPoolAndBuckets(quota, modelId) {
  const is3p = /claude|sonnet|opus|haiku|gpt/i.test(modelId);
  const isGem = /gemini|argon|carbon|neon|hydrogen|flash/i.test(modelId);
  const pool = is3p ? '3p' : isGem ? 'gemini' : null;

  if (!pool || !isPlainObject(quota)) {
    return { pool, b5h: null, bWk: null };
  }

  const entries = Object.entries(quota).filter(([, v]) => isPlainObject(v));
  const findBucket = (kind, suffix) =>
    entries.find(([id]) => id === `${pool}-${suffix}`)?.[1] ||
    entries.find(([id]) => id.startsWith(pool) && id.includes(kind))?.[1] ||
    null;

  return {
    pool,
    b5h: findBucket('5h', '5h'),
    bWk: findBucket('week', 'weekly'),
  };
}

function readRemainingFraction(bucket) {
  if (!isPlainObject(bucket) || bucket.disabled) return null;
  const f = toFiniteNumber(bucket.remaining_fraction);
  return f !== null ? clamp01(f) : null;
}

function resolveContextPercent(cw) {
  const used = isPlainObject(cw) ? toFiniteNumber(cw.used_percentage) : null;
  return used !== null ? Math.max(0, Math.min(100, used)) : null;
}

function resolveSessionCost(data) {
  const reported = toFiniteNumber(data?.cost?.total_usd);
  if (reported !== null && reported >= 0) {
    return { usd: reported, estimated: data?.cost?.estimated === true };
  }
  return null;
}

function sameResetCycle(a, b) {
  if (!a || !b) return false;
  if (a === b) return true;
  const ta = Date.parse(a);
  const tb = Date.parse(b);
  return Number.isFinite(ta) && Number.isFinite(tb) && Math.abs(ta - tb) <= CYCLE_RESET_TOLERANCE_MS;
}

function pruneMapByUpdatedAt(mapObj, maxCount) {
  const entries = Object.entries(mapObj);
  if (entries.length <= maxCount) return mapObj;
  entries.sort((a, b) => (toFiniteNumber(b[1]?.updatedAt) ?? 0) - (toFiniteNumber(a[1]?.updatedAt) ?? 0));
  return Object.fromEntries(entries.slice(0, maxCount));
}

function sanitizeSamples(rawSamples) {
  if (!Array.isArray(rawSamples)) return [];
  const clean = [];
  for (const s of rawSamples) {
    if (!isPlainObject(s)) continue;
    const usd = toFiniteNumber(s.usd);
    const drop = toFiniteNumber(s.drop);
    if (usd !== null && usd > 0 && drop !== null && drop > 0) clean.push({ usd, drop });
  }
  return clean.slice(-MAX_BATCH_SAMPLES);
}

function resolveAccountIdentity(data) {
  const email = typeof data?.email === 'string' ? data.email.trim().toLowerCase() : '';
  const planTier = typeof data?.plan_tier === 'string' ? data.plan_tier.trim().toLowerCase() : '';
  const accountKey = email
    ? createHash('sha256').update(email).digest('hex').slice(0, 12)
    : '';
  return { accountKey, planTier };
}

function loadPoolSlot(pools, pool, accountKey, planTier, resetTime, remWk, nowMs) {
  for (const [key, v] of Object.entries(pools)) {
    const slotAcct = typeof v?.accountKey === 'string' ? v.accountKey : '';
    if (
      !isPlainObject(v) ||
      v.pool !== pool ||
      slotAcct !== accountKey ||
      !sameResetCycle(v.resetTime, resetTime)
    ) {
      continue;
    }
    return {
      key,
      isNew: false,
      slot: {
        pool,
        accountKey,
        planTier: typeof v.planTier === 'string' ? v.planTier : planTier,
        resetTime: typeof v.resetTime === 'string' && v.resetTime.trim() ? v.resetTime : resetTime,
        lastRem: clamp01(toFiniteNumber(v.lastRem) ?? remWk),
        samples: sanitizeSamples(v.samples),
        pendingUsd: Math.max(0, toFiniteNumber(v.pendingUsd) ?? 0),
        pendingAt: Math.max(0, toFiniteNumber(v.pendingAt) ?? 0),
        pendingDrop: Math.max(0, toFiniteNumber(v.pendingDrop) ?? 0),
        pendingDropAt: Math.max(0, toFiniteNumber(v.pendingDropAt) ?? 0),
        updatedAt: Math.max(0, toFiniteNumber(v.updatedAt) ?? nowMs),
      },
    };
  }
  return {
    key: accountKey ? `${pool}:${accountKey}:${resetTime}` : `${pool}:${resetTime}`,
    isNew: true,
    slot: {
      pool,
      accountKey,
      planTier,
      resetTime,
      lastRem: remWk,
      samples: [],
      pendingUsd: 0,
      pendingAt: 0,
      pendingDrop: 0,
      pendingDropAt: 0,
      updatedAt: nowMs,
    },
  };
}

function median(nums) {
  const sorted = [...nums].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function summarizeCalibration(st, remWk) {
  const { samples, pendingUsd, pendingDrop } = st;
  if (samples.length > 0) {
    const med = median(samples.map((s) => s.usd / s.drop));
    const consistent = samples.filter((s) => {
      const rate = s.usd / s.drop;
      return rate >= med * 0.4 && rate <= med * 2.5;
    });
    const cDrop = consistent.reduce((acc, s) => acc + s.drop, 0);
    const cUsd = consistent.reduce((acc, s) => acc + s.usd, 0);
    if (cDrop >= MIN_CALIBRATION_DROP) {
      const fullUsd = cUsd / cDrop;
      return {
        calibrated: true,
        fullUsd,
        remUsd: fullUsd * remWk,
        uncertain: consistent.length * 2 <= samples.length,
      };
    }
    return {
      calibrated: false,
      usd: cUsd + pendingUsd,
      drop: cDrop + (pendingUsd > 0 ? pendingDrop : 0),
      pending: pendingUsd > 0,
    };
  }
  if (pendingUsd > 0) {
    return { calibrated: false, usd: pendingUsd, drop: pendingDrop, pending: true };
  }
  return null;
}

function resetSlotCalibration(st, remWk, nowMs) {
  st.samples = [];
  st.pendingUsd = 0;
  st.pendingAt = 0;
  st.pendingDrop = 0;
  st.pendingDropAt = 0;
  st.lastRem = remWk;
  st.updatedAt = nowMs;
}

function updatePoolCalibration(
  ledger,
  pool,
  accountKey,
  planTier,
  resetTime,
  remWk,
  dUsd,
  baselinedUnseen,
  nowMs,
) {
  const { key: slotKey, isNew: isNewSlot, slot: st } = loadPoolSlot(
    ledger.pools,
    pool,
    accountKey,
    planTier,
    resetTime,
    remWk,
    nowMs,
  );
  let changed = isNewSlot;

  if (!isNewSlot && planTier) {
    if (st.planTier && planTier !== st.planTier) {
      st.planTier = planTier;
      resetSlotCalibration(st, remWk, nowMs);
      changed = true;
    } else if (!st.planTier) {
      st.planTier = planTier;
      changed = true;
    }
  }

  // An upward quota jump within the same reset_time implies an unkeyed account switch or grant.
  if (!isNewSlot && remWk > st.lastRem + UPWARD_RESET_TOLERANCE) {
    resetSlotCalibration(st, remWk, nowMs);
    changed = true;
  }

  if (st.pendingUsd > 0 && nowMs - st.pendingAt > PENDING_USD_WINDOW_MS) {
    st.pendingUsd = 0;
    st.pendingAt = 0;
    changed = true;
  }
  if (st.pendingDrop > 0 && nowMs - st.pendingDropAt > PENDING_DROP_WINDOW_MS) {
    st.pendingDrop = 0;
    st.pendingDropAt = 0;
    changed = true;
  }

  if (dUsd > 0 && (remWk > 0 || st.lastRem > 0)) {
    st.pendingUsd += dUsd;
    st.pendingAt = nowMs;
    st.updatedAt = nowMs;
    changed = true;
  }

  const dDrop = Math.max(0, st.lastRem - remWk);
  if (dDrop > 0) {
    if (!(baselinedUnseen && st.pendingUsd === 0)) {
      st.pendingDrop += dDrop;
      st.pendingDropAt = nowMs;
    }
    st.lastRem = remWk;
    st.updatedAt = nowMs;
    changed = true;
  }

  if (st.pendingUsd > 0 && st.pendingDrop >= MIN_BATCH_DROP) {
    st.samples.push({ usd: st.pendingUsd, drop: st.pendingDrop });
    if (st.samples.length > MAX_BATCH_SAMPLES) st.samples = st.samples.slice(-MAX_BATCH_SAMPLES);
    st.pendingUsd = 0;
    st.pendingAt = 0;
    st.pendingDrop = 0;
    st.pendingDropAt = 0;
    st.updatedAt = nowMs;
    changed = true;
  }

  if (changed) {
    ledger.pools[slotKey] = st;
    ledger.pools = pruneMapByUpdatedAt(ledger.pools, MAX_POOL_SLOTS);
  }

  return { wkCalibration: summarizeCalibration(st, remWk), changed };
}

function sanitizeWarn(raw) {
  if (!isPlainObject(raw)) return null;
  const kind = typeof raw.kind === 'string' ? raw.kind : '';
  const text = typeof raw.text === 'string' ? raw.text : '';
  const at = toFiniteNumber(raw.at);
  return kind && text && at !== null ? { kind, text, severe: raw.severe === true, at } : null;
}

function sanitizeMonitor(raw) {
  if (!isPlainObject(raw)) return null;
  const phase = typeof raw.phase === 'string' ? raw.phase : '';
  const phaseAt = toFiniteNumber(raw.phaseAt);
  if (!phase || phaseAt === null) return null;
  return {
    phase,
    phaseAt,
    turnAt: Math.max(0, toFiniteNumber(raw.turnAt) ?? 0),
    turnUsd: Math.max(0, toFiniteNumber(raw.turnUsd) ?? 0),
    toolHops: Math.max(0, Math.floor(toFiniteNumber(raw.toolHops) ?? 0)),
    warn: sanitizeWarn(raw.warn),
  };
}

function classifySlowPhase(prevPhase, elapsedMs) {
  if (elapsedMs < SLOW_PHASE_MS) return null;
  const labels = { tool_use: 'TOOL', thinking: 'THK', working: 'WRK' };
  const kind = labels[prevPhase];
  if (!kind) return null;
  return {
    kind,
    text: `${kind} ${formatDuration(elapsedMs / 1000, true)}`,
    severe: elapsedMs >= SLOW_PHASE_MS * 2,
  };
}

function updateSessionMonitor(sess, agentState, dUsd, wkCalibration, nowMs) {
  const burnThreshold =
    wkCalibration?.calibrated && !wkCalibration.uncertain
      ? Math.max(BURN_FLOOR_USD, wkCalibration.fullUsd * BURN_WEEKLY_SHARE)
      : BURN_FALLBACK_USD;

  let mon = sanitizeMonitor(sess.mon);
  let changed = false;

  if (!agentState) {
    if (mon?.warn && (!mon.turnAt || mon.phase === 'idle') && nowMs - mon.warn.at > ALERT_IDLE_TTL_MS) {
      mon.warn = null;
      changed = true;
    }
    if (dUsd >= burnThreshold) {
      mon = mon || { phase: 'unknown', phaseAt: nowMs, turnAt: 0, turnUsd: 0, toolHops: 0, warn: null };
      mon.warn = {
        kind: 'BURN',
        text: `BURN +${formatUsdCompact(dUsd)}`,
        severe: dUsd >= burnThreshold * 2,
        at: nowMs,
      };
      changed = true;
    } else if (dUsd > 0 && mon?.warn?.kind === 'BURN') {
      mon.warn = null;
      changed = true;
    }
    return { mon, changed };
  }

  if (!mon) {
    const active = ACTIVE_AGENT_STATES.has(agentState);
    const turnUsd = active ? dUsd : 0;
    const burnWarn =
      dUsd >= burnThreshold
        ? {
            kind: 'BURN',
            text: `BURN +${formatUsdCompact(dUsd)}`,
            severe: dUsd >= burnThreshold * 2,
            at: nowMs,
          }
        : null;
    return {
      mon: {
        phase: agentState,
        phaseAt: nowMs,
        turnAt: active ? nowMs : 0,
        turnUsd,
        toolHops: agentState === 'tool_use' ? 1 : 0,
        warn: burnWarn,
      },
      changed: true,
    };
  }

  if (!ACTIVE_AGENT_STATES.has(agentState) && mon.warn && nowMs - mon.warn.at > ALERT_IDLE_TTL_MS) {
    mon.warn = null;
    changed = true;
  }

  let slowWarn = null;
  let completedTurnUsd = 0;

  if (agentState !== mon.phase) {
    const prevPhase = mon.phase;
    const elapsed = Math.max(0, nowMs - mon.phaseAt);

    if (!ACTIVE_AGENT_STATES.has(prevPhase) && ACTIVE_AGENT_STATES.has(agentState)) {
      mon.warn = null;
      mon.turnAt = nowMs;
      mon.turnUsd = dUsd;
      mon.toolHops = agentState === 'tool_use' ? 1 : 0;
    } else if (ACTIVE_AGENT_STATES.has(prevPhase)) {
      const classified = classifySlowPhase(prevPhase, elapsed);
      if (classified) slowWarn = { ...classified, at: nowMs };
      mon.turnUsd += dUsd;
      if (!ACTIVE_AGENT_STATES.has(agentState)) {
        completedTurnUsd = mon.turnUsd;
        mon.turnAt = 0;
        mon.turnUsd = 0;
        mon.toolHops = 0;
      } else if (agentState === 'tool_use') {
        mon.toolHops += 1;
      }
    }
    mon.phase = agentState;
    mon.phaseAt = nowMs;
    changed = true;
  } else if (dUsd > 0 && mon.turnAt > 0) {
    mon.turnUsd += dUsd;
    changed = true;
  }

  const turnElapsed = mon.turnAt > 0 ? Math.max(0, nowMs - mon.turnAt) : 0;
  const isLoop =
    mon.turnAt > 0 &&
    ((mon.toolHops >= LOOP_MIN_HOPS && turnElapsed >= LOOP_MIN_ELAPSED_MS) ||
      mon.toolHops >= LOOP_HARD_HOPS);
  const loopWarn = isLoop
    ? {
        kind: 'LOOP',
        text: `LOOP ${mon.toolHops}t (${formatDuration(turnElapsed / 1000, true)})`,
        severe: mon.toolHops >= LOOP_HARD_HOPS,
        at: nowMs,
      }
    : null;

  const activeSpend = Math.max(completedTurnUsd, mon.turnUsd, dUsd);
  const burnWarn =
    activeSpend >= burnThreshold
      ? {
          kind: 'BURN',
          text: `BURN +${formatUsdCompact(activeSpend)}`,
          severe: activeSpend >= burnThreshold * 2,
          at: nowMs,
        }
      : null;

  const candidate = loopWarn || slowWarn || burnWarn;
  if (candidate) {
    const prevPri = mon.warn ? (WARN_PRIORITY[mon.warn.kind] ?? 0) : 0;
    const nextPri = WARN_PRIORITY[candidate.kind] ?? 0;
    if (
      !mon.warn ||
      nextPri > prevPri ||
      (nextPri === prevPri &&
        (mon.warn.kind !== candidate.kind ||
          mon.warn.text !== candidate.text ||
          mon.warn.severe !== candidate.severe))
    ) {
      mon.warn = candidate;
      changed = true;
    }
  }

  return { mon, changed };
}

function renderAlertLine(warn, maxWidth, useColor) {
  if (!warn) return null;
  const color = warn.severe ? ANSI.redBold : ANSI.yellow;
  const full = paint(`! ${warn.text}`, color, useColor);
  if (maxWidth === null || stripAnsi(full).length <= maxWidth) return full;
  return paint(`! ${warn.kind}`, color, useColor);
}

function quotaColor(rem) {
  if (rem <= 0.15) return ANSI.redBold;
  if (rem <= 0.4) return ANSI.yellow;
  return ANSI.green;
}

function ctxColor(pct) {
  if (pct >= 80) return ANSI.redBold;
  if (pct >= 60) return ANSI.yellow;
  return ANSI.cyan;
}

function formatWindow(label, bucket, rem, tier, useColor) {
  if (rem === null) return `${label} ${paint('--', ANSI.dim, useColor)}`;
  const pct = paint(pctStr(rem, tier.decimals), quotaColor(rem), useColor);
  if (!tier.showReset) return `${label} ${pct}`;
  const secs = toFiniteNumber(bucket?.reset_in_seconds);
  const resetSuffix =
    secs !== null ? paint(`(${formatDuration(Math.max(0, secs))})`, ANSI.dim, useColor) : '';
  return `${label} ${pct}${resetSuffix}`;
}

function renderTier(state, tier, useColor) {
  const { pool, ctxPct, b5h, rem5h, bWk, remWk, wkCalibration, sessionUsd, costEstimated } = state;
  const parts = [];

  if (tier.showPool && pool) {
    parts.push(paint(pool === '3p' ? '3P' : 'GEM', ANSI.cyanDim, useColor));
  }

  const ctxVal =
    ctxPct !== null
      ? paint(`${ctxPct.toFixed(tier.decimals)}%`, ctxColor(ctxPct), useColor)
      : paint('--', ANSI.dim, useColor);
  parts.push(`Ctx ${ctxVal}`);
  parts.push(formatWindow('5h', b5h, rem5h, tier, useColor));
  parts.push(formatWindow('Wk', bWk, remWk, tier, useColor));

  if (sessionUsd !== null) {
    const approx = costEstimated ? '~' : '';
    parts.push(paint(`${approx}${formatUsdCompact(sessionUsd)}`, ANSI.dim, useColor));
  }

  if (wkCalibration && tier.estMode !== 'none') {
    if (wkCalibration.calibrated) {
      const { fullUsd, remUsd, uncertain } = wkCalibration;
      const round = tier.estMode === 'round';
      const color = uncertain ? ANSI.yellow : ANSI.cyan;
      const mark = uncertain ? '?' : '';
      const remTxt = paint(`~${formatEstUsd(remUsd, round, false)}${mark}`, color, useColor);
      const slash = paint('/', ANSI.dim, useColor);
      const fullTxt = paint(`~${formatEstUsd(fullUsd, round, true)}${mark}`, color, useColor);
      parts.push(`${remTxt}${slash}${fullTxt}`);
    } else if (tier.estMode !== 'round') {
      const { usd, drop, pending } = wkCalibration;
      const prefix = pending ? '~' : '';
      parts.push(paint(`Est ${prefix}${formatUsdCompact(usd)}/${pctStr(drop)}`, ANSI.yellow, useColor));
    }
  }

  return parts.join(paint(' │ ', ANSI.dim, useColor));
}

const LAYOUT_TIERS = [
  { showPool: true, decimals: 1, showReset: true, estMode: 'detail' },
  { showPool: false, decimals: 0, showReset: true, estMode: 'round' },
  { showPool: false, decimals: 0, showReset: false, estMode: 'none' },
];

/**
 * Pure statusLine renderer and incremental weekly-pool ledger updater.
 */
export function evaluateStatusLine(data, ledgerInput, nowMs = Date.now(), useColor = false) {
  const validLedger = isPlainObject(ledgerInput) && ledgerInput.version === LEDGER_VERSION;
  const ledger = validLedger
    ? {
        version: LEDGER_VERSION,
        pools: isPlainObject(ledgerInput.pools) ? { ...ledgerInput.pools } : {},
        sessions: isPlainObject(ledgerInput.sessions) ? { ...ledgerInput.sessions } : {},
      }
    : { version: LEDGER_VERSION, pools: {}, sessions: {} };

  const maxWidthVal = toFiniteNumber(data?.terminal_width);
  const maxWidth = maxWidthVal !== null && maxWidthVal > 0 ? maxWidthVal : null;

  const modelId = typeof data?.model?.id === 'string' ? data.model.id.trim() : '';
  const agentState =
    typeof data?.agent_state === 'string' ? data.agent_state.trim().toLowerCase() : '';
  const ctxPct = resolveContextPercent(data?.context_window);
  const { pool, b5h, bWk } = pickPoolAndBuckets(data?.quota, modelId);
  const remWk = readRemainingFraction(bWk);
  let rem5h = readRemainingFraction(b5h);
  if (remWk === 0 && b5h?.disabled === true) rem5h = 0;

  let ledgerChanged = false;
  let wkCalibration = null;
  let dUsd = 0;
  let baselinedUnseen = false;

  const cid = typeof data?.conversation_id === 'string' ? data.conversation_id.trim() : '';
  const { accountKey, planTier } = resolveAccountIdentity(data);
  const resolvedCost = resolveSessionCost(data);
  const sessionUsd = resolvedCost?.usd ?? null;
  const costEstimated = Boolean(resolvedCost?.estimated);

  const prevSess = cid && isPlainObject(ledger.sessions[cid]) ? ledger.sessions[cid] : null;
  let sessChanged = false;

  if (cid) {
    if (!prevSess && sessionUsd === null) {
      // Pre-register Turn 0 before cost appears so Turn 1 spend is tracked mid-cycle.
      ledger.sessions[cid] = { lastUsd: 0, updatedAt: nowMs };
      sessChanged = true;
    } else if (sessionUsd !== null) {
      const prevUsd = Math.max(0, toFiniteNumber(prevSess?.lastUsd) ?? 0);
      const nextUsd = Math.max(prevUsd, sessionUsd);
      const isMidCycleUnseen = !prevSess && remWk !== null && remWk < 1;
      dUsd = isMidCycleUnseen ? 0 : Math.max(0, nextUsd - prevUsd);
      if (isMidCycleUnseen && nextUsd > 0) baselinedUnseen = true;
      if (!prevSess || dUsd > 0) {
        ledger.sessions[cid] = { ...(prevSess || {}), lastUsd: nextUsd, updatedAt: nowMs };
        sessChanged = true;
      }
    }
  }

  const wkResetTime = typeof bWk?.reset_time === 'string' ? bWk.reset_time.trim() : '';
  if (pool && remWk !== null && wkResetTime) {
    const poolRes = updatePoolCalibration(
      ledger,
      pool,
      accountKey,
      planTier,
      wkResetTime,
      remWk,
      dUsd,
      baselinedUnseen,
      nowMs,
    );
    wkCalibration = poolRes.wkCalibration;
    if (poolRes.changed) ledgerChanged = true;
  }

  let activeWarn = null;
  if (cid && isPlainObject(ledger.sessions[cid])) {
    const currentSess = { ...ledger.sessions[cid] };
    const { mon, changed: monChanged } = updateSessionMonitor(
      currentSess,
      agentState,
      dUsd,
      wkCalibration,
      nowMs,
    );
    if (monChanged) {
      if (mon) currentSess.mon = mon;
      currentSess.updatedAt = nowMs;
      ledger.sessions[cid] = currentSess;
      sessChanged = true;
    }
    activeWarn = mon?.warn || null;
  }

  if (sessChanged) {
    ledger.sessions = pruneMapByUpdatedAt(ledger.sessions, MAX_TRACKED_SESSIONS);
    ledgerChanged = true;
  }

  const renderState = {
    pool,
    ctxPct,
    b5h,
    rem5h,
    bWk,
    remWk,
    wkCalibration,
    sessionUsd,
    costEstimated,
  };

  let line1 = renderTier(renderState, LAYOUT_TIERS[0], useColor);
  if (maxWidth !== null && stripAnsi(line1).length > maxWidth) {
    for (let i = 1; i < LAYOUT_TIERS.length; i++) {
      const candidate = renderTier(renderState, LAYOUT_TIERS[i], useColor);
      line1 = candidate;
      if (stripAnsi(candidate).length <= maxWidth) break;
    }
  }

  const line2 = renderAlertLine(activeWarn, maxWidth, useColor);
  const line = line2 ? `${line1}\n${line2}` : line1;

  return { line, ledger, ledgerChanged };
}

function loadLedgerFile(ledgerPath) {
  try {
    if (existsSync(ledgerPath)) {
      return JSON.parse(readFileSync(ledgerPath, 'utf8'));
    }
  } catch {
    // Corrupted ledger falls back cleanly
  }
  return { version: LEDGER_VERSION, pools: {}, sessions: {} };
}

function saveLedgerFile(ledgerPath, data) {
  const tmp = `${ledgerPath}.tmp.${process.pid}.${Date.now()}`;
  try {
    mkdirSync(dirname(ledgerPath), { recursive: true });
    writeFileSync(tmp, JSON.stringify(data), 'utf8');
    renameSync(tmp, ledgerPath);
  } catch {
    try {
      rmSync(tmp, { force: true });
    } catch {
      // Ignore cleanup failure
    }
  }
}

function withLedgerLock(ledgerPath, fn) {
  const lockPath = `${ledgerPath}.lock`;
  try {
    mkdirSync(dirname(ledgerPath), { recursive: true });
  } catch {
    return null;
  }

  const deadline = Date.now() + LOCK_WAIT_MS;
  while (true) {
    try {
      const fd = openSync(lockPath, 'wx');
      let myIno = 0;
      try {
        writeFileSync(fd, String(process.pid));
        myIno = fstatSync(fd).ino || 0;
      } finally {
        closeSync(fd);
      }
      try {
        return fn();
      } finally {
        try {
          if (!myIno || statSync(lockPath).ino === myIno) {
            rmSync(lockPath, { force: true });
          }
        } catch {
          // Ignore lock cleanup failure
        }
      }
    } catch (err) {
      if (err?.code !== 'EEXIST') return null;
      try {
        const st = statSync(lockPath);
        if (Date.now() - st.mtimeMs > LOCK_STALE_MS) {
          rmSync(lockPath, { force: true });
          continue;
        }
      } catch {
        continue;
      }
      if (Date.now() >= deadline) return null;
      Atomics.wait(LOCK_SLEEP_BUF, 0, 0, 15);
    }
  }
}

function resolveArgvRealPath(rawArgv) {
  if (!rawArgv) return '';
  try {
    return realpathSync(rawArgv);
  } catch {
    return resolve(rawArgv);
  }
}

function readStdin() {
  if (process.stdin.isTTY) return Promise.resolve('');
  return new Promise((resolveStdin) => {
    let raw = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      raw += chunk;
    });
    process.stdin.on('end', () => resolveStdin(raw));
    process.stdin.on('error', () => resolveStdin(''));
  });
}

async function main() {
  const rawInput = (await readStdin()).trim();
  if (!rawInput) return;

  let payload;
  try {
    payload = JSON.parse(rawInput);
  } catch {
    return;
  }
  if (!isPlainObject(payload)) return;

  const ledgerPath = process.env.AGY_STATUSLINE_LEDGER || DEFAULT_LEDGER_FILE;
  const nowMs = Date.now();
  const useColor = (process.env.NO_COLOR ?? '') === '';

  let result = evaluateStatusLine(payload, loadLedgerFile(ledgerPath), nowMs, useColor);
  if (result.ledgerChanged) {
    const locked = withLedgerLock(ledgerPath, () => {
      const evaluated = evaluateStatusLine(payload, loadLedgerFile(ledgerPath), nowMs, useColor);
      if (evaluated.ledgerChanged) {
        saveLedgerFile(ledgerPath, evaluated.ledger);
      }
      return evaluated;
    });
    if (locked) result = locked;
  }

  if (result.line) {
    process.stdout.write(result.line);
  }
}

const selfPath = fileURLToPath(import.meta.url);
const argvPath = resolveArgvRealPath(process.argv[1]);
const isEntrypoint =
  Boolean(argvPath) &&
  (process.platform === 'win32'
    ? selfPath.toLowerCase() === argvPath.toLowerCase()
    : selfPath === argvPath);
if (isEntrypoint) {
  void main();
}
