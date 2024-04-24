// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {Withdraw} from "./utils/Withdraw.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./utils/ISAPHandler.sol";
import "./utils/IBlackList.sol";

contract SAPBridge is Withdraw, ISAPHandler {
    address immutable ccipRouter;
    IBlackList blackList;
    mapping(address => bool) internal exemptList; // Address list of fee exemption
    mapping(uint64 => address) private sapBridgeReceivers;

    struct FeeParameter {
        uint24 rate; // 1feeRate = 1/1,000,000
        uint96 cap;
        uint96 floor;
    }
    mapping(uint64 => mapping(uint256 => mapping(address => FeeParameter))) public feeParam; // feeParam[destinationChainSelector][actionId][tokenAddress] = FeeParameter
    uint256 internal constant ACTION_EOAtoSA = 1;
    uint256 internal constant ACTION_SAtoEOA = 2;
    uint256 internal constant ACTION_SAtoSA = 3;

    event SAMessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address sapBridgeReceiver,
        address destination,
        address token,
        uint256 amount,
        uint256 bridgeGas,
        bytes ciphertext
    );

    event NormalAddressMessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address sapBridgeReceiver,
        address destination,
        address token,
        uint256 amount,
        uint256 bridgeGas
    );

    error NotSupported();

    constructor(address router, address blackListAddress) {
        ccipRouter = router;
        blackList = IBlackList(blackListAddress);
    }

    function setSapReceiver(uint64 destinationChainSelector, address sapBridgeReceiver) external onlyOwner {
        sapBridgeReceivers[destinationChainSelector] = sapBridgeReceiver;
    }

    function setBlackList(address blackListAddress) external onlyOwner {
        blackList = IBlackList(blackListAddress);
    }

    function approveToken(address token) external onlyOwner {
        IERC20(token).approve(ccipRouter, type(uint256).max);
    }

    function calcBridgeGas(uint64 destinationChainSelector, address saDest, address token, uint256 amount,
    bytes memory keyCipher) external view returns (uint256 bridgeGas) {
        (, bridgeGas) = _calcBridgeGasToSA(destinationChainSelector, saDest, token, amount, keyCipher);
    }

    function _calcBridgeGasToSA(uint64 destinationChainSelector, address saDest, address token, uint256 amount,
    bytes memory keyCipher) internal view returns (Client.EVM2AnyMessage memory message, uint256 bridgeGas) {
        message = _packMessageToSA(destinationChainSelector, saDest, token, amount, keyCipher);
        bridgeGas = IRouterClient(ccipRouter).getFee(destinationChainSelector, message);
    }

    function calcBridgeGasToEOA(uint64 destinationChainSelector, address eoaDest, address token, uint256 amount)
    external view returns (uint256 bridgeGas) {
        (, bridgeGas) = _calcBridgeGasToEOA(destinationChainSelector, eoaDest, token, amount);
    }

    function _calcBridgeGasToEOA(uint64 destinationChainSelector, address eoaDest, address token, uint256 amount)
    internal view returns (Client.EVM2AnyMessage memory message, uint256 bridgeGas) {
        message = _packMessageToEOA(eoaDest, token, amount);
        bridgeGas = IRouterClient(ccipRouter).getFee(destinationChainSelector, message);
    }

    function _calcFee(uint64 destinationChainSelector, uint256 actionId, address tokenAddress,
    uint256 amount) internal view returns (uint256 fee) {
        FeeParameter storage fParam = feeParam[destinationChainSelector][actionId][tokenAddress];
        require(fParam.cap > 0, "Token not allowed");
        fee = (amount * fParam.rate) / 1000000;
        uint96 cap = fParam.cap;
        uint96 floor = fParam.floor;
        if (fee < floor) {
            fee = floor;
        } else if (fee > cap) {
            fee = cap;
        }
    }

    function calcFee(uint64 destinationChainSelector, uint256 actionId, address tokenAddress, uint256 amount)
    external view returns (uint256 fee) {
        return _calcFee(destinationChainSelector, actionId, tokenAddress, amount);
    }

    function getFeeParam(uint64 destinationChainSelector, uint256 actionId, address tokenAddress)
    external view returns (uint24 rate, uint96 cap, uint96 floor) {
        FeeParameter storage fParam = feeParam[destinationChainSelector][actionId][tokenAddress];
        rate = fParam.rate;
        cap = fParam.cap;
        floor = fParam.floor;
    }

    function setFee(uint64 destinationChainSelector, uint256 actionId, address tokenAddress, uint24 rate,
    uint96 cap, uint96 floor) external onlyOwner {
        feeParam[destinationChainSelector][actionId][tokenAddress].rate = rate;
        feeParam[destinationChainSelector][actionId][tokenAddress].cap = cap;
        feeParam[destinationChainSelector][actionId][tokenAddress].floor = floor;
    }

    function setExempt(address exemptAddr, bool isExempt) external onlyOwner {
        exemptList[exemptAddr] = isExempt;
    }

    function _packMessageToSA(uint64 destinationChainSelector, address saDest, address token, uint256 amount,
    bytes memory keyCipher) internal view returns (Client.EVM2AnyMessage memory message) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({token: token, amount: amount});
        tokenAmounts[0] = tokenAmount;

        message = Client.EVM2AnyMessage({
            receiver: abi.encode(sapBridgeReceivers[destinationChainSelector]),
            data: abi.encode(saDest, keyCipher),
            tokenAmounts: tokenAmounts,
            extraArgs: "",
            feeToken: address(0)
        });
    }

    function _packMessageToEOA(address eoaDest, address token, uint256 amount) internal pure returns (Client.EVM2AnyMessage memory message) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({token: token, amount: amount});
        tokenAmounts[0] = tokenAmount;

        message = Client.EVM2AnyMessage({
            receiver: abi.encode(eoaDest),
            data: "",
            tokenAmounts: tokenAmounts,
            extraArgs: "",
            feeToken: address(0)
        });
    }

    function _sendToSA(uint64 destinationChainSelector, address saDest, address token, uint256 amount,
    bytes memory keyCipher) internal returns (bytes32 messageId) {
        (Client.EVM2AnyMessage memory message, uint256 bridgeGas) = 
        _calcBridgeGasToSA(destinationChainSelector, saDest, token, amount, keyCipher);
        require(msg.value >= bridgeGas, "Not enough bridge gas provided");
        messageId = IRouterClient(ccipRouter).ccipSend{value: bridgeGas}(destinationChainSelector, message);
        emit SAMessageSent(messageId, destinationChainSelector, sapBridgeReceivers[destinationChainSelector],
        saDest, token, amount, bridgeGas, keyCipher);
        return messageId;
    }

    function _sendToEOA(uint64 destinationChainSelector, address eoaDest, address token, uint256 amount)
    internal returns (bytes32 messageId) {
        (Client.EVM2AnyMessage memory message, uint256 bridgeGas) = _calcBridgeGasToEOA(destinationChainSelector, eoaDest, token, amount);
        require(msg.value >= bridgeGas, "Not enough bridge gas provided");
        messageId = IRouterClient(ccipRouter).ccipSend{value: bridgeGas}(destinationChainSelector, message);
        emit NormalAddressMessageSent(messageId, destinationChainSelector, address(0), eoaDest, token, amount, bridgeGas);
        require(!blackList.isProhibited(eoaDest), "Receiver address prohitbited");
        return messageId;
    }

    function sendToSA(uint64 destinationChainSelector, address saDest, address token, uint256 amount,
    bytes memory keyCipher) external payable returns (bytes32 messageId) {
        uint256 fee = _calcFee(destinationChainSelector, ACTION_EOAtoSA, token, amount);
        uint256 total = amount + fee;
        require(IERC20(token).balanceOf(msg.sender) >= total, "Not enough token in sender wallet");
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), total);
        require(!blackList.isProhibited(msg.sender), "Sender address prohitbited");
        return _sendToSA(destinationChainSelector, saDest, token, amount, keyCipher);
    }

    function unpackUint256(uint256 packed) internal pure returns (uint8 a, uint64 b) {
        a = uint8(packed & 0xFF);
        b = uint64(packed >> 8);
    }

    function handle(uint256 actionId, address token, uint216 amount, bytes calldata paramData) external payable {
        require(exemptList[msg.sender], "Not from a exempted contract");
        (uint8 action, uint64 destinationChainSelector) = unpackUint256(actionId);
        if (action == ACTION_SAtoSA) {
            (address saDest, bytes memory keyCipher) = abi.decode(paramData, (address, bytes));
            _sendToSA(destinationChainSelector, saDest, token, amount, keyCipher);
        } else if (action == ACTION_SAtoEOA) {
            (address eoaDest) = abi.decode(paramData, (address));
            _sendToEOA(destinationChainSelector, eoaDest, token, amount);
        } else {
            revert NotSupported();
        }
    }
}
