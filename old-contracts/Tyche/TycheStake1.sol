// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

contract TycheStake is ERC721Holder, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public totalCollections = 0;
    mapping(address => bool) public whitelist;
    address[] public poolContracts;
    struct PoolInfo {
        address rewardToken1;
        address rewardToken2;  // If provide the second reward token. If not, 0x
        uint256 startTime;
        uint256 endTime;
        uint256 rewardPerSecond1;  // reward amount per second for reward token1
        uint256 rewardPerSecond2;  // reward amount per second for reward token2
        uint256 lastRewardTime;
        uint256 stakedSupply;
        uint256 accPerShare1;
        uint256 accPerShare2;
    }
    // stakeToken address => PoolInfo
    mapping(address => PoolInfo) public pools;

    struct UserInfo {
        uint256 amount;  // How many tokens staked per collection
        uint256 debt1;  // Reward debt for first reward token
        uint256 debt2;  // Reward debt for second reward token
        uint256[] tokenIds;  // staked token ids
    }
    // user => collection => UserInfo
    mapping(address => mapping(address => UserInfo)) private users;
    // user => collections // view
    mapping(address => address[]) public userCollections;
    // check user staked for add/remove, user => collection => bool
    mapping(address => mapping(address => bool)) public isUserCollection;
    // collection => tokenId => user address
    mapping(address => mapping(uint256 => address)) public tokenOwners;
    
    event CreatePool(
        address stakeToken,
        address rewardToken1,
        uint256 rewardPerSecond1,
        uint256 startTime,
        uint256 endTime,
        address rewardToken2,
        uint256 rewardPerSecond2
    );
    event Stake(address user, address collection, uint256 tokenId);
    event Unstake(address user, address collection, uint256 tokenId);
    event Claim(address user, address collection, address rewardToken, uint256 amount);
    event UpdateReward(address collection, uint256 rate1, uint256 rate2);
    event UpdateStartTime(address collection, uint256 startTime);
    event UpdateEndTime(address collection, uint256 endTime);
    event ClaimTime(uint256);

    constructor() {}
    
    function createPool(address _stakeToken, address _rewardToken1, uint256 _rewardPerSecond1, uint256 _startTime, uint256 _endTime, address _rewardToken2, uint256 _rewardPerSecond2) external onlyOwner {
        require(!whitelist[_stakeToken], "The collection is added already.");
        totalCollections += 1;
        PoolInfo memory pool = pools[_stakeToken];
        pool.startTime = _startTime;
        pool.endTime = _endTime;
        pool.lastRewardTime = _startTime;
        pool.stakedSupply = 0;
        pool.rewardToken1 = _rewardToken1;
        pool.rewardPerSecond1 = _rewardPerSecond1;
        if (_rewardToken2 == address(0)) {
            pool.rewardToken2 = address(0);
            pool.rewardPerSecond2 = 0;
        } else {
            pool.rewardToken2 = _rewardToken2;
            pool.rewardPerSecond2 = _rewardPerSecond2;
        }
        pool.accPerShare1 = 0;
        pool.accPerShare2 = 0;

        pools[_stakeToken] = pool;
        whitelist[_stakeToken] = true;
        poolContracts.push(_stakeToken);
        emit CreatePool(_stakeToken, _rewardToken1, _rewardPerSecond1, _startTime, _endTime, _rewardToken2, _rewardPerSecond2);
    }

    function stake(address _stakeToken, uint256[] memory _tokenIds) external nonReentrant {
        require(whitelist[_stakeToken], "The token is not allowed to stake!");
        uint256 _length = _tokenIds.length;
        require(_length > 0, "You should stake tokens at least one.");
        _updatePool(_stakeToken);
        PoolInfo storage pool = pools[_stakeToken];
        UserInfo storage user = users[msg.sender][_stakeToken];

        uint256[2] memory rewardAmounts = checkRewards(msg.sender, _stakeToken);
        if (rewardAmounts[0] > 0) {
            safeRewardTransfer(pool.rewardToken1, msg.sender, rewardAmounts[0]);
            emit Claim(msg.sender, _stakeToken, pool.rewardToken1, rewardAmounts[0]);
        }
        if (rewardAmounts[1] > 0) {
            safeRewardTransfer(pool.rewardToken2, msg.sender, rewardAmounts[1]);
            emit Claim(msg.sender, _stakeToken, pool.rewardToken2, rewardAmounts[1]);
        }

        for (uint256 i = 0; i < _length; i++) {
            IERC721(_stakeToken).safeTransferFrom(msg.sender, address(this), _tokenIds[i]);
            user.tokenIds.push(_tokenIds[i]);
            tokenOwners[_stakeToken][_tokenIds[i]] = msg.sender;
            emit Stake(msg.sender, _stakeToken, _tokenIds[i]);
        }
        user.amount += _length;
        pool.stakedSupply += _length;

        if (!isUserCollection[msg.sender][_stakeToken]) {
            isUserCollection[msg.sender][_stakeToken] = true;
            userCollections[msg.sender].push(_stakeToken);
        }

        user.debt1 = user.amount * pool.accPerShare1;
        user.debt2 = user.amount * pool.accPerShare2;
    }

    function unstakeOne(address _stakeToken, uint256 _tokenId) external nonReentrant {
        require(whitelist[_stakeToken], "The token is not allowed to stake!");
        require(tokenOwners[_stakeToken][_tokenId] == msg.sender, "Token owner can unstake only");
        _updatePool(_stakeToken);
        PoolInfo storage pool = pools[_stakeToken];
        UserInfo storage user = users[msg.sender][_stakeToken];

        uint256[2] memory rewardAmounts = checkRewards(msg.sender, _stakeToken);
        if (rewardAmounts[0] > 0) {
            safeRewardTransfer(pool.rewardToken1, msg.sender, rewardAmounts[0]);
            emit Claim(msg.sender, _stakeToken, pool.rewardToken1, rewardAmounts[0]);
        }
        if (rewardAmounts[1] > 0) {
            safeRewardTransfer(pool.rewardToken2, msg.sender, rewardAmounts[1]);
            emit Claim(msg.sender, _stakeToken, pool.rewardToken2, rewardAmounts[1]);
        }

        uint256 _length = user.tokenIds.length;
        require(_length > 0, "You don't have any staked token");
        for(uint256 i = 0; i < _length - 1; i++) {
            if (user.tokenIds[i] == _tokenId) {
                user.tokenIds[i] = user.tokenIds[_length - 1];
            }
        }
        user.tokenIds.pop();
        user.amount --;
        if (user.amount == 0) {
            // remove user collection
            isUserCollection[msg.sender][_stakeToken] = false;
            uint256 lengthOfUserCollections = userCollections[msg.sender].length;
            for(uint256 i = 0; i < lengthOfUserCollections - 1; i++) {
                if (userCollections[msg.sender][i] == _stakeToken) {
                    userCollections[msg.sender][i] = userCollections[msg.sender][lengthOfUserCollections - 1];
                }
            }
            userCollections[msg.sender].pop();
        }
        pool.stakedSupply --;
        IERC721(_stakeToken).safeTransferFrom(address(this), msg.sender, _tokenId);
        tokenOwners[_stakeToken][_tokenId] = address(0);

        user.debt1 = user.amount * pool.accPerShare1;
        user.debt2 = user.amount * pool.accPerShare2;
        emit Unstake(msg.sender, _stakeToken, _tokenId);
    }

    function unstake(address _stakeToken) external nonReentrant {
        require(whitelist[_stakeToken], "The token is not allowed to stake!");
        _updatePool(_stakeToken);
        PoolInfo storage pool = pools[_stakeToken];
        UserInfo storage user = users[msg.sender][_stakeToken];
        
        uint256[2] memory rewardAmounts = checkRewards(msg.sender, _stakeToken);
        if (rewardAmounts[0] > 0) {
            safeRewardTransfer(pool.rewardToken1, msg.sender, rewardAmounts[0]);
            emit Claim(msg.sender, _stakeToken, pool.rewardToken1, rewardAmounts[0]);
        }
        if (rewardAmounts[1] > 0) {
            safeRewardTransfer(pool.rewardToken2, msg.sender, rewardAmounts[1]);
            emit Claim(msg.sender, _stakeToken, pool.rewardToken2, rewardAmounts[1]);
        }
        
        uint256[] memory tokenIds = user.tokenIds;
        uint256 _length = tokenIds.length;
        for (uint256 i = 0; i < _length; i++) {
            IERC721(_stakeToken).safeTransferFrom(address(this), msg.sender, tokenIds[i]);
            tokenOwners[_stakeToken][tokenIds[i]] = address(0);
            emit Unstake(msg.sender, _stakeToken, tokenIds[i]);
        }
        user.amount = 0;
        delete user.tokenIds;
        
        // remove user collection
        isUserCollection[msg.sender][_stakeToken] = false;
        uint256 lengthOfUserCollections = userCollections[msg.sender].length;
        for(uint256 i = 0; i < lengthOfUserCollections - 1; i++) {
            if (userCollections[msg.sender][i] == _stakeToken) {
                userCollections[msg.sender][i] = userCollections[msg.sender][lengthOfUserCollections - 1];
            }
        }
        userCollections[msg.sender].pop();

        pool.stakedSupply -= _length;
        user.debt1 = user.amount * pool.accPerShare1;
        user.debt2 = user.amount * pool.accPerShare2;
    }

    function claim(address _stakeToken) external nonReentrant {
        require(whitelist[_stakeToken], "The token is not allowed to stake!");
        _updatePool(_stakeToken);
        PoolInfo storage pool = pools[_stakeToken];
        UserInfo storage user = users[msg.sender][_stakeToken];

        uint256[2] memory rewardAmounts = checkRewards(msg.sender, _stakeToken);
        if (rewardAmounts[0] > 0) {
            safeRewardTransfer(pool.rewardToken1, msg.sender, rewardAmounts[0]);
            emit Claim(msg.sender, _stakeToken, pool.rewardToken1, rewardAmounts[0]);
        }
        if (rewardAmounts[1] > 0) {
            safeRewardTransfer(pool.rewardToken2, msg.sender, rewardAmounts[1]);
            emit Claim(msg.sender, _stakeToken, pool.rewardToken2, rewardAmounts[1]);
        }
        user.debt1 = user.amount * pool.accPerShare1;
        user.debt2 = user.amount * pool.accPerShare2;
        emit ClaimTime(block.timestamp);
    }

    // Internal functions
    function _updatePool(address _stakeToken) internal {
        PoolInfo storage pool = pools[_stakeToken];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        if (pool.stakedSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = _getMultiplier(pool.lastRewardTime, block.timestamp, pool.endTime);
        pool.accPerShare1 = pool.accPerShare1 + multiplier * pool.rewardPerSecond1 / pool.stakedSupply;
        if (pool.rewardToken2 != address(0)) {
            pool.accPerShare2 = pool.accPerShare2 + multiplier * pool.rewardPerSecond2 / pool.stakedSupply;
        }
        pool.lastRewardTime = block.timestamp;
    }

    function _getMultiplier(uint256 _from, uint256 _to, uint256 _endTime) internal pure returns (uint256) {
        if (_to <= _endTime) {
            return _to - _from;
        } else if (_from >= _endTime) {
            return 0;
        } else {
            return _endTime - _from;
        }
    }

    /*
     * @notice check rewards in real time.
     */
    function checkRewards(address _user, address _stakeToken) public view returns(uint256[2] memory) {
        uint256 reward1 = 0;
        uint256 reward2 = 0;
        PoolInfo storage pool = pools[_stakeToken];
        UserInfo storage user = users[_user][_stakeToken];
        uint256 adjustedPerShare1 = pool.accPerShare1;
        uint256 adjustedPerShare2 = pool.accPerShare2;
        uint256 multiplier = _getMultiplier(pool.lastRewardTime, block.timestamp, pool.endTime);
        if (block.timestamp > pool.lastRewardTime && pool.stakedSupply != 0) {
            adjustedPerShare1 = pool.accPerShare1 + multiplier * pool.rewardPerSecond1 / pool.stakedSupply;
        }
        reward1 = user.amount * adjustedPerShare1 - user.debt1;
        if (pool.rewardToken2 != address(0)) {
            if (block.timestamp > pool.lastRewardTime && pool.stakedSupply != 0) {
                adjustedPerShare2 = pool.accPerShare2 + multiplier * pool.rewardPerSecond2 / pool.stakedSupply;
            }
            reward2 = user.amount * adjustedPerShare2 - user.debt2;
        }
        return [reward1, reward2];
    }

    function safeRewardTransfer(address _rewardToken, address _to, uint256 _amount) internal {
        IERC20 rewardToken = IERC20(_rewardToken);
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        require(rewardBalance >= _amount, "insufficent reward.");
        rewardToken.safeTransfer(_to, _amount);
    }

    function updateRewardRate(address _stakeToken, uint256 _newRate1, uint256 _newRate2) external onlyOwner {
        require(whitelist[_stakeToken], "The token is not allowed to stake!");
        _updatePool(_stakeToken);
        PoolInfo storage pool = pools[_stakeToken];
        pool.rewardPerSecond1 = _newRate1;
        pool.rewardPerSecond2 = _newRate2;
        emit UpdateReward(_stakeToken, _newRate1, _newRate2);
    }

    function updateStartTime(address _stakeToken, uint256 _startTime) external onlyOwner {
        require(block.timestamp < _startTime, "New startBlock must be higher than current block");
        require(whitelist[_stakeToken], "The token is not allowed to stake!");
        PoolInfo storage pool = pools[_stakeToken];
        require(block.timestamp < pool.startTime, "Pool has started already");

        pool.startTime = _startTime;
        pool.lastRewardTime = _startTime;

        emit UpdateStartTime(_stakeToken, _startTime);
    }

    function getUserTokenIds(address _user, address _stakeToken) public view returns(uint256[] memory) {
        return users[_user][_stakeToken].tokenIds;
    }

    function getUserCollections(address _user) public view returns(address[] memory) {
        return userCollections[_user];
    }

    function checkUser(address _user, address _stakeToken) public view returns (UserInfo memory) {
        return users[_user][_stakeToken];
    }

    function getPoolContracts() public view returns(address[] memory) {
        return poolContracts;
    }
    
    function recoverWrongTokens(address _rewardToken) external onlyOwner {
        IERC20(_rewardToken).transfer(msg.sender, IERC20(_rewardToken).balanceOf(address(this)));
    }

    function readBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }
}
