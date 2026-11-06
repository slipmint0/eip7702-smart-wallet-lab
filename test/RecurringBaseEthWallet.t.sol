
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/RecurringBaseEthWallet.sol";

interface Vm {
    function warp(uint256 newTimestamp) external;
    function deal(address account, uint256 newBalance) external;
    function prank(address sender) external;
    function expectRevert(bytes4) external;
    function chainId(uint256 newChainId) external;
    function etch(address target, bytes calldata code) external;
}

// Mock Chainlink ETH/USD feed.
// Returns $2,000 with 8 decimal places.
contract MockEthUsdFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (
            1,
            2000e8,
            1,
            block.timestamp,
            1
        );
    }
}

// Mock Base sequencer uptime feed.
// Answer 0 means the sequencer is up.
contract MockSequencerFeed {
    function decimals() external pure returns (uint8) {
        return 0;
    }

    function latestRoundData()
        external
        pure
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (
            1,
            0,
            1,
            1,
            1
        );
    }
}

contract RecurringBaseEthWalletTest {
    Vm private constant vm =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    RecurringBaseEthWallet private wallet;

    address private keeper = address(0xBEEF);

    uint256 private constant WEEK = 7 days;

    function setUp() public {
        // Simulate Base Mainnet.
        vm.chainId(8453);

        // Ensure the timestamp is beyond the sequencer grace period.
        vm.warp(1_000_000);

        // Install mock oracle code at the contract's fixed feed addresses.
        MockEthUsdFeed ethFeed = new MockEthUsdFeed();
        MockSequencerFeed sequencerFeed = new MockSequencerFeed();

        vm.etch(
            0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            address(ethFeed).code
        );

        vm.etch(
            0xBCF85224fc0756B9Fa45aA7892530B47e10b6433,
            address(sequencerFeed).code
        );

        wallet = new RecurringBaseEthWallet();
    }

    function configureWallet() internal {
        vm.prank(address(wallet));

        wallet.configureSchedule(
            uint64(block.timestamp + 30 days),
            3,
            keeper,
            3 ether,
            0.1 ether
        );
    }

    // Test 1: The wallet starts with the correct configuration.
    function testConfigureSchedule() public {
        configureWallet();

        (
            bool initialized,
            bool enabled,
            uint64 nextPaymentAt,
            ,
            uint32 maxPayments,
            uint32 paymentsMade,
            address configuredKeeper,
            ,
        ) = wallet.getSchedule();

        require(initialized, "Wallet not initialized");
        require(enabled, "Schedule not enabled");
        require(
            nextPaymentAt == block.timestamp + WEEK,
            "Incorrect first payment date"
        );
        require(maxPayments == 3, "Incorrect payment limit");
        require(paymentsMade == 0, "Payments should start at zero");
        require(configuredKeeper == keeper, "Incorrect keeper");
    }

    // Test 2: A payment cannot happen before seven days.
    function testPaymentCannotHappenEarly() public {
        configureWallet();

        vm.prank(keeper);

        vm.expectRevert(
            RecurringBaseEthWallet.PaymentNotDue.selector
        );

        wallet.executePayment();
    }

    // Test 3: An unauthorized account cannot execute payments.
    function testUnauthorizedKeeperRejected() public {
        configureWallet();

        vm.warp(block.timestamp + WEEK);

        vm.prank(address(0x1234));

        vm.expectRevert(
            RecurringBaseEthWallet.OnlyKeeper.selector
        );

        wallet.executePayment();
    }

    // Test 4: A successful payment sends approximately 2 ETH.
    // At $2,000 per ETH, $4,000 equals 2 ETH.
    function testSuccessfulPayment() public {
        configureWallet();

        vm.deal(address(wallet), 2.1 ether);

        vm.warp(block.timestamp + WEEK);

        address payable recipient = wallet.RECIPIENT();

        uint256 balanceBefore = recipient.balance;

        vm.prank(keeper);
        wallet.executePayment();

        uint256 balanceAfter = recipient.balance;

        require(
            balanceAfter - balanceBefore == 2 ether,
            "Incorrect payment amount"
        );

        (
            ,
            ,
            ,
            ,
            ,
            uint32 paymentsMade,
            ,
            ,

        ) = wallet.getSchedule();

        require(paymentsMade == 1, "Payment count incorrect");
    }

    // Test 5: A paused schedule cannot execute payments.
    function testPausedScheduleCannotPay() public {
        configureWallet();

        vm.prank(address(wallet));
        wallet.pause();

        vm.warp(block.timestamp + WEEK);

        vm.prank(keeper);

        vm.expectRevert(
            RecurringBaseEthWallet.ScheduleDisabled.selector
        );

        wallet.executePayment();
    }

    // Test 6: An account other than the delegated wallet
    // cannot pause the schedule.
    function testUnauthorizedPauseRejected() public {
        configureWallet();

        vm.prank(address(0x1234));

        vm.expectRevert(
            RecurringBaseEthWallet.OnlyWalletOwner.selector
        );

        wallet.pause();
    }

    // Test 7: Insufficient balance prevents payment.
    function testInsufficientBalanceRejected() public {
        configureWallet();

        // The wallet needs 2 ETH payment + 0.1 ETH reserve.
        vm.deal(address(wallet), 2 ether);

        vm.warp(block.timestamp + WEEK);

        vm.prank(keeper);

        vm.expectRevert(
            RecurringBaseEthWallet.InsufficientWalletBalance.selector
        );

        wallet.executePayment();
    }
}
