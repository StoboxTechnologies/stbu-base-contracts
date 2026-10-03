// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  STBU — canonical Stobox Utility Token on Base
/// @author Stobox Technologies
/// @notice Single canonical STBU. Supply is created exclusively by the migration
///         claim contract (holder of {CLAIM_ROLE}) as legacy-chain burns are
///         verified, and is hard-capped at 250,000,000 STBU forever.
/// @dev    Immutable (no proxy). No owner-mint, no admin-mint, no cap change:
///         the only code path to `_mint` is {mint}, gated by {CLAIM_ROLE}.
///         Storage layout (append-only doc for auditors):
///           - ERC20:        _balances, _allowances, _totalSupply, _name, _symbol
///           - ERC20Permit:  _nonces (ERC20Votes-ready via Nonces), EIP712 immutables
///           - Pausable:     _paused
///           - AccessControl:_roles
///         This contract adds no storage variables of its own.
contract STBUToken is ERC20, ERC20Burnable, ERC20Pausable, ERC20Permit, AccessControl {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Absolute maximum supply: 250,000,000 STBU (18 decimals). Immutable forever.
    uint256 public constant MAX_SUPPLY = 250_000_000e18;

    /// @notice Role allowed to mint. Held exclusively by the MigrationClaim contract.
    bytes32 public constant CLAIM_ROLE = keccak256("CLAIM_ROLE");

    /// @notice Role allowed to pause transfers. Unpausing requires DEFAULT_ADMIN_ROLE.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on every mint, alongside the ERC20 Transfer event.
    /// @param to             Recipient of the newly minted tokens.
    /// @param amount         Amount minted (wei).
    /// @param newTotalSupply Total supply after this mint.
    event Minted(address indexed to, uint256 amount, uint256 newTotalSupply);

    /// @notice Emitted on every burn, alongside the ERC20 Transfer event.
    /// @param from   Address whose tokens were destroyed.
    /// @param amount Amount burned (wei).
    event MigrationBurn(address indexed from, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Minting `requested` would push totalSupply past {MAX_SUPPLY}.
    /// @param requested Amount requested to mint.
    /// @param available Remaining mintable amount (MAX_SUPPLY − totalSupply).
    error CapExceeded(uint256 requested, uint256 available);

    /// @notice The zero address was supplied where a real address is required.
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param initialAdmin Address receiving DEFAULT_ADMIN_ROLE (the Stobox multisig
    ///                     in production; the deploy script wires roles and then
    ///                     renounces the deployer's temporary admin).
    /// @dev    No tokens are minted at deployment: day-one supply is zero and grows
    ///         only through verified migration claims.
    constructor(address initialAdmin) ERC20("Stobox Token", "STBU") ERC20Permit("Stobox Token") {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    // ---------------------------------------------------------------------
    // Minting (CLAIM_ROLE only)
    // ---------------------------------------------------------------------

    /// @notice Mint `amount` STBU to `to`. Callable only by {CLAIM_ROLE}.
    /// @dev    Reverts with {CapExceeded} if the cap would be crossed. The cap check
    ///         reads totalSupply() before minting; ERC20 _mint itself cannot overflow
    ///         (OZ uses checked arithmetic on _totalSupply).
    /// @param to     Recipient; must be non-zero (enforced by ERC20 _mint).
    /// @param amount Amount in wei; zero-amount mints are allowed by ERC20 but the
    ///               claim contract never requests them.
    function mint(address to, uint256 amount) external onlyRole(CLAIM_ROLE) {
        uint256 supply = totalSupply();
        if (amount > MAX_SUPPLY - supply) {
            revert CapExceeded(amount, MAX_SUPPLY - supply);
        }
        _mint(to, amount);
        // supply + amount cannot exceed MAX_SUPPLY here, checked above.
        unchecked {
            emit Minted(to, amount, supply + amount);
        }
    }

    // ---------------------------------------------------------------------
    // Pause controls
    // ---------------------------------------------------------------------

    /// @notice Pause all transfers, mints and burns. Emergency brake.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause. Deliberately restricted to the admin (multisig), not the
    ///         pauser hot key, so a compromised pauser cannot flap the switch.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Internal overrides
    // ---------------------------------------------------------------------

    /// @dev Combines ERC20 and ERC20Pausable transfer hooks and emits
    ///      {MigrationBurn} on burns (transfers to address(0)).
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
        if (to == address(0)) {
            emit MigrationBurn(from, value);
        }
    }
}
