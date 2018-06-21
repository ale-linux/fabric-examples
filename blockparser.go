package main

import (
	"bufio"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"io/ioutil"
	"os"
	"strings"

	"github.com/golang/protobuf/proto"
	"github.com/hyperledger/fabric/core/ledger/kvledger/txmgmt/rwsetutil"
	"github.com/hyperledger/fabric/protos/common"
	"github.com/hyperledger/fabric/protos/msp"
	"github.com/hyperledger/fabric/protos/utils"
	"github.com/hyperledger/fabric/core/ledger/util"
)

func returnCreatorString(bytes []byte) string {
	defaultString := strings.Replace(string(bytes), "\n", ".", -1)

	sId := &msp.SerializedIdentity{}
	err := proto.Unmarshal(bytes, sId)
	if err != nil {
		return defaultString
	}

	bl, _ := pem.Decode(sId.IdBytes)
	if bl == nil {
		return defaultString
	}

	cert, err := x509.ParseCertificate(bl.Bytes)
	if err != nil {
		return defaultString
	}

	return cert.Subject.OrganizationalUnit[0] + "@" + sId.Mspid
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	res, err := ioutil.ReadAll(reader)
	if err != nil {
		fmt.Printf("Error reading, %+v\n", err)
		os.Exit(-1)
	}

	b := &common.Block{}
	err = proto.Unmarshal(res, b)
	if err != nil {
		fmt.Printf("Error unarshalling %+v\n", err)
		os.Exit(-1)
	}

	txsFltr := util.TxValidationFlags(b.Metadata.Metadata[common.BlockMetadataIndex_TRANSACTIONS_FILTER])

	fmt.Printf("There are %d transactions in this block\n", len(b.Data.Data))

	for i, d := range b.Data.Data {
		fmt.Printf("tx %d (validation status: %s):\n", i, txsFltr.Flag(i).String())

		env, err := utils.GetEnvelopeFromBlock(d)
		if err != nil {
			fmt.Printf("Error getting tx from block(%s)", err)
			os.Exit(-1)
		}

		payload, err := utils.GetPayload(env)
		if err != nil {
			fmt.Printf("GetPayload returns err %s", err)
			os.Exit(-1)
		}

		chdr, err := utils.UnmarshalChannelHeader(payload.Header.ChannelHeader)
		if err != nil {
			fmt.Printf("UnmarshalChannelHeader returns err %s", err)
			os.Exit(-1)
		}

		shdr, err := utils.GetSignatureHeader(payload.Header.SignatureHeader)
		if err != nil {
			fmt.Printf("GetSignatureHeader returns err %s", err)
			os.Exit(-1)
		}

		tx, err := utils.GetTransaction(payload.Data)
		if err != nil {
			fmt.Printf("GetTransaction returns err %s", err)
			os.Exit(-1)
		}

		_, respPayload, err := utils.GetPayloads(tx.Actions[0])
		if err != nil {
			fmt.Printf("GetPayloads returns err %s", err)
			os.Exit(-1)
		}

		fmt.Printf("\tCH: %s\n", chdr.ChannelId)
		fmt.Printf("\tCC: %+v\n", respPayload.ChaincodeId)
		fmt.Printf("\tcreator: %s\n", returnCreatorString(shdr.Creator))

		txRWSet := &rwsetutil.TxRwSet{}
		err = txRWSet.FromProtoBytes(respPayload.Results)
		if err != nil {
			fmt.Printf("FromProtoBytes returns err %s", err)
			os.Exit(-1)
		}

		fmt.Printf("\tRead-Write set:\n")
		for _, ns := range txRWSet.NsRwSets {
			fmt.Printf("\t\tNamespace: %s\n", ns.NameSpace)

			if len(ns.KvRwSet.Writes) > 0 {
				fmt.Printf("\t\t\tWrites:\n")
				for _, w := range ns.KvRwSet.Writes {
					fmt.Printf("\t\t\t\tK: %s, V:%s\n", w.Key, strings.Replace(string(w.Value), "\n", ".", -1))
				}
			}

			if len(ns.KvRwSet.Reads) > 0 {
				fmt.Printf("\t\t\tReads:\n")
				for _, w := range ns.KvRwSet.Reads {
					fmt.Printf("\t\t\t\tK: %s\n", w.Key)
				}
			}

			if len(ns.CollHashedRwSets) > 0 {
				for _, c := range ns.CollHashedRwSets {
					fmt.Printf("\t\t\tCollection: %s\n", c.CollectionName)

					if len(c.HashedRwSet.HashedWrites) > 0 {
						fmt.Printf("\t\t\t\tWrites:\n")
						for _, ww := range c.HashedRwSet.HashedWrites {
							fmt.Printf("\t\t\t\t\tK: %s, V:%s\n",
								base64.StdEncoding.EncodeToString(ww.KeyHash),
								base64.StdEncoding.EncodeToString(ww.ValueHash))
						}
					}

					if len(c.HashedRwSet.HashedReads) > 0 {
						fmt.Printf("\t\t\t\tReads:\n")
						for _, ww := range c.HashedRwSet.HashedReads {
							fmt.Printf("\t\t\t\t\tK: %s\n",
								base64.StdEncoding.EncodeToString(ww.KeyHash))
						}
					}
				}
			}
		}
	}

	os.Exit(0)
}
