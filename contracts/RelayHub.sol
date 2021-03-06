/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */
/* solhint-disable not-rely-on-time */
/* solhint-disable bracket-align */
// SPDX-License-Identifier:MIT
pragma solidity ^0.6.2;
pragma experimental ABIEncoderV2;

import "./0x/LibBytesV06.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./utils/EIP712Sig.sol";
import "./utils/GSNTypes.sol";
import "./utils/GsnUtils.sol";
import "./interfaces/IRelayHub.sol";
import "./interfaces/IPaymaster.sol";
import "./interfaces/ITrustedForwarder.sol";
import "./BaseRelayRecipient.sol";
import "./StakeManager.sol";
import "./Penalizer.sol";

contract RelayHub is IRelayHub {

    string constant public COMMIT_ID = "$Id$";

    // Minimum stake a relay can have. An attack to the network will never cost less than half this value.
    uint256 constant private MINIMUM_STAKE = 1 ether;

    // Minimum unstake delay blocks of a relay manager's stake on the StakeManager
    uint256 constant private MINIMUM_UNSTAKE_DELAY = 1000;

    // Minimum balance required for a relay to register or re-register. Prevents user error in registering a relay that
    // will not be able to immediately start serving requests.
    uint256 constant private MINIMUM_RELAY_BALANCE = 0.1 ether;

    // Maximum funds that can be deposited at once. Prevents user error by disallowing large deposits.
    uint256 constant private MAXIMUM_RECIPIENT_DEPOSIT = 2 ether;

    /**
    * the total gas overhead of relayCall(), before the first gasleft() and after the last gasleft().
    * Assume that relay has non-zero balance (costs 15'000 more otherwise).
    */

    // Gas cost of all relayCall() instructions after actual 'calculateCharge()'
    uint256 constant private GAS_OVERHEAD = 36834;

    function getHubOverhead() external override view returns (uint256) {
        return GAS_OVERHEAD;
    }
    // Gas set aside for all relayCall() instructions to prevent unexpected out-of-gas exceptions
    uint256 constant private GAS_RESERVE = 100000;

    uint256 public gtxdatanonzero;
    uint256 constant public GTRANSACTION = 21000;

    // maps relay worker's address to its manager's address
    mapping(address => address) private workerToManager;

    // maps relay managers to the number of their workers
    mapping(address => uint256) private workerCount;

    uint256 constant public MAX_WORKER_COUNT = 10;

    mapping(address => uint256) private balances;

    string public version = "1.0.0";
    // TODO: remove with 0.6 solc
    function getVersion() external override view returns (string memory) {
        return version;
    }


    EIP712Sig public eip712sig;
    StakeManager public stakeManager;
    Penalizer public penalizer;
    constructor (uint256 _gtxdatanonzero, StakeManager _stakeManager, Penalizer _penalizer) public {
        eip712sig = new EIP712Sig(address(this));
        stakeManager = _stakeManager;
        penalizer = _penalizer;
        gtxdatanonzero = _gtxdatanonzero;
    }

    function getStakeManager() external override view returns(address) {
        return address(stakeManager);
    }

    function calldatagascost() private view returns (uint256) {
        return GTRANSACTION + msg.data.length * gtxdatanonzero;
    }


    function registerRelayServer(uint256 baseRelayFee, uint256 pctRelayFee, string calldata url) external override {
        address relayManager = msg.sender;
        require(
            stakeManager.isRelayManagerStaked(relayManager, MINIMUM_STAKE, MINIMUM_UNSTAKE_DELAY),
            "relay manager not staked"
        );
        require(workerCount[relayManager] > 0, "no relay workers");
        emit RelayServerRegistered(relayManager, baseRelayFee, pctRelayFee, url);
    }

    function addRelayWorkers(address[] calldata newRelayWorkers) external override {
        address relayManager = msg.sender;
        workerCount[relayManager] = workerCount[relayManager] + newRelayWorkers.length;
        require(workerCount[relayManager] <= MAX_WORKER_COUNT, "too many workers");

        require(
            stakeManager.isRelayManagerStaked(relayManager, MINIMUM_STAKE, MINIMUM_UNSTAKE_DELAY),
            "relay manager not staked"
        );

        for (uint256 i = 0; i < newRelayWorkers.length; i++) {
            require(workerToManager[newRelayWorkers[i]] == address(0), "this worker has a manager");
            workerToManager[newRelayWorkers[i]] = relayManager;
        }

        emit RelayWorkersAdded(relayManager, newRelayWorkers, workerCount[relayManager]);
    }

    function depositFor(address target) public override payable {
        uint256 amount = msg.value;
        require(amount <= MAXIMUM_RECIPIENT_DEPOSIT, "deposit too big");

        balances[target] = SafeMath.add(balances[target], amount);

        emit Deposited(target, msg.sender, amount);
    }

    function balanceOf(address target) external override view returns (uint256) {
        return balances[target];
    }

    function withdraw(uint256 amount, address payable dest) public override {
        address payable account = msg.sender;
        require(balances[account] >= amount, "insufficient funds");

        balances[account] -= amount;
        dest.transfer(amount);

        emit Withdrawn(account, dest, amount);
    }

    function canRelay(
        GSNTypes.RelayRequest memory relayRequest,
        uint256 initialGas,
        bytes memory signature,
        bytes memory approvalData
    )
    private
    view
    returns (bool success, bytes memory returnValue, GSNTypes.GasLimits memory gasLimits)
    {
        gasLimits =
            IPaymaster(relayRequest.relayData.paymaster).getGasLimits();

        uint256 requiredGas =
            GAS_OVERHEAD +
            gasLimits.acceptRelayedCallGasLimit +
            gasLimits.preRelayedCallGasLimit +
            gasLimits.postRelayedCallGasLimit +
            relayRequest.gasData.gasLimit;

        // This transaction must have enough gas to forward the call to the recipient with the requested amount, and not
        // run out of gas later in this function.
        require(
            initialGas >= GAS_RESERVE + requiredGas,
            "Not enough gas left for recipientCallsAtomic to complete");

        // The maximum possible charge is the cost of transaction assuming all bytes of calldata are non-zero and
        // all paymaster and recipient calls consume entire available gas limit
        uint256 maxPossibleGas = calldatagascost() + requiredGas;
        uint256 maxPossibleCharge = calculateCharge(
            maxPossibleGas,
            relayRequest.gasData
        );

        // We don't yet know how much gas will be used by the recipient, so we make sure there are enough funds to pay
        // for the maximum possible charge.
        require(maxPossibleCharge <= balances[relayRequest.relayData.paymaster],
            "Paymaster balance too low");

        bytes memory encodedTx = abi.encodeWithSelector(IPaymaster.acceptRelayedCall.selector,
            relayRequest, signature, approvalData, maxPossibleGas
        );

        (success, returnValue) =
            relayRequest.relayData.paymaster.staticcall{gas:gasLimits.acceptRelayedCallGasLimit}(encodedTx);
    }

    struct RelayCallData {
        uint256 initialGas;
        bytes4 functionSelector;
        bytes recipientContext;
        GSNTypes.GasLimits gasLimits;
        RelayCallStatus status;
    }
    function relayCall(
    // TODO: msg.sender used to be treated as 'relay' (now passed in a struct),
    //  make sure this does not have security impl
        GSNTypes.RelayRequest calldata relayRequest,
        bytes calldata signature,
        bytes calldata approvalData
    )
    external
    override
    returns (bool paymasterAccepted, string memory revertReason)
    {
        RelayCallData memory vars;
        vars.initialGas = gasleft();
        vars.functionSelector = LibBytesV06.readBytes4(relayRequest.encodedFunction, 0);

        require(workerToManager[msg.sender] != address(0), "Unknown relay worker");
        require(
            stakeManager.isRelayManagerStaked(workerToManager[msg.sender], MINIMUM_STAKE, MINIMUM_UNSTAKE_DELAY),
            "relay manager not staked"
        );

        require(relayRequest.gasData.gasPrice <= tx.gasprice, "Invalid gas price");
        // We now verify that the paymaster will agree to be charged for the transaction.
        bool success;
        (success, vars.recipientContext, vars.gasLimits) =
            canRelay(
                GSNTypes.RelayRequest(
                    relayRequest.target,
                    relayRequest.encodedFunction,
                    relayRequest.gasData,
                    relayRequest.relayData),
                    vars.initialGas, signature, approvalData);

        if (!success) {
            revertReason = GsnUtils.getError(vars.recipientContext);
            emit TransactionRejectedByPaymaster(
                workerToManager[msg.sender],
                relayRequest.relayData.paymaster,
                relayRequest.relayData.senderAddress,
                relayRequest.target,
                msg.sender,
                vars.functionSelector,
                revertReason);
            return (success, revertReason);
        }

        // From this point on, this transaction will not revert nor run out of gas, and the recipient will be charged
        // for the gas spent.

        // Calls to the recipient are performed atomically inside an inner transaction which may revert in case of
        // errors in the recipient. In either case (revert or regular execution) the return data encodes the
        // RelayCallStatus value.
        (, bytes memory relayCallStatus) = address(this).call(
            abi.encodeWithSelector(RelayHub.recipientCallsAtomic.selector, relayRequest, signature, vars.gasLimits, vars.initialGas, calldatagascost(), abi.decode(vars.recipientContext, (bytes)))
        );
        vars.status = abi.decode(relayCallStatus, (RelayCallStatus));

        // We now perform the actual charge calculation, based on the measured gas used
        uint256 charge = calculateCharge(
            calldatagascost() +
            (vars.initialGas - gasleft()) +
            GAS_OVERHEAD,
            relayRequest.gasData
        );

        // We've already checked that the recipient has enough balance to pay for the relayed transaction, this is only
        // a sanity check to prevent overflows in case of bugs.
        require(balances[relayRequest.relayData.paymaster] >= charge, "Should not get here");
        balances[relayRequest.relayData.paymaster] -= charge;
        balances[workerToManager[msg.sender]] += charge;

        emit TransactionRelayed(
            workerToManager[msg.sender],
            msg.sender,
            relayRequest.relayData.senderAddress,
            relayRequest.target,
            relayRequest.relayData.paymaster,
            vars.functionSelector,
            vars.status,
            charge);
        return (true, "");
    }

    struct AtomicData {
        uint256 balanceBefore;
        bytes32 preReturnValue;
        bool relayedCallSuccess;
        bytes data;
    }

    function recipientCallsAtomic(
        GSNTypes.RelayRequest calldata relayRequest,
        bytes calldata signature,
        GSNTypes.GasLimits calldata gasLimits,
        uint256 totalInitialGas,
        uint256 calldataGas,
        bytes calldata recipientContext
    )
    external
    returns (RelayCallStatus)
    {
        AtomicData memory atomicData;
        // A new gas measurement is performed inside recipientCallsAtomic, since
        // due to EIP150 available gas amounts cannot be directly compared across external calls

        // This external function can only be called by RelayHub itself, creating an internal transaction. Calls to the
        // recipient (preRelayedCall, the relayedCall, and postRelayedCall) are called from inside this transaction.
        require(msg.sender == address(this), "Only RelayHub should call this function");

        // If either pre or post reverts, the whole internal transaction will be reverted, reverting all side effects on
        // the recipient. The recipient will still be charged for the used gas by the relay.

        // The recipient is no allowed to withdraw balance from RelayHub during a relayed transaction. We check pre and
        // post state to ensure this doesn't happen.
        atomicData.balanceBefore = balances[relayRequest.relayData.paymaster];

        // First preRelayedCall is executed.
        // Note: we open a new block to avoid growing the stack too much.
        atomicData.data = abi.encodeWithSelector(
            IPaymaster.preRelayedCall.selector, recipientContext
        );
        {
            bool success;
            bytes memory retData;
            // preRelayedCall may revert, but the recipient will still be charged: it should ensure in
            // acceptRelayedCall that this will not happen.
            (success, retData) = relayRequest.relayData.paymaster.call{gas:gasLimits.preRelayedCallGasLimit}(atomicData.data);
            if (!success) {
                revertWithStatus(RelayCallStatus.PreRelayedFailed);
            }
            atomicData.preReturnValue = abi.decode(retData, (bytes32));
        }
        // The actual relayed call is now executed. The sender's address is appended at the end of the transaction data
        (atomicData.relayedCallSuccess,) =
        relayRequest.relayData.forwarder.call(
            abi.encodeWithSelector(ITrustedForwarder.verifyAndCall.selector, relayRequest, signature)
        );

        // Finally, postRelayedCall is executed, with the relayedCall execution's status and a charge estimate
        // We now determine how much the recipient will be charged, to pass this value to postRelayedCall for accurate
        // accounting.
        atomicData.data = abi.encodeWithSelector(
            IPaymaster.postRelayedCall.selector,
            recipientContext,
            atomicData.relayedCallSuccess,
            atomicData.preReturnValue,
            totalInitialGas - gasleft() + GAS_OVERHEAD + calldataGas,
            relayRequest.gasData
        );

        (bool successPost,) = relayRequest.relayData.paymaster.call{gas:gasLimits.postRelayedCallGasLimit}(atomicData.data);

        if (!successPost) {
            revertWithStatus(RelayCallStatus.PostRelayedFailed);
        }

        if (balances[relayRequest.relayData.paymaster] < atomicData.balanceBefore) {
            revertWithStatus(RelayCallStatus.RecipientBalanceChanged);
        }

        return atomicData.relayedCallSuccess ? RelayCallStatus.OK : RelayCallStatus.RelayedCallFailed;
    }

    /**
     * @dev Reverts the transaction with return data set to the ABI encoding of the status argument.
     */
    function revertWithStatus(RelayCallStatus status) private pure {
        bytes memory data = abi.encode(status);

        assembly {
            let dataSize := mload(data)
            let dataPtr := add(data, 32)

            revert(dataPtr, dataSize)
        }
    }

    function calculateCharge(uint256 gasUsed, GSNTypes.GasData memory gasData) public override virtual view returns (uint256) {
        return gasData.baseRelayFee + (gasUsed * gasData.gasPrice * (100 + gasData.pctRelayFee)) / 100;
    }

    modifier penalizerOnly () {
        require(msg.sender == address(penalizer), "Not penalizer");
        _;
    }

    function penalize(address relayWorker, address payable beneficiary) external override penalizerOnly {
        address relayManager = workerToManager[relayWorker];
        // The worker must be controlled by a manager with a locked stake
        require(relayManager != address(0), "Unknown relay worker");
        require(
            stakeManager.isRelayManagerStaked(relayManager, MINIMUM_STAKE, MINIMUM_UNSTAKE_DELAY),
            "relay manager not staked"
        );
        (uint256 totalStake, , , ) = stakeManager.stakes(relayManager);
        stakeManager.penalizeRelayManager(relayManager, beneficiary, totalStake);
    }
}
