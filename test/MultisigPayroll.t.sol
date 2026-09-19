// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultisigPayroll} from "../src/MultisigPayroll.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockTarget} from "../src/mocks/MockTarget.sol";
import {MockReentrantAttacker} from "../src/mocks/MockReentrantAttacker.sol";

contract MultisigPayrollTest is Test {
    event PaymentExecuted(
        uint256 indexed nonce, address indexed to, uint256 value, bytes data, address indexed relayer
    );

    MultisigPayroll internal payroll;
    MockERC20 internal token;
    MockTarget internal target;

    address internal owner1;
    uint256 internal owner1Key;
    address internal owner2;
    uint256 internal owner2Key;
    address internal owner3;
    uint256 internal owner3Key;
    address internal stranger;
    uint256 internal strangerKey;

    address internal relayer = address(0xBEEF);
    uint256 internal constant THRESHOLD = 2;
    uint256 internal constant STARTING_BALANCE = 100 ether;

    // ---------- Setup ----------

    function setUp() public {
        (owner1, owner1Key) = makeAddrAndKey("owner1");
        (owner2, owner2Key) = makeAddrAndKey("owner2");
        (owner3, owner3Key) = makeAddrAndKey("owner3");
        (stranger, strangerKey) = makeAddrAndKey("stranger");

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        payroll = new MultisigPayroll(owners, THRESHOLD);
        token = new MockERC20("Payroll USD", "pUSD");
        target = new MockTarget();

        vm.deal(address(payroll), STARTING_BALANCE);
        token.mint(address(payroll), STARTING_BALANCE);
    }

    // ---------- Internal helpers ----------

    function _payment(address to, uint256 value, bytes memory data, uint256 nonce, uint256 deadline)
        internal
        view
        returns (MultisigPayroll.Payment memory)
    {
        return MultisigPayroll.Payment({
            to: to,
            value: value,
            data: data,
            nonce: nonce,
            deadline: deadline,
            chainId: block.chainid,
            verifyingContract: address(payroll)
        });
    }

    function _sign(uint256 privateKey, MultisigPayroll.Payment memory payment) internal view returns (bytes memory) {
        bytes32 digest = payroll.hashPayment(payment);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _quorumSignatures(MultisigPayroll.Payment memory payment)
        internal
        view
        returns (bytes[] memory sigs)
    {
        sigs = new bytes[](2);
        sigs[0] = _sign(owner1Key, payment);
        sigs[1] = _sign(owner2Key, payment);
    }

    function _erc20TransferData(address to, uint256 amount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(token.transfer.selector, to, amount);
    }

    // ---------- Constructor ----------

    function test_Constructor_SetsOwnersAndThreshold() public view {
        assertEq(payroll.threshold(), THRESHOLD);
        assertEq(payroll.ownerCount(), 3);
        assertTrue(payroll.isOwner(owner1));
        assertTrue(payroll.isOwner(owner2));
        assertTrue(payroll.isOwner(owner3));
        assertFalse(payroll.isOwner(stranger));
    }

    function test_RevertWhen_ConstructorThresholdIsZero() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.InvalidThreshold.selector, 0, 1));
        new MultisigPayroll(owners, 0);
    }

    function test_RevertWhen_ConstructorThresholdExceedsOwnerCount() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.InvalidThreshold.selector, 3, 2));
        new MultisigPayroll(owners, 3);
    }

    function test_RevertWhen_ConstructorHasDuplicateOwner() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner1;
        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.DuplicateOwner.selector, owner1));
        new MultisigPayroll(owners, 1);
    }

    function test_RevertWhen_ConstructorHasZeroAddressOwner() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = address(0);
        vm.expectRevert(MultisigPayroll.ZeroAddress.selector);
        new MultisigPayroll(owners, 1);
    }

    function test_RevertWhen_ConstructorHasNoOwners() public {
        address[] memory owners = new address[](0);
        vm.expectRevert(MultisigPayroll.EmptyOwners.selector);
        new MultisigPayroll(owners, 1);
    }

    // ---------- Main flow: ETH payroll ----------

    function test_ExecuteEthPayment_MainFlow() public {
        uint256 amount = 1 ether;
        MultisigPayroll.Payment memory payment = _payment(target, amount, "", 1, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);

        uint256 targetBalanceBefore = address(target).balance;

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true, address(payroll));
        emit PaymentExecuted(payment.nonce, payment.to, payment.value, payment.data, relayer);
        payroll.execute(payment, sigs);

        assertEq(address(target).balance, targetBalanceBefore + amount);
        assertTrue(payroll.usedNonces(1));
    }

    function _payment(MockTarget to, uint256 value, bytes memory data, uint256 nonce, uint256 deadline)
        internal
        view
        returns (MultisigPayroll.Payment memory)
    {
        return _payment(address(to), value, data, nonce, deadline);
    }

    // ---------- Main flow: ERC-20 payroll ----------

    function test_ExecuteErc20Payment_MainFlow() public {
        uint256 amount = 50 ether;
        bytes memory data = _erc20TransferData(stranger, amount);
        MultisigPayroll.Payment memory payment = _payment(address(token), 0, data, 1, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);

        payroll.execute(payment, sigs);

        assertEq(token.balanceOf(stranger), amount);
        assertEq(token.balanceOf(address(payroll)), STARTING_BALANCE - amount);
    }

    function test_Execute_AcceptsSignaturesInAnyOwnerOrder() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(owner3Key, payment);
        sigs[1] = _sign(owner1Key, payment);

        payroll.execute(payment, sigs);
        assertTrue(payroll.usedNonces(1));
    }

    function test_Execute_AcceptsMoreThanThresholdSignatures() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _sign(owner1Key, payment);
        sigs[1] = _sign(owner2Key, payment);
        sigs[2] = _sign(owner3Key, payment);

        payroll.execute(payment, sigs);
        assertTrue(payroll.usedNonces(1));
    }

    // ---------- Unauthorized / invalid signature flows ----------

    function test_RevertWhen_SignerIsNotAnOwner() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(owner1Key, payment);
        sigs[1] = _sign(strangerKey, payment);

        vm.expectRevert(MultisigPayroll.InvalidSignature.selector);
        payroll.execute(payment, sigs);
    }

    function test_RevertWhen_SignatureIsDuplicated() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        bytes memory sig = _sign(owner1Key, payment);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig;
        sigs[1] = sig;

        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.DuplicateSigner.selector, owner1));
        payroll.execute(payment, sigs);
    }

    function test_RevertWhen_TooFewSignaturesProvided() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(owner1Key, payment);

        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.InsufficientSignatures.selector, 1, THRESHOLD));
        payroll.execute(payment, sigs);
    }

    function test_RevertWhen_SignatureIsMalformed() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(owner1Key, payment);
        sigs[1] = hex"deadbeef";

        vm.expectRevert();
        payroll.execute(payment, sigs);
    }

    // ---------- Replay / expiry / domain-binding flows ----------

    function test_RevertWhen_NonceIsReused() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);
        payroll.execute(payment, sigs);

        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.NonceAlreadyUsed.selector, 1));
        payroll.execute(payment, sigs);
    }

    function test_RevertWhen_DeadlineHasPassed() public {
        uint256 deadline = block.timestamp + 1 hours;
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, deadline);
        bytes[] memory sigs = _quorumSignatures(payment);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.Expired.selector, deadline));
        payroll.execute(payment, sigs);
    }

    function test_RevertWhen_ChainIdDoesNotMatch() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        payment.chainId = block.chainid + 1;
        bytes[] memory sigs = _quorumSignatures(payment);

        vm.expectRevert(
            abi.encodeWithSelector(MultisigPayroll.ChainIdMismatch.selector, block.chainid + 1, block.chainid)
        );
        payroll.execute(payment, sigs);
    }

    function test_RevertWhen_VerifyingContractDoesNotMatch() public {
        MultisigPayroll.Payment memory payment = _payment(address(target), 1 ether, "", 1, block.timestamp + 1 days);
        payment.verifyingContract = address(0xC0FFEE);
        bytes[] memory sigs = _quorumSignatures(payment);

        vm.expectRevert(
            abi.encodeWithSelector(MultisigPayroll.ContractMismatch.selector, address(0xC0FFEE), address(payroll))
        );
        payroll.execute(payment, sigs);
    }

    // ---------- Failed target call ----------

    function test_RevertWhen_TargetCallFails() public {
        bytes memory data = abi.encodeWithSelector(target.alwaysReverts.selector);
        MultisigPayroll.Payment memory payment = _payment(address(target), 0, data, 1, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);

        vm.expectRevert();
        payroll.execute(payment, sigs);
        assertFalse(payroll.usedNonces(1));
    }

    // ---------- Reentrancy ----------

    function test_RevertWhen_ExecuteReentersItself() public {
        MockReentrantAttacker attacker = new MockReentrantAttacker(address(payroll));

        MultisigPayroll.Payment memory innerPayment =
            _payment(address(target), 1 ether, "", 2, block.timestamp + 1 days);
        bytes[] memory innerSigs = _quorumSignatures(innerPayment);
        attacker.setReentryCalldata(abi.encodeCall(MultisigPayroll.execute, (innerPayment, innerSigs)));

        MultisigPayroll.Payment memory outerPayment =
            _payment(address(attacker), 1 ether, "", 1, block.timestamp + 1 days);
        bytes[] memory outerSigs = _quorumSignatures(outerPayment);

        payroll.execute(outerPayment, outerSigs);

        assertTrue(attacker.reentryAttempted());
        assertFalse(attacker.reentrySucceeded(), "reentrant execute() call must be blocked");
        assertTrue(payroll.usedNonces(1), "outer payment should still succeed");
        assertFalse(payroll.usedNonces(2), "inner (reentrant) payment must not be consumed");
    }

    function _payment(MockReentrantAttacker to, uint256 value, bytes memory data, uint256 nonce, uint256 deadline)
        internal
        view
        returns (MultisigPayroll.Payment memory)
    {
        return _payment(address(to), value, data, nonce, deadline);
    }

    // ---------- Owner management (self-authorized) ----------

    function test_RevertWhen_AddOwnerCalledDirectly() public {
        vm.expectRevert(MultisigPayroll.OnlySelf.selector);
        vm.prank(owner1);
        payroll.addOwner(stranger, THRESHOLD);
    }

    function test_AddOwner_ViaSelfExecution() public {
        bytes memory data = abi.encodeCall(MultisigPayroll.addOwner, (stranger, 3));
        MultisigPayroll.Payment memory payment = _payment(address(payroll), 0, data, 1, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);

        payroll.execute(payment, sigs);

        assertTrue(payroll.isOwner(stranger));
        assertEq(payroll.ownerCount(), 4);
        assertEq(payroll.threshold(), 3);
    }

    function test_RemoveOwner_ViaSelfExecution() public {
        bytes memory data = abi.encodeCall(MultisigPayroll.removeOwner, (owner3, 2));
        MultisigPayroll.Payment memory payment = _payment(address(payroll), 0, data, 1, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);

        payroll.execute(payment, sigs);

        assertFalse(payroll.isOwner(owner3));
        assertEq(payroll.ownerCount(), 2);
        assertEq(payroll.threshold(), 2);
    }

    function test_RevertWhen_RemoveOwnerDropsThresholdBelowValidRange() public {
        bytes memory data = abi.encodeCall(MultisigPayroll.removeOwner, (owner3, 3));
        MultisigPayroll.Payment memory payment = _payment(address(payroll), 0, data, 1, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);

        vm.expectRevert();
        payroll.execute(payment, sigs);
    }

    function test_ChangeThreshold_ViaSelfExecution() public {
        bytes memory data = abi.encodeCall(MultisigPayroll.changeThreshold, (3));
        MultisigPayroll.Payment memory payment = _payment(address(payroll), 0, data, 1, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);

        payroll.execute(payment, sigs);

        assertEq(payroll.threshold(), 3);
    }

    // ---------- Fuzz ----------

    function testFuzz_ExecuteEthPayment_ArbitraryAmountAndNonce(uint256 amount, uint256 nonce) public {
        amount = bound(amount, 0, STARTING_BALANCE);
        vm.assume(nonce != 0);

        MultisigPayroll.Payment memory payment =
            _payment(address(target), amount, "", nonce, block.timestamp + 1 days);
        bytes[] memory sigs = _quorumSignatures(payment);

        uint256 targetBalanceBefore = address(target).balance;
        payroll.execute(payment, sigs);

        assertEq(address(target).balance, targetBalanceBefore + amount);
        assertTrue(payroll.usedNonces(nonce));

        vm.expectRevert(abi.encodeWithSelector(MultisigPayroll.NonceAlreadyUsed.selector, nonce));
        payroll.execute(payment, sigs);
    }
}