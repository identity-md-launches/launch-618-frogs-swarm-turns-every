export const AGENT_COUNT = 2000;
export const UNIT = 10n ** 18n;
export const LEVELS = ['Tadpole', 'Froglet', 'Frog', 'King Frog'];
export const ART = ['tadpole', 'froglet', 'frog', 'king-frog'];
export const levelOf = (accepted) => accepted < 100 ? 0 : accepted < 1000 ? 1 : accepted < 2000 ? 2 : 3;
export const hueOf = (id) => ((id * 137) % AGENT_COUNT) * (360 / AGENT_COUNT);
const count = (value) => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : 0;
export function normalizeSwarm(payload) {
  if (!payload || !payload.seats || typeof payload.seats !== 'object' || Array.isArray(payload.seats)) throw new Error('The swarm API returned an unfamiliar response.');
  return Array.from({ length: AGENT_COUNT }, (_, id) => {
    const seat = payload.seats[String(id)];
    const accepted = count(seat?.accepted);
    const settled = accepted + count(seat?.rejected) + count(seat?.failed);
    const last = typeof seat?.last === 'string' && Number.isFinite(Date.parse(seat.last)) ? seat.last : null;
    const online = typeof seat?.online === 'boolean' ? seat.online : seat?.working === true ? true : null;
    return { id, accepted, settled, rate: settled ? accepted / settled : null, last, online, working: seat?.working === true, hasData: Boolean(seat), level: levelOf(accepted), hue: hueOf(id) };
  }).sort((a, b) => b.accepted - a.accepted || a.id - b.id);
}
export function filterAgents(agents, query) {
  const trimmed = query.trim().replace(/^#/, '');
  if (!trimmed) return agents;
  if (!/^\d{1,4}$/.test(trimmed)) return [];
  return agents.filter((agent) => agent.id === Number(trimmed));
}
export function parseAmount(value) {
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(value)) throw new Error('Enter a positive FROGS amount with at most 18 decimal places.');
  const [whole, fraction = ''] = value.split('.');
  const amount = BigInt(whole) * UNIT + BigInt(fraction.padEnd(18, '0'));
  if (!amount || amount >= 1n << 256n) throw new Error('Amount must be positive and fit uint256.');
  return amount;
}
export function formatAmount(value, places = 3) {
  const amount = BigInt(value);
  const whole = (amount / UNIT).toLocaleString('en-US');
  const fraction = (amount % UNIT).toString().padStart(18, '0').slice(0, places).replace(/0+$/, '');
  if (amount > 0n && amount < UNIT / 10n ** BigInt(places)) return `<0.${'0'.repeat(places - 1)}1`;
  return `${whole}${fraction ? `.${fraction}` : ''}`;
}
export function exactAmount(value) {
  const amount = BigInt(value);
  return `${amount / UNIT}.${(amount % UNIT).toString().padStart(18, '0')}`.replace(/\.?0+$/, '');
}
export function parseAgent(value) {
  if (!/^\d{1,4}$/.test(value) || Number(value) >= AGENT_COUNT) throw new Error('Choose an agent number from 0 to 1999.');
  return Number(value);
}
export function parseWeek(value) {
  if (!/^[1-9]\d*$/.test(value) || !Number.isSafeInteger(Number(value))) throw new Error('Enter a whole week number, starting at 1.');
  return BigInt(value) - 1n;
}
export function shortAddress(address) { return `${address.slice(0, 6)}…${address.slice(-4)}`; }
export function timeAgo(iso, now = Date.now()) {
  if (!iso) return 'No recorded work';
  const seconds = Math.max(0, Math.floor((now - Date.parse(iso)) / 1000));
  if (seconds < 60) return 'Just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}
