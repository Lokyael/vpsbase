import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const DEFAULT_LEDGER_FILE = join(
  homedir(),
  '.gemini',
  'antigravity-cli',
  'statusline-ledger.json',
);

const CYCLE_RESET_TOLERANCE_MS = 120_000;
const MIN_CALIBRATION_DROP = 0.005; // 0.5% weekly quota drop before extrapolating
const EXTERNAL_DROP_NOISE_FLOOR = 0.003; // 0.3% drop with $0 local spend treated as off-machine usage
const MAX_TRACKED_SESSIONS = 200;

/**
 * Standard public API list prices in USD per 1M tokens:
 * [input, output, cacheRead, cacheWrite, longContextTier?]
 */
export const MODEL_PRICE_TABLE = [
  [/claude[-_ ]?opus[-_ ]?4[-.]?1|claude[-_ ]?opus[-_ ]?4(?![-.]\d)/i, [15.0, 75.0, 1.5, 18.75]],
  [/claude[-_ ]?opus[-_ ]?5[-.]?5/i, [4.0, 20.0, 0.2, 5.0]],
  [/opus/i, [5.0, 25.0, 0.5, 6.25]],
  [/claude[-_ ]?sonnet[-_ ]?5[-.]?5/i, [2.0, 10.0, 0.1, 2.5]],
  [/sonnet/i, [3.0, 15.0, 0.3, 3.75]],
  [/claude[-_ ]?haiku[-_ ]?5[-.]?5/i, [0.1, 0.5, 0.01, 0.125]],
  [/haiku/i, [1.0, 5.0, 0.1, 1.25]],
  [/gpt[-_ ]?oss[-_ ]?20b/i, [0.05, 0.2, 0.025, 0.05]],
  [/gpt/i, [0.15, 0.6, 0.075, 0.15]],
  [/flash[-_ ]?lite/i, [0.25, 1.5, 0.025, 0.25]],
  [/flash/i, [0.5, 3.0, 0.05, 0.5]],
  [
    /gemini|argon|carbon|neon|hydrogen/i,
    [2.0, 12.0, 0.2, 2.0, { threshold: 200_000, input: 4.0, output: 18.0, cacheRead: 0.4, cacheWrite: 4.0 }],
  ],
];

const clamp01 = (v) => Math.max(0, Math.min(1, v));
const pctStr = (frac) => `${(clamp01(frac) * 100).toFixed(1)}%`;

export function formatDuration(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  if (s >= 86_400) return `${Math.floor(s / 86_400)}d${Math.floor((s % 86_400) / 3600)}h`;
  if (s >= 3600) return `${Math.floor(s / 3600)}h${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 60)}m`;
}

