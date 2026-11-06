
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Educational EIP-7702 delegated EOA recurring-payment implementation.
/// @dev Deploy the implementation on Base Mainnet, chain ID 8453.
///      When delegated code executes, address(this) is the delegated EOA.
///      The EOA's own ETH balance is used for the payment.

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

    // $4,000.00 represented in cents.
    uint256 public constant PAYMENT_USD_CENTS = 400_000;

    uint64 public constant PAYMENT_INTERVAL = 7 days;
    uint256 public constant MAX_PRICE_AGE = 1 hours;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    // Exact recipient supplied by the wallet owner.
    address payable public constant RECIPIENT =
        payable(0x110741e1a3467c90a9f94fa4831ccd5acc95b438);

    // Chainlink Base Mainnet ETH/USD feed (8 decimals).
    address public constant ETH_USD_FEED =
        0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // Chainlink Base Mainnet sequencer uptime feed.
    address public constant SEQUENCER_UPTIME_FEED =
        0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Namespaced storage for the delegated EOA.
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
        // The owner calls the delegated EOA itself.
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

    /// @notice Accept native Base ETH.
    receive() external payable {}

    /// @notice Configure the recurring payment schedule.
    /// @dev Call this by sending a transaction from the EOA to itself.
    function configureSchedule(
        uint64 endTime,
        uint32 maxPayments,
        address keeper,
        uint256 maxEthPerPayment,
        uint256 reserveWei
    ) external onlyBase onlyWalletOwner {
        WalletState storage s = _state();

        if (s.initialized) {
            revert AlreadyInitialized();
        }

        if (
            endTime <= block.timestamp ||
            maxPayments == 0 ||
            keeper == address(0) ||
            maxEthPerPayment == 0
        ) {
            revert InvalidConfiguration();
        }

        s.initialized = true;
        s.enabled = true;
        s.nextPaymentAt = uint64(
            block.timestamp + PAYMENT_INTERVAL
        );
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

    /// @notice Execute a payment when the seven-day interval has elapsed.
    /// @dev The keeper calls the delegated EOA. ETH comes from that EOA.
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

        // ETH amount in wei for $4,000, using an 8-decimal USD price.
        uint256 amountWei =
            (PAYMENT_USD_CENTS * 1e24) / price;

        if (amountWei > s.maxEthPerPayment) {
            revert PaymentExceedsCap();
        }

        uint256 requiredBalance = amountWei + s.reserveWei;
        uint256 available = address(this).balance;

        if (available < requiredBalance) {
            revert InsufficientWalletBalance(
                requiredBalance,
                available
            );
        }

        // State changes revert automatically if the ETH transfer fails.
        s.paymentsMade += 1;
        s.nextPaymentAt = uint64(
            block.timestamp + PAYMENT_INTERVAL
        );

        (bool success, ) = RECIPIENT.call{value: amountWei}("");

        if (!success) {
            revert TransferFailed();
        }

        s.executing = false;

        emit PaymentExecuted(
            address(this),
            RECIPIENT,
            amountWei,
            s.paymentsMade,
            price
        );
    }

    /// @notice Stop recurring payments.
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

    /// @notice Read the current payment schedule.
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

    /// @notice Calculate the current ETH amount for the $4,000 target.
    function quotePaymentWei()
        external
        view
        returns (uint256 amountWei, uint256 price)
    {
        price = _readEthUsdPrice();

        amountWei = (PAYMENT_USD_CENTS * 1e24) / price;
    }

    /// @notice Read and validate the ETH/USD price.
    function _readEthUsdPrice()
        private
        view
        returns (uint256)
    {
        (
            ,
            int256 sequencerAnswer,
            uint256 startedAt,
            ,
        ) = AggregatorV3Interface(SEQUENCER_UPTIME_FEED)
            .latestRoundData();

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

        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,

        ) = AggregatorV3Interface(ETH_USD_FEED)
            .latestRoundData();

        if (answer <= 0) revert InvalidPrice();

        if (
            updatedAt == 0 ||
            updatedAt > block.timestamp ||
            block.timestamp - updatedAt > MAX_PRICE_AGE
        ) {
            revert StalePrice();
        }

        if (
            AggregatorV3Interface(ETH_USD_FEED).decimals() != 8
        ) {
            revert InvalidPrice();
        }

        return uint256(answer);
    }
}
