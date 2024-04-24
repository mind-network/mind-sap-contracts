// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISAPHandler {
    function handle(uint256 actionId, address token, uint216 amount, bytes calldata paramData) external payable;
}
