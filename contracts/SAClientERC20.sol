// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./utils/ISAPHandler.sol";
import "./utils/IBlackList.sol";

contract SAClientERC20 is Initializable, OwnableUpgradeable, PausableUpgradeable {
    event SATransaction(address indexed saDest, uint216 amount, address indexed token, bytes ciphertext);
    event NormalAddressTransaction(address indexed saSrc, uint216 amount, address indexed token);
    error FailedToWithdrawEth(address target, uint256 value);

    struct Account {
        bool exist;
        uint32 nonce;
        uint216 balance;
    }

    struct FeeParameter {
        uint24 rate; // 1feeRate = 1/1,000,000
        uint96 cap;
        uint96 floor;
    }

    struct RelayerRequest {
        address saSrc;
        address dest;
        address token;
        uint216 amount; 
        uint32 nonce;
        address relayerWallet;
        uint216 gas;
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint256 expireTime;
    }

    address payable public feeReceiver;
    IBlackList blackList;
    mapping(address => mapping(uint256 => mapping(address => FeeParameter))) public feeParam; // feeParam[contractAddress][actionId][tokenAddress] = FeeParameter
    mapping(address => mapping(address => uint256)) public beneficiaryBalance; // balance for transaction fee and relayer, beneficiaryBalance[roleWallet][tokenAddress] = amount
    mapping(address => mapping(address => Account)) public saAccount; // saAccount[sa][token] = Account
    mapping(address => bool) internal exemptList; // Address list of fee exemption
    
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant THIS_CONTRACT = 0x0000000000000000000000000000000000000001;
    uint256 internal constant ACTION_EOAtoSA = 1;
    uint256 internal constant ACTION_SAtoEOA = 2;
    uint256 internal constant ACTION_SAtoSA = 3;

    function initialize() public initializer {
        __Ownable_init();
        __Pausable_init();
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function setFee(address contractAddress, uint256 actionId, address tokenAddress, uint24 rate, uint96 cap, uint96 floor) external onlyOwner {
        _setFee(contractAddress, actionId, tokenAddress, rate, cap, floor);
    }

    function _setFee(address contractAddress, uint256 actionId, address tokenAddress, uint24 rate, uint96 cap, uint96 floor) internal {
        feeParam[contractAddress][actionId][tokenAddress].rate = rate;
        feeParam[contractAddress][actionId][tokenAddress].cap = cap;
        feeParam[contractAddress][actionId][tokenAddress].floor = floor;
    }

    function setFeeReceiver(address payable receiver) external onlyOwner {
        feeReceiver = receiver;
    }

    function setExempt(address exemptAddr, bool isExempt) external onlyOwner {
        exemptList[exemptAddr] = isExempt;
    }

    function setBlackList(address blackListAddress) external onlyOwner {
        blackList = IBlackList(blackListAddress);
    }

    function collectFee(address token) external whenNotPaused {
        _collectFee(token);
    }

    function _collectFee(address token) internal {
        uint256 balance = beneficiaryBalance[msg.sender][token];
        if (balance > 0) {
            beneficiaryBalance[msg.sender][token] = 0;
            if (token == NATIVE_TOKEN) {
                (bool sent, ) = msg.sender.call{value: balance}("");
                if (!sent) revert FailedToWithdrawEth(msg.sender, balance);
            } else {
                SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(token), msg.sender, balance);
            }
        }
    }

    function collectFeeBatch(address[] calldata tokens) external whenNotPaused {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            _collectFee(token);
        }
    }

    function _calcFee(address contractAddress, uint256 actionId, address tokenAddress, uint216 amount) internal view returns (uint216 fee) {
        FeeParameter storage fParam = feeParam[contractAddress][actionId][tokenAddress];
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

    function calcFee(address contractAddress, uint256 actionId, address tokenAddress, uint216 amount) external view returns (uint216 fee) {
        return _calcFee(contractAddress, actionId, tokenAddress, amount);
    }
    
    function transferEOAtoSA(address saDest, address token, uint216 amount, bytes calldata keyCipher) external payable whenNotPaused {
        _transferEOAtoSA(saDest, token, amount);
        emit SATransaction(saDest, amount, token, keyCipher);
    }

    function transferEOAtoExistingSA(address saDest, address token, uint216 amount) external payable whenNotPaused {
        _transferEOAtoSA(saDest, token, amount);
        emit SATransaction(saDest, amount, token, bytes(""));
    }

    function _transferEOAtoSA(address saDest, address token, uint216 amount) internal {
        uint216 fee = _calcFee(THIS_CONTRACT, ACTION_EOAtoSA, token, amount);
        uint216 total = amount + fee;
        if (token == NATIVE_TOKEN) {
            // Sending native token
            require(msg.value >= total, "Not enough token sended to SA");
            uint256 restAmount = msg.value - uint256(amount);
            if (restAmount > 0) beneficiaryBalance[feeReceiver][token] += restAmount;
        } else {
            // Sending contract token
            require(IERC20Upgradeable(token).balanceOf(msg.sender) >= total, "Not enough token in wallet");
            uint256 balanceBefore = IERC20Upgradeable(token).balanceOf(address(this));
            SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(token), msg.sender, address(this), total);
            uint256 balanceAfter = IERC20Upgradeable(token).balanceOf(address(this));
            require(balanceAfter - balanceBefore == total, "Balance mismatch after transfer");
            if (fee > 0) beneficiaryBalance[feeReceiver][token] += fee;
        }
        saAccount[saDest][token].exist = true;
        saAccount[saDest][token].balance += amount;
        require(!blackList.isProhibited(msg.sender), "Sender address prohitbited");
    }

    function transferContractToSA(address saDest, address token, uint216 amount, bytes calldata keyCipher) external payable whenNotPaused {
        _transferContractToSA(saDest, token, amount);
        emit SATransaction(saDest, amount, token, keyCipher);
    }

    function transferContractToExistingSA(address saDest, address token, uint216 amount) external payable whenNotPaused {
        _transferContractToSA(saDest, token, amount);
        emit SATransaction(saDest, amount, token, bytes(""));
    }

    function _transferContractToSA(address saDest, address token, uint216 amount) internal {
        // Transfer from a exempted contract, so no fee will be charged.
        require(exemptList[msg.sender], "Not from a exempted contract");
        if (token == NATIVE_TOKEN) {
            // Sending native token
            require(msg.value == amount, "Incorrect amount sended to SA");
        } else {
            // Sending contract token
            require(IERC20Upgradeable(token).balanceOf(msg.sender) >= amount, "Not enough token in wallet");
            uint256 balanceBefore = IERC20Upgradeable(token).balanceOf(address(this));
            SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(token), msg.sender, address(this), amount);
            uint256 balanceAfter = IERC20Upgradeable(token).balanceOf(address(this));
            require(balanceAfter - balanceBefore == amount, "Balance mismatch after transfer");
        }
        saAccount[saDest][token].exist = true;
        saAccount[saDest][token].balance += amount;
    }

    function transferSAtoEOA(RelayerRequest calldata relayerRequest) external whenNotPaused {
        _verifySASig(relayerRequest, ACTION_SAtoEOA);
        _transferToEVMAddr(_calcFee(THIS_CONTRACT, ACTION_SAtoEOA, relayerRequest.token, relayerRequest.amount), relayerRequest);
        require(!blackList.isProhibited(relayerRequest.dest), "Receiver address prohitbited");
    }

    function transferSAtoSA(RelayerRequest calldata relayerRequest, bytes calldata keyCipher) external whenNotPaused {
        _verifySASig(relayerRequest, ACTION_SAtoSA, keyCipher);
        _transferSAtoSA(relayerRequest);
        emit SATransaction(relayerRequest.dest, relayerRequest.amount, relayerRequest.token, keyCipher);
    }

    function transferSAtoExistingSA(RelayerRequest calldata relayerRequest) external whenNotPaused {
        _verifySASig(relayerRequest, ACTION_SAtoSA);
        _transferSAtoSA(relayerRequest);
        emit SATransaction(relayerRequest.dest, relayerRequest.amount, relayerRequest.token, bytes(""));
    }

    function transferSAToHandler(RelayerRequest calldata relayerRequest, uint256 actionId, bytes calldata paramData) external payable whenNotPaused {
        // combine r and s together to avoid Stack too deep error
        _verifySASig(relayerRequest, actionId, paramData);
        _transferToEVMAddr(_calcFee(relayerRequest.dest, actionId, relayerRequest.token, relayerRequest.amount), relayerRequest);
        ISAPHandler(payable(relayerRequest.dest)).handle{value: msg.value}(actionId, relayerRequest.token, relayerRequest.amount, paramData);
    }

    function _verifySASig(RelayerRequest calldata relayerRequest, uint256 actionId, bytes memory paramData) internal {
        bytes32 hash = ECDSAUpgradeable.toEthSignedMessageHash(abi.encode(
            block.chainid, address(this), relayerRequest.dest, actionId, relayerRequest.token, relayerRequest.amount, paramData,
            relayerRequest.nonce, relayerRequest.relayerWallet, relayerRequest.gas, relayerRequest.expireTime));
        address addressRecover = ecrecover(hash, relayerRequest.v, relayerRequest.r, relayerRequest.s);
        require(addressRecover == relayerRequest.saSrc && addressRecover != address(0), "Fail to verify signature");
        require(saAccount[relayerRequest.saSrc][relayerRequest.token].nonce == relayerRequest.nonce, "Incorrect nonce");
        require(block.timestamp <= relayerRequest.expireTime, "Request expired");
        saAccount[relayerRequest.saSrc][relayerRequest.token].nonce += 1;
    }

    function _verifySASig(RelayerRequest calldata relayerRequest, uint256 actionId) internal {
        _verifySASig(relayerRequest, actionId, "");
    }

    function _transferSAtoSA(RelayerRequest calldata relayerRequest) internal {
        uint216 fee = _calcFee(THIS_CONTRACT, ACTION_SAtoSA, relayerRequest.token, relayerRequest.amount);
        uint216 total = relayerRequest.amount + fee + relayerRequest.gas;
        require(saAccount[relayerRequest.saSrc][relayerRequest.token].balance >= total, "Not enough token in SA balance");

        saAccount[relayerRequest.saSrc][relayerRequest.token].balance -= total;
        if (fee > 0) beneficiaryBalance[feeReceiver][relayerRequest.token] += fee;
        saAccount[relayerRequest.dest][relayerRequest.token].exist = true;
        saAccount[relayerRequest.dest][relayerRequest.token].balance += relayerRequest.amount;
        if (relayerRequest.gas > 0) beneficiaryBalance[relayerRequest.relayerWallet][relayerRequest.token] += relayerRequest.gas;
    }

    function _transferToEVMAddr(uint216 fee, RelayerRequest calldata relayerRequest) internal {
        uint216 total = relayerRequest.amount + relayerRequest.gas + fee;
        require(saAccount[relayerRequest.saSrc][relayerRequest.token].balance >= total, "Not enough token in SA balance");

        saAccount[relayerRequest.saSrc][relayerRequest.token].balance -= total;
        if (relayerRequest.token == NATIVE_TOKEN) {
            (bool sent, ) = payable(relayerRequest.dest).call{value: relayerRequest.amount}("");
            if (!sent) revert FailedToWithdrawEth(relayerRequest.dest, relayerRequest.amount);
        } else {
            uint256 balanceBefore = IERC20Upgradeable(relayerRequest.token).balanceOf(address(this));
            SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(relayerRequest.token), relayerRequest.dest, relayerRequest.amount);
            uint256 balanceAfter = IERC20Upgradeable(relayerRequest.token).balanceOf(address(this));
            require(balanceBefore - balanceAfter == relayerRequest.amount, "Balance mismatch after transfer");
        }
        if (relayerRequest.gas > 0) beneficiaryBalance[relayerRequest.relayerWallet][relayerRequest.token] += relayerRequest.gas;
        if (fee > 0) beneficiaryBalance[feeReceiver][relayerRequest.token] += fee;
        emit NormalAddressTransaction(relayerRequest.saSrc, relayerRequest.amount, relayerRequest.token);
    }

    function getSA(address sa, address token) external view returns (uint32 nonce, uint216 balance) {
        Account storage saInfo = saAccount[sa][token];
        return (saInfo.nonce, saInfo.balance);
    }

    function existSA(address sa, address[] calldata tokens) external view returns (bool isExist) {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (saAccount[sa][token].exist) return true;
        }
        return false;
    }

    function getFeeParam(address contractAddress, uint256 actionId, address tokenAddress)
    external view returns (uint24 rate, uint96 cap, uint96 floor) {
        FeeParameter storage fParam = feeParam[contractAddress][actionId][tokenAddress];
        rate = fParam.rate;
        cap = fParam.cap;
        floor = fParam.floor;
    }
}
