// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ComputeCredit
/// @notice The provider's claim, issued on Creditcoin when a job settles.
/// @dev Value conservation mirrors the Attestcoin bridging tutorial: funds are locked on the
/// source chain and the equivalent claim is issued here. Nothing is created that was not paid for,
/// and the only address that can issue is the settlement contract.
contract ComputeCredit is ERC20 {
    address public minter;
    address public immutable DEPLOYER;

    event MinterSet(address indexed minter);

    error NotMinter();
    error NotDeployer();
    error MinterAlreadySet();
    error ZeroAddress();

    constructor() ERC20("Compute Credit", "CCRD") {
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
}
