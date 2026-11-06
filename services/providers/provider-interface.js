
/**
 * Generic exchange provider interface.
 *
 * Implement this separately for Coinbase, Binance,
 * OKX or another supported exchange.
 *
 * Never put exchange secrets in Solidity or frontend code.
 */

export class ExchangeProvider {
  constructor({ name }) {
    this.name = name;
  }

  // Check the exchange account's available balances.
  async getBalances() {
    throw new Error(
      `${this.name}: getBalances() is not implemented`
    );
  }

  // Buy ETH using an explicitly authorized payment method.
  async buyEth({ quoteCurrency, amount }) {
    throw new Error(
      `${this.name}: buyEth() is not implemented`
    );
  }

  // Withdraw ETH to the owner's EOA over Base.
  async withdrawEthOnBase({ amount, destination }) {
    throw new Error(
      `${this.name}: withdrawEthOnBase() is not implemented`
    );
  }
}

/**
 * Required security controls for every real adapter:
 *
 * 1. Verify the exchange account.
 * 2. Use read-only permissions for balance checks.
 * 3. Request withdrawal permission only when necessary.
 * 4. Restrict withdrawals to the owner's EOA.
 * 5. Restrict the withdrawal network to Base.
 * 6. Enforce per-payment and daily withdrawal limits.
 * 7. Require explicit approval for purchases.
 * 8. Track withdrawal IDs and transaction hashes.
 * 9. Verify the deposit on Base before retrying payment.
 * 10. Never log API keys, passwords, OTPs or recovery phrases.
 */
