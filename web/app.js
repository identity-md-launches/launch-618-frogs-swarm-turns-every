import { config } from './config.js';
import { normalizeSwarm, filterAgents, ART, LEVELS, hueOf, formatAmount, exactAmount, parseAgent, parseWeek, shortAddress, timeAgo } from './core.mjs';
import { Rpc, snapshot, castVote, sendTransaction, encode, words, address, friendlyError } from './chain.mjs';

const $ = (id) => document.getElementById(id);
const rpc = new Rpc(config.rpcUrl);
let agents = [], account = null, state = null, busy = false, chainRefreshing = false, swarmRefreshing = false;
let stateAt = 0, statePerformance = 0, walletChain = null, requestVersion = 0;
const provider = window.ethereum;
let configured = false;
try { configured = Boolean(config.frogOfTheWeek && address(config.frogOfTheWeek) && config.chainId === 11155111); } catch { /* Setup message below. */ }
function text(id, value) { $(id).textContent = value; }
function node(tag, className, value) { const el = document.createElement(tag); if (className) el.className = className; if (value !== undefined) el.textContent = value; return el; }
function frogImage(agent, className = '') {
  const image = node('img', className); image.src = `art/${ART[agent?.level ?? 2]}.svg`; image.alt = agent ? `${LEVELS[agent.level]} frog for agent #${agent.id}` : 'Frog'; image.loading = 'lazy'; image.decoding = 'async';
  image.style.filter = `hue-rotate(${agent?.hue ?? 0}deg)`;
  return image;
}
function findAgent(id) { return agents.find((agent) => agent.id === id) ?? { id, level: 0, hue: hueOf(id) }; }
function selectAgent(id) { $('vote-agent').value = String(id); $('voting').scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' }); $('vote-amount').focus({ preventScroll: true }); }
function renderAgents() {
  const result = filterAgents(agents, $('search').value);
  text('result-count', `${result.length.toLocaleString()} of ${agents.length.toLocaleString()} agents`);
  $('no-results').hidden = Boolean(result.length) || !agents.length;
  const fragment = document.createDocumentFragment();
  for (const agent of result) {
    const card = node('article', 'agent-card');
    card.style.setProperty('--frog-back', `hsl(${(94 + agent.hue) % 360} 28% 88%)`);
    const visual = node('div', 'agent-visual'); visual.append(node('span', 'agent-level', LEVELS[agent.level]), frogImage(agent));
    const body = node('div', 'agent-body'), title = node('div', 'agent-title-row');
    const status = node('span', `agent-online ${agent.online === null ? 'unknown' : agent.online ? '' : 'offline'}`);
    status.append(node('i', 'live-dot'), document.createTextNode(agent.working ? 'Working · online' : agent.online === null ? 'Status unknown' : agent.online ? 'Online' : 'Offline'));
    title.append(node('h3', '', `Agent #${agent.id}`), status);
    const metrics = node('dl', 'agent-metrics');
    for (const [label, value] of [['Accepted jobs', agent.accepted.toLocaleString()], ['Acceptance', agent.rate === null ? '—' : `${(agent.rate * 100).toFixed(1)}%`]]) {
      const metric = node('div'); metric.append(node('dt', '', label), node('dd', '', value)); metrics.append(metric);
    }
    const foot = node('div', 'agent-footer'), last = node('span', '', agent.last ? `Last work ${timeAgo(agent.last)}` : 'No recorded work');
    if (agent.last) last.title = new Date(agent.last).toLocaleString();
    const vote = node('button', 'card-vote', 'Vote ↗'); vote.type = 'button'; vote.setAttribute('aria-label', `Vote for agent ${agent.id}`); vote.addEventListener('click', () => selectAgent(agent.id));
    foot.append(last, vote); body.append(title, metrics, foot); card.append(visual, body); fragment.append(card);
  }
  $('agents').replaceChildren(fragment);
}
async function refreshSwarm() {
  if (swarmRefreshing) return;
  swarmRefreshing = true;
  try {
    const response = await fetch(config.swarmUrl, { signal: AbortSignal.timeout(20000), cache: 'no-store' });
    if (!response.ok) throw new Error(`The swarm API is unavailable (${response.status}).`);
    const payload = await response.json(); agents = normalizeSwarm(payload);
    $('api-error').hidden = true;
    const online = payload.health?.agentsOnline;
    text('global-online', Number.isInteger(online) && online >= 0 ? `${online.toLocaleString()} agents online` : 'Online count unavailable');
    text('total-work', `${agents.reduce((sum, agent) => sum + agent.accepted, 0).toLocaleString()} accepted jobs`);
    text('api-updated', `Updated ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`);
    renderAgents(); if (state) renderChain();
  } catch (error) {
    text('api-error', `${friendlyError(error)} ${agents.length ? 'Showing the last successful snapshot; data may be stale.' : 'The directory will retry automatically.'}`);
    $('api-error').hidden = false; text('api-updated', 'Agent data unavailable · retrying');
    if (!agents.length) text('result-count', 'Waiting for live agent data');
  } finally { swarmRefreshing = false; }
}
function renderChain() {
  if (!state) return;
  text('week-label', `WEEK ${state.week + 1n}`);
  text('total-votes', `${formatAmount(state.info[0])} FROGS locked`);
  $('total-votes').title = `${exactAmount(state.info[0])} FROGS`;
  const top = state.votes.map((amount, id) => ({ amount, id })).filter((entry) => entry.amount > 0n).sort((a, b) => a.amount === b.amount ? a.id - b.id : a.amount > b.amount ? -1 : 1).slice(0, 5);
  const leaders = document.createDocumentFragment();
  if (!top.length) leaders.append(node('li', 'empty-note', 'A fresh week, a fresh lily pad. Cast the first vote.'));
  top.forEach((entry, index) => {
    const row = node('li', 'leader'), button = node('button', 'leader-button', `Agent #${entry.id}`); button.type = 'button'; button.addEventListener('click', () => selectAgent(entry.id));
    const amount = node('strong', '', `${formatAmount(entry.amount)} FROGS`); amount.title = `${exactAmount(entry.amount)} FROGS`;
    row.append(node('span', 'leader-rank', String(index + 1).padStart(2, '0')), frogImage(findAgent(entry.id)), button, amount); leaders.append(row);
  });
  $('leaders').replaceChildren(leaders);
  const champion = document.createDocumentFragment();
  if (state.champion && state.champion[3] === 1n && state.champion[4] < 2000n && state.champion[0] > 0n) {
    const id = Number(state.champion[4]); champion.append(node('span', 'champion-crown', '♛'), frogImage(findAgent(id), 'champion-frog'), node('h3', '', `Agent #${id}`), node('p', '', `${formatAmount(state.champion[2])} FROGS voted for this little legend.`));
    text('champion-foot', `Winner of week ${state.cursor} · ${LEVELS[findAgent(id).level]} today`);
  } else {
    champion.append(node('div', 'crown-outline', '♛'), node('h3', '', state.cursor > 0n ? 'No votes, no crown' : 'The crown awaits'), node('p', '', state.cursor > 0n ? `Week ${state.cursor} ended without votes. Make this week count.` : 'A winner appears here after a week is finalized.'));
    text('champion-foot', 'Chosen by the holders of FROGS.');
  }
  $('champion-body').replaceChildren(champion);
  text('balance', account && state.balance !== null ? `${formatAmount(state.balance)} FROGS` : 'Connect to view');
  $('balance').title = state.balance !== null ? `${exactAmount(state.balance)} FROGS` : '';
  text('finalize-copy', state.cursor < state.week ? `Week ${state.cursor + 1n} is ready. Finalize oldest weeks first.` : 'The current week has not ended yet.');
  updateCountdown(); updateButtons();
}
function updateCountdown() {
  if (!state) return;
  const now = state.timestamp + (performance.now() - statePerformance) / 1000;
  const remaining = Math.max(0, Math.floor(state.end - now));
  const days = Math.floor(remaining / 86400), hours = Math.floor(remaining % 86400 / 3600), minutes = Math.floor(remaining % 3600 / 60), seconds = remaining % 60;
  text('countdown', `${days}d ${String(hours).padStart(2, '0')}h ${String(minutes).padStart(2, '0')}m ${String(seconds).padStart(2, '0')}s`);
  if (Date.now() - stateAt > 120000) {
    text('chain-status', 'Voting data is stale. Reconnecting to Sepolia; actions resume after a fresh snapshot.'); $('chain-status').classList.add('error');
  }
  updateButtons();
}
function updateButtons() {
  const ready = configured && state && account && walletChain === 11155111n && !busy && Date.now() - stateAt < 120000;
  $('connect').disabled = busy;
  $('vote-button').disabled = !ready || state.end <= state.timestamp + (performance.now() - statePerformance) / 1000;
  $('withdraw-button').disabled = !ready;
  $('finalize-button').disabled = !ready || state.cursor >= state.week;
}
async function refreshChain() {
  if (!configured || chainRefreshing) return;
  chainRefreshing = true;
  const version = requestVersion;
  try {
    const next = await snapshot(rpc, config.frogOfTheWeek, account);
    if (version !== requestVersion) return;
    state = next; stateAt = Date.now(); statePerformance = performance.now();
    $('chain-status').classList.remove('error');
    text('chain-status', `Live on Sepolia · week ${state.week + 1n} · voting contract ${shortAddress(state.contract)} · refreshed ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`);
    if (!$('withdraw-week').value && state.week > 0n) $('withdraw-week').value = String(state.week);
    renderChain(); await refreshLocked();
  } catch (error) {
    text('chain-status', `${friendlyError(error)} ${state ? 'Last successful voting data remains visible.' : 'Voting is temporarily unavailable.'}`); $('chain-status').classList.add('error');
  } finally { chainRefreshing = false; updateButtons(); if (version !== requestVersion) queueMicrotask(refreshChain); }
}
async function refreshLocked() {
  if (!account || !state || !$('withdraw-week').value) { text('withdraw-balance', ''); return; }
  const version = requestVersion, selected = $('withdraw-week').value, selectedAccount = account;
  try {
    const week = parseWeek(selected);
    const locked = words(await rpc.call(state.contract, 'locked', [week, selectedAccount]), 1)[0];
    if (version !== requestVersion || selected !== $('withdraw-week').value) return;
    text('withdraw-balance', `${formatAmount(locked)} FROGS ${week < state.week ? 'available to withdraw' : 'locked until this week ends'}.`);
    $('withdraw-balance').title = `${exactAmount(locked)} FROGS`;
  } catch (error) { if (version === requestVersion) text('withdraw-balance', friendlyError(error)); }
}
function onHash(hash) {
  $('transaction-link').href = `https://sepolia.etherscan.io/tx/${hash}`; $('transaction-link').hidden = false;
  text('action-status', 'Transaction submitted. Waiting for Sepolia confirmation…');
}
async function action(work) {
  if (busy) return;
  busy = true; updateButtons(); $('transaction-link').hidden = true; text('action-status', 'Review the request in your wallet.');
  try {
    if (!configured || !state) throw new Error('Voting is available after a Sepolia deployment is configured.');
    if (!account || !provider) throw new Error('Connect a wallet on Sepolia first.');
    await work();
  } catch (error) { text('action-status', friendlyError(error)); }
  finally { busy = false; updateButtons(); await refreshChain(); }
}
async function connectWallet() {
  if (!provider) { text('action-status', 'No Ethereum wallet was found. Open this site in a wallet browser or install an EIP-1193 wallet.'); return; }
  try {
    const accounts = await provider.request({ method: 'eth_requestAccounts' });
    if (!accounts[0]) throw new Error('No wallet account was shared.');
    let chain = BigInt(await provider.request({ method: 'eth_chainId' }));
    if (chain !== 11155111n) {
      try { await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xaa36a7' }] }); }
      catch (error) {
        if (error.code !== 4902) throw error;
        await provider.request({ method: 'wallet_addEthereumChain', params: [{ chainId: '0xaa36a7', chainName: 'Ethereum Sepolia', nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: [config.rpcUrl], blockExplorerUrls: ['https://sepolia.etherscan.io'] }] });
      }
      chain = BigInt(await provider.request({ method: 'eth_chainId' }));
    }
    const current = await provider.request({ method: 'eth_accounts' });
    if (!current[0]) throw new Error('Wallet disconnected.');
    account = address(current[0]); walletChain = chain; requestVersion++; stateAt = 0; if (state) state.balance = null;
    text('connect', shortAddress(account)); text('wallet-network', chain === 11155111n ? 'Connected to Ethereum Sepolia.' : 'Switch your wallet to Ethereum Sepolia.');
    text('action-status', chain === 11155111n ? 'Wallet connected. Choose a frog to back.' : 'Switch your wallet to Ethereum Sepolia.');
    await refreshChain(); updateButtons();
  } catch (error) { text('action-status', friendlyError(error)); }
}
$('connect').addEventListener('click', connectWallet);
$('search').addEventListener('input', renderAgents);
$('withdraw-week').addEventListener('change', refreshLocked);
$('vote-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const selectedState = state, selectedAccount = account;
  action(async () => {
    const agentId = parseAgent($('vote-agent').value.trim()), amount = $('vote-amount').value.trim();
    await castVote({ provider, rpc, account: selectedAccount, contract: selectedState.contract, token: selectedState.token, expectedWeek: selectedState.week, agentId, amount, onStatus: (status) => text('action-status', status), onHash });
    text('action-status', `Vote confirmed for agent #${agentId} in week ${selectedState.week + 1n}. Your FROGS are locked until that week ends.`);
  });
});
$('withdraw-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const selectedAccount = account, selectedState = state;
  action(async () => {
    const week = parseWeek($('withdraw-week').value.trim());
    const current = words(await rpc.call(selectedState.contract, 'currentWeek'), 1)[0];
    if (week >= current) throw new Error('That week has not ended. FROGS can be withdrawn after its deadline.');
    if (words(await rpc.call(selectedState.contract, 'locked', [week, selectedAccount]), 1)[0] === 0n) throw new Error('This wallet has no FROGS to withdraw from that week.');
    await sendTransaction({ provider, rpc, account: selectedAccount, to: selectedState.contract, data: encode('withdraw', [week]), onHash });
    text('action-status', `Withdrawal confirmed. All your locked FROGS from week ${week + 1n} are back in your wallet.`);
  });
});
$('finalize-button').addEventListener('click', () => {
  const selectedAccount = account, selectedState = state;
  action(async () => {
    await sendTransaction({ provider, rpc, account: selectedAccount, to: selectedState.contract, data: encode('finalize'), onHash });
    text('action-status', 'Week finalized. The recorded winner and vote totals are permanent.');
  });
});
if (provider?.on) {
  provider.on('accountsChanged', (accounts) => {
    account = accounts[0] ? address(accounts[0]) : null; requestVersion++; stateAt = 0; if (state) state.balance = null;
    text('connect', account ? shortAddress(account) : 'Connect wallet ↗'); text('balance', account ? 'Refreshing…' : 'Connect to view');
    text('withdraw-balance', ''); updateButtons(); refreshChain();
  });
  provider.on('chainChanged', (chain) => { walletChain = BigInt(chain); requestVersion++; stateAt = 0; text('wallet-network', walletChain === 11155111n ? 'Connected to Ethereum Sepolia.' : 'Switch your wallet to Ethereum Sepolia.'); updateButtons(); refreshChain(); });
  provider.on('disconnect', () => { account = null; walletChain = null; requestVersion++; stateAt = 0; if (state) state.balance = null; text('connect', 'Connect wallet ↗'); text('balance', 'Connect to view'); text('withdraw-balance', ''); updateButtons(); });
}
if (!configured) text('chain-status', 'The pond is open. Voting is not configured for this site yet. The live agent directory is available; crowns and voting open with the Sepolia deployment.');
refreshSwarm(); refreshChain();
setInterval(() => { if (!document.hidden) refreshSwarm(); }, 60000);
setInterval(() => { if (!document.hidden) refreshChain(); }, 30000);
setInterval(updateCountdown, 1000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) { refreshSwarm(); refreshChain(); } });
