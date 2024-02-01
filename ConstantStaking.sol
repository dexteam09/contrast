// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

library TransferHelper {
    /// @notice Transfers tokens from the targeted address to the given destination
    /// @notice Errors with 'STF' if transfer fails
    /// @param token The contract address of the token to be transferred
    /// @param from The originating address from which the tokens will be transferred
    /// @param to The destination address of the transfer
    /// @param value The amount to be transferred
    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) =
                            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'STF');
    }

    /// @notice Transfers tokens from msg.sender to a recipient
    /// @dev Errors with ST if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param to The recipient of the transfer
    /// @param value The value of the transfer
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'ST');
    }

    /// @notice Approves the stipulated contract to spend the given allowance in the given token
    /// @dev Errors with 'SA' if transfer fails
    /// @param token The contract address of the token to be approved
    /// @param to The target of the approval
    /// @param value The amount of the given token the target will be allowed to spend
    function safeApprove(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'SA');
    }

    /// @notice Transfers ETH to the recipient address
    /// @dev Fails with `STE`
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, 'STE');
    }
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

interface IGMTO {
    function mint(address to, uint256 amount) external;
}

contract ConstantStaking is Ownable {
    using TransferHelper for address;

    uint256 public apy;
    uint256 private constant MAX_APY = 100;
    address public MTO;
    address public GMTO;
    uint256 public total; // total staking amount
    uint256 private constant SECONDS_IN_YEAR = 365 days;
    uint256 public claim_interval = 7 days; // 7 days; claim wait interval seconds
    uint256 private constant CLAIM_INTERVAL_MAX = 365 days;

    struct Order {
        uint256 amount;
        uint256 createdTs;
    }

    struct Claim {
        uint256 amount; // MTO
        uint256 reward; // GMTO
        uint256 startTs; // claim time
    }

    mapping(address => Order[]) public stakings;
    mapping(address => Claim) public claims;

    event Staked(address indexed from, uint256 amount);
    event Claimed(address indexed from, uint256 amount, uint256 reward);
    event ClaimApplied(address indexed from, uint256 amount, uint256 reward);

    constructor(address _mto, address _gmto) {
        MTO = _mto;
        GMTO = _gmto;
        apy = 12;
    }

    function setAPY(uint256 _apy) external onlyOwner {
        require(_apy <= MAX_APY, "ConstantStaking: out of range");
        apy = _apy;
    }

    function setMTO(address _mto) external onlyOwner {
        MTO = _mto;
    }

    function setGMTO(address _gmto) external onlyOwner {
        GMTO = _gmto;
    }

    function setClaimInterval(uint256 _ts) external onlyOwner {
        require(_ts <= CLAIM_INTERVAL_MAX, "Claim interval cannot exceed 365 days");
        claim_interval = _ts;
    }

    function stake(uint256 amount) external {
        address sender = msg.sender;
        MTO.safeTransferFrom(sender, address(this), amount);
        Order[] storage orders = stakings[sender];
        orders.push(Order({amount: amount, createdTs: block.timestamp}));
        total += amount;
        emit Staked(sender, amount);
    }

    function applyClaim() external {
        Claim storage claimInfo = claims[msg.sender];
        require(claimInfo.amount == 0, "ConstantStaking: have already applied");

        uint256 allMTO = calculateMTO(msg.sender);
        require(allMTO > 0, "ConstantStaking: no staking");
        // MTO.safeTransfer(msg.sender, allMTO);
        uint256 allRewards = calculateRewards(msg.sender);
        require(allRewards > 0, "ConstantStaking: no rewards");

        claimInfo.amount = allMTO;
        claimInfo.reward = allRewards;
        claimInfo.startTs = block.timestamp + claim_interval;
        delete stakings[msg.sender];
        emit ClaimApplied(msg.sender, allMTO, allRewards);
    }

    function claim() external {
        Claim memory claimInfo = claims[msg.sender];
        require(claimInfo.amount > 0, "ConstantStaking: no apply");
        require(
            block.timestamp >= claimInfo.startTs,
            "ConstantStaking: claim too early"
        );
        // clear data
        delete claims[msg.sender];
        total -= claimInfo.amount;
        MTO.safeTransfer(msg.sender, claimInfo.amount);
        if (claimInfo.reward > 0) {
            GMTO.safeTransfer(msg.sender, claimInfo.reward);
        }
        emit Claimed(msg.sender, claimInfo.amount, claimInfo.reward);
    }

    function rewards(address sender) public view returns (uint256, uint256) {
        Claim memory claimInfo = claims[sender];
        uint256 reward = calculateRewards(sender);
        return (claimInfo.reward, reward);
    }

    function stakes(address sender) public view returns (uint256) {
        Claim memory claimInfo = claims[sender];
        uint256 all = calculateMTO(sender) + claimInfo.amount;
        return all;
    }

    function calculateMTO(address sender) internal view returns (uint256) {
        Order[] memory orders = stakings[sender];
        uint256 all = 0;
        for (uint i = 0; i < orders.length; i++) {
            Order memory order = orders[i];
            all += order.amount;
        }
        return all;
    }

    function calculateRewards(address sender) internal view returns (uint256) {
        Order[] memory orders = stakings[sender];
        uint256 all = 0;
        for (uint i = 0; i < orders.length; i++) {
            Order memory order = orders[i];
            uint256 ts = block.timestamp - order.createdTs;
            all += (((order.amount * apy) * ts) / MAX_APY) / SECONDS_IN_YEAR;
        }
        return all;
    }
}
