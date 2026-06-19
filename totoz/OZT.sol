// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title OZT — Advisory Governance Token
 * @notice 1 Billion supply. 1 OZT = 1 vote. Immediately transferable, no vesting.
 *         NOT consumed on vote — held as permanent voting weight.
 *         Owner should be a multi-sig (Gnosis Safe).
 *
 *         Governance: OZT holders vote on platform direction via TOTOZ.io.
 *         1 OZT = 1 vote. Any holder (1+ OZT) can submit proposals.
 *         Pure majority vote — no operator veto. OZ Capital votes like everyone else.
 *         See OZT_Governance_Cycle_Specification_v2.0 for full framework.
 *
 *         Security review rounds 1+2 applied June 13, 2026 — pause added,
 *         role sync, duplicate check, rescueTokens self-block, renounceRole blocked.
 *
 *         initialOwner receives all tokens and admin roles.
 *         Should be a Gnosis Safe multi-sig (2-of-3).
 */
contract OZT is ERC20, ERC20Pausable, Ownable2Step, AccessControl {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error BurnSourceAlreadySet();
    error WouldBreachBurnFloor();
    error EmptyRecipientsArray();
    error LengthMismatch();
    error MaxRecipientsExceeded();
    error ZeroAmount();
    error InsufficientBalance();
    error DuplicateRecipient();
    error CannotRenounceOwnership();
    error CannotRenounceAdminRole();
    error CannotRescueOwnToken();
    error CanOnlyBurnFromDesignatedSource();

    /// @notice Role for BurnSchedule contract to call burnFrom.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Minimum total supply — burns revert below this.
    uint256 public constant OZT_BURN_FLOOR = 10_000_000 * 10 ** 18; // 10 Million OZT

    /// @notice Designated wallet that burnFrom can target. Prevents BURNER_ROLE from
    ///         burning arbitrary user wallets. Set once by owner.
    /// @dev    IRREVERSIBLE — cannot be changed after being set. Verify address on-chain
    ///         before calling setBurnSource(). Incorrect address permanently breaks scheduled burns.
    address public burnSource;

    event ScheduledBurn(uint256 amount);
    event BurnFromSource(address indexed account, uint256 amount);
    event BatchDistribute(uint256 recipientCount, uint256 totalAmount);
    event BurnSourceSet(address indexed burnSource);

    constructor(address initialOwner)
        ERC20("OZT", "OZT")
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        _mint(initialOwner, 1_000_000_000 * 10 ** 18);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    /**
     * @notice Set the designated burn source wallet. Can only be set once.
     *         IRREVERSIBLE — verify the address is correct on-chain before calling.
     *         Incorrect address permanently breaks scheduled burns.
     * @param _burnSource The burn source wallet address (typically the multi-sig)
     */
    function setBurnSource(address _burnSource) external onlyOwner {
        if (burnSource != address(0)) revert BurnSourceAlreadySet();
        if (_burnSource == address(0)) revert ZeroAddress();
        burnSource = _burnSource;
        emit BurnSourceSet(_burnSource);
    }

    /**
     * @notice Scheduled burn of OZT from OWNER wallet specifically.
     *         Note: burns from msg.sender (owner), NOT from burnSource.
     *         For burns from the designated supply wallet, use BurnSchedule.
     * @param amount The number of tokens to burn from owner
     */
    function scheduledBurn(uint256 amount) external onlyOwner {
        if (totalSupply() - amount < OZT_BURN_FLOOR) revert WouldBreachBurnFloor();
        _burn(msg.sender, amount);
        emit ScheduledBurn(amount);
    }

    /**
     * @notice Burn tokens from the designated burn source wallet only.
     *         Called by BurnSchedule contract (BURNER_ROLE).
     *         Cannot target arbitrary user wallets — only the burn source.
     *         Requires prior approval (allowance) from the burn source wallet.
     * @param account The wallet to burn from (must be burnSource)
     * @param amount The number of tokens to burn
     */
    function burnFrom(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        if (account != burnSource) revert CanOnlyBurnFromDesignatedSource();
        if (totalSupply() - amount < OZT_BURN_FLOOR) revert WouldBreachBurnFloor();
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
        emit BurnFromSource(account, amount);
    }

    /**
     * @notice Batch distribute OZT to multiple recipients.
     *         Max 200 addresses per call.
     * @dev    Checks for duplicate addresses. Pre-validates total balance.
     * @param recipients Array of wallet addresses
     * @param amounts Array of token amounts (must match recipients length)
     */
    function batchDistribute(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
        uint256 len = recipients.length;
        if (len == 0) revert EmptyRecipientsArray();
        if (len != amounts.length) revert LengthMismatch();
        if (len > 200) revert MaxRecipientsExceeded();

        // Pre-validate total balance
        uint256 total = 0;
        for (uint256 i = 0; i < len; ) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert ZeroAmount();
            total += amounts[i];
            unchecked { ++i; }
        }
        if (balanceOf(msg.sender) < total) revert InsufficientBalance();

        // Duplicate check
        for (uint256 i = 0; i < len; ) {
            for (uint256 j = i + 1; j < len; ) {
                if (recipients[i] == recipients[j]) revert DuplicateRecipient();
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }

        for (uint256 i = 0; i < len; ) {
            _transfer(msg.sender, recipients[i], amounts[i]);
            unchecked { ++i; }
        }

        emit BatchDistribute(len, total);
    }

    /// @notice Pause all token transfers.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause all token transfers.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Prevent accidental renounce — would permanently lock admin functions.
    function renounceOwnership() public pure override {
        revert CannotRenounceOwnership();
    }

    /// @notice Prevent accidental renounce of DEFAULT_ADMIN_ROLE.
    /// @param role The role to renounce
    /// @param callerConfirmation The address confirming the renounce
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev    Cannot rescue the contract's own token.
     * @param token The ERC20 token to rescue (must not be this contract)
     * @param amount The amount to send to owner
     */
    function rescueTokens(IERC20 token, uint256 amount) external onlyOwner {
        if (address(token) == address(this)) revert CannotRescueOwnToken();
        token.safeTransfer(owner(), amount);
    }

    /**
     * @dev Sync DEFAULT_ADMIN_ROLE when ownership transfers.
     *      Prevents role divergence between Ownable2Step and AccessControl.
     * @param newOwner The new owner address
     */
    function _transferOwnership(address newOwner) internal override {
        address oldOwner = owner();
        super._transferOwnership(newOwner);
        if (oldOwner != address(0)) {
            _revokeRole(DEFAULT_ADMIN_ROLE, oldOwner);
        }
        if (newOwner != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        }
    }

    /**
     * @dev Hook that is called before any transfer of tokens, including minting and burning.
     * @param from The address tokens are transferred from
     * @param to The address tokens are transferred to
     * @param value The amount of tokens transferred
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }

    /**
     * @notice Check if the contract supports a given interface.
     * @param interfaceId The interface identifier to check
     * @return Whether the interface is supported
     */
    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControl) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
