// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";
import "../src/Refund.sol";

contract USDC is ERC20("USDC", "USDC") {
    address owner;

    constructor() {
        owner = msg.sender;
    }

    function mint(address _recipient, uint256 _dollars) public {
        require(msg.sender == owner);
        _mint(_recipient, _dollars * 10**6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract NotUSDC is ERC20("NotUSDC", "NotUSDC") {
    address owner;

    constructor() {
        owner = msg.sender;
    }

    function mint(address _recipient, uint256 _amount) public {
        require(msg.sender == owner);
        _mint(_recipient, _amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract RefundTest is Test {
    Refund public refund;
    USDC public usdc;
    uint256 private constant USDC_DECIMALS = 10**6;

    address buyer = vm.addr(50);
    address seller = vm.addr(60);

    uint40 feb7_2023 = 1675773554;
    uint40 march7_2023 = 1678191896;
    uint40 april7_2023 = 1680870296;

    function setUp() public {
        usdc = new USDC();
        refund = new Refund(address(usdc));
        bytes32 WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

        refund.grantRole(WITHDRAWER_ROLE, seller);
    }

    function setUpEconomy(uint32 purchasePriceDollars) public {
        usdc.mint(buyer, purchasePriceDollars);
        vm.warp(feb7_2023);

        refund.updateValidStartTimestamps([march7_2023, april7_2023, 0, 0]);
        vm.startPrank(buyer);
        usdc.approve(address(refund), purchasePriceDollars * USDC_DECIMALS);
        refund.payUpfront(purchasePriceDollars, march7_2023);
        vm.stopPrank();

        assertEq(usdc.balanceOf(buyer), 0, "buyer sent all the money");
        assertEq(usdc.balanceOf(seller), 0, "seller has no money");
        assertEq(usdc.balanceOf(address(refund)), uint256(purchasePriceDollars) * USDC_DECIMALS, "contract has all the money");
    }

    function assertBooksAreBalanced(uint32 purchacePriceDollars) public {
        uint256 moneyInTheEconomy = usdc.balanceOf(address(refund)) + usdc.balanceOf(buyer) + usdc.balanceOf(seller);
        assertEq(moneyInTheEconomy, purchacePriceDollars * USDC_DECIMALS, "books not balanced");
    }

    function depositAndWithDraw(uint256 time, uint32 purchasePriceDollars) public {
        setUpEconomy(purchasePriceDollars);
        vm.warp(march7_2023 + time);

        vm.prank(seller);
        address[] memory accountsToWithdraw = new address[](1);
        accountsToWithdraw[0] = buyer;
        refund.sellerWithdraw(accountsToWithdraw);

        vm.prank(buyer);
        refund.buyerClaimRefund();

        assertLe(usdc.balanceOf(address(refund)), 1 * 10**6, "dust should be less than two dollars");

        vm.prank(seller);
        refund.rescueERC20Token(usdc, usdc.balanceOf(address(refund)));

        assertBooksAreBalanced(purchasePriceDollars);
    }

    function depositAndWithDrawBeforeStartDate(uint256 time, uint32 purchasePriceDollars) public {
        setUpEconomy(purchasePriceDollars);
        vm.warp(feb7_2023 + time); // we are already in feb7 from setup, but just to make it explicit

        vm.prank(seller);
        address[] memory accountsToWithdraw = new address[](1);
        accountsToWithdraw[0] = buyer;
        refund.sellerWithdraw(accountsToWithdraw);

        vm.prank(buyer);
        refund.buyerClaimRefund();

        assertEq(usdc.balanceOf(buyer), purchasePriceDollars * USDC_DECIMALS, "buyer got 100% refund");
        //assertLe(usdc.balanceOf(address(refund)), 1 * 10**6, "dust should be less than two dollars");

        //vm.prank(seller);
        //refund.rescueERC20Token(usdc, usdc.balanceOf(address(refund)));

        //assertBooksAreBalanced(purchasePriceDollars);
    }

    function sellerTerminate(uint256 time, uint32 purchasePriceDollars) public {
        setUpEconomy(purchasePriceDollars);
        vm.warp(march7_2023 + time);

        vm.prank(seller);
        refund.sellerTerminateAgreement(buyer);

        assertLe(usdc.balanceOf(address(refund)), 1 * 10**6, "dust should be less than two dollars");

        vm.prank(seller);
        refund.rescueERC20Token(usdc, usdc.balanceOf(address(refund)));

        assertBooksAreBalanced(purchasePriceDollars);
    }

    function testFuzzDollarAmount(uint32 time, uint32 dollars) public {
        vm.assume(dollars > 0);
        vm.assume(time < 52 weeks);
        depositAndWithDraw(time, dollars);
    }

    function testSellerTerminatesAgreement(uint32 time, uint32 dollars) public {
        vm.assume(dollars > 0);
        vm.assume(time < 52 weeks);
        sellerTerminate(time, dollars);
    }

    function testFuzzDollarAmountBeforeStartDate(uint32 time, uint32 dollars) public {
        vm.assume(dollars > 0);
        vm.assume(time < refund.PERIOD());
        depositAndWithDrawBeforeStartDate(time, dollars);
    }

    // ---------------- updating the schedule ---------------------

    function testUpdateRefundPercentPerPeriod_onlyRole() public {
        vm.prank(buyer);
        vm.expectRevert("AccessControl: account 0x5ae58d2bc5145bff0c1bec0f32bfc2d079bc66ed is missing role 0x10dac8c06a04bec0b551627dad28bc00d6516b0caacd1c7b345fcdb5211334e4");
        refund.updateRefundPercentPerPeriod([100,100,100,100,100,100,100,100]);
    }

    function testUpdateRefundPercentPerPeriod_firstPeriodNonZero() public {
        vm.expectRevert("must have at least 1 non-zero refund period");
        refund.updateRefundPercentPerPeriod([0,0,0,0,0,0,0,0]);
    }
    
    function testUpdateRefundPercentPerPeriod_nonIncreasing() public {
        vm.expectRevert("refund must be non-increasing");
        refund.updateRefundPercentPerPeriod([100,90,80,80,80,80,80,81]);
    }

    function testUpdateRefundPercentPerPeriod_lessThan100() public {
        vm.expectRevert("refund cannot exceed 100%");
        refund.updateRefundPercentPerPeriod([101,90,80,80,80,80,80,80]);
    }

    function testUpdateRefundPercentPerPeriod_success() public {
        uint8[8] memory newSchedule = [100,50,25,0,0,0,0,0];
        refund.updateRefundPercentPerPeriod(newSchedule);

        for (uint i = 0; i < 8; i++) {
            assertEq(refund.refundPercentPerPeriod(i), newSchedule[i], "refund schedule doesn't match");
        }
    }

    // ------------ Someone directly transfers the wrong token ------

    function testSendWrongERC20Token(uint256 amount) public {
        NotUSDC notUSDC = new NotUSDC();
        notUSDC.mint(address(refund), amount);
        refund.rescueERC20Token(notUSDC, notUSDC.balanceOf(address(this)));
    }

    // ------------- Test time limits for deposit ------------

    function testDepositTooLate(uint32 purchasePriceDollars) public {
        vm.assume(purchasePriceDollars > 0);

        refund.updateValidStartTimestamps([march7_2023, april7_2023, 0, 0]);
        usdc.mint(buyer, purchasePriceDollars);
        vm.warp(march7_2023 + 30 days + 1 seconds);

        vm.startPrank(buyer);
        usdc.approve(address(refund), purchasePriceDollars * USDC_DECIMALS);
        vm.expectRevert("Date is too far in the past");
        refund.payUpfront(purchasePriceDollars, march7_2023);
        vm.stopPrank();
    }

    function testDepositTooEarly(uint32 purchasePriceDollars) public {
        vm.assume(purchasePriceDollars > 0);

        refund.updateValidStartTimestamps([march7_2023, april7_2023, 0, 0]);
        usdc.mint(buyer, purchasePriceDollars);
        vm.warp(march7_2023 - 180 days - 1 seconds);

        vm.startPrank(buyer);
        usdc.approve(address(refund), purchasePriceDollars * USDC_DECIMALS);
        vm.expectRevert("Date is too far in the future");
        refund.payUpfront(purchasePriceDollars, march7_2023);
        vm.stopPrank();
    }

    function testRejectInvalidStartDates(uint32 purchasePriceDollars) public {
        vm.assume(purchasePriceDollars > 0);
        vm.warp(march7_2023);
        uint40[4] memory startDates = [march7_2023 + 1, march7_2023 - 1, april7_2023 - 1, april7_2023 + 1];

        for (uint i = 0; i < startDates.length; i++) {
            refund.updateValidStartTimestamps([march7_2023, april7_2023, 0, 0]);
            usdc.mint(buyer, purchasePriceDollars);
            vm.warp(march7_2023);

            vm.startPrank(buyer);
            usdc.approve(address(refund), purchasePriceDollars * USDC_DECIMALS);
            vm.expectRevert("Invalid start date");
            refund.payUpfront(purchasePriceDollars, startDates[i]);
            vm.stopPrank();
        }
    }

    function testDepositZeroDollars() public {
        uint32 purchasePriceDollars = 0; 

        refund.updateValidStartTimestamps([march7_2023, april7_2023, 0, 0]);
        usdc.mint(buyer, purchasePriceDollars);
        vm.warp(march7_2023);

        vm.startPrank(buyer);
        usdc.approve(address(refund), purchasePriceDollars * USDC_DECIMALS);
        vm.expectRevert("User cannot deposit zero dollars.");
        refund.payUpfront(purchasePriceDollars, march7_2023);
        vm.stopPrank();
    }

    function testCannotDepositTwice() public {
        uint32 purchasePriceDollars = 1000; 

        refund.updateValidStartTimestamps([march7_2023, april7_2023, 0, 0]);
        usdc.mint(buyer, 2 * purchasePriceDollars);
        vm.warp(march7_2023);

        vm.startPrank(buyer);
        usdc.approve(address(refund), 2 * purchasePriceDollars * USDC_DECIMALS);
        refund.payUpfront(purchasePriceDollars, march7_2023);

        vm.expectRevert("User cannot deposit twice."); 
        refund.payUpfront(purchasePriceDollars, march7_2023);
        vm.stopPrank();
    }

    function testLowAllowance(uint8 _allowance) public {
        uint32 purchasePriceDollars = 1000; 

        refund.updateValidStartTimestamps([march7_2023, april7_2023, 0, 0]);
        usdc.mint(buyer, purchasePriceDollars);
        vm.warp(march7_2023);

        vm.startPrank(buyer);
        usdc.approve(address(refund), _allowance * USDC_DECIMALS / 2);

        vm.expectRevert("ERC20: insufficient allowance"); 
        refund.payUpfront(purchasePriceDollars, march7_2023);
        vm.stopPrank();
    }
}