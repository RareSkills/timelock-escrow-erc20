//SPDX-License-Identifier: GPL-3.0

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

pragma solidity 0.8.18;

/*  @author M. Burke
 *  @notice This is a payment contract that enforces a refund schedule.
 */

contract TimeBasedEscrow {
    bytes32 public constant MINTER_ROLE = keccak256("WITHDRAWER_ROLE");
    IERC20 public immutable USDC;

    // Technically, USDC could upgrade and change the decimals, in which
    // case we are screwed. But it's expensive to read it from the contract
    // and this event is extremely unlikely.
    uint64 public constant USDC_DECIMALS = 10**6;

    // These three storage variables all fits in one slot
    uint8[8] public refundPercentPerMonth = [100, 75, 50, 25, 0, 0, 0, 0];

    // good for until year 36,812
    uint40[4] public validStartTimestamps;

    // we can't hold over 4 million bucks, but seems like enough room
    // Someone else who is
    uint32 public depositedDollars = 0;

    event RefundPercentPerMonthUpdated(uint8[8]);
    event ValidStartTimestampsUpdated(uint40[4]);
    event SellerTerminateAgreement(address indexed, uint256);
    event BuyerClaimRefundDollars(address indexed, uint256);
    event BuyerDepositDollars(address indexed, uint256);

    mapping(address => Deposit) public deposits;

    ///@notice This struct is used to handle book keeping for each user.
    struct Deposit {
        uint32 originalDepositInDollars;
        uint32 balanceInDollars; // this goes down as the seller withdraws
        uint64 cohortStartTimestamp; // When the class starts and the refund counters starts deducting
        uint8[4] refundPercentPerMonth;
    }

    constructor(address _usdc) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        USDC = IERC20(_usdc);
    }

    /*
    modifier onlyAdmin() {
        require(_minters.has(msg.sender), "DOES_NOT_HAVE_WITHDRAWER_ROLE");
        _;
    }
    */

    function updateValidStartTimestamps(uint40[4] _validStartTimestamps)
        external
        onlyAdmin
    {
        emit ValidStartTimestampsUpdated(_validStartTimestamps);
        validStartTimestamps = _validStartTimestamps;
    }

    /*  @notice Users are required to make allowance with USDC contract before calling.
     *  @param _price The price in dollars to be paid. NOT USDC decimals
     *  @param _startTime The start time in seconds. See EPOCH time converter.
     */
    function payUpfront(uint32 _priceInDollars, uint40 _cohortStartTimestamp)
        external
    {
        // We don't force someone to pay a particular price because this can change.
        // We just inspect the logs to see if the address paid the amount expected
        // at time of enrollment. If they pay the wrong amount, they can just withdraw
        // within 30 days.
        uint256 _priceInUSDC = _priceInDollars * USDC_DECIMALS;

        // these are just sanity checks in case someone is enrolling when
        // a new date isn't set
        require(
            _cohortStartTimestamp >= uint40(block.timestamp) - uint40(30 days),
            "Date is too far in the past"
        );
        require(
            _cohortStartTimestamp <= uint40(block.timestamp) + uint40(180 days),
            "Date is too far in the future"
        );

        require(
            _cohortStartTimestamp == validStartTimestamps[0] ||
                _cohortStartTimestamp == validStartTimestamps[1] ||
                _cohortStartTimestamp == validStartTimestamps[2] ||
                _cohortStartTimestamp == validStartTimestamps[3],
            "Invalid start date"
        );

        require(_priceInDollars > 0, "User cannot deposit zero dollars.");
        require(
            deposits[msg.sender].originalDepositInDollars == 0,
            "User cannot deposit twice."
        );
        require(
            USDC.allowance(msg.sender, address(this)) >= _priceInUSDC,
            "User must have made allowance via USDC contract."
        );

        deposits[msg.sender] = Deposit({
            originalDepositInDollars: _priceInDollars,
            balanceInDollars: _priceInDollars,
            cohortStartTimestamp: _cohortStartTimestamp,
            refundPercentPerMonth: refundPercentPerMonth
        });

        // it's really unlike 4 million dollars will be in the contract.
        // If so, revert.
        depositedDollars += _priceInDollars;

        emit BuyerDepositDollars(msg.sender, depositedDollars);
        USDC.transferFrom(msg.sender, address(this), _priceInUSDC);
    }

    ///@notice Users can claim refund and remove 'account' from contract.
    function buyerClaimRefund() external {
        uint256 refundInDollars = calculateRefundDollars(msg.sender);

        // refundInDollars is rounded down. So if someone deposits 101 dollars,
        // during the first refund they could get back $75.75. However, they only
        // get back $75. This means we will never underflow. This difference is
        // negligible compared to the gas costs.
        depositedDollars -= uint32(refundInDollars);

        delete deposits[msg.sender];
        emit BuyerClaimRefundDollars(msg.sender, refundInDollars);
        USDC.transfer(msg.sender, refundInDollars * USDC_DECIMALS);
    }

    /*
     *  @param _schedule The percentage at which the escrow unlocks the money for the seller week by week
     */

    function updateRefundPercentPerMonth(uint8[8] calldata _schedule)
        external
        payable
        onlyRole(WITHDRAWER_ROLE)
    {
        require(
            _schedule[0] > 0,
            "must have at least 1 non-zero refund period"
        );

        uint256 len = _schedule.length;
        for (uint256 i = 0; i < len - 1; ) {
            uint256 idxValue = _schedule[i];
            require(
                idxValue >= _schedule[i + 1],
                "refund must be non-increasing"
            );
            require(idxValue < 101, "refund cannot exceed 100%");
            unchecked {
                ++i;
            }
        }

        emit RefundPercentPerMonthUpdated(_schedule);
        refundPercentPerMonth = _schedule;
    }

    /*  @dev Push payment to user and removal of 'account'
     *  @param _buyer The user's wallet address who is to be removed.
     */

    function sellerTerminateAgreement(address _buyer)
        external
        payable
        onlyRole(WITHDRAWER_ROLE)
    {
        uint256 _refundInDollars = calculateRefundDollars(_buyer);

        depositedDollars -= uint128(_refundInDollars);
        delete deposits[_buyer];

        emit SellerTerminateAgreement(_buyer, _refundInDollars);
        USDC.transfer(_buyer, _refundInDollars * USDC_DECIMALS);
    }

    /*  @dev See calculation to ensure user refund policy is respected.
     *  @param _buyers An array of active user accounts (wallet addresses)
     *         to withdraw funds from.
     */

    function sellerWithdraw(address[] calldata _buyers)
        external
        onlyRole(WITHDRAWER_ROLE)
    {
        uint256 dollarsToWithdraw = 0;
        uint256 len = _buyers.length;

        for (uint256 i = 0; i < len; ) {
            uint256 dollarsDueToSeller = calculateDollarsSellerCanWithdraw(
                _buyers[i]
            );

            deposits[_buyers[i]].balanceInDollars -= uint32(dollarsDueToSeller);
            unchecked {
                dollarsToWithdraw += dollarsDueToSeller;
                ++i;
            }
        }
        depositedDollars -= uint32(dollarsToWithdraw);
        USDC.transfer(msg.sender, dollarsToWithdraw * USDC_DECIMALS);
    }

    /*  @notice This is used internally for book keeping but made available
     *          publicly.
     *  @notice Everything is done in uint256 for gas efficiency, but we know the output cannot exceed uint32
     *  @param _buyer User wallet address.
     *  @returns dollar amount the buyer can refund at this point in time (NOT USDC DECIMALS)
     */

    function calculateRefundDollars(address _buyer)
        public
        view
        returns (uint256)
    {
        uint256 paidDollars = deposits[_buyer].originalDepositInDollars;
        uint256 scheduleLength = deposits[_buyer].refundPercentPerMonth.length;

        uint256 monthsComplete = _getMonthsComplete(_buyer);
        uint256 multiplier;

        if (monthsComplete < scheduleLength) {
            multiplier = deposits[_buyer].refundPercentPerMonth[monthsComplete];
        }

        if (monthsComplete >= scheduleLength) {
            multiplier = 0;
        }

        return (paidDollars * multiplier) / 100;
    }

    /*  @notice This is used internally for book keeping but made available
     *          publicly.
     *  @notice This function rounds down the amount the seller can withdraw.
     *          So if the seller can withdraw $10.50, they can only withdraw $10.
     *  @param _buyer User wallet address.
     *  @returns how much the seller can withdraw in dollars (NOT USDC DECIMALS)
     */

    function calculateDollarsSellerCanWithdraw(address _buyer)
        public
        view
        returns (uint256)
    {
        // NOTE: The +1 here is because calculateRefundDollars rounds down the cents
        // This means the seller will get up to 0.99 less than they are supposed to.
        // This is okay because the seller can later sweep the excess balances with
        // the rescue function.
        //
        // Basically, ensuring that the buyer and seller cannot withdraw the cents
        // portion of their part of the deal ensures that neither party underflows
        // and bricks the contract (because Solidity will revert underflow).
        uint256 amountBuyerCanRefundDollars = calculateRefundDollars(_buyer) +
            1;
        uint256 buyerBalanceInDollars = deposits[_buyer].balanceInDollars;

        if (amountBuyerCanRefundDollars >= buyerBalanceInDollars) {
            return 0;
        }

        return buyerBalanceDollars - amountBuyerCanRefundDollars;
    }

    /*  @notice Used internally for calculating where a user is within their
     *          refund schedule.
     *  @param _buyer User wallet address.
     *  @returns number of months since the start date
     */

    function _getMonthsComplete(address _buyer)
        internal
        view
        returns (uint256)
    {
        uint256 startTime = deposits[_buyer].cohortStartTimestamp;
        uint256 currentTime = block.timestamp;

        if (currentTime < startTime) {
            return 0;
        }

        return (currentTime - startTime) / uint256(30 days);
    }

    /*  @notice Used to recover ERC20 tokens transfered to contract
     *          outside of standard interactions.
     *  @param _tokenContract The contract address of a standard ERC20
     *  @param _amount The value (with correct decimals) to be recovered.
     */

    function rescueERC20Token(IERC20 _tokenContract, _amount)
        external
        onlyRole(WITHDRAWER_ROLE)
    {
        // In case someone sent Tether or something else
        if (_tokenContract != USDC) {
            _tokenContract.transfer(msg.sender, _amount);
            return;
        }

        /*  For transfer of USDC make check (passed in `_amount` is ignored and
         *  amountToWithdraw is calculated.
         */

        uint256 contractBalanceUSDC = USDC.balanceOf(address(this));

        if (contractBalance > depositedDollars) {
            uint256 amountToWithdrawUSDC = contractBalanceUSDC -
                depositedDollars *
                USDC_DECIMALS;
            _tokenContract.transfer(msg.sender, amountToWithdrawUSDC);
        }
    }
}
