// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity 0.8.9;

import {SafeCast} from "@openzeppelin/contracts-v4.4/utils/math/SafeCast.sol";
import {SafeCastExt} from "../lib/SafeCastExt.sol";

import {Math256} from "../../common/lib/Math256.sol";
import {AccessControlEnumerable} from "../utils/access/AccessControlEnumerable.sol";
import {PositiveTokenRebaseLimiter, TokenRebaseLimiterData} from "../lib/PositiveTokenRebaseLimiter.sol";
import {ILidoLocator} from "../../common/interfaces/ILidoLocator.sol";
import {IBurner} from "../../common/interfaces/IBurner.sol";

interface IWithdrawalQueue {
    struct WithdrawalRequestStatus {
        /// @notice stETH token amount that was locked on withdrawal queue for this request
        uint256 amountOfStETH;
        /// @notice amount of stETH shares locked on withdrawal queue for this request
        uint256 amountOfShares;
        /// @notice address that can claim or transfer this request
        address owner;
        /// @notice timestamp of when the request was created, in seconds
        uint256 timestamp;
        /// @notice true, if request is finalized
        bool isFinalized;
        /// @notice true, if request is claimed. Request is claimable if (isFinalized && !isClaimed)
        bool isClaimed;
    }

    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);
}

interface IBaseOracle {
    function SECONDS_PER_SLOT() external view returns (uint256);
    function GENESIS_TIME() external view returns (uint256);
    function getLastProcessingRefSlot() external view returns (uint256);
}

interface ISecondOpinionOracle {
    function getReport(uint256 refSlot)
        external
        view
        returns (
            bool success,
            uint256 clBalanceGwei,
            uint256 withdrawalVaultBalanceWei,
            uint256 totalDepositedValidators,
            uint256 totalExitedValidators
        );
}

interface IStakingRouter {
    struct StakingModuleSummary {
        /// @notice The total number of validators in the EXITED state on the Consensus Layer
        /// @dev This value can't decrease in normal conditions
        uint256 totalExitedValidators;

        /// @notice The total number of validators deposited via the official Deposit Contract
        /// @dev This value is a cumulative counter: even when the validator goes into EXITED state this
        ///     counter is not decreasing
        uint256 totalDepositedValidators;

        /// @notice The number of validators in the set available for deposit
        uint256 depositableValidatorsCount;
    }

    function getStakingModuleIds() external view returns (uint256[] memory stakingModuleIds);

    function getStakingModuleSummary(uint256 _stakingModuleId) external view
        returns (StakingModuleSummary memory summary);
}

/// @notice The set of restrictions used in the sanity checks of the oracle report
/// @dev struct is loaded from the storage and stored in memory during the tx running
struct LimitsList {
    /// @notice The max possible number of validators that might been reported as `appeared` or `exited`
    ///     during a single day
    /// NB: `appeared` means `pending` (maybe not `activated` yet), see further explanations
    //      in docs for the `setChurnValidatorsPerDayLimit` func below.
    /// @dev Must fit into uint16 (<= 65_535)
    uint256 churnValidatorsPerDayLimit;

    /// @notice The max annual increase of the total validators' balances on the Consensus Layer
    ///     since the previous oracle report
    /// @dev Represented in the Basis Points (100% == 10_000)
    uint256 annualBalanceIncreaseBPLimit;

    /// @notice The max deviation of the provided `simulatedShareRate`
    ///     and the actual one within the currently processing oracle report
    /// @dev Represented in the Basis Points (100% == 10_000)
    uint256 simulatedShareRateDeviationBPLimit;

    /// @notice The max number of exit requests allowed in report to ValidatorsExitBusOracle
    uint256 maxValidatorExitRequestsPerReport;

    /// @notice The max number of data list items reported to accounting oracle in extra data
    /// @dev Must fit into uint16 (<= 65_535)
    uint256 maxAccountingExtraDataListItemsCount;

    /// @notice The max number of node operators reported per extra data list item
    /// @dev Must fit into uint16 (<= 65_535)
    uint256 maxNodeOperatorsPerExtraDataItemCount;

    /// @notice The min time required to be passed from the creation of the request to be
    ///     finalized till the time of the oracle report
    uint256 requestTimestampMargin;

    /// @notice The positive token rebase allowed per single LidoOracle report
    /// @dev uses 1e9 precision, e.g.: 1e6 - 0.1%; 1e9 - 100%, see `setMaxPositiveTokenRebase()`
    uint256 maxPositiveTokenRebase;

    /// @notice Initial slashing amount per one validator to calculate initial slashing of the validators' balances on the Consensus Layer
    /// @dev Represented in the PWei (1^15 Wei). Must fit into uint16 (<= 65_535)
    uint256 initialSlashingAmountPWei;

    /// @notice Inactivity penalties amount per one validator to calculate penalties of the validators' balances on the Consensus Layer
    /// @dev Represented in the PWei (1^15 Wei). Must fit into uint16 (<= 65_535)
    uint256 inactivityPenaltiesAmountPWei;

    /// @notice The maximum percent on how Second Opinion Oracle reported value could be greater
    ///     than reported by the AccountingOracle. There is an assumption that second opinion oracle CL balance
    ///     can be greater as calculated for the withdrawal credentials.
    /// @dev Represented in the Basis Points (100% == 10_000)
    uint256 clBalanceOraclesErrorUpperBPLimit;
}

/// @dev The packed version of the LimitsList struct to be effectively persisted in storage
struct LimitsListPacked {
    uint16 churnValidatorsPerDayLimit;
    uint16 annualBalanceIncreaseBPLimit;
    uint16 simulatedShareRateDeviationBPLimit;
    uint16 maxValidatorExitRequestsPerReport;
    uint16 maxAccountingExtraDataListItemsCount;
    uint16 maxNodeOperatorsPerExtraDataItemCount;
    uint48 requestTimestampMargin;
    uint64 maxPositiveTokenRebase;
    uint16 initialSlashingAmountPWei;
    uint16 inactivityPenaltiesAmountPWei;
    uint16 clBalanceOraclesErrorUpperBPLimit;
}

struct ReportData {
    uint64 timestamp;
    uint64 totalExitedValidators;
    uint128 negativeCLRebaseWei;
}

uint256 constant MAX_BASIS_POINTS = 10_000;
uint256 constant SHARE_RATE_PRECISION_E27 = 1e27;
uint256 constant ONE_PWEI = 1e15;

