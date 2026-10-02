// Fill in the Sepolia FrogOfTheWeek address from the reviewed deployment handoff.
// The application discovers FROGS via token(); it never trusts a separate token address.
export const config = Object.freeze({
  chainId: 11155111,
  rpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
  frogOfTheWeek: '',
  swarmUrl: 'https://api.imd.fun/swarm',
});
