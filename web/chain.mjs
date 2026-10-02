import { parseAmount } from './core.mjs';
export const SELECTORS = Object.freeze({ token: 'fc0c546a', startTime: '78e97925', WEEK_DURATION: '76f5f700', AGENT_COUNT: '90a56671', NO_WINNER: '0606d17a', currentWeek: '06575c89', nextWeekToFinalize: 'fabe6873', vote: '8a6655d6', finalize: '4bb278f3', withdraw: '2e1a7d4d', locked: '24ef458a', weekInfo: '378f56a4', getVotes: 'ff981099', balanceOf: '70a08231', allowance: 'dd62ed3e', approve: '095ea7b3', decimals: '313ce567' });
export function address(value) {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value) || /^0x0{40}$/i.test(value)) throw new Error('A nonzero Ethereum contract or wallet address is required.');
  return value.toLowerCase();
}
export function encode(name, args = []) {
  if (!SELECTORS[name]) throw new Error('Unknown contract method.');
  return `0x${SELECTORS[name]}${args.map((arg) => {
    if (typeof arg === 'string' && /^0x[0-9a-fA-F]{40}$/.test(arg)) return arg.slice(2).toLowerCase().padStart(64, '0');
    const n = BigInt(arg);
    if (n < 0n || n >= 1n << 256n) throw new Error('Integer outside uint256.');
    return n.toString(16).padStart(64, '0');
  }).join('')}`;
}
export function words(data, expected) {
  if (typeof data !== 'string' || !/^0x(?:[0-9a-fA-F]{64})+$/.test(data)) throw new Error('The contract returned invalid ABI data.');
  const result = data.slice(2).match(/.{64}/g).map((word) => BigInt(`0x${word}`));
  if (expected !== undefined && result.length !== expected) throw new Error('The configured contract does not match FrogOfTheWeek.');
  return result;
}
export function decodedAddress(data) {
  const n = words(data, 1)[0];
  if (n >= 1n << 160n) throw new Error('Invalid token address response.');
  return address(`0x${n.toString(16).padStart(40, '0')}`);
}
export class Rpc {
  constructor(url, fetcher = fetch) { this.url = url; this.fetcher = fetcher; this.id = 0; }
  async request(method, params = []) {
    const response = await this.fetcher(this.url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++this.id, method, params }), signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new Error(`Sepolia RPC unavailable (${response.status}).`);
    const json = await response.json();
    if (json.error) throw new Error(json.error.message || 'Sepolia RPC rejected the request.');
    if (!Object.hasOwn(json, 'result')) throw new Error('Invalid Sepolia RPC response.');
    return json.result;
  }
  call(to, method, args = [], block = 'latest') { return this.request('eth_call', [{ to, data: encode(method, args) }, block]); }
}
export async function snapshot(rpc, contract, account = null) {
  contract = address(contract);
  if (BigInt(await rpc.request('eth_chainId')) !== 11155111n) throw new Error('The configured RPC must serve Ethereum Sepolia.');
  const block = await rpc.request('eth_getBlockByNumber', ['latest', false]);
  if (!block?.number || !block?.timestamp) throw new Error('No latest Sepolia block is available.');
  const call = (method, args = []) => rpc.call(contract, method, args, block.number);
  const [tokenData, startData, durationData, countData, sentinelData, weekData, cursorData] = await Promise.all(['token', 'startTime', 'WEEK_DURATION', 'AGENT_COUNT', 'NO_WINNER', 'currentWeek', 'nextWeekToFinalize'].map((method) => call(method)));
  const token = decodedAddress(tokenData);
  const start = words(startData, 1)[0], duration = words(durationData, 1)[0], week = words(weekData, 1)[0], cursor = words(cursorData, 1)[0];
  if (duration !== 604800n || words(countData, 1)[0] !== 2000n || words(sentinelData, 1)[0] !== 2000n) throw new Error('The configured contract has unexpected voting rules.');
  if (words(await rpc.call(token, 'decimals', [], block.number), 1)[0] !== 18n) throw new Error('FROGS must use 18 decimals.');
  const [voteData, infoData, championData, balanceData] = await Promise.all([call('getVotes', [week]), call('weekInfo', [week]), cursor > 0n ? call('weekInfo', [cursor - 1n]) : null, account ? rpc.call(token, 'balanceOf', [address(account)], block.number) : null]);
  return { contract, token, start, duration, week, cursor, votes: words(voteData, 2000), info: words(infoData, 5), champion: championData ? words(championData, 5) : null, balance: balanceData ? words(balanceData, 1)[0] : null, timestamp: Number(BigInt(block.timestamp)), end: Number(start + (week + 1n) * duration), block: block.number };
}
export async function walletIdentity(provider, expectedAccount, expectedChain = 11155111n) {
  const [accounts, chain] = await Promise.all([provider.request({ method: 'eth_accounts' }), provider.request({ method: 'eth_chainId' })]);
  if (BigInt(chain) !== expectedChain) throw new Error('Switch your wallet to Ethereum Sepolia.');
  if (!accounts[0] || address(accounts[0]) !== address(expectedAccount)) throw new Error('Wallet account changed. Review the action and try again.');
}
export async function waitReceipt(rpc, hash, { attempts = 90, interval = 2000, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) } = {}) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) throw new Error('The wallet returned an invalid transaction hash.');
  for (let i = 0; i < attempts; i++) {
    const receipt = await rpc.request('eth_getTransactionReceipt', [hash]);
    if (receipt) {
      if (BigInt(receipt.status) !== 1n) throw new Error('Transaction reverted. No action was recorded.');
      return receipt;
    }
    await sleep(interval);
  }
  throw new Error('Transaction is still unconfirmed. Check its explorer link before trying again.');
}
export async function sendTransaction({ provider, rpc, account, to, data, onHash = () => {} }) {
  await walletIdentity(provider, account);
  const hash = await provider.request({ method: 'eth_sendTransaction', params: [{ from: address(account), to: address(to), data, chainId: '0xaa36a7' }] });
  onHash(hash);
  await waitReceipt(rpc, hash);
  return hash;
}
export async function castVote({ provider, rpc, account, contract, token, expectedWeek, agentId, amount: amountString, onStatus = () => {}, onHash }) {
  const amount = parseAmount(amountString);
  if (!Number.isInteger(agentId) || agentId < 0 || agentId >= 2000) throw new Error('Agent number must be between 0 and 1999.');
  await walletIdentity(provider, account);
  const [weekData, balanceData, allowanceData] = await Promise.all([rpc.call(contract, 'currentWeek'), rpc.call(token, 'balanceOf', [account]), rpc.call(token, 'allowance', [account, contract])]);
  if (words(weekData, 1)[0] !== BigInt(expectedWeek)) throw new Error('The week changed. Refresh and review your vote.');
  if (words(balanceData, 1)[0] < amount) throw new Error('Your FROGS balance is too low for this vote.');
  if (words(allowanceData, 1)[0] < amount) {
    onStatus('Approve this exact FROGS amount in your wallet.');
    await sendTransaction({ provider, rpc, account, to: token, data: encode('approve', [contract, amount]), onHash });
  }
  await walletIdentity(provider, account);
  if (words(await rpc.call(contract, 'currentWeek'), 1)[0] !== BigInt(expectedWeek)) throw new Error('The week ended during approval. Your tokens were not locked; review the new week before voting.');
  onStatus('Confirm your vote in your wallet.');
  return sendTransaction({ provider, rpc, account, to: contract, data: encode('vote', [expectedWeek, agentId, amount]), onHash });
}
export function friendlyError(error) {
  return error?.code === 4001 ? 'Request declined in your wallet. No new transaction was sent.' : error?.message || 'The request failed. Please try again.';
}
