#!/bin/bash
set -e +u
set -o pipefail

# export NETWORK=testnet
export DEPLOYER=${DEPLOYER}
export NETWORK=local
export RPC_URL=${RPC_URL:="http://127.0.0.1:8555"}  # if defined use the value set to default otherwise

export PAUSE_INTENT_VALIDITY_PERIOD_BLOCKS=7200
export MAX_OPERATORS_PER_UNVETTING=20

export SECONDS_PER_SLOT=12
export GENESIS_TIME=1695902400

export GAS_PRIORITY_FEE=${GAS_PRIORITY_FEE:=2}
export GAS_MAX_FEE=${GAS_MAX_FEE:=100}


# contracts addresses on mainnet
export LIDO="0x3F1c547b21f65e10480dE3ad8E19fAAC46C95034"
export DEPOSIT_CONTRACT="0x4242424242424242424242424242424242424242"
export STAKING_ROUTER="0xd6EbF043D30A7fe46D1Db32BA90a0A51207FE229"
export ACCOUNTING_ORACLE_PROXY="0x4E97A3972ce8511D87F334dA17a2C332542a5246"
export EL_REWARDS_VAULT="0xE73a3602b99f1f913e72F8bdcBC235e206794Ac8"
export POST_TOKEN_REBASE_RECEIVER="0x072f72BE3AcFE2c52715829F2CD9061A6C8fF019"
export BURNER="0x4E46BD7147ccf666E1d73A3A456fC7a68de82eCA"
export TREASURY_ADDRESS="0xE92329EC7ddB11D25e25b3c21eeBf11f15eB325d"
export VEBO="0xffDDF7025410412deaa05E3E1cE68FE53208afcb"
export WITHDRAWAL_QUEUE_ERC721="0xc7cc160b58F8Bb0baC94b80847E2CF2800565C50"
export WITHDRAWAL_VAULT_ADDRESS="0xF0179dEC45a37423EAD4FaD5fCb136197872EAd9"
export ORACLE_DAEMON_CONFIG="0xC01fC1F2787687Bc656EAc0356ba9Db6e6b7afb7"
export LOCATOR="0x28fab2059c713a7f9d8c86db49f9bb0e96af1ef8"
export LEGACY_ORACLE="0x072f72be3acfe2c52715829f2cd9061a6c8ff019"

# Run the deployment script with the environment variables
yarn hardhat --network $NETWORK run scripts/staking-router-v2/deploy.ts
