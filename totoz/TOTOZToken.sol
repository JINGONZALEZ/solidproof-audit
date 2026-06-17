// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title TOTOz — Access and Participation Token
 * @notice Consumptive utility token burned on AI agent use. 8 Quadrillion supply.
 *         100% allocated/airdropped — never sold by OZ Capital.
 *         Owner should be a multi-sig (Gnosis Safe).
 *
 *         Burn schedule: 90% trustless (anyone can trigger via BurnSchedule),
 *         5% discretionary (executor role). See BurnSchedule contract.
 *
 *         Burn floor: 1 Billion tokens minimum — enforced on-chain, cannot be overridden.
 *
 *         Security review rounds 1+2 applied June 13, 2026.
 *
 *         initialOwner receives all tokens and admin roles.
 *         Should be a Gnosis Safe multi-sig (2-of-3).
 */
contract TOTOZToken is ERC20, ERC20Pausable, Ownable2Step, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role for BurnSchedule contract to call burnFrom.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Minimum total supply — burns revert if they would reduce supply below this.
    uint256 public constant BURN_FLOOR = 1_000_000_000 * 10 ** 18; // 1 Billion tokens

    /// @notice Maximum daily burn per user (limits damage if owner key compromised).
    uint256 public constant DAILY_BURN_CAP = 1_000_000 * 10 ** 18; // 1M tokens/user/day

    /// @notice Designated wallet that burnFrom can target. Prevents BURNER_ROLE from
    ///         burning arbitrary user wallets. Set once by owner.
    /// @dev    IRREVERSIBLE — cannot be changed after being set. Verify address on-chain
    ///         before calling setBurnSource(). Incorrect address permanently breaks scheduled burns.
    address public burnSource;

    uint256 public maxBurnPerCall;

    /// @dev Tracks daily burns per user to enforce DAILY_BURN_CAP.
    mapping(address => uint256) public dailyBurned;
    mapping(address => uint256) public lastBurnDay;

    event AgentBurn(address indexed user, uint256 amount, string reason);
    event ScheduledBurn(uint256 amount);
    event BurnFromSource(address indexed account, uint256 amount);
    event BatchAirdrop(uint256 recipientCount, uint256 totalAmount);
    event MaxBurnUpdated(uint256 oldMax, uint256 newMax);
    event BurnSourceSet(address indexed burnSource);

    constructor(address initialOwner)
        ERC20("TOTOz", "TOTOZ")
        Ownable(initialOwner)
    {
        require(initialOwner != address(0), "Zero owner address");
        _mint(initialOwner, 8_000_000_000_000_000 * 10 ** 18);
        maxBurnPerCall = 100_000 * 10 ** 18;
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
     * @notice Burn tokens from a user's wallet for AI agent interaction.
     *         Only callable by owner (platform backend).
     *         Enforces per-call cap AND per-user daily cap to limit damage
     *         if the owner key is compromised.
     * @param user The wallet address to burn from
     * @param amount The number of tokens to burn
     * @param reason Description of the agent action (e.g., "country_comparison")
     */
    function agentBurn(address user, uint256 amount, string calldata reason) external onlyOwner {
        require(amount <= maxBurnPerCall, "Exceeds burn cap");
        require(totalSupply() - amount >= BURN_FLOOR, "Would breach burn floor");

        // Daily per-user rate limit
        uint256 today = block.timestamp / 1 days;
        if (lastBurnDay[user] < today) {
            dailyBurned[user] = 0;
            lastBurnDay[user] = today;
        }
        require(dailyBurned[user] + amount <= DAILY_BURN_CAP, "Daily burn cap exceeded");
        dailyBurned[user] += amount;

        _burn(user, amount);
        emit AgentBurn(user, amount, reason);
    }

    /**
     * @notice Update the maximum tokens that can be burned per agentBurn call.
     * @param newMax The new maximum burn amount
     */
    function setMaxBurnPerCall(uint256 newMax) external onlyOwner {
        require(newMax >= 1_000 * 10 ** 18, "Below minimum (1,000)");
        require(newMax <= DAILY_BURN_CAP, "Cannot exceed daily cap");
        emit MaxBurnUpdated(maxBurnPerCall, newMax);
        maxBurnPerCall = newMax;
    }

    /**
     * @notice Scheduled burn of unallocated supply from OWNER wallet specifically.
     *         Note: burns from msg.sender (owner), NOT from burnSource.
     *         For burns from the designated supply wallet, use BurnSchedule.
     * @param amount The number of tokens to burn from owner
     */
    function scheduledBurn(uint256 amount) external onlyOwner {
        require(totalSupply() - amount >= BURN_FLOOR, "Would breach burn floor");
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
        require(totalSupply() - amount >= BURN_FLOOR, "Would breach burn floor");
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
        emit BurnFromSource(account, amount);
    }

    /// @notice Returns the minimum total supply floor.
    function burnFloor() external pure returns (uint256) {
        return BURN_FLOOR;
    }

    /// @notice Returns true if totalSupply is above the burn floor.
    function isBurnActive() external view returns (bool) {
        return totalSupply() > BURN_FLOOR;
    }

    /**
     * @notice Batch airdrop tokens to multiple recipients.
     *         Max 200 addresses per call to stay within gas limits.
     * @dev    Checks for duplicate addresses to prevent accidental double allocation.
     *         Pre-validates total balance before any transfers.
     * @param recipients Array of wallet addresses
     * @param amounts Array of token amounts (must match recipients length)
     */
    function batchAirdrop(
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
        require(balanceOf(msg.sender) >= total, "Insufficient balance for airdrop");

        // Duplicate check
        for (uint256 i = 0; i < recipients.length; i++) {
            for (uint256 j = i + 1; j < recipients.length; j++) {
                require(recipients[i] != recipients[j], "Duplicate recipient");
            }
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(msg.sender, recipients[i], amounts[i]);
        }

        emit BatchAirdrop(recipients.length, total);
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
     * @dev    Cannot rescue the contract's own token — use scheduledBurn or transfer instead.
     * @param token The ERC20 token to rescue (must not be this contract)
     * @param amount The amount to send to owner
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
