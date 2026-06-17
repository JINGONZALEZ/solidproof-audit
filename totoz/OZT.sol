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
        require(initialOwner != address(0), "Zero owner address");
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
        require(burnSource == address(0), "Burn source already set");
        require(_burnSource != address(0), "Zero address");
        burnSource = _burnSource;
        emit BurnSourceSet(_burnSource);
    }

    /**
     * @notice Scheduled burn of OZT from OWNER wallet specifically.
     *         Note: burns from msg.sender (owner), NOT from burnSource.
     *         For burns from the designated supply wallet, use BurnSchedule.
     */
    function scheduledBurn(uint256 amount) external onlyOwner {
        require(totalSupply() - amount >= OZT_BURN_FLOOR, "Would breach OZT burn floor");
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
        require(account == burnSource, "Can only burn from designated source");
        require(totalSupply() - amount >= OZT_BURN_FLOOR, "Would breach OZT burn floor");
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
        emit BurnFromSource(account, amount);
    }

    /**
     * @notice Batch distribute OZT to multiple recipients.
     *         Max 200 addresses per call.
     * @dev    Checks for duplicate addresses. Pre-validates total balance.
     */
    function batchDistribute(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
        require(recipients.length > 0, "Empty recipients array");
        require(recipients.length == amounts.length, "Length mismatch");
        require(recipients.length <= 200, "Max 200 recipients");

        // Pre-validate total balance
        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address");
            require(amounts[i] > 0, "Zero amount");
            total += amounts[i];
        }
        require(balanceOf(msg.sender) >= total, "Insufficient balance for distribution");

        // Duplicate check
        for (uint256 i = 0; i < recipients.length; i++) {
            for (uint256 j = i + 1; j < recipients.length; j++) {
                require(recipients[i] != recipients[j], "Duplicate recipient");
            }
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(msg.sender, recipients[i], amounts[i]);
        }

        emit BatchDistribute(recipients.length, total);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Prevent accidental renounce — would permanently lock admin functions.
    function renounceOwnership() public pure override {
        revert("Cannot renounce ownership");
    }

    /// @notice Prevent accidental renounce of DEFAULT_ADMIN_ROLE.
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        require(role != DEFAULT_ADMIN_ROLE, "Cannot renounce admin role");
        super.renounceRole(role, callerConfirmation);
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev    Cannot rescue the contract's own token.
     */
    function rescueTokens(IERC20 token, uint256 amount) external onlyOwner {
        require(address(token) != address(this), "Cannot rescue own token");
        token.safeTransfer(owner(), amount);
    }

    /**
     * @dev Sync DEFAULT_ADMIN_ROLE when ownership transfers.
     *      Prevents role divergence between Ownable2Step and AccessControl.
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

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControl) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
