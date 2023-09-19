// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19 <0.9.0;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import {PRBTest} from "@prb/test/PRBTest.sol";
import {console2} from "forge-std/console2.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {xPERP} from "../src/xPERP.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev If this is your first time with Forge, read this tutorial in the Foundry Book:
/// https://book.getfoundry.sh/forge/writing-tests
contract xPERPTest is PRBTest, StdCheats {
    xPERP internal xperp;
    address payable constant teamTestWallet = payable(0x282e0D30DF3C7Ecb58430d31c1A28De4f9ee7F44);
    IUniswapV2Pair internal uniswapV2Pair;
    IUniswapV2Router02 internal uniswapV2Router;
    address internal weth;

    /// @dev A function invoked before each test case is run.
    function setUp() public virtual {
        // Instantiate the contract-under-test.
        xperp = new xPERP(teamTestWallet);
        xperp.init();
    }

    /// @dev Total Supply check
    function testSupplyCheck() external {
        uint256 balance = xperp.balanceOf(address(this));
        assertEq(balance, 1_000_000e18, "balance mismatch");
    }

    /// @dev Total Supply check
    function testUniswapPairFund() public {
        // depositing 50 ether / 990_000 xperp
        uint256 amountETHToUse = 30e18;
        uint256 amountTokenToUse = 990_000e18;
        fundPair(amountETHToUse, amountTokenToUse);
        (uint reserveA, uint reserveB,) = uniswapV2Pair.getReserves();
        assertEq(reserveA, amountTokenToUse, "reserves A (XPERP) are wrong");
        assertEq(reserveB, amountETHToUse, "reserves B (ETH) are wrong");
    }

    /// @dev buy on uniswap, sell on uniswap for ether, taxes are correct
    function testSwap() public {
        //fund the pair
        fundPair(50e18, 990_000e18);
        xperp.EnableTradingOnUniSwap();

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(xperp);

        // Fetch reserves
        (uint reserveA, uint reserveB,) = uniswapV2Pair.getReserves();
        // Make sure reserveA corresponds to ETH and reserveB to XPERP
        address token0 = uniswapV2Pair.token0();
        if (token0 == address(xperp)) {
            (reserveA, reserveB) = (reserveB, reserveA);
        }

        // Calculate expected XPERP
        uint256 amountETHToUse = 1e17;
        uint256 amountInWithFee = amountETHToUse * 997;  // 0.3% fee is subtracted
        uint256 numerator = amountInWithFee * reserveB;
        uint256 denominator = reserveA * 1000 + amountInWithFee;  // 0.3% fee is added
        uint256 expectedXPERP = numerator / denominator;

        // Apply 5% tax, the formula is  expectedXPERPAfterTax = (expectedXPERP * 9500) / 10000;
        // buy 1 ether worth of xperp
        address payable user1 = payable(address(0x13));
        user1.transfer(amountETHToUse);
        vm.startPrank(user1);
        uniswapV2Router.swapExactETHForTokens{value: amountETHToUse}(
            0,
            path,
            user1,
            block.timestamp
        );
        vm.stopPrank();
        assertThreshold((numerator * 950) / (1000 * denominator), xperp.balanceOf(user1), "XPERP balance mismatch");

        //the contract gets 5% (all tax)
        assertEq(xperp.balanceOf(address(xperp)), expectedXPERP * 50 / 1000, "Contract balance mismatch");

        //check taxes, team wallet gets 2%
        // selling and sending for team wallet
        path[0] = address(xperp);
        path[1] = weth;
        uint256 teamWalletAndRevenueShareEstimated = (expectedXPERP * (20 + 20)) / 1000;
        uint256[] memory estimatedTeamWalletAndRevenueETH = uniswapV2Router.getAmountsOut(teamWalletAndRevenueShareEstimated, path);
        uint256 estimatedTeamWalletETH = estimatedTeamWalletAndRevenueETH[estimatedTeamWalletAndRevenueETH.length - 1] / 2;
//        uint256 estimatedRevShareETH = estimatedTeamWalletAndRevenueETH[estimatedTeamWalletAndRevenueETH.length - 1] / 2;
        xperp.snapshot{value: 0}();
        assertThreshold(estimatedTeamWalletETH, teamTestWallet.balance, "team wallet balance mismatch");

        // check distribution 1% to the liquidity pair, - should be on the contract
        assertEq(xperp.liquidityPairTaxCollectedNotYetInjectedXPERP(), expectedXPERP * 10 / 1000, "liquidityPairTaxCollectedNotYetInjectedXPERP mismatch");
        assertEq(xperp.balanceOf(address(xperp)), expectedXPERP * 10 / 1000, "liquidityPairTaxCollectedNotYetInjected mismatch");

    }

    function testInjectLiquidity() public {
        // depositing 20 eth and 990K xperp in the pair
        uint256 amountETHToUse = 20e18;
        uint256 amountTokenToUse = 990_000e18;
        fundPair(amountETHToUse, amountTokenToUse);
        xperp.EnableTradingOnUniSwap();


        // swap tokens to generate lp share 1%
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(xperp);
        address payable user1 = payable(address(0x13));
        user1.transfer(1e18);
        vm.startPrank(user1);
        uniswapV2Router.swapExactETHForTokens{value: 1e14}(
            0,
            path,
            user1,
            block.timestamp
        );
        vm.stopPrank();
        console2.log("swapped");

        // checking the amount of xperp that is a 1% lp tax
        uint lpShare = xperp.liquidityPairTaxCollectedNotYetInjectedXPERP();
        console2.log("liquidityPairTaxCollectedNotYetInjectedXPERP", lpShare);


        (uint reserveA, uint reserveB,) = IUniswapV2Pair(xperp.uniswapV2Pair()).getReserves();
        console2.log("xperp balance on the contract", xperp.balanceOf(address(xperp)));
        console2.log("reserveA", reserveA);
        console2.log("reserveB", reserveB);

        //fund the pair
        console2.log("eth on the contract before injection", address(xperp).balance);
        console2.log("token on the contract before injection", xperp.balanceOf(address(xperp)));

        xperp.injectLiquidity(0);
//        xperp.injectLiquidity{value: 1 ether}();
        console2.log("eth on the contract", address(xperp).balance);
        console2.log("token on the contract", xperp.balanceOf(address(xperp)));


        (reserveA, reserveB,) = IUniswapV2Pair(xperp.uniswapV2Pair()).getReserves();
        console2.log("reserveA", reserveA);
        console2.log("reserveB", reserveB);

        //fund the pair
        console2.log("eth on the contract after injection", address(xperp).balance);
        console2.log("token on the contract after injection", xperp.balanceOf(address(xperp)));
//        assertEq(xperp.balanceOf(address(xperp)), 0, "contract balance mismatch");

    }

    function testSnapshotTradingTax() public {
        // depositing 20 eth and 990K xperp in the pair
        uint256 amountETHToUse = 20e18;
        uint256 amountTokenToUse = 990_000e18;
        fundPair(amountETHToUse, amountTokenToUse);
        xperp.EnableTradingOnUniSwap();
        // this is a must to initialize epoch
        xperp.snapshot{value: 0}();

        //several users
        address user1 = address(0x13);
        address user2 = address(0x14);

        //fund these wallet with xperp tokens
        xperp.transfer(user1, 2000e18);
        xperp.transfer(user2, 4000e18);

        //swap to cgereate apair
        // swap tokens to generate lp share 1%
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(xperp);
        uniswapV2Router.swapExactETHForTokens{value: 1e18}(
            0,
            path,
            address(this),
            block.timestamp
        );

        xperp.snapshot{value: 0}();


        uint balanceBefore = user1.balance;
        vm.startPrank(user1);
        xperp.claimAll();
        vm.stopPrank();
        uint balanceAfter = user1.balance;
        console2.log("balanceChange", balanceAfter - balanceBefore);

        xperp.snapshot{value: 10}();
        balanceBefore = user1.balance;
        vm.startPrank(user1);
        xperp.claimAll();
        vm.stopPrank();
        balanceAfter = user1.balance;
        console2.log("balanceChange2", balanceAfter - balanceBefore);

        //        20853460472609082 * 20/1000
//        assertEq(balanceAfter - balanceBefore, 41706920945218, "balance mismatch");

    }


    function testSnapshotTradingDistribution() public {
        xperp.snapshot{value: 0}();
        //several users
        address user1 = address(0x13);
        address user2 = address(0x14);

        //fund these wallet with xperp tokens
        xperp.transfer(user1, 2000e18);
        xperp.transfer(user2, 4000e18);

        console2.log("balance", xperp.balanceOf(user1));
        console2.log("user2 balance", xperp.balanceOf(user2));
        console2.log("total supply", xperp.totalSupply());

        xperp.snapshot{value: 1e18}();


        uint balanceBefore = user1.balance;
        vm.startPrank(user1);
        xperp.claimAll();
        vm.stopPrank();
        uint balanceAfter = user1.balance;
        console2.log("balanceBefore", balanceBefore);
        console2.log("balanceAfter", balanceAfter);

        uint total = 6000;
        uint share = 1 ether * 2000 / total;
        assertEq(balanceAfter - balanceBefore, share, "balance mismatch");
    }


    function testClaimAll() public {
        xperp.snapshot{value: 0}();
        //several users
        address user1 = address(0x13);
        address user2 = address(0x14);

        //fund these wallet with xperp tokens
        xperp.transfer(user1, 2000e18);
        xperp.transfer(user2, 4000e18);
        console2.log("EPOCH 1");
        console2.log("balance", xperp.balanceOf(user1));
        console2.log("user2 balance", xperp.balanceOf(user2));
        console2.log("circulatingSupply", xperp.circulatingSupply());
        xperp.snapshot{value: 1e18}();


        xperp.transfer(user1, 2000e18);
        console2.log("EPOCH 2");
        console2.log("balance", xperp.balanceOf(user1));
        console2.log("circulatingSupply", xperp.circulatingSupply());
        xperp.snapshot{value: 1e18}();

        vm.startPrank(user1);
        xperp.transfer(user2, 1000e18);
        vm.stopPrank();
        console2.log("EPOCH 3");
        console2.log("balance", xperp.balanceOf(user1));
        console2.log("circulatingSupply", xperp.circulatingSupply());
        xperp.snapshot{value: 1e18}();

        uint balanceBefore = user1.balance;
        vm.startPrank(user1);
        xperp.claimAll();
        vm.stopPrank();
        uint balanceAfter = user1.balance;
        console2.log("balanceBefore", balanceBefore);
        console2.log("balanceAfter", balanceAfter);

        // epoch 1, 20/60
        uint total = 6000;
        uint shareEpoch1 = 1 ether * 2000 / total;
        // epoch 2, 40, 80
        total = 8000;
        uint shareEpoch2 = 1 ether * 4000 / total;
        // epoch 3, 40, 80
        total = 8000;
        uint shareEpoch3 = 1 ether * 3000 / total;
        assertEq(balanceAfter - balanceBefore, shareEpoch1 + shareEpoch2 + shareEpoch3, "balance mismatch");
    }

    /// @dev transfer to another address, no taxes are paid
    /// @dev trasnfer limitation, 1% of total supply
    /// @dev revenue sharing

    /// @dev Fuzz test that provides random values for an unsigned integer, but which rejects zero as an input.
    /// If you need more sophisticated input validation, you should use the `bound` utility instead.
    /// See https://twitter.com/PaulRBerg/status/1622558791685242880
    function testFuzz_Example(uint256 x) external {
//        vm.assume(x != 0); // or x = bound(x, 1, 100)
//        assertEq(xperp.id(x), x, "value mismatch");
    }

    /// @dev Fork test that runs against an Ethereum Mainnet fork. For this to work, you need to set `API_KEY_ALCHEMY`
    /// in your environment You can get an API key for free at https://alchemy.com.
    function testFork_Example() external {
        // Silently pass this test if there is no API key.
        string memory alchemyApiKey = vm.envOr("API_KEY_ALCHEMY", string(""));
        if (bytes(alchemyApiKey).length == 0) {
            return;
        }

        // Otherwise, run the test against the mainnet fork.
        vm.createSelectFork({urlOrAlias: "mainnet", blockNumber: 16_428_000});
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address holder = 0x7713974908Be4BEd47172370115e8b1219F4A5f0;
        uint256 actualBalance = IERC20(usdc).balanceOf(holder);
        uint256 expectedBalance = 196_307_713.810457e6;
        assertEq(actualBalance, expectedBalance);
    }

    // ================= Helper functions =================

    function fundPair(uint256 amountETHToUse, uint256 amountTokenToUse) public {
        uniswapV2Pair = IUniswapV2Pair(xperp.uniswapV2Pair());
        uniswapV2Router = IUniswapV2Router02(xperp.uniswapV2Router());
        weth = uniswapV2Router.WETH();
        xperp.approve(address(uniswapV2Router), 1_000_000e18);
        uniswapV2Router.addLiquidityETH{value: amountETHToUse}(
            address(xperp),
            amountTokenToUse,
            0,
            0,
            address(this),
            block.timestamp
        );
    }


    function assertThreshold(uint256 a, uint256 b, string memory err) internal {
        //threshold is 1e-17, just to eliminate some rounding errors
        uint256 threshold = 10;
        if (a + threshold < b || b + threshold < a) {
            emit Log("Error: a == b with threshold not satisfied");
            emit Log(err);
            emit LogNamedUint256("   Left", a);
            emit LogNamedUint256("  Right", b);
            fail();
        }
    }


    receive() external payable {}
}

///todo test multiple claims to avoid doubling
// test swap eth to token and token to eth
// test multiple claims in one epoch
// test multiple claims in multiple epochs
// test multiple claims in multiple epochs with transfers
// test multiple claims in multiple epochs with transfers and revenue sharing
// test multiple claims in multiple epochs with transfers and revenue sharing and liquidity injection
// test multiple claims in multiple epochs with transfers and revenue sharing and liquidity injection and trading
