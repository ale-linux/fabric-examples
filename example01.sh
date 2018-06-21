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
CONFIGTXLTR_CMD=$fabricDir/.build/bin/configtxlator

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
    BatchTimeout: 10ms
    BatchSize:
        MaxMessageCount: 10
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

cd $artifactsDir
runStep $CRYPTOGEN_CMD generate --config=$cryptogenCfgFile

cd $curDir

# generating genesis block (main channel)
runStep $CONFIGTXGEN_CMD -profile TwoOrgsOrdererGenesis -outputBlock $ordBlockMain --configPath $artifactsDir

$CONFIGTXLTR_CMD proto_decode --input $ordBlockMain --type common.Block | jq .data.data[0].payload.data.config
