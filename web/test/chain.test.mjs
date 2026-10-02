import test from 'node:test';
import assert from 'node:assert/strict';
import { Rpc, SELECTORS, address, encode, words, decodedAddress, walletIdentity, castVote, sendTransaction, waitReceipt, snapshot, friendlyError } from '../chain.mjs';
import { UNIT } from '../core.mjs';
const ACCOUNT = `0x${'11'.repeat(20)}`, OTHER = `0x${'22'.repeat(20)}`, CONTRACT = `0x${'33'.repeat(20)}`, TOKEN = `0x${'44'.repeat(20)}`, HASH = `0x${'ab'.repeat(32)}`;
const abi = (...values) => `0x${values.map((value) => BigInt(value).toString(16).padStart(64, '0')).join('')}`;
function fixture({ allowance = 0n, balance = 100n * UNIT, initialWeek = 3n, laterWeek = 3n, mutateOnApproval = null, receiptStatus = '0x1' } = {}) {
  const txs = [], calls = []; let account = ACCOUNT, chainId = '0xaa36a7', weekReads = 0;
  const provider = { async request({ method, params }) {
    if (method === 'eth_accounts') return [account];
    if (method === 'eth_chainId') return chainId;
    if (method === 'eth_sendTransaction') { txs.push(params[0]); if (txs.length === 1 && mutateOnApproval) { if (mutateOnApproval === 'account') account = OTHER; else chainId = '0x1'; } return HASH; }
    throw new Error(`Unexpected method ${method}`);
  }};
  const rpc = { async call(to, method, args = []) { calls.push({ to, method, args }); if (method === 'currentWeek') return abi(++weekReads === 1 ? initialWeek : laterWeek); if (method === 'balanceOf') return abi(balance); if (method === 'allowance') return abi(allowance); throw new Error(`Unexpected call ${method}`); }, async request(method) { assert.equal(method, 'eth_getTransactionReceipt'); return { status: receiptStatus }; }};
  const vote = (overrides = {}) => castVote({ provider, rpc, account: ACCOUNT, contract: CONTRACT, token: TOKEN, expectedWeek: 3n, agentId: 1999, amount: '12.000000000000000001', ...overrides });
  return { provider, rpc, txs, calls, vote };
}
test('ABI encoding and decoding match fixed selectors and preserve 256-bit values', () => {
  assert.equal(encode('vote', [3n, 1999, UNIT]), `0x8a6655d6${abi(3n, 1999n, UNIT).slice(2)}`);
  assert.equal(encode('approve', [CONTRACT, 1n]), `0x095ea7b3${CONTRACT.slice(2).padStart(64, '0')}${'1'.padStart(64, '0')}`);
  assert.deepEqual(words(abi(0n, (1n << 256n) - 1n), 2), [0n, (1n << 256n) - 1n]);
  assert.equal(decodedAddress(abi(BigInt(TOKEN))), TOKEN);
  for (const data of ['0x', '0x11', 'garbage']) assert.throws(() => words(data));
  assert.throws(() => words(abi(1n), 2)); assert.throws(() => decodedAddress(abi(1n << 160n)));
  assert.throws(() => encode('unknown')); assert.throws(() => encode('vote', [-1n])); assert.throws(() => encode('vote', [1n << 256n]));
  assert.throws(() => address(`0x${'0'.repeat(40)}`)); assert.throws(() => address('0x1234'));
});
test('first vote approves the exact amount, waits for receipt, then sends the expected week', async () => {
  const { vote, txs } = fixture(); await vote();
  assert.equal(txs.length, 2); assert.equal(txs[0].to, TOKEN); assert.equal(txs[1].to, CONTRACT);
  assert.equal(txs[0].data, encode('approve', [CONTRACT, 12n * UNIT + 1n]));
  assert.equal(txs[1].data, encode('vote', [3n, 1999, 12n * UNIT + 1n]));
  assert.ok(txs.every((tx) => tx.from === ACCOUNT && tx.chainId === '0xaa36a7'));
});
test('existing sufficient allowance skips approval without skipping account/week validation', async () => {
  const { vote, txs, calls } = fixture({ allowance: 20n * UNIT }); await vote();
  assert.equal(txs.length, 1); assert.ok(txs[0].data.startsWith(`0x${SELECTORS.vote}`));
  assert.equal(calls.filter((call) => call.method === 'currentWeek').length, 2);
});
test('insufficient funds, invalid precision, invalid agent, and stale week send no transactions', async () => {
  for (const [options, overrides, pattern] of [[{ balance: 1n }, {}, /balance is too low/], [{}, { amount: '0.0000000000000000001' }, /18 decimal/], [{}, { agentId: 2000 }, /between 0 and 1999/], [{ initialWeek: 4n }, {}, /week changed/]]) {
    const { vote, txs } = fixture(options); await assert.rejects(vote(overrides), pattern); assert.equal(txs.length, 0);
  }
});
test('a week rolling over during approval cannot lock funds into an unintended week', async () => {
  const { vote, txs } = fixture({ laterWeek: 4n }); await assert.rejects(vote(), /week ended during approval/);
  assert.equal(txs.length, 1); assert.equal(txs[0].to, TOKEN);
});
test('account changes during approval stop before vote', async () => {
  const { vote, txs } = fixture({ mutateOnApproval: 'account' }); await assert.rejects(vote(), /account changed/); assert.equal(txs.length, 1);
});
test('chain changes during approval stop before vote', async () => {
  const { vote, txs } = fixture({ mutateOnApproval: 'chain' }); await assert.rejects(vote(), /Ethereum Sepolia/); assert.equal(txs.length, 1);
});
test('reverted approval cannot be followed by a vote', async () => {
  const { vote, txs } = fixture({ receiptStatus: '0x0' }); await assert.rejects(vote(), /reverted/); assert.equal(txs.length, 1);
});
test('wallet rejection is reported, and no receipt or follow-on transaction is attempted', async () => {
  const { provider, rpc } = fixture(); const original = provider.request;
  provider.request = async (request) => { if (request.method === 'eth_sendTransaction') throw Object.assign(new Error('user rejected'), { code: 4001 }); return original(request); };
  await assert.rejects(sendTransaction({ provider, rpc, account: ACCOUNT, to: CONTRACT, data: encode('finalize') }), { code: 4001 });
  assert.match(friendlyError({ code: 4001 }), /declined/);
});
test('disconnected accounts and wrong networks fail before sending', async () => {
  await assert.rejects(walletIdentity({ request: async ({ method }) => method === 'eth_accounts' ? [] : '0xaa36a7' }, ACCOUNT), /account changed/);
  await assert.rejects(walletIdentity({ request: async ({ method }) => method === 'eth_accounts' ? [ACCOUNT] : '0x1' }, ACCOUNT), /Ethereum Sepolia/);
});
test('receipt polling distinguishes pending, success, timeout, and revert', async () => {
  let calls = 0;
  const receipt = await waitReceipt({ request: async () => ++calls < 3 ? null : { status: '0x1' } }, HASH, { attempts: 3, sleep: async () => {} });
  assert.equal(receipt.status, '0x1'); assert.equal(calls, 3);
  await assert.rejects(waitReceipt({ request: async () => null }, HASH, { attempts: 2, sleep: async () => {} }), /still unconfirmed/);
  await assert.rejects(waitReceipt({ request: async () => ({ status: '0x0' }) }, HASH), /reverted/);
  await assert.rejects(waitReceipt({}, 'not-a-hash'), /invalid transaction hash/);
});
test('RPC propagates HTTP failures, JSON-RPC failures, and malformed responses', async () => {
  await assert.rejects(new Rpc('rpc', async () => ({ ok: false, status: 429 })).request('eth_chainId'), /429/);
  await assert.rejects(new Rpc('rpc', async () => ({ ok: true, json: async () => ({ error: { message: 'rate limited' } }) })).request('eth_chainId'), /rate limited/);
  await assert.rejects(new Rpc('rpc', async () => ({ ok: true, json: async () => ({}) })).request('eth_chainId'), /Invalid/);
  const rpc = new Rpc('rpc', async (_url, options) => { const body = JSON.parse(options.body); assert.equal(body.method, 'eth_chainId'); return { ok: true, json: async () => ({ result: '0xaa36a7' }) }; });
  assert.equal(await rpc.request('eth_chainId'), '0xaa36a7');
});
test('snapshot pins every contract read to one block and validates rules and decimals', async () => {
  const pins = [];
  const values = { token: abi(BigInt(TOKEN)), startTime: abi(100n), WEEK_DURATION: abi(604800n), AGENT_COUNT: abi(2000n), NO_WINNER: abi(2000n), currentWeek: abi(1n), nextWeekToFinalize: abi(1n), decimals: abi(18n), getVotes: abi(...Array(2000).fill(0n)), weekInfo: abi(0n, 2000n, 0n, 1n, 2000n), balanceOf: abi(50n * UNIT) };
  const rpc = { request: async (method) => method === 'eth_chainId' ? '0xaa36a7' : { number: '0x100', timestamp: '0x93ae4' }, call: async (_to, method, _args, block) => { pins.push(block); return values[method]; } };
  const result = await snapshot(rpc, CONTRACT, ACCOUNT);
  assert.equal(result.token, TOKEN); assert.equal(result.balance, 50n * UNIT); assert.equal(result.votes.length, 2000); assert.equal(result.end, 1209700); assert.equal(result.champion[4], 2000n);
  assert.ok(pins.every((block) => block === '0x100'));
  values.decimals = abi(6n); await assert.rejects(snapshot(rpc, CONTRACT), /18 decimals/);
  values.decimals = abi(18n); values.WEEK_DURATION = abi(1n); await assert.rejects(snapshot(rpc, CONTRACT), /unexpected voting rules/);
  await assert.rejects(snapshot({ request: async () => '0x1' }, CONTRACT), /Ethereum Sepolia/);
});
