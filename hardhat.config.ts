import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import dotenv from "dotenv";
require('@openzeppelin/hardhat-upgrades');
import { network } from "hardhat";

dotenv.config();
const { PRIVATE_KEY, INFURA_ID, ETHERSCAN_API_KEY, POLYGONSCAN_API_KEY, BSCSCAN_API_KEY, LINEASCAN_API_KEY, ARBISCAN_API_KEY, SCROLLSCAN_API_KEY, BERATRAILSCAN_API_KEY, AMOYSCAN_API_KEY } = process.env;

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 31337
    },
    ethereum: {
      url: "https://mainnet.infura.io/v3/" + INFURA_ID,
      accounts: PRIVATE_KEY!.split(','),
      chainId: 1
    },
    polygon: {
      url: "https://polygon-mainnet.infura.io/v3/" + INFURA_ID,
      accounts: PRIVATE_KEY!.split(','),
      chainId: 137
    },
    sepolia: {
      url: "https://sepolia.infura.io/v3/" + INFURA_ID,
      accounts: PRIVATE_KEY!.split(','),
      chainId: 11155111
    },
  },
  typechain: {
    externalArtifacts: ['./abi/*.json']
  },
  paths: {
    sources: './contracts',
    tests: './test',
    cache: './cache',
    artifacts: './artifacts'
  },
  etherscan: {
    apiKey: {
      sepolia: ETHERSCAN_API_KEY!,
    },
    customChains: []
  },
};

export default config;
