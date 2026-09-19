// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MultisigPayroll
/// @notice M-of-N multisig treasury that executes ETH/ERC-20 payroll payments
///         authorized off-chain via EIP-712 typed signatures and relayed on-chain
///         by anyone holding a quorum of owner signatures.
/// @dev ERC-20 payroll is expressed as a native call into the token contract
///      (`to` = token, `value` = 0, `data` = encoded `transfer(...)` call), so the
///      same typed struct and execution path covers both ETH and token payroll.
contract MultisigPayroll is EIP712, ReentrancyGuard {
    // ---------- Types ----------

    struct Payment {
        address to;
        uint256 value;
        bytes data;
        uint256 nonce;
        uint256 deadline;
        uint256 chainId;
        address verifyingContract;
    }

    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "Payment(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline,uint256 chainId,address verifyingContract)"
    );

    // ---------- Storage ----------

    mapping(address => bool) public isOwner;
    address[] public owners;
    uint256 public threshold;
    mapping(uint256 => bool) public usedNonces;

    // ---------- Events ----------

    event PaymentExecuted(
        uint256 indexed nonce, address indexed to, uint256 value, bytes data, address indexed relayer
    );
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);
    event Deposited(address indexed sender, uint256 amount);

    // ---------- Errors ----------

    error ZeroAddress();
    error NotOwner(address account);
    error AlreadyOwner(address account);
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);
    error DuplicateOwner(address account);
    error DuplicateSigner(address signer);
    error InvalidSignature();
    error InsufficientSignatures(uint256 provided, uint256 required);
    error Expired(uint256 deadline);
    error NonceAlreadyUsed(uint256 nonce);
    error ChainIdMismatch(uint256 expected, uint256 actual);
    error ContractMismatch(address expected, address actual);
    error ExecutionFailed(bytes returnData);
    error OnlySelf();
    error EmptyOwners();

    // ---------- Modifiers ----------

    /// @dev Owner-management functions may only be invoked by the contract
    ///      itself, i.e. through a successfully authorized `execute` call
    ///      that targets `address(this)`. This forces owner/threshold
    ///      changes through the same M-of-N signature quorum as payroll.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    // ---------- Constructor ----------

    constructor(address[] memory _owners, uint256 _threshold) EIP712("MultisigPayroll", "1") {
        uint256 len = _owners.length;
        if (len == 0) revert EmptyOwners();
        if (_threshold == 0 || _threshold > len) revert InvalidThreshold(_threshold, len);

        for (uint256 i = 0; i < len; i++) {
            address owner_ = _owners[i];
            if (owner_ == address(0)) revert ZeroAddress();
            if (isOwner[owner_]) revert DuplicateOwner(owner_);
            isOwner[owner_] = true;
            owners.push(owner_);
            emit OwnerAdded(owner_);
        }

        threshold = _threshold;
        emit ThresholdChanged(0, _threshold);
    }

    // ---------- Receive ----------

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // ---------- Execution ----------

    /// @notice Executes a signed payment after validating a quorum of unique,
    ///         authorized owner signatures over the EIP-712 typed payload.
    /// @param payment The typed payment payload.
    /// @param signatures Array of owner signatures over the payment's EIP-712 digest.
    function execute(Payment calldata payment, bytes[] calldata signatures)
        external
        nonReentrant
        returns (bytes memory returnData)
    {
        if (block.timestamp > payment.deadline) revert Expired(payment.deadline);
        if (usedNonces[payment.nonce]) revert NonceAlreadyUsed(payment.nonce);
        if (payment.chainId != block.chainid) {
            revert ChainIdMismatch(payment.chainId, block.chainid);
        }
        if (payment.verifyingContract != address(this)) {
            revert ContractMismatch(payment.verifyingContract, address(this));
        }

        uint256 required = threshold;
        if (signatures.length < required) {
            revert InsufficientSignatures(signatures.length, required);
        }

        bytes32 digest = hashPayment(payment);

        address[] memory seen = new address[](signatures.length);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!isOwner[signer]) revert InvalidSignature();
            for (uint256 j = 0; j < i; j++) {
                if (seen[j] == signer) revert DuplicateSigner(signer);
            }
            seen[i] = signer;
        }

        // Effects before interaction: nonce is consumed prior to the external call.
        usedNonces[payment.nonce] = true;

        (bool success, bytes memory ret) = payment.to.call{value: payment.value}(payment.data);
        if (!success) revert ExecutionFailed(ret);
        returnData = ret;

        emit PaymentExecuted(payment.nonce, payment.to, payment.value, payment.data, msg.sender);
    }

    // ---------- Owner management (self-authorized only) ----------

    function addOwner(address newOwner, uint256 newThreshold) external onlySelf {
        if (newOwner == address(0)) revert ZeroAddress();
        if (isOwner[newOwner]) revert AlreadyOwner(newOwner);

        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);

        _changeThreshold(newThreshold);
    }

    function removeOwner(address ownerToRemove, uint256 newThreshold) external onlySelf {
        if (!isOwner[ownerToRemove]) revert NotOwner(ownerToRemove);

        isOwner[ownerToRemove] = false;
        uint256 len = owners.length;
        for (uint256 i = 0; i < len; i++) {
            if (owners[i] == ownerToRemove) {
                owners[i] = owners[len - 1];
                owners.pop();
                break;
            }
        }
        emit OwnerRemoved(ownerToRemove);

        _changeThreshold(newThreshold);
    }

    function changeThreshold(uint256 newThreshold) external onlySelf {
        _changeThreshold(newThreshold);
    }

    function _changeThreshold(uint256 newThreshold) internal {
        uint256 len = owners.length;
        if (newThreshold == 0 || newThreshold > len) {
            revert InvalidThreshold(newThreshold, len);
        }
        emit ThresholdChanged(threshold, newThreshold);
        threshold = newThreshold;
    }

    // ---------- Views ----------

    function hashPayment(Payment calldata payment) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_TYPEHASH,
                payment.to,
                payment.value,
                keccak256(payment.data),
                payment.nonce,
                payment.deadline,
                payment.chainId,
                payment.verifyingContract
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function ownerCount() external view returns (uint256) {
        return owners.length;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}