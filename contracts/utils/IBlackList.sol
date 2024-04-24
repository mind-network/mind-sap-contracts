// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBlackList {
    function isProhibited(address addr) external view returns (bool);
}
