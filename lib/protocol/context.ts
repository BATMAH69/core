import { ContractTransactionReceipt } from "ethers";

import { ether, findEventsWithInterfaces, impersonate } from "lib";

import { discover } from "./discover";
import { provision } from "./provision";
import { ProtocolContext, ProtocolSigners, Signer } from "./types";

const getSigner = async (signer: Signer, balance = ether("100"), signers: ProtocolSigners) => {
  const signerAddress = signers[signer] ?? signer;
  return impersonate(signerAddress, balance);
};

export const getProtocolContext = async (): Promise<ProtocolContext> => {
  const { contracts, signers } = await discover();
  const interfaces = Object.values(contracts).map(contract => contract.interface);

  const context = {
    contracts,
    signers,
    interfaces,
    getSigner: async (signer: Signer, balance?: bigint) => getSigner(signer, balance, signers),
    getEvents: (receipt: ContractTransactionReceipt, eventName: string) => findEventsWithInterfaces(receipt, eventName, interfaces),
  } as ProtocolContext;

  await provision(context);

  return context;
};
