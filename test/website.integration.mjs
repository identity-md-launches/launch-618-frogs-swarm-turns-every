// Runs entirely against a disposable local Anvil chain. No keys or external network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { Rpc, snapshot, castVote, sendTransaction, waitReceipt, encode, words, SELECTORS } from '../web/chain.mjs';
import { UNIT } from '../web/core.mjs';

const signatures = {
  token: 'token()', startTime: 'startTime()', WEEK_DURATION: 'WEEK_DURATION()',
  AGENT_COUNT: 'AGENT_COUNT()', NO_WINNER: 'NO_WINNER()', currentWeek: 'currentWeek()',
  nextWeekToFinalize: 'nextWeekToFinalize()', vote: 'vote(uint256,uint256,uint256)',
  finalize: 'finalize()', withdraw: 'withdraw(uint256)', locked: 'locked(uint256,address)',
  weekInfo: 'weekInfo(uint256)', getVotes: 'getVotes(uint256)', balanceOf: 'balanceOf(address)',
  allowance: 'allowance(address,address)', approve: 'approve(address,uint256)', decimals: 'decimals()',
};

test('every website selector matches its Solidity signature', () => {
  for (const [name, signature] of Object.entries(signatures)) {
    const result = spawnSync('cast', ['sig', signature], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(`0x${SELECTORS[name]}`, result.stdout.trim(), signature);
  }
});

test('website client approves, votes, crowns, refunds and survives missed weeks on real bytecode', { timeout: 90000 }, async (t) => {
  const portProbe = createServer();
  portProbe.listen(0, '127.0.0.1');
  await once(portProbe, 'listening');
  const port = portProbe.address().port;
  await new Promise((resolve) => portProbe.close(resolve));
  const child = spawn('anvil', ['--host', '127.0.0.1', '--port', String(port), '--chain-id', '11155111', '--silent'], { stdio: ['ignore', 'ignore', 'pipe'] });
  let launchError;
  child.on('error', (error) => { launchError = error; });
  t.after(async () => {
    if (child.exitCode === null && child.pid) {
      const ended = once(child, 'exit');
      child.kill('SIGTERM');
      await ended;
    }
  });
  const rpc = new Rpc(`http://127.0.0.1:${port}`);
  let accounts;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (launchError) throw launchError;
    try { accounts = await rpc.request('eth_accounts'); break; }
    catch { await new Promise((resolve) => setTimeout(resolve, 50)); }
  }
  assert.ok(accounts?.length >= 2, 'Anvil did not start');
  const [alice, bob] = accounts;
  const providerFor = (account) => ({ request: ({ method, params = [] }) => method === 'eth_accounts' ? Promise.resolve([account]) : rpc.request(method, params) });
  const aliceProvider = providerFor(alice), bobProvider = providerFor(bob);
  const tokenArtifact = JSON.parse(await readFile(new URL('../out/LaunchToken.sol/LaunchToken.json', import.meta.url), 'utf8'));
  const appArtifact = JSON.parse(await readFile(new URL('../out/FrogOfTheWeek.sol/FrogOfTheWeek.json', import.meta.url), 'utf8'));
  const deploy = async (data) => {
    const hash = await rpc.request('eth_sendTransaction', [{ from: alice, data, gas: '0x989680' }]);
    const receipt = await waitReceipt(rpc, hash, { interval: 25 });
    assert.equal(receipt.status, '0x1');
    return receipt.contractAddress;
  };
  const token = await deploy(tokenArtifact.bytecode.object);
  const contract = await deploy(appArtifact.bytecode.object + token.slice(2).padStart(64, '0'));
  let state = await snapshot(rpc, contract, alice);
  assert.equal(state.token, token);
  assert.equal(state.balance, 1_000_000_000n * UNIT);
  assert.equal(state.week, 0n);
  assert.equal(state.champion, null);
  assert.equal(state.info[1], 2000n);
  const initialBalance = state.balance;
  const transferData = '0xa9059cbb' + bob.slice(2).padStart(64, '0') + (20n * UNIT).toString(16).padStart(64, '0');
  await sendTransaction({ provider: aliceProvider, rpc, account: alice, to: token, data: transferData });
  const hashes = [];
  await castVote({ provider: aliceProvider, rpc, account: alice, contract, token, expectedWeek: 0n, agentId: 1999, amount: '12.5', onHash: (hash) => hashes.push(hash) });
  assert.equal(hashes.length, 2, 'exact approval followed by vote');
  assert.equal(words(await rpc.call(token, 'allowance', [alice, contract]), 1)[0], 0n);
  await castVote({ provider: bobProvider, rpc, account: bob, contract, token, expectedWeek: 0n, agentId: 0, amount: '12.5' });
  state = await snapshot(rpc, contract, alice);
  assert.equal(state.info[0], 25n * UNIT);
  assert.equal(state.info[1], 0n, 'lower agent wins tie');
  assert.equal(state.votes[1999], 125n * UNIT / 10n);
  assert.equal(state.votes[0], 125n * UNIT / 10n);
  assert.equal(words(await rpc.call(contract, 'locked', [0n, alice]), 1)[0], 125n * UNIT / 10n);
  await assert.rejects(sendTransaction({ provider: aliceProvider, rpc, account: alice, to: contract, data: encode('withdraw', [0n]) }));
  await rpc.request('evm_setNextBlockTimestamp', [Number(state.start + state.duration)]);
  await rpc.request('evm_mine');
  await assert.rejects(castVote({ provider: aliceProvider, rpc, account: alice, contract, token, expectedWeek: 0n, agentId: 2, amount: '1' }), /week changed/);
  // Refund before any finalization is an essential liveness property.
  await sendTransaction({ provider: aliceProvider, rpc, account: alice, to: contract, data: encode('withdraw', [0n]) });
  assert.equal(words(await rpc.call(token, 'balanceOf', [alice]), 1)[0], initialBalance - 20n * UNIT);
  await sendTransaction({ provider: bobProvider, rpc, account: bob, to: contract, data: encode('finalize') });
  state = await snapshot(rpc, contract, bob);
  assert.equal(state.cursor, 1n);
  assert.equal(state.champion[3], 1n);
  assert.equal(state.champion[4], 0n);
  assert.equal(state.champion[2], 125n * UNIT / 10n);
  await sendTransaction({ provider: bobProvider, rpc, account: bob, to: contract, data: encode('withdraw', [0n]) });
  assert.equal(words(await rpc.call(token, 'balanceOf', [bob]), 1)[0], 20n * UNIT);
  assert.equal(words(await rpc.call(contract, 'getVotes', [0n]), 2000)[1999], 125n * UNIT / 10n, 'history remains after refunds');
  await assert.rejects(sendTransaction({ provider: bobProvider, rpc, account: bob, to: contract, data: encode('withdraw', [0n]) }));
  await castVote({ provider: aliceProvider, rpc, account: alice, contract, token, expectedWeek: 1n, agentId: 4, amount: '3' });
  await rpc.request('evm_setNextBlockTimestamp', [Number(state.start + 3n * state.duration)]);
  await rpc.request('evm_mine');
  await sendTransaction({ provider: aliceProvider, rpc, account: alice, to: contract, data: encode('withdraw', [1n]) });
  await sendTransaction({ provider: bobProvider, rpc, account: bob, to: contract, data: encode('finalize') });
  assert.equal((await snapshot(rpc, contract)).champion[4], 4n);
  await sendTransaction({ provider: bobProvider, rpc, account: bob, to: contract, data: encode('finalize') });
  state = await snapshot(rpc, contract);
  assert.equal(state.week, 3n);
  assert.equal(state.cursor, 3n);
  assert.equal(state.champion[4], 2000n, 'empty week has no fabricated champion');
  assert.equal(words(await rpc.call(token, 'balanceOf', [contract]), 1)[0], 0n);
});
