import * as dotenv from "dotenv";
import { ethers, run } from "hardhat";
import { join } from "path";
import readline from "readline";

import {
  DepositSecurityModule,
  DepositSecurityModule__factory,
  LidoLocator,
  LidoLocator__factory,
} from "typechain-types";

import {
  cy,
  deployImplementation,
  deployWithoutProxy,
  loadContract,
  log,
  persistNetworkState,
  rd,
  readNetworkState,
  Sk,
  updateObjectInState,
} from "lib";

dotenv.config({ path: join(__dirname, "../../.env") });

function getEnvVariable(name: string, defaultValue?: string) {
  const value = process.env[name];
  if (value === undefined) {
    if (defaultValue === undefined) {
      throw new Error(`Env variable ${name} must be set`);
    }
    return defaultValue;
  } else {
    log(`Using env variable ${name}=${value}`);
    return value;
  }
}

// Accounting Oracle args
const SECONDS_PER_SLOT = 12;
const GENESIS_TIME = 1606824023;

// Oracle report sanity checker
const EXITED_VALIDATORS_PER_DAY_LIMIT = 9000;
const APPEARED_VALIDATORS_PER_DAY_LIMIT = 43200;
const ANNUAL_BALANCE_INCREASE_BP_LIMIT = 1000;
const SIMULATED_SHARE_RATE_DEVIATION_BP_LIMIT = 50;
const MAX_VALIDATOR_EXIT_REQUESTS_PER_REPORT = 600;
const MAX_ITEMS_PER_EXTRA_DATA_TRANSACTION = 8;
const MAX_NODE_OPERATORS_PER_EXTRA_DATA_ITEM = 24;
const REQUEST_TIMESTAMP_MARGIN = 7680;
const MAX_POSITIVE_TOKEN_REBASE = 750000;
const INITIAL_SLASHING_AMOUNT_P_WEI = 1000;
const INACTIVITY_PENALTIES_AMOUNT_P_WEI = 101;
const CL_BALANCE_ORACLES_ERROR_UPPER_BP_LIMIT = 74;

const LIMITS = [
  EXITED_VALIDATORS_PER_DAY_LIMIT,
  APPEARED_VALIDATORS_PER_DAY_LIMIT,
  ANNUAL_BALANCE_INCREASE_BP_LIMIT,
  SIMULATED_SHARE_RATE_DEVIATION_BP_LIMIT,
  MAX_VALIDATOR_EXIT_REQUESTS_PER_REPORT,
  MAX_ITEMS_PER_EXTRA_DATA_TRANSACTION,
  MAX_NODE_OPERATORS_PER_EXTRA_DATA_ITEM,
  REQUEST_TIMESTAMP_MARGIN,
  MAX_POSITIVE_TOKEN_REBASE,
  INITIAL_SLASHING_AMOUNT_P_WEI,
  INACTIVITY_PENALTIES_AMOUNT_P_WEI,
  CL_BALANCE_ORACLES_ERROR_UPPER_BP_LIMIT,
];

// DSM args
const PAUSE_INTENT_VALIDITY_PERIOD_BLOCKS = 6646;
const MAX_OPERATORS_PER_UNVETTING = 200;
const guardians = [
  "0x5fd0dDbC3351d009eb3f88DE7Cd081a614C519F1",
  "0x7912Fa976BcDe9c2cf728e213e892AD7588E6AaF",
  "0x14D5d5B71E048d2D75a39FfC5B407e3a3AB6F314",
  "0xf82D88217C249297C6037BA77CE34b3d8a90ab43",
  "0xa56b128Ea2Ea237052b0fA2a96a387C0E43157d8",
  "0xd4EF84b638B334699bcf5AF4B0410B8CCD71943f",
];
const quorum = 4;

