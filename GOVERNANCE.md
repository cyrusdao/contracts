# CyrusDAO Governance

## Overview

CyrusDAO is the decentralized governance system for the CYRUS token, designed to empower the Persian diaspora community while ensuring responsible stewardship during the initial phase.

## Governance Philosophy

The governance model honors Cyrus the Great's principles:
- **Freedom**: Token holders have voting power proportional to their stake
- **Tolerance**: Community proposals welcome diverse perspectives
- **Human Dignity**: Guardian protections prevent malicious takeovers

## Governance Phases

### Phase 1: Stewardship (Now → Nowruz 2026)

During the stewardship phase:
- **Board Members** can create proposals
- **All token holders** can vote on proposals
- **Guardian** (Cyrus Pahlavi multisig) has veto power
- Transfers are locked to build genuine community

**Board Members:**
- Cyrus Pahlavi
- Kamran Pahlavi
- Dara Gallopin

### Phase 2: Public Governance (After Nowruz 2026)

After March 21, 2026 (Nowruz):
- Guardian can activate full public governance
- Any holder with 1M+ CYRUS can propose
- Community votes determine outcomes
- Guardian retains emergency veto

### Phase 3: Full Decentralization (Optional)

Guardian can abdicate:
- Permanently removes veto power
- True decentralized autonomous organization
- Community has full control

## Governance Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Voting Delay | 1 day | Time before voting starts |
| Voting Period | 5 days | Duration of voting |
| Proposal Threshold | 1,000,000 CYRUS | Minimum tokens to propose |
| Quorum | 10,000,000 CYRUS | Minimum votes for validity |
| Timelock Delay | 48 hours | Wait period before execution |
| Grace Period | 14 days | Time to execute after queue |

## Proposal Lifecycle

```
1. Propose → 2. Pending (1 day) → 3. Active (5 days voting)
                                          ↓
                    ←←←←←←← 4. Defeated (if failed)
                    ↓
              5. Succeeded → 6. Queued (48h) → 7. Executed
                                    ↓
                              8. Expired (14 days)
```

## Safe Multisig Setup

The Guardian is a Gnosis Safe multisig for secure, transparent governance.

### Creating the Safe

1. Go to [app.safe.global](https://app.safe.global)
2. Connect wallet and select **Base** network
3. Click "Create new Safe"
4. Add board member addresses:
   - Cyrus Pahlavi: `0x...`
   - Kamran Pahlavi: `0x...`
   - Dara Gallopin: `0x...`
5. Set threshold: **2 of 3** (majority required)
6. Deploy the Safe

### Safe Configuration

| Setting | Value | Rationale |
|---------|-------|-----------|
| Signers | 3 | Board members |
| Threshold | 2 | Majority approval |
| Network | Base | Same as token |

### Safe as Guardian

The Safe address becomes the `guardian` in CyrusDAO:
- Can veto malicious proposals
- Can activate public governance
- Can add/remove board members
- Can update treasury address
- Can abdicate (irreversible)

## Deploying CyrusDAO

### Prerequisites

```bash
# Set environment variables
export CYRUS_TOKEN_ADDRESS=0x...  # Deployed token
export GUARDIAN_ADDRESS=0x...     # Safe multisig address
export TREASURY_ADDRESS=0x...     # DAO treasury
export BOARD_MEMBERS=0x...,0x...,0x...  # Comma-separated
```

### Deployment

```bash
# Deploy to Base Sepolia (testnet)
npx hardhat run scripts/deployDAO.js --network baseSepolia

# Deploy to Base (mainnet)
npx hardhat run scripts/deployDAO.js --network base
```

### Verification

```bash
npx hardhat verify --network base <DAO_ADDRESS> \
  "<TOKEN_ADDRESS>" \
  "<GUARDIAN_ADDRESS>" \
  "<TREASURY_ADDRESS>" \
  "[\"<BOARD_1>\",\"<BOARD_2>\",\"<BOARD_3>\"]"
```

## Voting

### Cast a Vote

```solidity
// Support: 0 = Against, 1 = For, 2 = Abstain
dao.castVote(proposalId, 1);  // Vote For

// With reason
dao.castVoteWithReason(proposalId, 1, "Supporting cultural preservation");
```

### Check Vote Receipt

```solidity
CyrusDAO.Receipt memory receipt = dao.getReceipt(proposalId, voterAddress);
// receipt.hasVoted, receipt.support, receipt.votes
```

## Creating Proposals

### During Stewardship (Board Members Only)

```solidity
address[] memory targets = new address[](1);
uint256[] memory values = new uint256[](1);
bytes[] memory calldatas = new bytes[](1);

targets[0] = treasuryAddress;
values[0] = 0;
calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", recipient, amount);

uint256 proposalId = dao.propose(targets, values, calldatas, "Fund cultural center");
```

### After Public Governance

Same interface, but requires 1M+ CYRUS tokens to propose.

## Security Considerations

### Timelock Protection

All proposals have a 48-hour delay before execution, allowing:
- Community review of queued actions
- Guardian intervention if needed
- Public transparency

### Guardian Veto

The guardian can cancel any proposal before execution:
```solidity
dao.cancel(proposalId);
```

### Emergency Pause

If critical issues arise:
1. Guardian cancels active proposals
2. Token contract has `pause()` function
3. Community notified via official channels

## Contract Addresses

| Contract | Network | Address |
|----------|---------|---------|
| CYRUS Token | Base | `TBD` |
| CyrusDAO | Base | `TBD` |
| Guardian Safe | Base | `TBD` |
| Treasury | Base | `TBD` |

## Resources

- [Gnosis Safe](https://app.safe.global) - Multisig wallet
- [Base Network](https://base.org) - L2 blockchain
- [CyrusDAO Contract](./contracts/CyrusDAO.sol) - Governance code
- [Whitepaper](https://cyrus.cash/whitepaper) - Full documentation

---

*"I gathered all their people and returned them to their homelands."* - Cyrus the Great
