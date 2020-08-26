pragma solidity ^0.5.0;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Mintable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interface/IPriceOracle.sol";
import "./utils/FMintErrorCodes.sol";
import "./utils/RewardDistributionRecipient.sol";
import "./utils/FantomCollateralStorage.sol";
import "./utils/FantomDebtStorage.sol";

// FantomBalancePoolCore implements a balance pool of collateral and debt tokens
// for the related Fantom DeFi contract. The collateral part allows notified rewards
// distribution to eligible collateral accounts.
contract FantomBalancePoolCore is
            Ownable,
            ReentrancyGuard,
            FMintErrorCodes,
            FantomCollateralStorage,
            FantomDebtStorage,
            RewardDistributionRecipient
{
    // define used libs
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for ERC20;

    // -------------------------------------------------------------
    // Price and value calculation related constants
    // -------------------------------------------------------------

    // collateralLowestDebtRatio4dec represents the lowest ratio between
    // collateral value and debt value allowed for the user.
    // User can not withdraw his collateral if the active ratio would
    // drop below this value.
    // The value is returned in 4 decimals, e.g. value 30000 = 3.0
    uint256 public constant collateralLowestDebtRatio4dec = 30000;

    // collateralRatioDecimalsCorrection represents the value to be used
    // to adjust result decimals after applying ratio to a value calculation.
    uint256 public constant collateralRatioDecimalsCorrection = 10000;

    // -------------------------------------------------------------
    // Rewards distribution related constants
    // -------------------------------------------------------------

    // collateralRewardsPool represents the address of the pool used to settle
    // collateral rewards to eligible accounts.
    address public constant collateralRewardsPool = address(0xf1277d1Ed8AD466beddF92ef448A132661956621);

    // rewardEpochLength represents the shortest possible length of the rewards
    // epoch where accounts can claim their accumulated rewards from staked collateral.
    uint256 public constant rewardEpochLength = 7 days;

    // rewardPerTokenDecimalsCorrection represents the correction done on rewards per token
    // so the calculation does not loose precision on very low reward rates and high collateral
    // balance in the system.
    uint256 public constant rewardPerTokenDecimalsCorrection = 1e6;

    // rewardClaimRatio4dec represents the collateral to debt ratio user has to have
    // to be able to claim accumulated rewards.
    // The value is kept in 4 decimals, e.g. value 50000 = 5.0
    uint256 public constant rewardClaimRatio4dec = 50000;

    // rewardClaimRatioDecimalsCorrection represents the the value to be used
    // to adjust claim check decimals after applying ratio to a value calculation.
    uint256 public constant rewardClaimRatioDecimalsCorrection = 10000;

    // -------------------------------------------------------------
    // Rewards distribution related state
    // -------------------------------------------------------------

    // rewardsRate represents the current rate of reward distribution;
    // e.g. the amount of reward tokens distributed per second of the current reward epoch
    uint256 public rewardRate;

    // rewardEpochEnds represents the time stamp of the expected end of this reward epoch;
    // the notified reward amount is spread across the epoch at its beginning and the distribution ends
    // on this time stamp; if a new epoch is started before this one ends, the remaining reward
    // is pushed to the new epoch; if the current epoch is past its end, no additional rewards
    // are distributed
    uint256 public rewardEpochEnds;

    // rewardUpdated represents the time stamp of the last reward distribution update; the update
    // is executed every time an account state changes and the purpose is to reflect the previous
    // state impact on the reward distribution
    uint256 public rewardUpdated;

    // rewardLastPerToken represents previous stored value of the rewards per token
    // and reflects rewards distribution before the latest collateral state change
    uint256 public rewardLastPerToken;

    // rewardPerTokenPaid represents the amount of reward tokens already settled for an account
    // per collateral token; it's updated each time the collateral amount changes to reflect
    // previous state impact on the rewards the account is eligible for.
    mapping(address => uint256) public rewardPerTokenPaid;

    // rewardStash represents the amount of reward tokens stashed
    // for an account address during the reward distribution update.
    mapping(address => uint256) public rewardStash;

    // -------------------------------------------------------------
    // Emitted events definition
    // -------------------------------------------------------------

    // Deposited is emitted on token received to deposit
    // increasing user's collateral value.
    event Deposited(address indexed token, address indexed user, uint256 amount);

    // Withdrawn is emitted on confirmed token withdraw
    // from the deposit decreasing user's collateral value.
    event Withdrawn(address indexed token, address indexed user, uint256 amount);

    // RewardAdded is emitted on starting new rewards epoch with specified amount
    // of rewards, which correspond to a reward rate per second based on epoch length.
    event RewardAdded(uint256 reward);

    // RewardPaid event is emitted when an account claims their rewards from the system.
    event RewardPaid(address indexed user, uint256 reward);

    // -------------------------------------------------------------
    // Collateral management functions below
    // -------------------------------------------------------------

    // deposit receives assets to build up the collateral value.
    // The collateral can be used later to mint tokens inside fMint module.
    // The call does not subtract any fee. No interest is granted on deposit.
    function deposit(address _token, uint256 _amount) public nonReentrant returns (uint256)
    {
        // make sure a non-zero value is being deposited
        if (_amount == 0) {
            return ERR_ZERO_AMOUNT;
        }

        // make sure caller has enough balance to cover the deposit
        if (_amount > ERC20(_token).balanceOf(msg.sender)) {
            return ERR_LOW_BALANCE;
        }

        // make sure we are allowed to transfer funds from the caller
        // to the fMint deposit pool
        if (_amount > ERC20(_token).allowance(msg.sender, address(this))) {
            return ERR_LOW_ALLOWANCE;
        }

        // transfer ERC20 tokens from account to the collateral pool
        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // update the reward distribution for the account before the state changes
        rewardUpdate(msg.sender);

        // add the collateral to the account
        collateralAdd(msg.sender, _token, _amount);

        // emit the event signaling a successful deposit
        emit Deposited(_token, msg.sender, _amount);

        // deposit successful
        return ERR_NO_ERROR;
    }

    // withdraw subtracts any deposited collateral token from the contract.
    // The remaining collateral value is compared to the minimal required
    // collateral to debt ratio and the transfer is rejected
    // if the ratio is lower than the enforced one.
    function withdraw(address _token, uint256 _amount) public nonReentrant returns (uint256) {
        // make sure a non-zero value is being withdrawn
        if (_amount == 0) {
            return ERR_ZERO_AMOUNT;
        }

        // make sure the withdraw does not exceed collateral balance
        if (_amount > _collateralBalance[msg.sender][_token]) {
            return ERR_LOW_BALANCE;
        }

        // does the new state obey the enforced minimal collateral to debt ratio?
        // if the check fails, the collateral withdraw is rejected
        if (!collateralCanDecrease(msg.sender, _token, _amount)) {
            return ERR_LOW_COLLATERAL_RATIO;
        }

        // update the reward distribution for the account before state changes
        rewardUpdate(msg.sender);

        // remove the collateral from account
        collateralSub(msg.sender, _token, _amount);

        // transfer withdrawn ERC20 tokens to the caller
        ERC20(_token).safeTransfer(msg.sender, _amount);

        // signal the successful asset withdrawal
        emit Withdrawn(_token, msg.sender, _amount);

        // withdraw successful
        return ERR_NO_ERROR;
    }

    // -------------------------------------------------------------
    // Collateral to debt ratio checks below
    // -------------------------------------------------------------

    // collateralCanDecrease checks if the specified amount of collateral can be removed from account
    // without breaking collateral to debt ratio rule
    function collateralCanDecrease(address _account, address _token, uint256 _amount) public view returns (bool) {
        // calculate the collateral and debt values in ref. denomination
        // for the current exchange rate and balance amounts
        uint256 cDebtValue = debtBalanceOf(_account);
        uint256 cCollateralValue = collateralBalanceOf(_account);

        // lower the collateral value by the withdraw value
        cCollateralValue.sub(collateralTokenValue(_token, _amount));

        // minCollateralValue is the minimal collateral value required for the current debt
        // to be within the minimal allowed collateral to debt ratio
        uint256 minCollateralValue = cDebtValue
                                        .mul(collateralLowestDebtRatio4dec)
                                        .div(collateralRatioDecimalsCorrection);

        // final collateral value must match the minimal value or exceed it
        return (cCollateralValue >= minCollateralValue);
    }

    // debtCanIncrease checks if the specified amount of debt can be added to the account
    // without breaking collateral to debt ratio rule
    function debtCanIncrease(address _account, address _token, uint256 _amount) public view returns (bool) {
        // calculate the collateral and debt values in ref. denomination
        // for the current exchange rate and balance amounts
        uint256 cDebtValue = debtBalanceOf(_account);
        uint256 cCollateralValue = collateralBalanceOf(_account);

        // increase the current debt by the value of the newly requested debt
        cDebtValue.add(collateralTokenValue(_token, _amount));

        // minCollateralValue is the minimal collateral value required for the current debt
        // to be within the minimal allowed collateral to debt ratio
        uint256 minCollateralValue = cDebtValue
                                        .mul(collateralLowestDebtRatio4dec)
                                        .div(collateralRatioDecimalsCorrection);

        // final collateral value must match the minimal value or exceed it
        return (cCollateralValue >= minCollateralValue);
    }

    // -------------------------------------------------------------
    // Reward related functions below
    // -------------------------------------------------------------

    // rewardNotifyAmount is called by reward distribution management to start new reward epoch
    // with a new reward amount added to the reward pool.
    function rewardNotifyAmount(uint256 reward) external onlyRewardDistribution {
        // update the global reward distribution state before closing
        // the current epoch
        rewardUpdate(address(0));

        // if the previous reward epoch is about to end sooner than it's expected,
        // calculate remaining reward tokens from the previous epoch
        // and add it to the notified reward pushing the leftover to the new epoch
        if (now < rewardEpochEnds) {
            uint256 leftover = rewardEpochEnds.sub(now).mul(rewardRate);
            reward = reward.add(leftover);
        }

        // start new reward epoch with the new reward rate
        rewardRate = reward.div(rewardEpochLength);
        rewardEpochEnds = now.add(rewardEpochLength);
        rewardUpdated = now;

        // emit the events to notify new epoch with the updated rewards rate
        emit RewardAdded(reward);
    }

    // rewardUpdate updates the stored reward distribution state
    // and the accumulated reward tokens status per account;
    // it is called on each collateral state change to reflect
    // the previous state in collateral reward distribution.
    function rewardUpdate(address _account) internal {
        // calculate the current reward per token value globally
        rewardLastPerToken = rewardPerToken();
        rewardUpdated = rewardApplicableUntil();

        // if this is an account state update, calculate rewards earned
        // to this point (before the account collateral value changes)
        // and stash those rewards
        if (_account != address(0)) {
            rewardStash[_account] = rewardEarned(_account);
            rewardPerTokenPaid[_account] = rewardLastPerToken;
        }
    }

    // rewardApplicableUntil returns the time stamp of the latest time
    // the notified rewards can be distributed.
    // The notified reward is spread across the whole epoch period
    // using the reward rate (number of reward tokens per second).
    // No more reward tokens remained to be distributed past the
    // epoch duration, so the distribution has to stop.
    function rewardApplicableUntil() public view returns (uint256) {
        return Math.min(now, rewardEpochEnds);
    }

    // rewardPerToken calculates the reward share per virtual collateral value
    // token. It's based on the reward rate for the epoch (e.g. the total amount
    // of reward tokens per second)
    function rewardPerToken() public view returns (uint256) {
        // @NOTE: collateralBalance() loops over collateral tokens
        // and calculates price using oracles; this could be expensive and it's called repeatedly.
        // We may want to cache the balance along with the last update time stamp to save some gas.

        // the reward distribution is normalized to the total amount of collateral
        // in the system; calculate the current collateral value across all the tokens
        uint256 total = collateralBalance();

        // no collateral? use just the reward per token stored
        if (total == 0) {
            return rewardLastPerToken;
        }

        // return accumulated stored rewards plus the rewards
        // coming from the current reward rate normalized to the total
        // collateral amount. The distribution stops at the epoch end.
        return rewardLastPerToken.add(
            rewardApplicableUntil().sub(rewardUpdated)
            .mul(rewardRate)
            .mul(rewardPerTokenDecimalsCorrection)
            .div(total)
            );
    }

    // rewardEarned calculates the amount of reward tokens the given account is eligible
    // for right now based on its collateral balance value and the total value
    // of all collateral tokens in the system
    function rewardEarned(address _account) public view returns (uint256) {
        // @NOTE: We calculate the rewards earned from the whole collateral value,
        // but we may consider changing it to use only excessive collateral above
        // certain collateral to debt ratio.
        // e.g. excessive collateral = collateral value - (debt value * 300%)
        return collateralBalanceOf(_account)
                .mul(rewardPerToken().sub(rewardPerTokenPaid[_account]))
                .div(rewardPerTokenDecimalsCorrection)
                .add(rewardStash[_account]);
    }

    // rewardClaim transfers earned rewards to the caller account address
    function rewardClaim() public returns (uint256) {
        // update the reward distribution for the account
        rewardUpdate(msg.sender);

        // how many reward tokens were earned by the account?
        uint256 reward = rewardStash[msg.sender];

        // @NOTE: Pulling this from the rewardEarned() invokes system-wide
        // collateral balance calculation again (through rewardPerToken) burning gas;
        // All the earned tokens should be in the stash already after
        // the reward update call above.

        // are there any at all?
        if (0 == reward) {
            return ERR_NO_REWARD;
        }

        // check if the account can claim
        // @NOTE: We may not need this check if the actual amount of rewards will
        // be calculated from an excessive amount of collateral compared to debt
        // including certain ration (e.g. debt value * 300% < collateral value)
        // @see rewardEarned() call above
        if (!rewardCanClaim(msg.sender)) {
            return ERR_REWARD_CLAIM_REJECTED;
        }

        // reset accumulated rewards on the account
        rewardStash[msg.sender] = 0;

        // transfer earned reward tokens to the caller
        ERC20(collateralRewardsPool).safeTransfer(msg.sender, reward);

        // notify about the action
        emit RewardPaid(msg.sender, reward);

        // claim successful
        return ERR_NO_ERROR;
    }

    // rewardCanClaim checks if the account can claim accumulated rewards
    // by being on a high enough collateral to debt ratio.
    function rewardCanClaim(address _account) public view returns (bool) {
        // calculate the collateral and debt values in ref. denomination
        // for the current exchange rate and balance amounts
        uint256 cDebtValue = debtBalanceOf(_account);
        uint256 cCollateralValue = collateralBalanceOf(_account);

        // minCollateralValue is the minimal collateral value required for the current debt
        // to be within the allowed collateral to debt ratio for reward claiming
        uint256 minCollateralValue = cDebtValue
                                        .mul(rewardClaimRatio4dec)
                                        .div(rewardClaimRatioDecimalsCorrection);

        // final collateral value must match the minimal value or exceed it
        return (cCollateralValue >= minCollateralValue);
    }
}