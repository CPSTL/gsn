// SPDX-License-Identifier:MIT
pragma solidity ^0.6.2;
pragma experimental ABIEncoderV2;

import "./utils/GSNTypes.sol";
import "./utils/GsnUtils.sol";
import "./utils/EIP712Sig.sol";
import "./interfaces/ITrustedForwarder.sol";

contract TrustedForwarder is ITrustedForwarder {

    EIP712Sig private eip712sig;

    // Nonces of senders, used to prevent replay attacks
    mapping(address => uint256) private nonces;

    constructor() public {
        eip712sig = new EIP712Sig(address(this));
    }

    function getNonce(address from) external override view returns (uint256) {
        return nonces[from];
    }

    function verify(GSNTypes.RelayRequest memory req, bytes memory sig) public override view {
        _verify(req, sig);
    }

    function verifyAndCall(GSNTypes.RelayRequest memory req, bytes memory sig)
    public
    override
    {
        _verify(req, sig);
        _updateNonce(req);

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnValue) = req.target.call{gas:req.gasData.gasLimit}(abi.encodePacked(req.encodedFunction, req.relayData.senderAddress));
        // TODO: use assembly to prevent double-wrapping of the revert reason (part of GSN-37)
        require(success, GsnUtils.getError(returnValue));
    }

    function _verify(GSNTypes.RelayRequest memory req, bytes memory sig) internal view {
        _verifyNonce(req);
        _verifySig(req, sig);
    }

    function _verifyNonce(GSNTypes.RelayRequest memory req) internal view {
        require(nonces[req.relayData.senderAddress] == req.relayData.senderNonce, "nonce mismatch");
    }

    function _updateNonce(GSNTypes.RelayRequest memory req) internal {
        nonces[req.relayData.senderAddress]++;
    }

    function _verifySig(GSNTypes.RelayRequest memory req, bytes memory sig) internal view {
        require(eip712sig.verify(req, sig), "signature mismatch");
    }
}
