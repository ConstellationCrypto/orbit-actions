#!/bin/bash

export MODULE_NAME=$1
export DEPLOYMENT_PK=$2

export CPATH=$3$MODULE_NAME
export OWNER_PK=$(aws secretsmanager --query SecretString --output text get-secret-value --secret-id $(cat $CPATH/helm/values.yaml | yq .accounts.OWNER_KMS_ID) | jq .privateKey | tr -d '"')
export OWNER_ADDRESS=$(cat $CPATH/helm/values.yaml | yq .accounts.OWNER_ADDRESS)
export CHAIN_TYPE=$(cat $CPATH/helm/values.yaml | yq .CHAIN_TYPE)
export RPC=$(cat $CPATH/helm/values.yaml | yq .L1_RPC_URL | tr -d '"')

export INBOX_ADDRESS=$(cat $CPATH/.constellation/contracts.json | jq .coreContracts.inbox | tr -d '"') 
export PROXY_ADMIN_ADDRESS=$(cat $CPATH/.constellation/contracts.json | jq .coreContracts.adminProxy | tr -d '"')  
export PARENT_UPGRADE_EXECUTOR_ADDRESS=$(cat $CPATH/.constellation/contracts.json | jq .coreContracts.upgradeExecutor | tr -d '"') 
PARENT_CHAIN_ID=$(cat $CPATH/.constellation/contracts.json | jq .chainInfo.parentChainId) 
if [[ "$PARENT_CHAIN_ID" == "421614" || "$PARENT_CHAIN_ID" == "42161" ]]; then
  export PARENT_CHAIN_IS_ARBITRUM=true
else
  export PARENT_CHAIN_IS_ARBITRUM=false
fi

if [[ "$PARENT_CHAIN_ID" == "1" || "$PARENT_CHAIN_ID" == "11155111" ]]; then
  export ETHERSCAN_API_KEY=RWSGJAX2JJNX42SB56ADUWFN6MSB5WBHNR
fi
if [[ "$PARENT_CHAIN_ID" == "8453" || "$PARENT_CHAIN_ID" == "84532" ]]; then
  export ETHERSCAN_API_KEY=N7MQWFSFH7PTU38W28KKGKDGDWRI5EYFR6
else
  export ETHERSCAN_API_KEY=VAQC4ZPAQGBRUMW8AR5CVAUKE96VNM2735
fi


IS_FEE_TOKEN_CHAIN=$(cat $CPATH/.constellation/contracts.json | jq .chainInfo.nativeToken | tr -d '"') 
if [[ "$IS_FEE_TOKEN_CHAIN" == "0x0000000000000000000000000000000000000000" ]]; then
  export IS_FEE_TOKEN_CHAIN=false
else
  export IS_FEE_TOKEN_CHAIN=true
fi

export MAX_DATA_SIZE=$(cast call --rpc-url $RPC $INBOX_ADDRESS "maxDataSize()(uint256)" | awk '{print $1; exit}')

DEV=true INBOX_ADDRESS=$INBOX_ADDRESS yarn orbit:contracts:version --network $(echo $PARENT_CHAIN_ID | tr -d '"')

if [[ "$CHAIN_TYPE" == "Celestia" ]]; then
  echo "Youre doing something silly with a Celestia chain."
else
  echo "Deploying DeployNitroContracts2Point1Point3UpgradeActionScript"
  forge script --private-key $DEPLOYMENT_PK --rpc-url $RPC --broadcast DeployNitroContracts2Point1Point2UpgradeActionScript -vvv --verify --skip-simulation

  #echo "Topup owner with 0.01ether"
  #cast send --rpc-url $RPC --private-key $DEPLOYMENT_PK $OWNER_ADDRESS --value 0.001ether
  echo "Balance of "$OWNER_ADDRESS
  cast from-wei $(cast balance --rpc-url $RPC $OWNER_ADDRESS)
  export MULTISIG=false
  #export UPGRADE_ACTION_ADDRESS=
  #forge script --private-key $OWNER_PK --rpc-url $RPC --broadcast ExecuteNitroContracts2Point1Point2UpgradeScript -vvv --verify --skip-simulation
fi

