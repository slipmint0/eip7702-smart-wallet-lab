
# Manual test checklist

Use a disposable test EOA and test funds only.

## EIP-7702 setup

- [ ] Confirm the selected network supports EIP-7702.
- [ ] Confirm the selected wallet supports EIP-7702 authorization.
- [ ] Deploy the implementation to the appropriate test environment.
- [ ] Delegate a disposable EOA.
- [ ] Confirm the delegated EOA address remains unchanged.

## Schedule configuration

- [ ] Configure the schedule from the EOA itself.
- [ ] Confirm the fixed recipient address.
- [ ] Confirm the keeper address.
- [ ] Confirm the payment count and expiry.
- [ ] Confirm the ETH payment cap.
- [ ] Confirm the ETH reserve.

## Authorization and security

- [ ] Confirm another address cannot configure the schedule.
- [ ] Confirm another address cannot pause or resume it.
- [ ] Confirm an unauthorized keeper cannot execute.
- [ ] Confirm the owner can pause the schedule.
- [ ] Confirm the owner can resume the schedule.
- [ ] Confirm the owner can change the keeper.

## Payment execution

- [ ] Confirm payment cannot execute before seven days.
- [ ] Confirm payment executes after seven days.
- [ ] Confirm the recipient receives native Base ETH.
- [ ] Confirm the payment count increments after success.
- [ ] Confirm the next payment is scheduled seven days after success.
- [ ] Confirm the payment cap is enforced.
- [ ] Confirm the reserve is maintained.

## Failure conditions

- [ ] Confirm insufficient ETH blocks payment.
- [ ] Confirm failed payment does not increment the counter.
- [ ] Confirm stale price data blocks payment.
- [ ] Confirm invalid price data blocks payment.
- [ ] Confirm sequencer-down conditions block payment.
- [ ] Confirm the payment limit is enforced.
- [ ] Confirm the expiry date is enforced.

## Revocation

- [ ] Test EIP-7702 delegation revocation.
- [ ] Confirm the EOA no longer executes the delegated implementation.
- [ ] Confirm the EOA's remaining ETH is still controlled by its owner.
