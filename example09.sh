#!/bin/bash

set -e

source $(dirname $0)/common.sh

curDir=$PWD
trap cleanup EXIT
function cleanup {
  cd $curDir
}

ChannelName=my-ch
CCName=my-cc

fabricDir=$GOPATH/src/github.com/hyperledger/fabric/
artifactsDir=/tmp/$(basename $0).mat/
pluginSrc=$(readlink -f $(dirname $0)/myvscc.go)
coreYamlFile=$(readlink -f $(dirname $0)/core.yaml.ex05)

if test -d $artifactsDir
then
  rm -rf $artifactsDir
fi
mkdir $artifactsDir

ordererOrg=myordererorg
applicationOrg=myapplicationorg

ordererOrgDir=$artifactsDir/crypto-config/ordererOrganizations/$ordererOrg
applicationOrgDir=$artifactsDir/crypto-config/peerOrganizations/$applicationOrg

genBlockMain=$artifactsDir/$ChannelName.block
ordBlockMain=$artifactsDir/$ChannelName-orderer.block
genTransMain=$artifactsDir/$ChannelName-channel.tx

CONFIGTXGEN_CMD=$fabricDir/.build/bin/configtxgen
CONFIGTXLTR_CMD=$fabricDir/.build/bin/configtxlator
PEER_CMD=$fabricDir/.build/bin/peer
CRYPTOGEN_CMD=$fabricDir/.build/bin/cryptogen
BLOCKPARSER_CMD=$(readlink -f $(dirname $0))/blockparser

configtxgenFile=$artifactsDir/configtx.yaml
cat <<- EOF > $configtxgenFile
---
Organizations:
    - &OrdererOrg
        Name: $ordererOrg
        ID: $ordererOrg
        MSPDir: $ordererOrgDir/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('$ordererOrg.member')"
            Writers:
                Type: Signature
                Rule: "OR('$ordererOrg.member')"
            Admins:
                Type: Signature
                Rule: "OR('$ordererOrg.admin')"

    - &$applicationOrg
        Name: $applicationOrg
        ID: $applicationOrg
        MSPDir: $applicationOrgDir/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('$applicationOrg.admin', '$applicationOrg.peer', '$applicationOrg.client')"
            Writers:
                Type: Signature
                Rule: "OR('$applicationOrg.admin', '$applicationOrg.client')"
            Admins:
                Type: Signature
                Rule: "OR('$applicationOrg.admin')"
        AnchorPeers:
            - Host: $applicationOrg
              Port: 7051

Capabilities:
    Global: &ChannelCapabilities
        V1_1: true
    Orderer: &OrdererCapabilities
        V1_1: true
    Application: &ApplicationCapabilities
        V1_2: true

Application: &ApplicationDefaults
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
    Capabilities:
        <<: *ApplicationCapabilities

Orderer: &OrdererDefaults
    OrdererType: solo
    Addresses:
        - $ordererOrg:7050
    BatchTimeout: 1s
    BatchSize:
        MaxMessageCount: 2
        AbsoluteMaxBytes: 99 MB
        PreferredMaxBytes: 512 KB
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
        BlockValidation:
            Type: ImplicitMeta
            Rule: "ANY Writers"
    Capabilities:
        <<: *OrdererCapabilities

Channel: &ChannelDefaults
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
    Capabilities:
        <<: *ChannelCapabilities

Profiles:
    TwoOrgsOrdererGenesis:
        <<: *ChannelDefaults
        Orderer:
            <<: *OrdererDefaults
            Organizations:
                - *OrdererOrg
        Consortiums:
            SampleConsortium:
                Organizations:
                    - *$applicationOrg
    TwoOrgsChannel:
        Consortium: SampleConsortium
        Application:
            <<: *ApplicationDefaults
            Organizations:
                - *$applicationOrg

EOF

cryptogenCfgFile=$artifactsDir/crypto-config.yaml
cat <<- EOF > $cryptogenCfgFile
OrdererOrgs:
  - Name: $ordererOrg
    Domain: $ordererOrg
    Specs:
      - Hostname: orderer
        CommonName: orderer
