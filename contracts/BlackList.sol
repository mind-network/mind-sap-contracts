// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./utils/IBlackList.sol";

contract BlackList is Ownable, IBlackList {
    mapping(address => bool) public addressPool;

    function isProhibited(address addr) external view returns (bool) {
        return addressPool[addr];
    }

    function setProhibited(address[] calldata addrList) external onlyOwner {
        for (uint256 i = 0; i < addrList.length; i++) {
            addressPool[addrList[i]] = true;
        }
    }

    function revokeProhibited(address[] calldata addrList) external onlyOwner {
        for (uint256 i = 0; i < addrList.length; i++) {
            addressPool[addrList[i]] = false;
        }
    }
}
