
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice EIP-7702 delegated EOA recurring-payment wallet.
/// @dev Base Mainnet only. The delegated EOA holds and spends the ETH.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract RecurringBaseEthWallet {
    uint256 public constant BASE_CHAIN_ID = 8453;
    uint256 public constant PAYMENT_USD_CENTS = 400_000;

    uint64 public constant PAYMENT_INTERVAL = 7 days;
    uint256 public constant MAX_PRICE_AGE = 1 hours;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;


    address public constant ETH_USD_FEED =
        0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    address public constant SEQUENCER_UPTIME_FEED =
        0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Keep this storage slot and struct layout stable.
    bytes32 private constant STATE_SLOT =
        keccak256("recurring.base.eth.wallet.storage.v1");

    struct WalletState {
        bool initialized;
        bool enabled;
        bool executing;
        uint64 nextPaymentAt;
        uint64 endTime;
        uint32 maxPayments;
        uint32 paymentsMade;
        address keeper;
        uint256 maxEthPerPayment;
        uint256 reserveWei;
    }

    event ScheduleConfigured(
        address indexed wallet,
        address indexed keeper,
        uint64 firstPaymentAt,
        uint64 endTime,
        uint32 maxPayments,
        uint256 maxEthPerPayment,
        uint256 reserveWei
    );

    event PaymentExecuted(
        address indexed wallet,
        address indexed recipient,
        uint256 ethAmount,
        uint256 paymentNumber,
        uint256 ethUsdPrice
    );

    event SchedulePaused(address indexed wallet);
    event ScheduleResumed(address indexed wallet);
    event KeeperChanged(address indexed wallet, address indexed newKeeper);

    event PaymentPolicyUpdated(
        uint64 endTime,
        uint32 maxPayments,
        uint256 maxEthPerPayment,
        uint256 reserveWei
    );

    error WrongNetwork();
    error OnlyWalletOwner();
    error OnlyKeeper();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidConfiguration();
    error ScheduleDisabled();
    error PaymentNotDue();
    error ScheduleExpired();
    error PaymentLimitReached();
    error SequencerUnavailable();
    error SequencerGracePeriod();
    error InvalidPrice();
    error StalePrice();
    error InvalidOracleRound();
    error ZeroPayment();
    error PaymentExceedsCap();
    error InsufficientWalletBalance(
        uint256 required,
        uint256 available
    );
    error ReentrantCall();
    error TransferFailed();

    modifier onlyBase() {
        if (block.chainid != BASE_CHAIN_ID) {
            revert WrongNetwork();
        }
        _;
    }

    modifier onlyWalletOwner() {
        // Owner must submit a transaction to the delegated EOA itself.
        if (msg.sender != address(this)) {
            revert OnlyWalletOwner();
        }
        _;
    }

    function _state()
        private
        pure
        returns (WalletState storage s)
    {
        bytes32 slot = STATE_SLOT;

        assembly {
            s.slot := slot
        }
    }

    receive() external payable {}

    /// @notice Configure the initial weekly payment schedule.
    function configureSchedule(
        uint64 endTime,
        uint32 maxPayments,
        address keeper,
        uint256 maxEthPerPayment,
        uint256 reserveWei
    ) external onlyBase onlyWalletOwner {
        WalletState storage s = _state();

        if (s.initialized) revert AlreadyInitialized();

        if (
            endTime <= block.timestamp ||
            maxPayments == 0 ||
            keeper == address(0) ||
            maxEthPerPayment == 0 ||
            reserveWei > type(uint256).max - maxEthPerPayment
        ) {
            revert InvalidConfiguration();
        }

        uint256 firstPayment =
            block.timestamp + PAYMENT_INTERVAL;

        uint256 lastPayment =
            firstPayment +
            (uint256(maxPayments) - 1) * PAYMENT_INTERVAL;

        if (
            firstPayment > type(uint64).max ||
            lastPayment > endTime
        ) {
            revert InvalidConfiguration();
        }

        s.initialized = true;
        s.enabled = true;
        s.nextPaymentAt = uint64(firstPayment);
        s.endTime = endTime;
        s.maxPayments = maxPayments;
        s.keeper = keeper;
        s.maxEthPerPayment = maxEthPerPayment;
        s.reserveWei = reserveWei;

        emit ScheduleConfigured(
            address(this),
            keeper,
            s.nextPaymentAt,
            endTime,
            maxPayments,
            maxEthPerPayment,
            reserveWei
        );
    }

    /// @notice Execute one authorized weekly payment.
    function executePayment() external onlyBase {
        WalletState storage s = _state();

        if (!s.initialized) revert NotInitialized();
        if (!s.enabled) revert ScheduleDisabled();
        if (msg.sender != s.keeper) revert OnlyKeeper();
        if (s.executing) revert ReentrantCall();

        if (block.timestamp < s.nextPaymentAt) {
            revert PaymentNotDue();
        }

        if (block.timestamp > s.endTime) {
            revert ScheduleExpired();
        }

        if (s.paymentsMade >= s.maxPayments) {
            revert PaymentLimitReached();
        }

        s.executing = true;

        uint256 price = _readEthUsdPrice();

        // USD cents * 10^26 / USD price with 8 decimals.
        uint256 amountWei =
            (PAYMENT_USD_CENTS * 1e24) / price;

        if (amountWei == 0) revert ZeroPayment();

        if (amountWei > s.maxEthPerPayment) {
            revert PaymentExceedsCap();
        }

        if (s.reserveWei > type(uint256).max - amountWei) {
            revert InvalidConfiguration();
        }

        uint256 requiredBalance = amountWei + s.reserveWei;
        uint256 available = address(this).balance;

        if (available < requiredBalance) {
            revert InsufficientWalletBalance(
                requiredBalance,
                available
            );
        }

        uint256 nextDue =
            block.timestamp + PAYMENT_INTERVAL;

        if (nextDue > type(uint64).max) {
            revert InvalidConfiguration();
        }

        // Effects before interaction.
        // A failed transfer reverts these changes automatically.
        s.paymentsMade += 1;
        s.nextPaymentAt = uint64(nextDue);

        (bool success, ) =
            RECIPIENT.call{value: amountWei}("");

        if (!success) revert TransferFailed();

        s.executing = false;

        emit PaymentExecuted(
            address(this),
            RECIPIENT,
            amountWei,
            s.paymentsMade,
            price
        );
    }

    /// @notice Pause recurring payments.
    function pause() external onlyBase onlyWalletOwner {
        WalletState storage s = _state();

        if (!s.initialized) revert NotInitialized();

        s.enabled = false;

        emit SchedulePaused(address(this));
    }

    /// @notice Resume recurring payments.
    function resume() external onlyBase onlyWalletOwner {
        WalletState storage s = _state();

        if (!s.initialized) revert NotInitialized();

        s.enabled = true;

        emit ScheduleResumed(address(this));
    }

    /// @notice Change the authorized keeper.
    function changeKeeper(
        address newKeeper
    ) external onlyBase onlyWalletOwner {
        if (newKeeper == address(0)) {
            revert InvalidConfiguration();
        }

        WalletState storage s = _state();

        if (!s.initialized) revert NotInitialized();

        s.keeper = newKeeper;

        emit KeeperChanged(address(this), newKeeper);
    }

    /// @notice Owner-authorized update of future payment limits.
    /// @dev Cannot change the fixed recipient or payment USD target.
    function updatePaymentPolicy(
        uint64 newEndTime,
        uint32 newMaxPayments,
        uint256 newMaxEthPerPayment,
        uint256 newReserveWei
    ) external onlyBase onlyWalletOwner {
        WalletState storage s = _state();

        if (!s.initialized) revert NotInitialized();

        if (
            newEndTime <= block.timestamp ||
            newMaxPayments < s.paymentsMade ||
            newMaxEthPerPayment == 0 ||
            newReserveWei >
                type(uint256).max - newMaxEthPerPayment
        ) {
            revert InvalidConfiguration();
        }

        uint256 remaining =
            uint256(newMaxPayments) - s.paymentsMade;

        if (remaining > 0) {
            uint256 lastPayment =
                uint256(s.nextPaymentAt) +
                (remaining - 1) * PAYMENT_INTERVAL;

            if (lastPayment > newEndTime) {
                revert InvalidConfiguration();
            }
        }

        s.endTime = newEndTime;
        s.maxPayments = newMaxPayments;
        s.maxEthPerPayment = newMaxEthPerPayment;
        s.reserveWei = newReserveWei;

        emit PaymentPolicyUpdated(
            newEndTime,
            newMaxPayments,
            newMaxEthPerPayment,
            newReserveWei
        );
    }

    /// @notice Read current schedule and limits.
    function getSchedule()
        external
        view
        returns (
            bool initialized,
            bool enabled,
            uint64 nextPaymentAt,
            uint64 endTime,
            uint32 maxPayments,
            uint32 paymentsMade,
            address keeper,
            uint256 maxEthPerPayment,
            uint256 reserveWei
        )
    {
        WalletState storage s = _state();

        return (
            s.initialized,
            s.enabled,
            s.nextPaymentAt,
            s.endTime,
            s.maxPayments,
            s.paymentsMade,
            s.keeper,
            s.maxEthPerPayment,
            s.reserveWei
        );
    }

    /// @notice Calculate the current ETH equivalent of $4,000.
    function quotePaymentWei()
        external
        view
        returns (uint256 amountWei, uint256 price)
    {
        price = _readEthUsdPrice();

        amountWei =
            (PAYMENT_USD_CENTS * 1e24) / price;

        if (amountWei == 0) revert ZeroPayment();
    }

    /// @notice Read and validate Chainlink feeds.
    function _readEthUsdPrice()
        private
        view
        returns (uint256)
    {
        (
            uint80 seqRound,
            int256 sequencerAnswer,
            uint256 startedAt,
            ,
            uint80 seqAnsweredInRound
        ) = AggregatorV3Interface(SEQUENCER_UPTIME_FEED)
            .latestRoundData();

        if (
            seqRound == 0 ||
            seqAnsweredInRound < seqRound
        ) {
            revert InvalidOracleRound();
        }

        if (sequencerAnswer != 0) {
            revert SequencerUnavailable();
        }

        if (
            startedAt == 0 ||
            block.timestamp < startedAt ||
            block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD
        ) {
            revert SequencerGracePeriod();
        }

        if (AggregatorV3Interface(ETH_USD_FEED).decimals() != 8) {
            revert InvalidPrice();
        }

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = AggregatorV3Interface(ETH_USD_FEED)
            .latestRoundData();

        if (
            roundId == 0 ||
            answeredInRound < roundId
        ) {
            revert InvalidOracleRound();
        }

        if (answer <= 0) revert InvalidPrice();

        if (
            updatedAt == 0 ||
            updatedAt > block.timestamp ||
            block.timestamp - updatedAt > MAX_PRICE_AGE
        ) {
            revert StalePrice();
        }

        return uint256(answer);
    }
}