PeerOrgs:
  - Name: $applicationOrg
    Domain: $applicationOrg
    EnableNodeOUs: true
    Specs:
      - Hostname: peer
        CommonName: peer
    Users:
      Count: 1
EOF

dockerComposeFile=$artifactsDir/network.yaml
cat <<- EOF > $dockerComposeFile
version: '3.5'

services:

  $ordererOrg:
    container_name: $ordererOrg
    image: hyperledger/fabric-orderer
    networks:
      - fabric-net
    environment:
      - ORDERER_GENERAL_LOGLEVEL=debug
      - ORDERER_GENERAL_LISTENADDRESS=0.0.0.0
      - ORDERER_GENERAL_GENESISMETHOD=file
      - ORDERER_GENERAL_LOCALMSPID=$ordererOrg
      - ORDERER_GENERAL_GENESISFILE=/var/hyperledger/orderer/genesis.block
      - ORDERER_GENERAL_LOCALMSPDIR=/var/hyperledger/orderer/msp
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric
    command: orderer
    volumes:
    - $ordBlockMain:/var/hyperledger/orderer/genesis.block
    - $ordererOrgDir/orderers/orderer/msp:/var/hyperledger/orderer/msp
    ports:
      - 7050:7050

networks:
  fabric-net:
    name: fabric-net
EOF

# build plugin
cp $pluginSrc $fabricDir
cd $fabricDir
go build -buildmode=plugin -o plugin.so
cp $fabricDir/plugin.so /tmp

cd $artifactsDir
$CRYPTOGEN_CMD generate --config=$cryptogenCfgFile

cd $curDir

# generating genesis block (main channel)
runStep $CONFIGTXGEN_CMD -profile TwoOrgsOrdererGenesis -outputBlock $ordBlockMain --configPath $artifactsDir
$CONFIGTXGEN_CMD -profile TwoOrgsChannel -outputCreateChannelTx $genTransMain -channelID $ChannelName --configPath $artifactsDir

docker ps -a | awk '{print $1}' | xargs docker kill || true
docker ps -a | awk '{print $1}' | xargs docker rm || true
docker network rm fabric-net || true
docker image ls | grep $CCName | awk '{print $3}' | xargs docker rmi -f || true
docker-compose -f $dockerComposeFile up -d

killall -9 peer || true
rm -rf /tmp/hyperledger

cp $coreYamlFile $artifactsDir/core.yaml

screen -d -m -L -S peer \
env \
FABRIC_CFG_PATH=$artifactsDir \
CORE_PEER_COMMITTER_LEDGER_ORDERER=localhost:7050 \
CORE_LOGGING_LEVEL=DEBUG \
CORE_PEER_TLS_ENABLED=false \
CORE_PEER_ID=$applicationOrg \
CORE_PEER_ADDRESS=localhost:7051 \
CORE_PEER_LOCALMSPID=$applicationOrg \
CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/peers/peer/msp \
$PEER_CMD node start --logging-level debug

sleep .2

# creating channel
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD channel create -o 127.0.0.1:7050 -c $ChannelName -f $genTransMain --outputBlock $genBlockMain

# joining channel
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD channel join -b $genBlockMain

# install chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD chaincode install -n $CCName -v 1 -p github.com/hyperledger/fabric/examples/chaincode/go/example02/cmd

# instantiate chaincode
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD chaincode instantiate -C $ChannelName -n $CCName -v 1 -c '{"Args":["init","a","100","b","200"]}' # -V myvscc

sleep 2

# query chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c '{"Args":["query","a"]}'

# invoke chaincode
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode invoke -n $CCName -C $ChannelName  -c '{"Args":["invoke","a","b","10"]}' &

# invoke chaincode
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode invoke -n $CCName -C $ChannelName  -c '{"Args":["invoke","a","b","10"]}' &

# invoke chaincode
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode invoke -n $CCName -C $ChannelName  -c '{"Args":["invoke","a","b","10"]}' &

# invoke chaincode
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode invoke -n $CCName -C $ChannelName  -c '{"Args":["invoke","a","b","10"]}' &

sleep 2

# query chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c '{"Args":["query","a"]}'

echo "env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD channel fetch 1 /dev/stdout -c my-ch | $BLOCKPARSER_CMD"
