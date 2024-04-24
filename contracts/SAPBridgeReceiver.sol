// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Withdraw} from "./utils/Withdraw.sol";
import "./SAClientERC20.sol";

contract SAPBridgeReceiver is CCIPReceiver, Withdraw {
    event MessageReceived(
        bytes32 latestMessageId,
        uint64 latestSourceChainSelector,
        address latestSender,
        address sa,
        bytes ciphertext
    );

    address private immutable _saClientERC20;
    mapping(uint256 => mapping(address => bool)) allowedSenders; // allowedSenders[chainSelector][contractAddress] = bool

    constructor(address router, address saClientERC20) CCIPReceiver(router) {
        _saClientERC20 = saClientERC20;
    }

    function approveToken(address token) public onlyOwner {
        IERC20(token).approve(_saClientERC20, type(uint256).max);
    }

    function setSapSender(uint256 sourceChainSelector, address senderContract, bool isAllowed) public onlyOwner {
        allowedSenders[sourceChainSelector][senderContract] = isAllowed;
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        bytes32 latestMessageId = message.messageId;
        uint64 latestSourceChainSelector = message.sourceChainSelector;
        address latestSender = abi.decode(message.sender, (address));
        require(allowedSenders[latestSourceChainSelector][latestSender], "Not from allowed sender");
        (address sa, bytes memory ciphertext) = abi.decode(
            message.data, (address, bytes)
        );
        Client.EVMTokenAmount[] memory tokenAmounts = message.destTokenAmounts;

        emit MessageReceived(
            latestMessageId,
            latestSourceChainSelector,
            latestSender,
            sa,
            ciphertext
        );

        SAClientERC20(_saClientERC20).transferContractToSA(sa, tokenAmounts[0].token, uint216(tokenAmounts[0].amount), ciphertext);
    }
}
