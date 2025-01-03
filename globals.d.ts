declare namespace NodeJS {
  export interface ProcessEnv {
    /* iternal logging verbosity (used in scratch deploy / integration tests) */
    LOG_LEVEL?: "all" | "debug" | "info" | "warn" | "error" | "none"; // default: "info"

    /**
     * Flags for changing the behavior of the Hardhat Network
     */

    /* RPC URL for Hardhat Network forking, required for running tests on mainnet fork with tracing */
    HARDHAT_FORKING_URL?: string;

    /**
     * Flags for changing the behavior of the integration tests
     */

    /* if "on" the integration tests will deploy the contracts to the empty Hardhat Network node using scratch deploy */
    INTEGRATION_ON_SCRATCH?: "on" | "off"; // default: "off"

    /* if "on" the integration tests will assume CSM module is present in the StakingRouter, and adjust accordingly */
    INTEGRATION_WITH_CSM?: "on" | "off"; // default: "off"

    /**
     * Network configuration for the protocol discovery.
     */

    /* for local development */
    LOCAL_RPC_URL: string;
    LOCAL_LOCATOR_ADDRESS: string;
    LOCAL_AGENT_ADDRESS: string;
    LOCAL_VOTING_ADDRESS: string;
    LOCAL_EASY_TRACK_EXECUTOR_ADDRESS: string;
    LOCAL_ACCOUNTING_ORACLE_ADDRESS?: string;
    LOCAL_ACL_ADDRESS?: string;
    LOCAL_BURNER_ADDRESS?: string;
    LOCAL_DEPOSIT_SECURITY_MODULE_ADDRESS?: string;
    LOCAL_EL_REWARDS_VAULT_ADDRESS?: string;
    LOCAL_HASH_CONSENSUS_ADDRESS?: string;
    LOCAL_KERNEL_ADDRESS?: string;
    LOCAL_LEGACY_ORACLE_ADDRESS?: string;
    LOCAL_LIDO_ADDRESS?: string;
    LOCAL_NOR_ADDRESS?: string;
    LOCAL_ORACLE_DAEMON_CONFIG_ADDRESS?: string;
    LOCAL_ORACLE_REPORT_SANITY_CHECKER_ADDRESS?: string;
    LOCAL_SDVT_ADDRESS?: string;
    LOCAL_STAKING_ROUTER_ADDRESS?: string;
    LOCAL_VALIDATORS_EXIT_BUS_ORACLE_ADDRESS?: string;
    LOCAL_WITHDRAWAL_QUEUE_ADDRESS?: string;
    LOCAL_WITHDRAWAL_VAULT_ADDRESS?: string;

    /* for mainnet fork testing */
    MAINNET_RPC_URL: string;
    MAINNET_LOCATOR_ADDRESS: string;
    MAINNET_AGENT_ADDRESS: string;
    MAINNET_VOTING_ADDRESS: string;
    MAINNET_EASY_TRACK_EXECUTOR_ADDRESS: string;
    MAINNET_ACCOUNTING_ORACLE_ADDRESS?: string;
    MAINNET_ACL_ADDRESS?: string;
    MAINNET_BURNER_ADDRESS?: string;
    MAINNET_DEPOSIT_SECURITY_MODULE_ADDRESS?: string;
    MAINNET_EL_REWARDS_VAULT_ADDRESS?: string;
    MAINNET_HASH_CONSENSUS_ADDRESS?: string;
    MAINNET_KERNEL_ADDRESS?: string;
    MAINNET_LEGACY_ORACLE_ADDRESS?: string;
    MAINNET_LIDO_ADDRESS?: string;
    MAINNET_NOR_ADDRESS?: string;
    MAINNET_ORACLE_DAEMON_CONFIG_ADDRESS?: string;
    MAINNET_ORACLE_REPORT_SANITY_CHECKER_ADDRESS?: string;
    MAINNET_SDVT_ADDRESS?: string;
    MAINNET_STAKING_ROUTER_ADDRESS?: string;
    MAINNET_VALIDATORS_EXIT_BUS_ORACLE_ADDRESS?: string;
    MAINNET_WITHDRAWAL_QUEUE_ADDRESS?: string;
    MAINNET_WITHDRAWAL_VAULT_ADDRESS?: string;

    /* for contract sourcecode verification with `hardhat-verify` */
    ETHERSCAN_API_KEY?: string;
  }
}
