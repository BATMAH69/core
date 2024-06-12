declare namespace NodeJS {
  export interface ProcessEnv {
    /* for local development and testing */
    LOCAL_RPC_URL: string;
    LOCAL_LOCATOR_ADDRESS: string;
    LOCAL_AGENT_ADDRESS: string;

    /* for mainnet testing */
    MAINNET_RPC_URL: string;
    MAINNET_LOCATOR_ADDRESS: string;
    MAINNET_AGENT_ADDRESS: string;
  }
}
