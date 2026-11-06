
# EIP-7702 Recurring Base ETH Smart Wallet

An educational project for building a delegated Ethereum EOA that can execute an authorized recurring ETH payment on Base.

## Project configuration

| Setting | Value |
|---|---|
| Network | Base Mainnet |
| Chain ID | 8453 |
| Asset | Native Base ETH |
| Recipient | `0x110741e1a3467c90a9f94fa4831ccd5acc95b438` |
| Payment target | $4,000 USD equivalent |
| Frequency | Every 7 days |
| Price source | Chainlink ETH/USD |
| Execution | Authorized keeper |

## Architecture

The project has three main parts:

1. Solidity wallet implementation: enforces the payment schedule and transfers ETH.
2. Keeper service: checks when payment is due and submits the execution transaction.
3. Funding services: monitor the wallet balance and provide a framework for future exchange integrations.

## How EIP-7702 works here

1. Deploy the implementation contract.
2. The owner EOA signs an EIP-7702 authorization delegating execution to the implementation.
3. The EOA retains its original address and ETH balance.
4. The owner configures the payment schedule by calling the delegated EOA itself.
5. An authorized keeper calls `executePayment()` when payment is due.
6. The delegated code transfers native Base ETH from the EOA to the fixed recipient.

Deploying the implementation alone does not delegate an EOA. A compatible wallet or transaction tool must submit the EIP-7702 authorization.

## Payment rules

- Recipient is fixed in the Solidity source.
- Payment target is $4,000 USD equivalent.
- ETH amount is recalculated using the Chainlink ETH/USD price at execution.
- Payments are separated by at least seven days.
- The owner configures a maximum payment count and expiry.
- The owner configures an ETH-per-payment cap and a minimum reserve.
- Only the configured keeper can execute a payment.
- The owner can pause and resume the schedule.
- Insufficient balance causes the payment transaction to revert.
- A failed payment does not advance the payment counter.

## Configure the schedule

Call `configureSchedule()` from the delegated EOA itself:

`configureSchedule(endTime, maxPayments, keeper, maxEthPerPayment, reserveWei)`

Parameters:

- `endTime`: Unix timestamp after which payments are not allowed.
- `maxPayments`: maximum successful payment count.
- `keeper`: address permitted to trigger payment execution.
- `maxEthPerPayment`: maximum ETH amount per payment, in wei.
- `reserveWei`: ETH that must remain in the EOA after payment.

The first payment becomes eligible seven days after configuration.

## Local JavaScript setup

Install dependencies:

```bash
npm install
```

Copy `.env.example` to `.env` and fill in the required values.

Check the EOA's Base ETH balance:

```bash
npm run funding:check
```

Run the keeper once:

```bash
npm run keeper
```

The keeper script is a one-time check and trigger. It is not yet a continuously running scheduler.

## Exchange integration status

Coinbase, Binance and other exchanges are not yet connected.

The provider interface is a framework only. A real integration must use the exchange's official API and support the user's account, country, payment method, purchase permissions and Base withdrawal network.

The funding monitor currently performs read-only balance checks. It does not buy ETH or withdraw funds.

## Security

- Never put wallet recovery phrases or owner private keys in this repository.
- Never put exchange API secrets in Solidity or frontend code.
- Use a separate keeper account.
- Restrict exchange withdrawal permissions and destinations.
- Test with a disposable EOA and test funds.
- Review the delegated implementation before signing an EIP-7702 authorization.
- Test pause, revocation and insufficient-balance behavior.

## Important limitations

This is an educational starter, not an audited production wallet.

It has not been deployed, audited or tested with real funds.

It does not yet implement:
- Automatic exchange purchases.
- Automatic exchange withdrawals.
- Bank or debit-card integrations.
- Automatic keeper scheduling.
- Paymaster integration.
- Production EIP-7702 authorization tooling.

A paymaster may sponsor transaction gas under its own rules. It cannot supply the $4,000 payment principal.

The contract is configured for Base Mainnet. Its chain ID and oracle addresses must be changed for a different network or testnet.

## Official references

- EIP-7702: https://eips.ethereum.org/EIPS/eip-7702
- Ethereum EIP-7702 overview: https://ethereum.org/roadmap/pectra/7702
- OpenZeppelin EOA delegation: https://docs.openzeppelin.com/contracts/5.x/eoa-delegation
- Chainlink Base price feeds: https://docs.chain.link/data-feeds/price-feeds/addresses?network=base
- Chainlink L2 sequencer feeds: https://docs.chain.link/data-feeds/l2-sequencer-feeds
- Binance API documentation: https://developers.binance.com/
