require('@nomicfoundation/hardhat-toolbox');
require('@nomicfoundation/hardhat-verify');

/** @type {import('hardhat/config').HardhatUserConfig} */
const config = {
  solidity: {
    version: '0.8.24',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
    remappings: [
      '@openzeppelin/=lib/openzeppelin-contracts/',
      '@limitbreak/creator-token-standards/=lib/creator-token-standards/',
      '@limitbreak/permit-c/=lib/creator-token-standards/lib/permit-c/',
    ],
  },
  paths: {
    sources: './contract',
    tests: './test/hardhat',
    cache: './cache',
    artifacts: './artifacts',
  },
  networks: {
    hardhat: {
      chainId: 1337,
    },
    localhost: {
      url: 'http://127.0.0.1:8545',
      chainId: 1337,
    },
  },
  mocha: {
    timeout: 40000,
  },
};

module.exports = config;
