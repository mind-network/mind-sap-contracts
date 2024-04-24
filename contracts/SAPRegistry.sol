// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract SAPRegistry {
    event KeyChanged(address indexed walletAddress);

    struct KeySet {
        bytes32[2] opPubKey;
        bytes32[8] encPubKey;
        bytes32[16] opPriKeyCipher;
    }
    mapping(address => KeySet) private keyStore;

    function setKeys(bytes32[2] calldata opPubKey, bytes32[8] calldata encPubKey, bytes32[16] calldata opPriKeyCipher) external {
        emit KeyChanged(msg.sender);

        keyStore[msg.sender].opPubKey = opPubKey;
        keyStore[msg.sender].encPubKey = encPubKey;
        keyStore[msg.sender].opPriKeyCipher = opPriKeyCipher;
    }

    function getKeys(address walletAddress) external view
    returns (bytes32[2] memory opPubKey, bytes32[8] memory encPubKey, bytes32[16] memory opPriKeyCipher) {
        KeySet storage data = keyStore[walletAddress];
        return (data.opPubKey, data.encPubKey, data.opPriKeyCipher);
    }
}