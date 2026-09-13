// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ComputeCredit
/// @notice Non-transferable historical accounting receipts on Creditcoin.
/// @dev Receipts are not money, redeemable claims or evidence of a source-chain withdrawal.
/// The fixed source-chain return relayer separately releases the original payment.
contract ComputeCredit is ERC20 {
    address public minter;
    address public immutable DEPLOYER;

    event MinterSet(address indexed minter);

    error NotMinter();
    error NotDeployer();
    error MinterAlreadySet();
    error ZeroAddress();

    constructor() ERC20("ProofSettle Receipt", "PSR") {
        DEPLOYER = msg.sender;
    }

    /// @notice Bind the settlement contract as the only minter. Callable once, then permanent.
    /// @dev The settlement contract needs this token's address at construction and this token needs
    /// the settlement contract's address, so one of the two has to be wired after the fact. Making
    /// it single-shot and irreversible keeps that from being a standing privilege.
    function setMinter(address settlement) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (minter != address(0)) revert MinterAlreadySet();
        if (settlement == address(0)) revert ZeroAddress();
        minter = settlement;
        emit MinterSet(settlement);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }
    error NonTransferableReceipt();
    /// @dev Historical accounting receipts, not redeemable or transferable money.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) revert NonTransferableReceipt();
        super._update(from, to, value);
    }

}