export function formatTokens(n) {
  if (!Number.isFinite(n) || n <= 0) return '0';
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(0)}K`;
  return `${Math.round(n)}`;
}

export function matchModelRates(modelName) {
  const s = String(modelName || '');
  for (const [re, rates] of MODEL_PRICE_TABLE) {
    if (re.test(s)) return rates;
  }
  return [2.0, 12.0, 0.2, 2.0];
}

export function pickPoolAndBuckets(quota, modelName) {
  const model = String(modelName || '');
  const is3p = /claude|sonnet|opus|haiku|gpt/i.test(model);
  const isArgon = /\bargon\b/i.test(model);
  const isCarbon = /\bcarbon\b/i.test(model);

  if (!quota || typeof quota !== 'object' || Array.isArray(quota)) {
    return { pool: is3p ? '3p' : isCarbon ? 'carbon' : isArgon ? 'argon' : 'gemini', b5h: null, bWk: null };
  }

  const entries = Object.entries(quota).filter(([, v]) => v && typeof v === 'object');
  const findByKeys = (keys) => {
    for (const k of keys) {
      const hit = entries.find(([id]) => id === k);
      if (hit) return hit[1];
    }
    return null;
  };

  if (is3p) {
    return {
      pool: '3p',
      b5h: findByKeys(['3p-5h']) || entries.find(([id]) => id.startsWith('3p') && id.includes('5h'))?.[1] || null,
      bWk: findByKeys(['3p-weekly']) || entries.find(([id]) => id.startsWith('3p') && id.includes('week'))?.[1] || null,
    };
  }

  const subPool = isCarbon ? 'carbon' : isArgon ? 'argon' : 'gemini';
  const bWk =
    findByKeys([`${subPool}-weekly`, 'gemini-weekly']) ||
    entries.find(([id]) => !id.startsWith('3p') && id.includes('week'))?.[1] ||
    null;
  const b5h =
    findByKeys([`${subPool}-5h`, 'gemini-5h']) ||
    entries.find(([id]) => !id.startsWith('3p') && id.includes('5h'))?.[1] ||
    null;

  const actualPool =
    isCarbon && quota['carbon-weekly']
      ? 'carbon'
      : isArgon && quota['argon-weekly']
        ? 'argon'
        : 'gemini';

  return { pool: actualPool, b5h, bWk };
}

function readRemainingFraction(bucket) {
  if (!bucket || bucket.disabled) return null;
  const f = Number(bucket.remaining_fraction);
  return Number.isFinite(f) ? clamp01(f) : null;
}

function resolveContextPercent(cw) {
  if (!cw || typeof cw !== 'object') return null;
  const explicit = Number(cw.used_percentage);
  if (Number.isFinite(explicit)) return Math.max(0, Math.min(100, explicit));
  const size = Number(cw.context_window_size);
  const cu = cw.current_usage;
  if (Number.isFinite(size) && size > 0 && cu && typeof cu === 'object') {
    const used =
      Number(cu.input_tokens || 0) +
      Number(cu.cache_creation_input_tokens || 0) +
      Number(cu.cache_read_input_tokens || 0) +
      Number(cu.output_tokens || 0);
    if (used > 0) return Math.max(0, Math.min(100, (used / size) * 100));
  }
  return null;
}

export function estimateSessionUsd(data, rates) {
  const reported = Number(data?.cost?.total_usd);
  if (Number.isFinite(reported) && reported >= 0) return reported;

  const cw = data?.context_window;
  if (!cw || typeof cw !== 'object') return null;

  const [pIn, pOut, pCache, pWrite, tier] = rates;
  const cu = cw.current_usage;
  if (cu && typeof cu === 'object') {
    const inTok = Math.max(0, Number(cu.input_tokens || 0));
    const cacheWriteTok = Math.max(0, Number(cu.cache_creation_input_tokens || 0));
    const cacheReadTok = Math.max(0, Number(cu.cache_read_input_tokens || 0));
    const outTok = Math.max(0, Number(cu.output_tokens || 0));
    const promptTok = inTok + cacheWriteTok + cacheReadTok;
    const useLong = tier && promptTok > tier.threshold;
    const rIn = useLong ? tier.input : pIn;
    const rOut = useLong ? tier.output : pOut;
    const rCache = useLong ? tier.cacheRead : pCache;
    const rWrite = useLong ? tier.cacheWrite : pWrite;
    return (inTok * rIn + cacheWriteTok * rWrite + cacheReadTok * rCache + outTok * rOut) / 1e6;
  }

  const totalIn = Number(cw.total_input_tokens);
  const totalOut = Number(cw.total_output_tokens);
  if (Number.isFinite(totalIn) || Number.isFinite(totalOut)) {
    return (Math.max(0, totalIn || 0) * pIn + Math.max(0, totalOut || 0) * pOut) / 1e6;
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

function pruneSessions(sessions) {
  const entries = Object.entries(sessions);
  if (entries.length <= MAX_TRACKED_SESSIONS) return sessions;
  entries.sort((a, b) => (b[1]?.updatedAt || 0) - (a[1]?.updatedAt || 0));
  return Object.fromEntries(entries.slice(0, MAX_TRACKED_SESSIONS));
}

function formatWindow(label, bucket, rem, nowMs) {
  if (rem === null) return `${label} --`;
  const used = 1 - rem;
  let secs = Number(bucket?.reset_in_seconds);
  if (!Number.isFinite(secs) && bucket?.reset_time) {
    const resetMs = Date.parse(bucket.reset_time);
    if (Number.isFinite(resetMs)) secs = Math.max(0, (resetMs - nowMs) / 1000);
  }
  const resetSuffix = Number.isFinite(secs) ? `(${formatDuration(secs)})` : '';
  return `${label} 余${pctStr(rem)}/用${pctStr(used)}${resetSuffix}`;
}

/**
 * Pure statusLine renderer and incremental weekly-pool ledger updater.
 */
export function evaluateStatusLine(data, ledgerInput, nowMs = Date.now()) {
  const ledger =
    ledgerInput && typeof ledgerInput === 'object' && !Array.isArray(ledgerInput)
      ? {
          version: 1,
          pools: { ...(ledgerInput.pools || {}) },
          sessions: { ...(ledgerInput.sessions || {}) },
        }
      : { version: 1, pools: {}, sessions: {} };

  const modelStr = `${data?.model?.id || ''} ${data?.model?.display_name || ''}`.trim();
  const rates = matchModelRates(modelStr);
  const baseInputPrice = rates[0];

  // 1. Context %
  const ctxPct = resolveContextPercent(data?.context_window);
  const ctxPart = ctxPct !== null ? `Ctx ${ctxPct.toFixed(1)}%` : 'Ctx --';

  // 2. 5h & Weekly %
  const { pool, b5h, bWk } = pickPoolAndBuckets(data?.quota, modelStr);
  const remWk = readRemainingFraction(bWk);
  let rem5h = readRemainingFraction(b5h);
  if (remWk === 0 && b5h?.disabled) rem5h = 0;

  const part5h = formatWindow('5h', b5h, rem5h, nowMs);
  const partWk = formatWindow('周', bWk, remWk, nowMs);

  // 3. Weekly quota equivalent value & weighted token conversion
  let ledgerChanged = false;
  let wkValuePart = '';

  const cid = String(data?.conversation_id || data?.session_id || '').trim();
  const sessionUsd = estimateSessionUsd(data, rates);

  if (remWk !== null && bWk?.reset_time) {
    const prevPool = ledger.pools[pool];
    const isSameCycle = prevPool && sameResetCycle(prevPool.resetTime, bWk.reset_time);
    const st = isSameCycle
      ? { ...prevPool }
      : {
          resetTime: bWk.reset_time,
          lastRem: remWk,
          trackedDrop: 0,
          trackedUsd: 0,
        };

    if (!isSameCycle) ledgerChanged = true;

    let dUsd = 0;
    if (cid && sessionUsd !== null) {
      const prevSess = ledger.sessions[cid];
      const prevUsd = Number(prevSess?.lastUsd || 0);
      const nextUsd = Math.max(prevUsd, sessionUsd);
      // On cold-start mid-cycle (no prior pool state and weekly already < 100%),
      // treat an unseen session's pre-existing spend as baseline so it doesn't inflate dUsd/dDrop.
      const isColdMidCycleBaseline = !prevPool && !prevSess && remWk < 1;
      dUsd = isColdMidCycleBaseline ? 0 : Math.max(0, nextUsd - prevUsd);
      if (dUsd > 0 || !prevSess) {
        ledger.sessions[cid] = { lastUsd: nextUsd, updatedAt: nowMs };
        ledger.sessions = pruneSessions(ledger.sessions);
        ledgerChanged = true;
      }
    }

    const dDrop = Math.max(0, Number(st.lastRem) - remWk);
    if (dDrop > 0) {
      if (dUsd > 0 || dDrop < EXTERNAL_DROP_NOISE_FLOOR) {
        st.trackedDrop += dDrop;
        st.trackedUsd += dUsd;
      }
      st.lastRem = remWk;
      ledgerChanged = true;
    } else if (dUsd > 0) {
      st.trackedUsd += dUsd;
      ledgerChanged = true;
    }

    ledger.pools[pool] = st;

    if (st.trackedDrop >= MIN_CALIBRATION_DROP && st.trackedUsd > 0) {
      const fullUsd = st.trackedUsd / st.trackedDrop;
      const remUsd = fullUsd * remWk;
      const remEqInTokens = (remUsd / baseInputPrice) * 1e6;
      wkValuePart = `周估 ≈$${fullUsd.toFixed(0)} (余$${remUsd.toFixed(1)} · ~${formatTokens(remEqInTokens)} eqIn)`;
    } else if (st.trackedUsd > 0) {
      wkValuePart = `周估 采样($${st.trackedUsd.toFixed(2)}/${pctStr(st.trackedDrop)})`;
    }
  }

  const line = [ctxPart, part5h, partWk, wkValuePart].filter(Boolean).join(' │ ');
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
  return { version: 1, pools: {}, sessions: {} };
}

function saveLedgerFile(ledgerPath, data) {
  try {
    mkdirSync(dirname(ledgerPath), { recursive: true });
    const tmp = `${ledgerPath}.tmp.${process.pid}`;
    writeFileSync(tmp, JSON.stringify(data), 'utf8');
    renameSync(tmp, ledgerPath);
  } catch {
    // Never fail statusline rendering on disk errors
  }
}

export function main() {
  let raw = '';
  try {
    raw = readFileSync(0, 'utf8').trim();
  } catch {
    return;
  }
  if (!raw) return;

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return;
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return;

  const ledgerPath = process.env.AGY_STATUSLINE_LEDGER || DEFAULT_LEDGER_FILE;
  const ledger = loadLedgerFile(ledgerPath);
  const { line, ledger: nextLedger, ledgerChanged } = evaluateStatusLine(payload, ledger, Date.now());
  if (ledgerChanged) {
    saveLedgerFile(ledgerPath, nextLedger);
  }
  if (line) {
    process.stdout.write(line);
  }
}

const selfPath = fileURLToPath(import.meta.url);
const argvPath = process.argv[1] ? resolve(process.argv[1]) : '';
const isEntrypoint =
  Boolean(argvPath) &&
  (process.platform === 'win32'
    ? selfPath.toLowerCase() === argvPath.toLowerCase()
    : selfPath === argvPath);
if (isEntrypoint) {
  main();
}