/// @title Sanity checks for the Lido's oracle report
/// @notice The contracts contain view methods to perform sanity checks of the Lido's oracle report
///     and lever methods for granular tuning of the params of the checks
contract OracleReportSanityChecker is AccessControlEnumerable {
    using LimitsListPacker for LimitsList;
    using LimitsListUnpacker for LimitsListPacked;
    using PositiveTokenRebaseLimiter for TokenRebaseLimiterData;

    bytes32 public constant ALL_LIMITS_MANAGER_ROLE = keccak256("ALL_LIMITS_MANAGER_ROLE");
    bytes32 public constant CHURN_VALIDATORS_PER_DAY_LIMIT_MANAGER_ROLE =
        keccak256("CHURN_VALIDATORS_PER_DAY_LIMIT_MANAGER_ROLE");
    bytes32 public constant ANNUAL_BALANCE_INCREASE_LIMIT_MANAGER_ROLE =
        keccak256("ANNUAL_BALANCE_INCREASE_LIMIT_MANAGER_ROLE");
    bytes32 public constant SHARE_RATE_DEVIATION_LIMIT_MANAGER_ROLE =
        keccak256("SHARE_RATE_DEVIATION_LIMIT_MANAGER_ROLE");
    bytes32 public constant MAX_VALIDATOR_EXIT_REQUESTS_PER_REPORT_ROLE =
        keccak256("MAX_VALIDATOR_EXIT_REQUESTS_PER_REPORT_ROLE");
    bytes32 public constant MAX_ACCOUNTING_EXTRA_DATA_LIST_ITEMS_COUNT_ROLE =
        keccak256("MAX_ACCOUNTING_EXTRA_DATA_LIST_ITEMS_COUNT_ROLE");
    bytes32 public constant MAX_NODE_OPERATORS_PER_EXTRA_DATA_ITEM_COUNT_ROLE =
        keccak256("MAX_NODE_OPERATORS_PER_EXTRA_DATA_ITEM_COUNT_ROLE");
    bytes32 public constant REQUEST_TIMESTAMP_MARGIN_MANAGER_ROLE = keccak256("REQUEST_TIMESTAMP_MARGIN_MANAGER_ROLE");
    bytes32 public constant MAX_POSITIVE_TOKEN_REBASE_MANAGER_ROLE =
        keccak256("MAX_POSITIVE_TOKEN_REBASE_MANAGER_ROLE");
    bytes32 public constant SECOND_OPINION_MANAGER_ROLE =
        keccak256("SECOND_OPINION_MANAGER_ROLE");
    bytes32 public constant INITIAL_SLASHING_AND_PENALTIES_MANAGER_ROLE =
        keccak256("INITIAL_SLASHING_AND_PENALTIES_MANAGER_ROLE");

    uint256 private constant DEFAULT_TIME_ELAPSED = 1 hours;
    uint256 private constant DEFAULT_CL_BALANCE = 1 gwei;
    uint256 private constant SECONDS_PER_DAY = 24 * 60 * 60;

    ILidoLocator private immutable LIDO_LOCATOR;
    uint256 private immutable GENESIS_TIME;
    uint256 private immutable SECONDS_PER_SLOT;
    address private immutable LIDO_ADDRESS;

    LimitsListPacked private _limits;

    /// @dev Historical reports data
    ReportData[] public reportData;

    /// @dev The address of the second opinion oracle
    ISecondOpinionOracle public secondOpinionOracle;

    /// @param _lidoLocator address of the LidoLocator instance
    /// @param _admin address to grant DEFAULT_ADMIN_ROLE of the AccessControl contract
    /// @param _limitsList initial values to be set for the limits list
    constructor(
        address _lidoLocator,
        address _admin,
        LimitsList memory _limitsList
    ) {
        if (_admin == address(0)) revert AdminCannotBeZero();
        LIDO_LOCATOR = ILidoLocator(_lidoLocator);

        address accountingOracle = LIDO_LOCATOR.accountingOracle();
        GENESIS_TIME = IBaseOracle(accountingOracle).GENESIS_TIME();
        SECONDS_PER_SLOT = IBaseOracle(accountingOracle).SECONDS_PER_SLOT();
        LIDO_ADDRESS = LIDO_LOCATOR.lido();

        _updateLimits(_limitsList);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @notice Return number of report data elements available on the public reportData array.
    function getReportDataCount() external view returns (uint256) {
        return reportData.length;
    }

    /// @notice returns the address of the LidoLocator
    function getLidoLocator() public view returns (address) {
        return address(LIDO_LOCATOR);
    }

    /// @notice Returns the limits list for the Lido's oracle report sanity checks
    function getOracleReportLimits() public view returns (LimitsList memory) {
        return _limits.unpack();
    }

    /// @notice Returns max positive token rebase value with 1e9 precision:
    ///     e.g.: 1e6 - 0.1%; 1e9 - 100%
    ///     - zero value means uninitialized
    ///     - type(uint64).max means unlimited
    ///
    /// @dev Get max positive rebase allowed per single oracle report token rebase happens on total
    ///     supply adjustment, huge positive rebase can incur oracle report sandwiching.
    ///
    ///     stETH balance for the `account` defined as:
    ///         balanceOf(account) =
    ///             shares[account] * totalPooledEther / totalShares = shares[account] * shareRate
    ///
    ///     Suppose shareRate changes when oracle reports (see `handleOracleReport`)
    ///     which means that token rebase happens:
    ///
    ///         preShareRate = preTotalPooledEther() / preTotalShares()
    ///         postShareRate = postTotalPooledEther() / postTotalShares()
    ///         R = (postShareRate - preShareRate) / preShareRate
    ///
    ///         R > 0 corresponds to the relative positive rebase value (i.e., instant APR)
    ///
    /// NB: The value is not set by default (explicit initialization required),
    ///     the recommended sane values are from 0.05% to 0.1%.
    function getMaxPositiveTokenRebase() public view returns (uint256) {
        return _limits.maxPositiveTokenRebase;
    }

    /// @notice Sets the new values for the limits list and second opinion oracle
    /// @param _limitsList new limits list
    /// @param _secondOpinionOracle negative rebase oracle.
    function setOracleReportLimits(LimitsList calldata _limitsList, ISecondOpinionOracle _secondOpinionOracle) external onlyRole(ALL_LIMITS_MANAGER_ROLE) {
        _updateLimits(_limitsList);
        if (_secondOpinionOracle != secondOpinionOracle) {
            secondOpinionOracle = _secondOpinionOracle;
            emit SecondOpinionOracleChanged(_secondOpinionOracle);
        }
    }

    /// @notice Sets the new value for the churnValidatorsPerDayLimit
    ///     The limit is applicable for `appeared` and `exited` validators
    ///
    /// NB: AccountingOracle reports validators as `appeared` once them become `pending`
    ///     (might be not `activated` yet). Thus, this limit should be high enough for such cases
    ///     because Consensus Layer has no intrinsic churn limit for the amount of `pending` validators
    ///     (only for `activated` instead). For Lido it's limited by the max daily deposits via DepositSecurityModule
    ///
    ///     In contrast, `exited` are reported according to the Consensus Layer churn limit.
    ///
    /// @param _churnValidatorsPerDayLimit new churnValidatorsPerDayLimit value
    function setChurnValidatorsPerDayLimit(uint256 _churnValidatorsPerDayLimit)
        external
        onlyRole(CHURN_VALIDATORS_PER_DAY_LIMIT_MANAGER_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.churnValidatorsPerDayLimit = _churnValidatorsPerDayLimit;
        _updateLimits(limitsList);
    }

    /// @notice Sets the new value for the annualBalanceIncreaseBPLimit
    /// @param _annualBalanceIncreaseBPLimit new annualBalanceIncreaseBPLimit value
    function setAnnualBalanceIncreaseBPLimit(uint256 _annualBalanceIncreaseBPLimit)
        external
        onlyRole(ANNUAL_BALANCE_INCREASE_LIMIT_MANAGER_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.annualBalanceIncreaseBPLimit = _annualBalanceIncreaseBPLimit;
        _updateLimits(limitsList);
    }

    /// @notice Sets the new value for the simulatedShareRateDeviationBPLimit
    /// @param _simulatedShareRateDeviationBPLimit new simulatedShareRateDeviationBPLimit value
    function setSimulatedShareRateDeviationBPLimit(uint256 _simulatedShareRateDeviationBPLimit)
        external
        onlyRole(SHARE_RATE_DEVIATION_LIMIT_MANAGER_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.simulatedShareRateDeviationBPLimit = _simulatedShareRateDeviationBPLimit;
        _updateLimits(limitsList);
    }

    /// @notice Sets the new value for the maxValidatorExitRequestsPerReport
    /// @param _maxValidatorExitRequestsPerReport new maxValidatorExitRequestsPerReport value
    function setMaxExitRequestsPerOracleReport(uint256 _maxValidatorExitRequestsPerReport)
        external
        onlyRole(MAX_VALIDATOR_EXIT_REQUESTS_PER_REPORT_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.maxValidatorExitRequestsPerReport = _maxValidatorExitRequestsPerReport;
        _updateLimits(limitsList);
    }

    /// @notice Sets the new value for the requestTimestampMargin
    /// @param _requestTimestampMargin new requestTimestampMargin value
    function setRequestTimestampMargin(uint256 _requestTimestampMargin)
        external
        onlyRole(REQUEST_TIMESTAMP_MARGIN_MANAGER_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.requestTimestampMargin = _requestTimestampMargin;
        _updateLimits(limitsList);
    }

    /// @notice Set max positive token rebase allowed per single oracle report token rebase happens
    ///     on total supply adjustment, huge positive rebase can incur oracle report sandwiching.
    ///
    /// @param _maxPositiveTokenRebase max positive token rebase value with 1e9 precision:
    ///     e.g.: 1e6 - 0.1%; 1e9 - 100%
    ///     - passing zero value is prohibited
    ///     - to allow unlimited rebases, pass max uint64, i.e.: type(uint64).max
    function setMaxPositiveTokenRebase(uint256 _maxPositiveTokenRebase)
        external
        onlyRole(MAX_POSITIVE_TOKEN_REBASE_MANAGER_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.maxPositiveTokenRebase = _maxPositiveTokenRebase;
        _updateLimits(limitsList);
    }

    /// @notice Sets the new value for the maxAccountingExtraDataListItemsCount
    /// @param _maxAccountingExtraDataListItemsCount new maxAccountingExtraDataListItemsCount value
    function setMaxAccountingExtraDataListItemsCount(uint256 _maxAccountingExtraDataListItemsCount)
        external
        onlyRole(MAX_ACCOUNTING_EXTRA_DATA_LIST_ITEMS_COUNT_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.maxAccountingExtraDataListItemsCount = _maxAccountingExtraDataListItemsCount;
        _updateLimits(limitsList);
    }

    /// @notice Sets the new value for the max maxNodeOperatorsPerExtraDataItemCount
    /// @param _maxNodeOperatorsPerExtraDataItemCount new maxNodeOperatorsPerExtraDataItemCount value
    function setMaxNodeOperatorsPerExtraDataItemCount(uint256 _maxNodeOperatorsPerExtraDataItemCount)
        external
        onlyRole(MAX_NODE_OPERATORS_PER_EXTRA_DATA_ITEM_COUNT_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.maxNodeOperatorsPerExtraDataItemCount = _maxNodeOperatorsPerExtraDataItemCount;
        _updateLimits(limitsList);
    }

    /// @notice Sets the address of the second opinion oracle and clBalanceOraclesErrorUpperBPLimit value
    /// @param _secondOpinionOracle second opinion oracle.
    ///     If it's zero address — oracle is disabled.
    ///     Default value is zero address.
    /// @param _clBalanceOraclesErrorUpperBPLimit new clBalanceOraclesErrorUpperBPLimit value
    function setSecondOpinionOracleAndCLBalanceUpperMargin(ISecondOpinionOracle _secondOpinionOracle, uint256 _clBalanceOraclesErrorUpperBPLimit)
        external
        onlyRole(SECOND_OPINION_MANAGER_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.clBalanceOraclesErrorUpperBPLimit = _clBalanceOraclesErrorUpperBPLimit;
        _updateLimits(limitsList);
        if (_secondOpinionOracle != secondOpinionOracle) {
            secondOpinionOracle = ISecondOpinionOracle(_secondOpinionOracle);
            emit SecondOpinionOracleChanged(_secondOpinionOracle);
        }
    }

    /// @notice Sets the initial slashing and penalties Amountficients
    /// @param _initialSlashingAmountPWei - initial slashing Amountficient (in PWei)
    /// @param _inactivityPenaltiesAmountPWei - penalties Amountficient (in PWei)
    function setInitialSlashingAndPenaltiesAmount(uint256 _initialSlashingAmountPWei, uint256 _inactivityPenaltiesAmountPWei)
        external
        onlyRole(INITIAL_SLASHING_AND_PENALTIES_MANAGER_ROLE)
    {
        LimitsList memory limitsList = _limits.unpack();
        limitsList.initialSlashingAmountPWei = _initialSlashingAmountPWei;
        limitsList.inactivityPenaltiesAmountPWei = _inactivityPenaltiesAmountPWei;
        _updateLimits(limitsList);
    }

    /// @notice Returns the allowed ETH amount that might be taken from the withdrawal vault and EL
    ///     rewards vault during Lido's oracle report processing
    /// @param _preTotalPooledEther total amount of ETH controlled by the protocol
    /// @param _preTotalShares total amount of minted stETH shares
    /// @param _preCLBalance sum of all Lido validators' balances on the Consensus Layer before the
    ///     current oracle report
    /// @param _postCLBalance sum of all Lido validators' balances on the Consensus Layer after the
    ///     current oracle report
    /// @param _withdrawalVaultBalance withdrawal vault balance on Execution Layer for the report calculation moment
    /// @param _elRewardsVaultBalance elRewards vault balance on Execution Layer for the report calculation moment
    /// @param _sharesRequestedToBurn shares requested to burn through Burner for the report calculation moment
    /// @param _etherToLockForWithdrawals ether to lock on withdrawals queue contract
    /// @param _newSharesToBurnForWithdrawals new shares to burn due to withdrawal request finalization
    /// @return withdrawals ETH amount allowed to be taken from the withdrawals vault
    /// @return elRewards ETH amount allowed to be taken from the EL rewards vault
    /// @return simulatedSharesToBurn simulated amount to be burnt (if no ether locked on withdrawals)
    /// @return sharesToBurn amount to be burnt (accounting for withdrawals finalization)
    function smoothenTokenRebase(
        uint256 _preTotalPooledEther,
        uint256 _preTotalShares,
        uint256 _preCLBalance,
        uint256 _postCLBalance,
        uint256 _withdrawalVaultBalance,
        uint256 _elRewardsVaultBalance,
        uint256 _sharesRequestedToBurn,
        uint256 _etherToLockForWithdrawals,
        uint256 _newSharesToBurnForWithdrawals
    ) external view returns (
        uint256 withdrawals,
        uint256 elRewards,
        uint256 simulatedSharesToBurn,
        uint256 sharesToBurn
    ) {
        TokenRebaseLimiterData memory tokenRebaseLimiter = PositiveTokenRebaseLimiter.initLimiterState(
            getMaxPositiveTokenRebase(),
            _preTotalPooledEther,
            _preTotalShares
        );

        if (_postCLBalance < _preCLBalance) {
            tokenRebaseLimiter.decreaseEther(_preCLBalance - _postCLBalance);
        } else {
            tokenRebaseLimiter.increaseEther(_postCLBalance - _preCLBalance);
        }

        withdrawals = tokenRebaseLimiter.increaseEther(_withdrawalVaultBalance);
        elRewards = tokenRebaseLimiter.increaseEther(_elRewardsVaultBalance);

        // determining the shares to burn limit that would have been
        // if no withdrawals finalized during the report
        // it's used to check later the provided `simulatedShareRate` value
        // after the off-chain calculation via `eth_call` of `Lido.handleOracleReport()`
        // see also step 9 of the `Lido._handleOracleReport()`
        simulatedSharesToBurn = Math256.min(tokenRebaseLimiter.getSharesToBurnLimit(), _sharesRequestedToBurn);

        // remove ether to lock for withdrawals from total pooled ether
        tokenRebaseLimiter.decreaseEther(_etherToLockForWithdrawals);
        // re-evaluate shares to burn after TVL was updated due to withdrawals finalization
        sharesToBurn = Math256.min(
            tokenRebaseLimiter.getSharesToBurnLimit(),
            _newSharesToBurnForWithdrawals + _sharesRequestedToBurn
        );
    }

    /// @notice Applies sanity checks to the accounting params of Lido's oracle report
    /// WARNING. The function has side effects and modifies the state of the contract.
    ///          It's needed to keep information about exited validators counts and negative rebase values over time.
    ///          The function called from Lido contract that uses the 'old' Solidity version (0.4.24) and will do a correct
    ///          call to this method even it's declared as "view" in interface there.
    /// @param _timeElapsed time elapsed since the previous oracle report
    /// @param _preCLBalance sum of all Lido validators' balances on the Consensus Layer before the
    ///     current oracle report (NB: also include the initial balance of newly appeared validators)
    /// @param _postCLBalance sum of all Lido validators' balances on the Consensus Layer after the
    ///     current oracle report
    /// @param _withdrawalVaultBalance withdrawal vault balance on Execution Layer for the report reference slot
    /// @param _elRewardsVaultBalance el rewards vault balance on Execution Layer for the report reference slot
    /// @param _sharesRequestedToBurn shares requested to burn for the report reference slot
    /// @param _preCLValidators Lido-participating validators on the CL side before the current oracle report
    /// @param _postCLValidators Lido-participating validators on the CL side after the current oracle report
    function checkAccountingOracleReport(
        uint256 _timeElapsed,
        uint256 _preCLBalance,
        uint256 _postCLBalance,
        uint256 _withdrawalVaultBalance,
        uint256 _elRewardsVaultBalance,
        uint256 _sharesRequestedToBurn,
        uint256 _preCLValidators,
        uint256 _postCLValidators
    ) external {
        if (msg.sender != LIDO_ADDRESS) {
            revert CalledNotFromLido();
        }
        LimitsList memory limitsList = _limits.unpack();
        uint256 refSlot = IBaseOracle(LIDO_LOCATOR.accountingOracle()).getLastProcessingRefSlot();

        address withdrawalVault = LIDO_LOCATOR.withdrawalVault();
        // 1. Withdrawals vault reported balance
        _checkWithdrawalVaultBalance(withdrawalVault.balance, _withdrawalVaultBalance);

        address elRewardsVault = LIDO_LOCATOR.elRewardsVault();
        // 2. EL rewards vault reported balance
        _checkELRewardsVaultBalance(elRewardsVault.balance, _elRewardsVaultBalance);

        // 3. Burn requests
        _checkSharesRequestedToBurn(_sharesRequestedToBurn);

        // 4. Consensus Layer balance decrease
        _checkCLBalanceDecrease(limitsList, _preCLBalance,
            _postCLBalance, _withdrawalVaultBalance, _postCLValidators, refSlot);

        // 5. Consensus Layer annual balances increase
        _checkAnnualBalancesIncrease(limitsList, _preCLBalance, _postCLBalance, _timeElapsed);

        // 6. Appeared validators increase
        if (_postCLValidators > _preCLValidators) {
            _checkAppearedValidatorsChurnLimit(limitsList, (_postCLValidators - _preCLValidators), _timeElapsed);
        }
    }

    /// @notice Applies sanity checks to the number of validator exit requests supplied to ValidatorExitBusOracle
    /// @param _exitRequestsCount Number of validator exit requests supplied per oracle report
    function checkExitBusOracleReport(uint256 _exitRequestsCount)
        external
        view
    {
        uint256 limit = _limits.unpack().maxValidatorExitRequestsPerReport;
        if (_exitRequestsCount > limit) {
            revert IncorrectNumberOfExitRequestsPerReport(limit);
        }
    }

    /// @notice Check rate of exited validators per day
    /// @param _exitedValidatorsCount Number of validator exited per oracle report
    function checkExitedValidatorsRatePerDay(uint256 _exitedValidatorsCount)
        external
        view
    {
        uint256 limit = _limits.unpack().churnValidatorsPerDayLimit;
        if (_exitedValidatorsCount > limit) {
            revert ExitedValidatorsLimitExceeded(limit, _exitedValidatorsCount);
        }
    }

    /// @notice Check number of node operators reported per extra data item in accounting oracle
    /// @param _itemIndex Index of item in extra data
    /// @param _nodeOperatorsCount Number of validator exit requests supplied per oracle report
    /// @dev Checks against the same limit as used in checkAccountingExtraDataListItemsCount
    function checkNodeOperatorsPerExtraDataItemCount(uint256 _itemIndex, uint256 _nodeOperatorsCount)
        external
        view
    {
        uint256 limit = _limits.unpack().maxNodeOperatorsPerExtraDataItemCount;
        if (_nodeOperatorsCount > limit) {
            revert TooManyNodeOpsPerExtraDataItem(_itemIndex, _nodeOperatorsCount);
        }
    }

    /// @notice Check max accounting extra data list items count
    /// @param _extraDataListItemsCount Accounting extra data list items count
    function checkAccountingExtraDataListItemsCount(uint256 _extraDataListItemsCount)
        external
        view
    {
        uint256 limit = _limits.unpack().maxAccountingExtraDataListItemsCount;
        if (_extraDataListItemsCount > limit) {
            revert MaxAccountingExtraDataItemsCountExceeded(limit, _extraDataListItemsCount);
        }
    }

    /// @notice Applies sanity checks to the withdrawal requests finalization
    /// @param _lastFinalizableRequestId last finalizable withdrawal request id
    /// @param _reportTimestamp timestamp when the originated oracle report was submitted
    function checkWithdrawalQueueOracleReport(
        uint256 _lastFinalizableRequestId,
        uint256 _reportTimestamp
    )
        external
        view
    {
        LimitsList memory limitsList = _limits.unpack();
        address withdrawalQueue = LIDO_LOCATOR.withdrawalQueue();

        _checkLastFinalizableId(limitsList, withdrawalQueue, _lastFinalizableRequestId, _reportTimestamp);
    }

    /// @notice Applies sanity checks to the simulated share rate for withdrawal requests finalization
    /// @param _postTotalPooledEther total pooled ether after report applied
    /// @param _postTotalShares total shares after report applied
    /// @param _etherLockedOnWithdrawalQueue ether locked on withdrawal queue for the current oracle report
    /// @param _sharesBurntDueToWithdrawals shares burnt due to withdrawals finalization
    /// @param _simulatedShareRate share rate provided with the oracle report (simulated via off-chain "eth_call")
    function checkSimulatedShareRate(
        uint256 _postTotalPooledEther,
        uint256 _postTotalShares,
        uint256 _etherLockedOnWithdrawalQueue,
        uint256 _sharesBurntDueToWithdrawals,
        uint256 _simulatedShareRate
    ) external view {
        LimitsList memory limitsList = _limits.unpack();

        // Pretending that withdrawals were not processed
        // virtually return locked ether back to `_postTotalPooledEther`
        // virtually return burnt just finalized withdrawals shares back to `_postTotalShares`
        _checkSimulatedShareRate(
            limitsList,
            _postTotalPooledEther + _etherLockedOnWithdrawalQueue,
            _postTotalShares + _sharesBurntDueToWithdrawals,
            _simulatedShareRate
        );
    }

    function _checkWithdrawalVaultBalance(
        uint256 _actualWithdrawalVaultBalance,
        uint256 _reportedWithdrawalVaultBalance
    ) internal pure {
        if (_reportedWithdrawalVaultBalance > _actualWithdrawalVaultBalance) {
            revert IncorrectWithdrawalsVaultBalance(_actualWithdrawalVaultBalance);
        }
    }

    function _checkELRewardsVaultBalance(
        uint256 _actualELRewardsVaultBalance,
        uint256 _reportedELRewardsVaultBalance
    ) internal pure {
        if (_reportedELRewardsVaultBalance > _actualELRewardsVaultBalance) {
            revert IncorrectELRewardsVaultBalance(_actualELRewardsVaultBalance);
        }
    }

    function _checkSharesRequestedToBurn(uint256 _sharesRequestedToBurn) internal view {
        (uint256 coverShares, uint256 nonCoverShares) = IBurner(LIDO_LOCATOR.burner()).getSharesRequestedToBurn();
        uint256 actualSharesToBurn = coverShares + nonCoverShares;
        if (_sharesRequestedToBurn > actualSharesToBurn) {
            revert IncorrectSharesRequestedToBurn(actualSharesToBurn);
        }
    }

    function _addReportData(uint256 _timestamp, uint256 _exitedValidatorsCount, uint256 _negativeCLRebase) internal {
        reportData.push(ReportData(
            SafeCast.toUint64(_timestamp),
            SafeCast.toUint64(_exitedValidatorsCount),
            SafeCast.toUint128(_negativeCLRebase)
        ));
    }

    function _sumNegativeRebasesNotOlderThan(uint256 _timestamp) internal view returns (uint256) {
        uint256 sum;
        for (int256 index = int256(reportData.length) - 1; index >= 0; index--) {
            if (reportData[uint256(index)].timestamp > SafeCast.toUint64(_timestamp)) {
                sum += reportData[uint256(index)].negativeCLRebaseWei;
            } else {
                break;
            }
        }
        return sum;
    }

    function _exitedValidatorsAtTimestamp(uint256 _timestamp) internal view returns (uint256) {
        for (int256 index = int256(reportData.length) - 1; index >= 0; index--) {
            if (reportData[uint256(index)].timestamp <= SafeCast.toUint64(_timestamp)) {
                return reportData[uint256(index)].totalExitedValidators;
            }
        }
        return 0;
    }

    function _checkCLBalanceDecrease(
        LimitsList memory _limitsList,
        uint256 _preCLBalance,
        uint256 _postCLBalance,
        uint256 _withdrawalVaultBalance,
        uint256 _postCLValidators,
        uint256 _refSlot
    ) internal {
        uint256 reportTimestamp = GENESIS_TIME + _refSlot * SECONDS_PER_SLOT;

        // Checking exitedValidators against StakingRouter
        IStakingRouter stakingRouter = IStakingRouter(LIDO_LOCATOR.stakingRouter());
        uint256[] memory ids = stakingRouter.getStakingModuleIds();

        uint256 stakingRouterExitedValidators;
        for (uint256 i = 0; i < ids.length; i++) {
            IStakingRouter.StakingModuleSummary memory summary = stakingRouter.getStakingModuleSummary(ids[i]);
            stakingRouterExitedValidators += summary.totalExitedValidators;
        }

        if (_preCLBalance <= _postCLBalance + _withdrawalVaultBalance) {
            _addReportData(reportTimestamp, stakingRouterExitedValidators, 0);
            // If the CL balance is not decreased, we don't need to check anyting here
            return;
        }
        _addReportData(reportTimestamp, stakingRouterExitedValidators, _preCLBalance - (_postCLBalance + _withdrawalVaultBalance));

        uint256 negativeCLRebaseSum = _sumNegativeRebasesNotOlderThan(reportTimestamp - 18 days);
        uint256 maxAllowedCLRebaseNegativeSum =
            _limits.initialSlashingAmountPWei * ONE_PWEI * (_postCLValidators - _exitedValidatorsAtTimestamp(reportTimestamp - 18 days)) +
            _limits.inactivityPenaltiesAmountPWei * ONE_PWEI * (_postCLValidators - _exitedValidatorsAtTimestamp(reportTimestamp - 54 days));

        if (negativeCLRebaseSum <= maxAllowedCLRebaseNegativeSum) {
            // If the rebase diff is less or equal max allowed sum, we accept the report
            emit NegativeCLRebaseAccepted(_refSlot, _postCLBalance + _withdrawalVaultBalance, negativeCLRebaseSum, maxAllowedCLRebaseNegativeSum);
            return;
        }

        // If there is no negative rebase oracle, then we don't need to check it's report
        if (address(secondOpinionOracle) == address(0)) {
            // If there is no oracle and the diff is more than limit, we revert
            revert IncorrectCLBalanceDecrease(negativeCLRebaseSum, maxAllowedCLRebaseNegativeSum);
        }
        _askSecondOpinion(_refSlot, _postCLBalance, _withdrawalVaultBalance, _limitsList);
    }

    function _askSecondOpinion(uint256 _refSlot, uint256 _postCLBalance, uint256 _withdrawalVaultBalance, LimitsList memory _limitsList) internal {
        (bool success, uint256 clOracleBalanceGwei, uint256 oracleWithdrawalVaultBalanceWei,,) = secondOpinionOracle.getReport(_refSlot);

        if (success) {
            uint256 clBalanceWei = clOracleBalanceGwei * 1 gwei;
            if (clBalanceWei < _postCLBalance) {
                revert NegativeRebaseFailedCLBalanceMismatch(_postCLBalance, clBalanceWei, _limitsList.clBalanceOraclesErrorUpperBPLimit);
            }
            if (MAX_BASIS_POINTS * (clBalanceWei - _postCLBalance) >
                _limitsList.clBalanceOraclesErrorUpperBPLimit * clBalanceWei) {
                revert NegativeRebaseFailedCLBalanceMismatch(_postCLBalance, clBalanceWei, _limitsList.clBalanceOraclesErrorUpperBPLimit);
            }
            if (oracleWithdrawalVaultBalanceWei != _withdrawalVaultBalance) {
                revert NegativeRebaseFailedWithdrawalVaultBalanceMismatch(_withdrawalVaultBalance, oracleWithdrawalVaultBalanceWei);
            }
            emit NegativeCLRebaseConfirmed(_refSlot, _postCLBalance, _withdrawalVaultBalance);
        } else {
            revert NegativeRebaseFailedSecondOpinionReportIsNotReady();
        }
    }

    function _checkAnnualBalancesIncrease(
        LimitsList memory _limitsList,
        uint256 _preCLBalance,
        uint256 _postCLBalance,
        uint256 _timeElapsed
    ) internal pure {
        // allow zero values for scratch deploy
        // NB: annual increase have to be large enough for scratch deploy
        if (_preCLBalance == 0) {
            _preCLBalance = DEFAULT_CL_BALANCE;
        }

        if (_preCLBalance >= _postCLBalance) return;

        if (_timeElapsed == 0) {
            _timeElapsed = DEFAULT_TIME_ELAPSED;
        }

        uint256 balanceIncrease = _postCLBalance - _preCLBalance;
        uint256 annualBalanceIncrease = ((365 days * MAX_BASIS_POINTS * balanceIncrease) /
            _preCLBalance) /
            _timeElapsed;

        if (annualBalanceIncrease > _limitsList.annualBalanceIncreaseBPLimit) {
            revert IncorrectCLBalanceIncrease(annualBalanceIncrease);
        }
    }

    function _checkAppearedValidatorsChurnLimit(
        LimitsList memory _limitsList,
        uint256 _appearedValidators,
        uint256 _timeElapsed
    ) internal pure {
        if (_timeElapsed == 0) {
            _timeElapsed = DEFAULT_TIME_ELAPSED;
        }

        uint256 churnLimit = (_limitsList.churnValidatorsPerDayLimit * _timeElapsed) / SECONDS_PER_DAY;

        if (_appearedValidators > churnLimit) revert IncorrectAppearedValidators(_appearedValidators);
    }

    function _checkLastFinalizableId(
        LimitsList memory _limitsList,
        address _withdrawalQueue,
        uint256 _lastFinalizableId,
        uint256 _reportTimestamp
    ) internal view {
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = _lastFinalizableId;

        IWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = IWithdrawalQueue(_withdrawalQueue)
            .getWithdrawalStatus(requestIds);
        if (_reportTimestamp < statuses[0].timestamp + _limitsList.requestTimestampMargin)
            revert IncorrectRequestFinalization(statuses[0].timestamp);
    }

    function _checkSimulatedShareRate(
        LimitsList memory _limitsList,
        uint256 _noWithdrawalsPostTotalPooledEther,
        uint256 _noWithdrawalsPostTotalShares,
        uint256 _simulatedShareRate
    ) internal pure {
        uint256 actualShareRate = (
            _noWithdrawalsPostTotalPooledEther * SHARE_RATE_PRECISION_E27
        ) / _noWithdrawalsPostTotalShares;

        if (actualShareRate == 0) {
            // can't finalize anything if the actual share rate is zero
            revert ActualShareRateIsZero();
        }

        // the simulated share rate can be either higher or lower than the actual one
        // in case of new user-submitted ether & minted `stETH` between the oracle reference slot
        // and the actual report delivery slot
        //
        // it happens because the oracle daemon snapshots rewards or losses at the reference slot,
        // and then calculates simulated share rate, but if new ether was submitted together with minting new `stETH`
        // after the reference slot passed, the oracle daemon still submits the same amount of rewards or losses,
        // which now is applicable to more 'shareholders', lowering the impact per a single share
        // (i.e, changing the actual share rate)
        //
        // simulated share rate ≤ actual share rate can be for a negative token rebase
        // simulated share rate ≥ actual share rate can be for a positive token rebase
        //
        // Given that:
        // 1) CL one-off balance decrease ≤ token rebase ≤ max positive token rebase
        // 2) user-submitted ether & minted `stETH` don't exceed the current staking rate limit
        // (see Lido.getCurrentStakeLimit())
        //
        // can conclude that `simulatedShareRateDeviationBPLimit` (L) should be set as follows:
        // L = (2 * SRL) * max(CLD, MPR),
        // where:
        // - CLD is consensus layer one-off balance decrease (as BP),
        // - MPR is max positive token rebase (as BP),
        // - SRL is staking rate limit normalized by TVL (`maxStakeLimit / totalPooledEther`)
        //   totalPooledEther should be chosen as a reasonable lower bound of the protocol TVL
        //
        uint256 simulatedShareDiff = Math256.absDiff(actualShareRate, _simulatedShareRate);
        uint256 simulatedShareDeviation = (MAX_BASIS_POINTS * simulatedShareDiff) / actualShareRate;

        if (simulatedShareDeviation > _limitsList.simulatedShareRateDeviationBPLimit) {
            revert IncorrectSimulatedShareRate(_simulatedShareRate, actualShareRate);
        }
    }

    function _updateLimits(LimitsList memory _newLimitsList) internal {
        LimitsList memory _oldLimitsList = _limits.unpack();
        if (_oldLimitsList.churnValidatorsPerDayLimit != _newLimitsList.churnValidatorsPerDayLimit) {
            _checkLimitValue(_newLimitsList.churnValidatorsPerDayLimit, 0, type(uint16).max);
            emit ChurnValidatorsPerDayLimitSet(_newLimitsList.churnValidatorsPerDayLimit);
        }
        if (_oldLimitsList.annualBalanceIncreaseBPLimit != _newLimitsList.annualBalanceIncreaseBPLimit) {
            _checkLimitValue(_newLimitsList.annualBalanceIncreaseBPLimit, 0, MAX_BASIS_POINTS);
            emit AnnualBalanceIncreaseBPLimitSet(_newLimitsList.annualBalanceIncreaseBPLimit);
        }
        if (_oldLimitsList.simulatedShareRateDeviationBPLimit != _newLimitsList.simulatedShareRateDeviationBPLimit) {
            _checkLimitValue(_newLimitsList.simulatedShareRateDeviationBPLimit, 0, MAX_BASIS_POINTS);
            emit SimulatedShareRateDeviationBPLimitSet(_newLimitsList.simulatedShareRateDeviationBPLimit);
        }
        if (_oldLimitsList.maxValidatorExitRequestsPerReport != _newLimitsList.maxValidatorExitRequestsPerReport) {
            _checkLimitValue(_newLimitsList.maxValidatorExitRequestsPerReport, 0, type(uint16).max);
            emit MaxValidatorExitRequestsPerReportSet(_newLimitsList.maxValidatorExitRequestsPerReport);
        }
        if (_oldLimitsList.maxAccountingExtraDataListItemsCount != _newLimitsList.maxAccountingExtraDataListItemsCount) {
            _checkLimitValue(_newLimitsList.maxAccountingExtraDataListItemsCount, 0, type(uint16).max);
            emit MaxAccountingExtraDataListItemsCountSet(_newLimitsList.maxAccountingExtraDataListItemsCount);
        }
        if (_oldLimitsList.maxNodeOperatorsPerExtraDataItemCount != _newLimitsList.maxNodeOperatorsPerExtraDataItemCount) {
            _checkLimitValue(_newLimitsList.maxNodeOperatorsPerExtraDataItemCount, 0, type(uint16).max);
            emit MaxNodeOperatorsPerExtraDataItemCountSet(_newLimitsList.maxNodeOperatorsPerExtraDataItemCount);
        }
        if (_oldLimitsList.requestTimestampMargin != _newLimitsList.requestTimestampMargin) {
            _checkLimitValue(_newLimitsList.requestTimestampMargin, 0, type(uint48).max);
            emit RequestTimestampMarginSet(_newLimitsList.requestTimestampMargin);
        }
        if (_oldLimitsList.maxPositiveTokenRebase != _newLimitsList.maxPositiveTokenRebase) {
            _checkLimitValue(_newLimitsList.maxPositiveTokenRebase, 1, type(uint64).max);
            emit MaxPositiveTokenRebaseSet(_newLimitsList.maxPositiveTokenRebase);
        }
        if (_oldLimitsList.initialSlashingAmountPWei != _newLimitsList.initialSlashingAmountPWei) {
            _checkLimitValue(_newLimitsList.initialSlashingAmountPWei, 0, type(uint16).max);
            emit InitialSlashingAmountSet(_newLimitsList.initialSlashingAmountPWei);
        }
        if (_oldLimitsList.inactivityPenaltiesAmountPWei != _newLimitsList.inactivityPenaltiesAmountPWei) {
            _checkLimitValue(_newLimitsList.inactivityPenaltiesAmountPWei, 0, type(uint16).max);
            emit InactivityPenaltiesAmountSet(_newLimitsList.inactivityPenaltiesAmountPWei);
        }
        if (_oldLimitsList.clBalanceOraclesErrorUpperBPLimit != _newLimitsList.clBalanceOraclesErrorUpperBPLimit) {
            _checkLimitValue(_newLimitsList.clBalanceOraclesErrorUpperBPLimit, 0, MAX_BASIS_POINTS);
            emit CLBalanceOraclesErrorUpperBPLimitSet(_newLimitsList.clBalanceOraclesErrorUpperBPLimit);
        }
        _limits = _newLimitsList.pack();
    }

    function _checkLimitValue(uint256 _value, uint256 _minAllowedValue, uint256 _maxAllowedValue) internal pure {
        if (_value > _maxAllowedValue || _value < _minAllowedValue) {
            revert IncorrectLimitValue(_value, _minAllowedValue, _maxAllowedValue);
        }
    }

    event ChurnValidatorsPerDayLimitSet(uint256 churnValidatorsPerDayLimit);
    event SecondOpinionOracleChanged(ISecondOpinionOracle indexed secondOpinionOracle);
    event AnnualBalanceIncreaseBPLimitSet(uint256 annualBalanceIncreaseBPLimit);
    event SimulatedShareRateDeviationBPLimitSet(uint256 simulatedShareRateDeviationBPLimit);
    event MaxPositiveTokenRebaseSet(uint256 maxPositiveTokenRebase);
    event MaxValidatorExitRequestsPerReportSet(uint256 maxValidatorExitRequestsPerReport);
    event MaxAccountingExtraDataListItemsCountSet(uint256 maxAccountingExtraDataListItemsCount);
    event MaxNodeOperatorsPerExtraDataItemCountSet(uint256 maxNodeOperatorsPerExtraDataItemCount);
    event RequestTimestampMarginSet(uint256 requestTimestampMargin);
    event InitialSlashingAmountSet(uint256 initialSlashingAmountPWei);
    event InactivityPenaltiesAmountSet(uint256 inactivityPenaltiesAmountPWei);
    event CLBalanceOraclesErrorUpperBPLimitSet(uint256 clBalanceOraclesErrorUpperBPLimit);
    event NegativeCLRebaseConfirmed(uint256 refSlot, uint256 clBalanceWei, uint256 withdrawalVaultBalance);
    event NegativeCLRebaseAccepted(uint256 refSlot, uint256 clBalance, uint256 clBalanceDecrease, uint256 clBalanceMaxDecrease);

    error IncorrectLimitValue(uint256 value, uint256 minAllowedValue, uint256 maxAllowedValue);
    error IncorrectWithdrawalsVaultBalance(uint256 actualWithdrawalVaultBalance);
    error IncorrectELRewardsVaultBalance(uint256 actualELRewardsVaultBalance);
    error IncorrectSharesRequestedToBurn(uint256 actualSharesToBurn);
    error IncorrectCLBalanceIncrease(uint256 annualBalanceDiff);
    error IncorrectAppearedValidators(uint256 churnLimit);
    error IncorrectNumberOfExitRequestsPerReport(uint256 maxRequestsCount);
    error IncorrectExitedValidators(uint256 churnLimit);
    error IncorrectRequestFinalization(uint256 requestCreationBlock);
    error ActualShareRateIsZero();
    error IncorrectSimulatedShareRate(uint256 simulatedShareRate, uint256 actualShareRate);
    error MaxAccountingExtraDataItemsCountExceeded(uint256 maxItemsCount, uint256 receivedItemsCount);
    error ExitedValidatorsLimitExceeded(uint256 limitPerDay, uint256 exitedPerDay);
    error TooManyNodeOpsPerExtraDataItem(uint256 itemIndex, uint256 nodeOpsCount);
    error AdminCannotBeZero();

    error IncorrectCLBalanceDecrease(uint256 negativeCLRebaseSum, uint256 maxNegativeCLRebaseSum);
    error NegativeRebaseFailedCLBalanceMismatch(uint256 reportedValue, uint256 provedValue, uint256 limitBP);
    error NegativeRebaseFailedWithdrawalVaultBalanceMismatch(uint256 reportedValue, uint256 provedValue);
    error NegativeRebaseFailedSecondOpinionReportIsNotReady();
    error CalledNotFromLido();
}

library LimitsListPacker {
    function pack(LimitsList memory _limitsList) internal pure returns (LimitsListPacked memory res) {
        res.churnValidatorsPerDayLimit = SafeCast.toUint16(_limitsList.churnValidatorsPerDayLimit);
        res.annualBalanceIncreaseBPLimit = _toBasisPoints(_limitsList.annualBalanceIncreaseBPLimit);
        res.simulatedShareRateDeviationBPLimit = _toBasisPoints(_limitsList.simulatedShareRateDeviationBPLimit);
        res.requestTimestampMargin = SafeCastExt.toUint48(_limitsList.requestTimestampMargin);
        res.maxPositiveTokenRebase = SafeCast.toUint64(_limitsList.maxPositiveTokenRebase);
        res.maxValidatorExitRequestsPerReport = SafeCast.toUint16(_limitsList.maxValidatorExitRequestsPerReport);
        res.maxAccountingExtraDataListItemsCount = SafeCast.toUint16(_limitsList.maxAccountingExtraDataListItemsCount);
        res.maxNodeOperatorsPerExtraDataItemCount = SafeCast.toUint16(_limitsList.maxNodeOperatorsPerExtraDataItemCount);
        res.initialSlashingAmountPWei = SafeCast.toUint16(_limitsList.initialSlashingAmountPWei);
        res.inactivityPenaltiesAmountPWei = SafeCast.toUint16(_limitsList.inactivityPenaltiesAmountPWei);
        res.clBalanceOraclesErrorUpperBPLimit = _toBasisPoints(_limitsList.clBalanceOraclesErrorUpperBPLimit);
    }

    function _toBasisPoints(uint256 _value) private pure returns (uint16) {
        require(_value <= MAX_BASIS_POINTS, "BASIS_POINTS_OVERFLOW");
        return uint16(_value);
    }
}

library LimitsListUnpacker {
    function unpack(LimitsListPacked memory _limitsList) internal pure returns (LimitsList memory res) {
        res.churnValidatorsPerDayLimit = _limitsList.churnValidatorsPerDayLimit;
        res.annualBalanceIncreaseBPLimit = _limitsList.annualBalanceIncreaseBPLimit;
        res.simulatedShareRateDeviationBPLimit = _limitsList.simulatedShareRateDeviationBPLimit;
        res.requestTimestampMargin = _limitsList.requestTimestampMargin;
        res.maxPositiveTokenRebase = _limitsList.maxPositiveTokenRebase;
        res.maxValidatorExitRequestsPerReport = _limitsList.maxValidatorExitRequestsPerReport;
        res.maxAccountingExtraDataListItemsCount = _limitsList.maxAccountingExtraDataListItemsCount;
        res.maxNodeOperatorsPerExtraDataItemCount = _limitsList.maxNodeOperatorsPerExtraDataItemCount;
        res.initialSlashingAmountPWei = _limitsList.initialSlashingAmountPWei;
        res.inactivityPenaltiesAmountPWei = _limitsList.inactivityPenaltiesAmountPWei;
        res.clBalanceOraclesErrorUpperBPLimit = _limitsList.clBalanceOraclesErrorUpperBPLimit;
    }
}