async function main() {
  const deployer = ethers.getAddress(getEnvVariable("DEPLOYER"));
  const chainId = (await ethers.provider.getNetwork()).chainId;

  if (chainId !== 1n) {
    log(rd(`Expected mainnet, got chain id ${chainId}`));
    return;
  }

  log(cy(`Deploy of contracts on chain ${chainId}`));

  const state = readNetworkState();
  persistNetworkState(state);

  // Read contracts addresses from config
  const DEPOSIT_CONTRACT_ADDRESS = state[Sk.chainSpec].depositContractAddress;
  const APP_AGENT_ADDRESS = state[Sk.appAgent].proxy.address;
  const SC_ADMIN = APP_AGENT_ADDRESS;
  const LOCATOR = state[Sk.lidoLocator].proxy.address;

  const locatorContract = await loadContract<LidoLocator>(LidoLocator__factory, LOCATOR);
  // fetch contract addresses that will not changed
  const ACCOUNTING_ORACLE_PROXY = await locatorContract.accountingOracle();
  const EL_REWARDS_VAULT = await locatorContract.elRewardsVault();
  const LEGACY_ORACLE = await locatorContract.legacyOracle();
  const LIDO = await locatorContract.lido();
  const POST_TOKEN_REABSE_RECEIVER = await locatorContract.postTokenRebaseReceiver();
  const BURNER = await locatorContract.burner();
  const STAKING_ROUTER = await locatorContract.stakingRouter();
  const TREASURY_ADDRESS = await locatorContract.treasury();
  const VEBO = await locatorContract.validatorsExitBusOracle();
  const WQ = await locatorContract.withdrawalQueue();
  const WITHDRAWAL_VAULT = await locatorContract.withdrawalVault();
  const ORACLE_DAEMON_CONFIG = await locatorContract.oracleDaemonConfig();

  log.lineWithArguments(
    `Fetched addresses from locator ${LOCATOR}, result: `,
    getLocatorAddressesToString(
      ACCOUNTING_ORACLE_PROXY,
      EL_REWARDS_VAULT,
      LEGACY_ORACLE,
      LIDO,
      POST_TOKEN_REABSE_RECEIVER,
      BURNER,
      STAKING_ROUTER,
      TREASURY_ADDRESS,
      VEBO,
      WQ,
      WITHDRAWAL_VAULT,
      ORACLE_DAEMON_CONFIG,
    ),
  );
  // Deploy MinFirstAllocationStrategy
  const minFirstAllocationStrategyAddress = (
    await deployWithoutProxy(Sk.minFirstAllocationStrategy, "MinFirstAllocationStrategy", deployer)
  ).address;
  log.success(`MinFirstAllocationStrategy address: ${minFirstAllocationStrategyAddress}`);
  log.emptyLine();

  const libraries = {
    MinFirstAllocationStrategy: minFirstAllocationStrategyAddress,
  };

  // Deploy StakingRouter
  const stakingRouterAddress = (
    await deployImplementation(Sk.stakingRouter, "StakingRouter", deployer, [DEPOSIT_CONTRACT_ADDRESS], { libraries })
  ).address;
  log.success(`StakingRouter implementation address: ${stakingRouterAddress}`);
  log.emptyLine();

  // Deploy NOR
  const appNodeOperatorsRegistry = (
    await deployImplementation(Sk.appNodeOperatorsRegistry, "NodeOperatorsRegistry", deployer, [], { libraries })
  ).address;
  log.success(`NodeOperatorsRegistry address implementation: ${appNodeOperatorsRegistry}`);
  log.emptyLine();

  updateObjectInState(Sk.appSimpleDvt, {
    implementation: {
      contract: "contracts/0.4.24/nos/NodeOperatorsRegistry.sol",
      address: appNodeOperatorsRegistry,
      constructorArgs: [],
    },
  });

  // Deploy DSM
  const depositSecurityModuleParams = [
    LIDO,
    DEPOSIT_CONTRACT_ADDRESS,
    STAKING_ROUTER,
    PAUSE_INTENT_VALIDITY_PERIOD_BLOCKS,
    MAX_OPERATORS_PER_UNVETTING,
  ];
  const depositSecurityModuleAddress = (
    await deployWithoutProxy(Sk.depositSecurityModule, "DepositSecurityModule", deployer, depositSecurityModuleParams)
  ).address;
  log.success(`New DSM address: ${depositSecurityModuleAddress}`);
  log.emptyLine();

  const dsmContract = await loadContract<DepositSecurityModule>(
    DepositSecurityModule__factory,
    depositSecurityModuleAddress,
  );
  await dsmContract.addGuardians(guardians, quorum);
  await dsmContract.setOwner(APP_AGENT_ADDRESS);
  log.success(`Guardians list: ${await dsmContract.getGuardians()}`);
  log.success(`Quorum: ${await dsmContract.getGuardianQuorum()}`);
  log.emptyLine();

  // Deploy AO
  const accountingOracleArgs = [LOCATOR, LIDO, LEGACY_ORACLE, SECONDS_PER_SLOT, GENESIS_TIME];
  const accountingOracleAddress = (
    await deployImplementation(Sk.accountingOracle, "AccountingOracle", deployer, accountingOracleArgs)
  ).address;
  log.success(`AO implementation address: ${accountingOracleAddress}`);
  log.emptyLine();

  // Deploy OracleReportSanityCheckerArgs
  const oracleReportSanityCheckerArgs = [LOCATOR, SC_ADMIN, LIMITS];
  const oracleReportSanityCheckerAddress = (
    await deployWithoutProxy(
      Sk.oracleReportSanityChecker,
      "OracleReportSanityChecker",
      deployer,
      oracleReportSanityCheckerArgs,
    )
  ).address;
  log.success(`OracleReportSanityChecker new address ${oracleReportSanityCheckerAddress}`);
  log.emptyLine();

  const locatorConfig = [
    [
      ACCOUNTING_ORACLE_PROXY,
      depositSecurityModuleAddress,
      EL_REWARDS_VAULT,
      LEGACY_ORACLE,
      LIDO,
      oracleReportSanityCheckerAddress,
      POST_TOKEN_REABSE_RECEIVER,
      BURNER,
      STAKING_ROUTER,
      TREASURY_ADDRESS,
      VEBO,
      WQ,
      WITHDRAWAL_VAULT,
      ORACLE_DAEMON_CONFIG,
    ],
  ];

  const locatorAddress = (await deployImplementation(Sk.lidoLocator, "LidoLocator", deployer, locatorConfig)).address;
  log.success(`Locator implementation address ${locatorAddress}`);
  log.emptyLine();

  if (getEnvVariable("RUN_ON_FORK", "false") === "true") {
    log(cy("Deploy script was executed on fork, will skip verification"));
    return;
  }

  await waitForPressButton();

  log(cy("Continuing..."));

  await run("verify:verify", {
    address: minFirstAllocationStrategyAddress,
    constructorArguments: [],
    contract: "contracts/common/lib/MinFirstAllocationStrategy.sol:MinFirstAllocationStrategy",
  });

  await run("verify:verify", {
    address: stakingRouterAddress,
    constructorArguments: [DEPOSIT_CONTRACT_ADDRESS],
    libraries: {
      MinFirstAllocationStrategy: minFirstAllocationStrategyAddress,
    },
    contract: "contracts/0.8.9/StakingRouter.sol:StakingRouter",
  });

  await run("verify:verify", {
    address: appNodeOperatorsRegistry,
    constructorArguments: [],
    libraries: {
      MinFirstAllocationStrategy: minFirstAllocationStrategyAddress,
    },
    contract: "contracts/0.4.24/nos/NodeOperatorsRegistry.sol:NodeOperatorsRegistry",
  });

  await run("verify:verify", {
    address: depositSecurityModuleAddress,
    constructorArguments: depositSecurityModuleParams,
    contract: "contracts/0.8.9/DepositSecurityModule.sol:DepositSecurityModule",
  });

  await run("verify:verify", {
    address: accountingOracleAddress,
    constructorArguments: accountingOracleArgs,
    contract: "contracts/0.8.9/oracle/AccountingOracle.sol:AccountingOracle",
  });

  await run("verify:verify", {
    address: oracleReportSanityCheckerAddress,
    constructorArguments: oracleReportSanityCheckerArgs,
    contract: "contracts/0.8.9/sanity_checks/OracleReportSanityChecker.sol:OracleReportSanityChecker",
  });

  await run("verify:verify", {
    address: locatorAddress,
    constructorArguments: locatorConfig,
    contract: "contracts/0.8.9/LidoLocator.sol:LidoLocator",
  });
}

