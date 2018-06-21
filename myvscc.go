package main

import (
	"strconv"

	"github.com/golang/protobuf/proto"
	"github.com/hyperledger/fabric/core/ledger/kvledger/txmgmt/rwsetutil"
	"github.com/hyperledger/fabric/protos/common"
	"github.com/hyperledger/fabric/protos/peer"
	"github.com/hyperledger/fabric/protos/utils"
	vdeps "github.com/hyperledger/fabric/core/handlers/validation/api/state"
	"github.com/hyperledger/fabric/core/handlers/validation/api"
	"github.com/pkg/errors"
	"github.com/hyperledger/fabric/protos/ledger/rwset/kvrwset"
)

type MyPluginImpl struct {
	sf vdeps.StateFetcher
}

func getArgs(block *common.Block, txPosition int, actionPosition int) ([][]byte, error) {
	env, err := utils.GetEnvelopeFromBlock(block.Data.Data[txPosition])
	if err != nil {
		return nil, err
	}

	payl, err := utils.GetPayload(env)
	if err != nil {
		return nil, err
	}

	tx, err := utils.GetTransaction(payl.Data)
	if err != nil {
		return nil, err
	}

	ccPayload, _, err := utils.GetPayloads(tx.Actions[actionPosition])
	if err != nil {
		return nil, err
	}

	cpp, err := utils.GetChaincodeProposalPayload(ccPayload.ChaincodeProposalPayload)
	if err != nil {
		return nil, err
	}

	cis := &peer.ChaincodeInvocationSpec{}
	err = proto.Unmarshal(cpp.Input, cis)
	if err != nil {
		return nil, err
	}

	return cis.ChaincodeSpec.Input.Args, nil
}

func getRwset(block *common.Block, txPosition int, actionPosition int) (*rwsetutil.TxRwSet, error) {
	env, err := utils.GetEnvelopeFromBlock(block.Data.Data[txPosition])
	if err != nil {
		return nil, err
	}

	payl, err := utils.GetPayload(env)
	if err != nil {
		return nil, err
	}

	tx, err := utils.GetTransaction(payl.Data)
	if err != nil {
		return nil, err
	}

	ccPayload, ca, err := utils.GetPayloads(tx.Actions[actionPosition])
	if err != nil {
		return nil, err
	}

	pRespPayload := &peer.ProposalResponsePayload{}
	err = proto.Unmarshal(ccPayload.Action.ProposalResponsePayload, pRespPayload)
	if err != nil {
		return nil, err
	}

	txRWSet := &rwsetutil.TxRwSet{}
	err = txRWSet.FromProtoBytes(ca.Results)
	if err != nil {
		return nil, err
	}

	return txRWSet, nil
}

func setRwset(block *common.Block, txPosition int, actionPosition int, rws *rwsetutil.TxRwSet) error {
	env, err := utils.GetEnvelopeFromBlock(block.Data.Data[txPosition])
	if err != nil {
		return err
	}

	payl, err := utils.GetPayload(env)
	if err != nil {
		return err
	}

	tx, err := utils.GetTransaction(payl.Data)
	if err != nil {
		return err
	}

	ccPayload, ca, err := utils.GetPayloads(tx.Actions[actionPosition])
	if err != nil {
		return err
	}

	pRespPayload := &peer.ProposalResponsePayload{}
	err = proto.Unmarshal(ccPayload.Action.ProposalResponsePayload, pRespPayload)
	if err != nil {
		return err
	}

	newresults, err := rws.ToProtoBytes()
	if err != nil {
		return err
	}

	ca.Results = newresults
	pRespPayload.Extension = utils.MarshalOrPanic(ca)
	ccPayload.Action.ProposalResponsePayload = utils.MarshalOrPanic(pRespPayload)
	tx.Actions[actionPosition].Payload = utils.MarshalOrPanic(ccPayload)
	payl.Data = utils.MarshalOrPanic(tx)
	env.Payload = utils.MarshalOrPanic(payl)
	block.Data.Data[txPosition] = utils.MarshalOrPanic(env)

	return nil
}

func (p *MyPluginImpl) getValFromLedger(namespace, key string) (int, error) {
	s, err := p.sf.FetchState()
	if err != nil {
		return -1, err
	}
	defer s.Done()

	val, err := s.GetStateMultipleKeys(namespace, []string{key})
	if err != nil {
		return -1, err
	}

	return strconv.Atoi(string(val[0]))
}

func (p *MyPluginImpl) Validate(block *common.Block, namespace string, txPosition int, actionPosition int, contextData ...validation.ContextDatum) error {
	args, err := getArgs(block, txPosition, actionPosition)
	if err != nil {
		return err
	}

	if string(args[0]) != "invoke" {
		return nil
	}

	src := string(args[1])
	dst := string(args[2])

	srcVal, err := p.getValFromLedger(namespace, src)
	if err != nil {
		return err
	}

	dstVal, err := p.getValFromLedger(namespace, dst)
	if err != nil {
		return err
	}

	delta, err := strconv.Atoi(string(args[3]))
	if err != nil {
		return err
	}

	srcVal -= delta
	dstVal += delta

	for i := txPosition-1; i >= 0; i-- {
		oldargs, err := getArgs(block, i, 0)
		if err != nil {
			return err
		}

		if string(oldargs[0]) != "invoke" {
			return nil
		}

		oldSrc := string(oldargs[1])
		oldDst := string(oldargs[2])
		oldDelta, err := strconv.Atoi(string(oldargs[3]))
		if err != nil {
			return err
		}

		if oldSrc == src {
			srcVal -= oldDelta
		} else if oldSrc == dst {
			dstVal -= oldDelta
		}

		if oldDst == src {
			srcVal += oldDelta
		} else if oldDst == dst {
			dstVal += oldDelta
		}
	}

	rws, err := getRwset(block, txPosition, actionPosition)
	if err != nil {
		return err
	}

	for _, nsrws := range rws.NsRwSets {
		if nsrws.NameSpace == namespace {
			nsrws.NameSpace = nsrws.NameSpace + ".orig"
			nsrws.KvRwSet.Reads = []*kvrwset.KVRead{}
		}
	}

	newRwset := &rwsetutil.NsRwSet{
		NameSpace: namespace,
		KvRwSet: &kvrwset.KVRWSet{
			Writes: []*kvrwset.KVWrite{
				{
					Key: src,
					Value: []byte(strconv.Itoa(srcVal)),
				},
				{
					Key: dst,
					Value: []byte(strconv.Itoa(dstVal)),
				},
			},
		},
	}

	rws.NsRwSets = append(rws.NsRwSets, newRwset)

	err = setRwset(block, txPosition, actionPosition, rws)
	if err != nil {
		return err
	}

	return nil
}

func (p *MyPluginImpl) Init(dependencies ...validation.Dependency) error {
	var (
		sf vdeps.StateFetcher
	)
	for _, dep := range dependencies {
		if stateFetcher, isStateFetcher := dep.(vdeps.StateFetcher); isStateFetcher {
			sf = stateFetcher
		}
	}
	if sf == nil {
		return errors.New("stateFetcher not passed in init")
	}

	p.sf = sf

	return nil
}

type MyPluginFactory struct {
}

func (p *MyPluginFactory) New() validation.Plugin {
	return &MyPluginImpl{}
}

func NewPluginFactory() validation.PluginFactory {
	return &MyPluginFactory{}
}
