// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {STBUToken} from "./STBUToken.sol";

/// @title  MigrationClaim — voucher-gated minting of canonical STBU on Base
/// @author Stobox Technologies
/// @notice Redeems EIP-712 vouchers signed by the Stobox migration signer (an AWS
///         KMS-held key) after legacy-chain burns are verified off-chain. Uses
///         cumulative accounting: a voucher states the wallet's lifetime claimable
///         total, and this contract mints only the difference over what the wallet
///         has already claimed — making replay structurally worthless.
/// @dev    Immutable (no proxy). Trust model: signatures from a registered signer
///         attest off-chain burn verification; every rule this contract can check
///         itself (replay, ordering, deadline, chain, version, claim window, pause)
///         is checked here regardless of signer honesty, and the token enforces the
///         250M cap independently.
///
///         Storage layout (append-only doc for auditors):
///           slot 0..n (inherited): AccessControl._roles, Pausable._paused,
///                                  ReentrancyGuard._status, EIP712 immutables (no slots)
///           claimStart            (uint64,  this contract)
///           activeVoucherVersion  (uint16,  packed with claimStart)
///           isSigner              (mapping(address => bool))
///           claimed               (mapping(address => uint256))
///           lastNonce             (mapping(address => uint256))
///           totalClaimed          (uint256)
contract MigrationClaim is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Voucher signed off-chain authorizing a wallet's lifetime cumulative claim.
    /// @param wallet           Beneficiary. Tokens always mint here, never to msg.sender.
    /// @param cumulativeAmount Lifetime total (wei) this wallet may ever have claimed.
    /// @param deadline         Unix time after which the voucher is unusable.
    /// @param nonce            Strictly increasing per wallet; orders vouchers.
    /// @param chainId          Must equal block.chainid (fork defense, in addition to
    ///                         the EIP-712 domain separator).
    /// @param version          Signer-generation gate; must equal {activeVoucherVersion}.
    struct MigrationVoucher {
        address wallet;
        uint256 cumulativeAmount;
        uint256 deadline;
        uint256 nonce;
        uint256 chainId;
        uint16 version;
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice EIP-712 type hash of {MigrationVoucher}. Mirrored in packages/shared;
    ///         a CI test asserts the TypeScript-computed hash matches this constant.
    bytes32 public constant VOUCHER_TYPEHASH = keccak256(
        "MigrationVoucher(address wallet,uint256 cumulativeAmount,uint256 deadline,uint256 nonce,uint256 chainId,uint16 version)"
    );

    /// @notice Role allowed to pause claims. Unpausing requires DEFAULT_ADMIN_ROLE.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ---------------------------------------------------------------------
    // Immutables & storage
    // ---------------------------------------------------------------------

    /// @notice The canonical STBU token this contract mints. Set once at deployment.
    STBUToken public immutable token;

    /// @notice Previous MigrationClaim generation, or address(0) for the first
    ///         deployment. If set, per-wallet accounting is seeded lazily from it:
    ///         a wallet with no local state reads `claimed`/`lastNonce` from the
    ///         predecessor on first claim, so a replaced claim contract can never
    ///         double-mint what the old one already minted (ADR-0005 recovery path).
    MigrationClaim public immutable predecessor;

    /// @notice Unix time when claiming opens. Adjustable by admin only before it passes.
    uint64 public claimStart;

    /// @notice Currently accepted voucher version; bumped on signer rotation.
    uint16 public activeVoucherVersion;

    /// @notice Registered voucher signers (KMS-derived addresses).
    mapping(address signer => bool registered) public isSigner;

    /// @notice Lifetime amount already minted per wallet (cumulative accounting).
    mapping(address wallet => uint256 amount) public claimed;

    /// @notice Highest voucher nonce accepted per wallet.
    mapping(address wallet => uint256 nonce) public lastNonce;

    /// @notice Total STBU minted through this contract (transparency counter).
    uint256 public totalClaimed;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on every successful claim.
    /// @param wallet          Beneficiary that received newly minted STBU.
    /// @param minted          Amount minted in this claim (delta).
    /// @param cumulativeTotal Wallet's lifetime claimed total after this claim.
    /// @param nonce           Voucher nonce redeemed.
    event MigrationMint(
        address indexed wallet, uint256 minted, uint256 cumulativeTotal, uint256 nonce
    );

    /// @notice Emitted when a signer is registered or deregistered.
    event SignerSet(address indexed signer, bool registered);

    /// @notice Emitted when the accepted voucher version changes.
    event VoucherVersionSet(uint16 previousVersion, uint16 newVersion);

    /// @notice Emitted when the claim window start is (re)scheduled.
    event ClaimStartSet(uint64 previousStart, uint64 newStart);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Claiming has not opened yet.
    error ClaimNotStarted(uint64 startsAt);
    /// @notice Voucher's chainId field does not match this chain.
    error WrongChain(uint256 expected, uint256 actual);
    /// @notice Voucher's version is not the active one (stale signer generation).
    error StaleVoucherVersion(uint16 expected, uint16 actual);
    /// @notice Voucher deadline has passed.
    error VoucherExpired(uint256 deadline);
    /// @notice Recovered signer is not registered.
    error InvalidSigner(address recovered);
    /// @notice Voucher nonce is not greater than the wallet's last accepted nonce.
    error NonceUsed(uint256 provided, uint256 lastAccepted);
    /// @notice Cumulative amount does not exceed what the wallet already claimed.
    error NothingToClaim(uint256 cumulative, uint256 alreadyClaimed);
    /// @notice The zero address was supplied where a real address is required.
    error ZeroAddress();
    /// @notice Claim start can only be changed before the current start has passed.
    error ClaimAlreadyStarted();
    /// @notice New claim start must not be in the past.
    error StartInPast(uint64 provided);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param token_         Canonical STBU token (this contract must be granted
    ///                       CLAIM_ROLE on it after deployment).
    /// @param initialAdmin   DEFAULT_ADMIN_ROLE holder (Stobox multisig in production).
    /// @param initialSigner  First voucher signer (KMS-derived address).
    /// @param initialPauser  PAUSER_ROLE holder (the ops pauser hot key / auto-pause
    ///                       watchdog). Granted here in the constructor because this
    ///                       contract's admin is the multisig from birth — the deploy
    ///                       script (run by the deployer) cannot grant claim roles, so
    ///                       wiring the pauser post-deploy would depend on a fallible
    ///                       manual multisig step. Baking it in guarantees the
    ///                       emergency brake exists from block one.
    /// @param claimStart_    Unix time when claiming opens; may be now or future.
    /// @param predecessor_   Prior MigrationClaim to seed accounting from, or
    ///                       address(0) for the first deployment. When replacing a
    ///                       claim contract, the old one must be paused and stripped
    ///                       of CLAIM_ROLE before this one is granted it.
    /// @dev   activeVoucherVersion starts at 1. EIP-712 domain: name "STBU MigrationClaim",
    ///        version "1"; OZ EIP712 recomputes the domain separator if block.chainid
    ///        changes (fork defense).
    constructor(
        STBUToken token_,
        address initialAdmin,
        address initialSigner,
        address initialPauser,
        uint64 claimStart_,
        MigrationClaim predecessor_
    ) EIP712("STBU MigrationClaim", "1") {
        if (
            address(token_) == address(0) || initialAdmin == address(0)
                || initialSigner == address(0) || initialPauser == address(0)
        ) {
            revert ZeroAddress();
        }
        token = token_;
        predecessor = predecessor_;
        claimStart = claimStart_;
        activeVoucherVersion = 1;
        isSigner[initialSigner] = true;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialPauser);

        emit SignerSet(initialSigner, true);
        emit VoucherVersionSet(0, 1);
        emit ClaimStartSet(0, claimStart_);
    }

    // ---------------------------------------------------------------------
    // Claim
    // ---------------------------------------------------------------------

    /// @notice Redeem a voucher: mints `cumulativeAmount − claimed[wallet]` to the
    ///         wallet named in the voucher.
    /// @dev    Deliberately callable by anyone (gas sponsorship friendly): the
    ///         beneficiary is bound inside the signed payload, so a front-runner can
    ///         only pay the wallet's gas. Checks-effects-interactions plus
    ///         nonReentrant; the only external call is to our own hook-free token.
    /// @param voucher   The signed voucher fields (see {MigrationVoucher}).
    /// @param signature 65-byte ECDSA signature by a registered signer over the
    ///                  EIP-712 digest of `voucher`.
    function claim(MigrationVoucher calldata voucher, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        // --- checks -------------------------------------------------------
        uint64 start = claimStart;
        if (block.timestamp < start) revert ClaimNotStarted(start);
        if (voucher.chainId != block.chainid) revert WrongChain(block.chainid, voucher.chainId);
        uint16 activeVersion = activeVoucherVersion;
        if (voucher.version != activeVersion) {
            revert StaleVoucherVersion(activeVersion, voucher.version);
        }
        if (block.timestamp > voucher.deadline) revert VoucherExpired(voucher.deadline);

        address recovered = ECDSA.recover(hashVoucher(voucher), signature);
        if (!isSigner[recovered]) revert InvalidSigner(recovered);

        // Nonces are issued starting at 1; lastNonce defaults to 0, so the first
        // voucher passes and any replayed or out-of-order voucher fails. Effective
        // state falls back to the predecessor generation for locally-untouched
        // wallets, so a replacement contract can never re-mint old claims.
        uint256 last = lastNonceOf(voucher.wallet);
        if (voucher.nonce <= last) revert NonceUsed(voucher.nonce, last);

        uint256 alreadyClaimed = claimedOf(voucher.wallet);
        if (voucher.cumulativeAmount <= alreadyClaimed) {
            revert NothingToClaim(voucher.cumulativeAmount, alreadyClaimed);
        }

        // --- effects ------------------------------------------------------
        uint256 delta;
        unchecked {
            // cumulativeAmount > alreadyClaimed checked above.
            delta = voucher.cumulativeAmount - alreadyClaimed;
        }
        claimed[voucher.wallet] = voucher.cumulativeAmount;
        lastNonce[voucher.wallet] = voucher.nonce;
        totalClaimed += delta;

        // --- interactions -------------------------------------------------
        token.mint(voucher.wallet, delta);

        emit MigrationMint(voucher.wallet, delta, voucher.cumulativeAmount, voucher.nonce);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice EIP-712 digest for a voucher — what the KMS signer signs and what
    ///         off-chain tooling should reproduce byte-for-byte.
    /// @param voucher The voucher fields.
    /// @return The fully-domain-separated typed-data digest.
    function hashVoucher(MigrationVoucher calldata voucher) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    VOUCHER_TYPEHASH,
                    voucher.wallet,
                    voucher.cumulativeAmount,
                    voucher.deadline,
                    voucher.nonce,
                    voucher.chainId,
                    voucher.version
                )
            )
        );
    }

    /// @notice Effective lifetime claimed total for `wallet`, including state
    ///         inherited from the predecessor generation if this contract has not
    ///         been touched by the wallet yet.
    /// @dev    A successful claim always sets both `claimed` and `lastNonce`
    ///         (nonce ≥ 1, cumulative > 0), so "both zero" is a reliable
    ///         locally-untouched marker.
    function claimedOf(address wallet) public view returns (uint256) {
        if (claimed[wallet] == 0 && lastNonce[wallet] == 0 && address(predecessor) != address(0)) {
            return predecessor.claimedOf(wallet);
        }
        return claimed[wallet];
    }

    /// @notice Effective highest accepted nonce for `wallet`, including the
    ///         predecessor generation for locally-untouched wallets.
    function lastNonceOf(address wallet) public view returns (uint256) {
        if (claimed[wallet] == 0 && lastNonce[wallet] == 0 && address(predecessor) != address(0)) {
            return predecessor.lastNonceOf(wallet);
        }
        return lastNonce[wallet];
    }

    /// @notice Amount a voucher would mint right now (0 if fully claimed already).
    /// @dev    View helper for frontends; performs no signature validation.
    function claimableFor(address wallet, uint256 cumulativeAmount)
        external
        view
        returns (uint256)
    {
        uint256 alreadyClaimed = claimedOf(wallet);
        return cumulativeAmount > alreadyClaimed ? cumulativeAmount - alreadyClaimed : 0;
    }

    /// @notice The EIP-712 domain separator currently in effect.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------
    // Administration (DEFAULT_ADMIN_ROLE = Stobox multisig)
    // ---------------------------------------------------------------------

    /// @notice Register or deregister a voucher signer (KMS rotation).
    /// @dev    Multiple signers may be active during a rotation overlap window.
    function setSigner(address signer, bool registered) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (signer == address(0)) revert ZeroAddress();
        isSigner[signer] = registered;
        emit SignerSet(signer, registered);
    }

    /// @notice Bump the accepted voucher version. Instantly invalidates all vouchers
    ///         signed under previous versions (rotation / incident response).
    function setActiveVoucherVersion(uint16 newVersion) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint16 previous = activeVoucherVersion;
        activeVoucherVersion = newVersion;
        emit VoucherVersionSet(previous, newVersion);
    }

    /// @notice Reschedule the claim window start. Only allowed while claiming has
    ///         not yet begun, and never into the past.
    function setClaimStart(uint64 newStart) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint64 current = claimStart;
        if (block.timestamp >= current) revert ClaimAlreadyStarted();
        if (newStart < block.timestamp) revert StartInPast(newStart);
        claimStart = newStart;
        emit ClaimStartSet(current, newStart);
    }

    /// @notice Pause claiming. Emergency brake, callable by the pauser hot key.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause claiming. Admin (multisig) only — a compromised pauser
    ///         cannot re-enable a system the admin chose to halt.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