async function waitForPressButton(): Promise<void> {
  return new Promise<void>((resolve) => {
    log(cy("When contracts will be ready for verification step, press Enter to continue..."));
    const rl = readline.createInterface({ input: process.stdin });

    rl.on("line", () => {
      rl.close();
      resolve();
    });
  });
}

function getLocatorAddressesToString(
  ACCOUNTING_ORACLE_PROXY: string,
  EL_REWARDS_VAULT: string,
  LEGACY_ORACLE: string,
  LIDO: string,
  POST_TOKEN_REABSE_RECEIVER: string,
  BURNER: string,
  STAKING_ROUTER: string,
  TREASURY_ADDRESS: string,
  VEBO: string,
  WQ: string,
  WITHDRAWAL_VAULT: string,
  ORACLE_DAEMON_CONFIG: string,
) {
  return [
    { toString: () => `ACCOUNTING_ORACLE_PROXY: ${ACCOUNTING_ORACLE_PROXY}` },
    { toString: () => `EL_REWARDS_VAULT: ${EL_REWARDS_VAULT}` },
    { toString: () => `LEGACY_ORACLE: ${LEGACY_ORACLE}` },
    { toString: () => `LIDO: ${LIDO}` },
    { toString: () => `POST_TOKEN_REABSE_RECEIVER: ${POST_TOKEN_REABSE_RECEIVER}` },
    { toString: () => `BURNER: ${BURNER}` },
    { toString: () => `STAKING_ROUTER: ${STAKING_ROUTER}` },
    { toString: () => `TREASURY_ADDRESS: ${TREASURY_ADDRESS}` },
    { toString: () => `VEBO: ${VEBO}` },
    { toString: () => `WQ: ${WQ}` },
    { toString: () => `WITHDRAWAL_VAULT: ${WITHDRAWAL_VAULT}` },
    { toString: () => `ORACLE_DAEMON_CONFIG: ${ORACLE_DAEMON_CONFIG}` },
  ];
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    log.error(error);
    process.exit(1);
  });
