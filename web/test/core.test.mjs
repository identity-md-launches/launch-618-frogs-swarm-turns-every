import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeSwarm, levelOf, hueOf, filterAgents, parseAmount, formatAmount, exactAmount, parseAgent, parseWeek, timeAgo, UNIT } from '../core.mjs';

test('all level boundaries map to the requested stages', () => {
  for (const [jobs, level] of [[0, 0], [99, 0], [100, 1], [999, 1], [1000, 2], [1999, 2], [2000, 3], [50000, 3]]) assert.equal(levelOf(jobs), level);
});
test('each of the 2000 agent numbers has a deterministic unique hue', () => {
  const hues = Array.from({ length: 2000 }, (_, id) => hueOf(id));
  assert.equal(new Set(hues).size, 2000);
  assert.ok(hues.every((hue) => hue >= 0 && hue < 360));
  assert.equal(hueOf(743), hueOf(743));
});
test('API seat keys identify agents; internal agentId and pending are not used for identity or acceptance', () => {
  const agents = normalizeSwarm({ seats: { 0: { tokenId: 0, agentId: '50906', accepted: 343, rejected: 13, failed: 5, pending: 47, attempts: 408, working: false, last: '2026-10-02T12:00:00Z' }, 24: { accepted: 343, working: true }, 1999: { accepted: 2000, rejected: 0, failed: 0, online: false } } });
  assert.equal(agents.length, 2000);
  assert.deepEqual(agents.slice(0, 3).map((agent) => agent.id), [1999, 0, 24]);
  const first = agents.find((agent) => agent.id === 0);
  assert.equal(first.rate, 343 / 361);
  assert.equal(first.online, null);
  assert.equal(first.last, '2026-10-02T12:00:00Z');
  assert.equal(agents.find((agent) => agent.id === 24).online, true);
  assert.equal(agents[0].online, false);
  const absent = agents.find((agent) => agent.id === 900);
  assert.equal(absent.accepted, 0); assert.equal(absent.rate, null); assert.equal(absent.last, null); assert.equal(absent.hasData, false); assert.equal(absent.online, null);
});
test('bad API shapes fail and malformed counters/timestamps cannot produce invented work', () => {
  for (const payload of [null, {}, { seats: [] }, { seats: null }]) assert.throws(() => normalizeSwarm(payload), /unfamiliar/);
  const agents = normalizeSwarm({ seats: { 0: { accepted: -1, rejected: NaN, failed: '3', last: 'yesterday', working: 'true' } } });
  assert.equal(agents[0].accepted, 0); assert.equal(agents[0].rate, null); assert.equal(agents[0].online, null); assert.equal(agents[0].last, null);
});
test('agent search is exact numeric matching, includes #0 and rejects markup', () => {
  const agents = normalizeSwarm({ seats: {} });
  assert.equal(filterAgents(agents, '').length, 2000);
  assert.deepEqual(filterAgents(agents, ' #0 ').map((agent) => agent.id), [0]);
  assert.deepEqual(filterAgents(agents, '19').map((agent) => agent.id), [19]);
  assert.equal(filterAgents(agents, '2000').length, 0);
  assert.equal(filterAgents(agents, '<script>').length, 0);
});
test('token amount parsing preserves every minor unit and rejects unsafe values', () => {
  assert.equal(parseAmount('1'), UNIT); assert.equal(parseAmount('0.000000000000000001'), 1n);
  assert.equal(parseAmount('123456789.123456789123456789'), 123456789123456789123456789n);
  assert.equal(parseAmount('1000000000'), 10n ** 27n);
  for (const value of ['0', '0.0', '-1', '+1', '1e18', '.2', '1.', '1.0000000000000000001', '01', ' 1', 'NaN', '', '9'.repeat(90)]) assert.throws(() => parseAmount(value));
});
test('display formatting never rounds small positive votes to zero', () => {
  assert.equal(formatAmount(1n), '<0.001'); assert.equal(formatAmount(0n), '0');
  assert.equal(formatAmount(1234000000000000000000n), '1,234');
  assert.equal(formatAmount(1234567890000000000n), '1.234');
  assert.equal(exactAmount(1n), '0.000000000000000001');
  assert.equal(exactAmount(100n * UNIT), '100'); assert.equal(exactAmount(0n), '0');
});
test('agent and displayed week input validation rejects fractional or out-of-range values', () => {
  assert.equal(parseAgent('0'), 0); assert.equal(parseAgent('1999'), 1999);
  for (const value of ['2000', '-1', '0.1', '1e3', '']) assert.throws(() => parseAgent(value));
  assert.equal(parseWeek('1'), 0n); assert.equal(parseWeek('500'), 499n);
  for (const value of ['0', '-1', '1.5', '01', '9007199254740992', '']) assert.throws(() => parseWeek(value));
});
test('last work labels handle missing and future timestamps without negative ages', () => {
  assert.equal(timeAgo(null), 'No recorded work');
  assert.equal(timeAgo('2026-10-02T00:00:00Z', Date.parse('2026-10-01T00:00:00Z')), 'Just now');
  assert.equal(timeAgo('2026-10-01T00:00:00Z', Date.parse('2026-10-02T00:00:00Z')), '1d ago');
});
