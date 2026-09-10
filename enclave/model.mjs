/**
 * The model this enclave runs, and how it is identified.
 *
 * The buyer names a model by hash in the payment. That hash is keccak256 of the canonical JSON of
 * model.json, so anyone holding the file can recompute it, and the enclave refuses a job that
 * names a model it does not serve. Inference is plain arithmetic over published weights, with no
 * floating point ambiguity that matters at the precision the score is reported to.
 *
 * Zero dependencies, like everything else inside the trust boundary.
 */
import { readFileSync } from 'node:fs';
import { keccak256, toHex } from './crypto.mjs';

/** Canonical JSON: keys sorted, no whitespace, so the hash does not depend on formatting. */
export function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.keys(value).sort().map((k) => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}';
  }
  return JSON.stringify(value);
}

export function hashOf(value) {
  return toHex(keccak256(Buffer.from(canonical(value), 'utf8')));
}

export function loadModel(path = new URL('./model.json', import.meta.url)) {
  const model = JSON.parse(readFileSync(path, 'utf8'));
  return { model, modelHash: hashOf(model) };
}

/**
 * Score an applicant record against the model.
 *
 * The record must carry every feature the model names, as finite numbers, and nothing else is
 * read. Returns the probability, the score in basis points, and the decision, plus the
 * standardised contribution of each feature so a reader can see why.
 */
export function score(model, record) {
  if (!record || typeof record !== 'object') throw new Error('record must be an object');
  let z = model.bias;
  const contributions = [];
  for (const f of model.features) {
    const v = record[f.name];
    if (typeof v !== 'number' || !Number.isFinite(v)) throw new Error(`feature ${f.name} missing or not a finite number`);
    const x = (v - f.mean) / f.scale;
    const c = x * f.weight;
    z += c;
    contributions.push({ name: f.name, value: v, contribution: Number(c.toFixed(4)) });
  }
  const p = 1 / (1 + Math.exp(-z));
  const scoreBps = Math.round(p * 10000);
  const decision = p >= model.decision.approve_at ? 'approve' : p >= model.decision.refer_at ? 'refer' : 'decline';
  return { probability: Number(p.toFixed(6)), scoreBps, decision, contributions };
}
