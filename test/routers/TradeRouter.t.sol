// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { RoutersErrors as Errors } from "@errors/routers/RoutersErrors.sol";
import { RoutersEvents as Events } from "@events/routers/RoutersEvents.sol";
import { DopplerData } from "@types/registries/PlayerSetTypes.sol";
import { TradeRouter } from "@routers/TradeRouter.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { MockPlayerSetRegistry } from "../vaults/mocks/MockPlayerSetRegistry.sol";
import { MockPlayerToken } from "../vaults/mocks/MockPlayerToken.sol";
import { MockPoolManager } from "./mocks/MockPoolManager.sol";
import { MockSwapHook } from "./mocks/MockSwapHook.sol";
import { MockZRouter } from "./mocks/MockZRouter.sol";

contract TradeRouterTest is Test {
    bytes32 internal constant PLAYER = keccak256("player-1");

    AddressProvider internal ap;
    MockPlayerSetRegistry internal playerSetRegistry;
    MockPlayerToken internal playerToken;
    MockPlayerToken internal usdc;
    MockZRouter internal zRouter;
    MockPoolManager internal manager;
    MockSwapHook internal hooks;
    TradeRouter internal router;
    PoolKey internal poolKey;

    address internal user = makeAddr("user");

    function setUp() public {
        ap = new AddressProvider(address(this));
        playerSetRegistry = new MockPlayerSetRegistry();
        playerToken = new MockPlayerToken();
        usdc = new MockPlayerToken();
        zRouter = new MockZRouter();
        manager = new MockPoolManager();
        hooks = new MockSwapHook();

        // Inventory for 1:1 takes from the mock manager.
        vm.deal(address(manager), 1_000 ether);
        vm.deal(address(zRouter), 1_000 ether);
        playerToken.mint(address(manager), 1_000 ether);

        ap.setName(Addresses.PLAYER_SET_REGISTRY, address(playerSetRegistry));
        ap.setName(Addresses.Z_ROUTER, address(zRouter));

        router = new TradeRouter(address(ap), address(manager));

        // Default pool includes a test-double hook so buy/sell paths exercise before/afterSwap.
        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(playerToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hooks))
        });

        playerSetRegistry.setPlayerToken(PLAYER, address(playerToken));
        playerSetRegistry.setDopplerData(
            PLAYER,
            DopplerData({
                activePool: poolKey,
                hookDoppler: address(hooks),
                hookMigrator: address(0),
                feeRouter: address(0)
            })
        );

        vm.deal(user, 100 ether);
    }

    // --------------------------------------------
    //  Views / guards
    // --------------------------------------------

    function test_poolOf_resolvesEthPlayerPool() public view {
        PoolKey memory key = router.poolOf(address(playerToken));
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(playerToken));
        assertEq(uint256(key.fee), 3000);
    }

    function test_poolOf_revertsUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownToken.selector, address(0xBEEF)));
        router.poolOf(address(0xBEEF));
    }

    function test_poolOf_revertsInvalidPool() public {
        MockPlayerToken other = new MockPlayerToken();
        bytes32 pid = keccak256("bad-pool");
        playerSetRegistry.setPlayerToken(pid, address(other));
        playerSetRegistry.setDopplerData(
            pid,
            DopplerData({
                activePool: PoolKey({
                    currency0: Currency.wrap(address(usdc)),
                    currency1: Currency.wrap(address(other)),
                    fee: 3000,
                    tickSpacing: 60,
                    hooks: IHooks(address(0))
                }),
                hookDoppler: address(0),
                hookMigrator: address(0),
                feeRouter: address(0)
            })
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPool.selector, address(other)));
        router.poolOf(address(other));
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        router.unlockCallback("");
    }

    // --------------------------------------------
    //  buy / sell (ETH ↔ player)
    // --------------------------------------------

    function test_buy_exactIn_oneToOne() public {
        uint256 ethIn = 1 ether;

        vm.prank(user);
        uint256 amountOut = router.buy{ value: ethIn }(address(playerToken), 0, block.timestamp + 1);

        assertEq(amountOut, ethIn);
        assertEq(playerToken.balanceOf(user), ethIn);
        assertEq(address(router).balance, 0);
        assertEq(hooks.beforeSwapCount(), 1);
        assertEq(hooks.afterSwapCount(), 1);
        assertEq(hooks.lastSender(), address(router));
        assertEq(hooks.lastHookData(), "");
    }

    function test_buy_revertsWhenHookRevertsBefore() public {
        hooks.setRevertBefore(true);
        vm.prank(user);
        vm.expectRevert(MockSwapHook.HookReverted.selector);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);
    }

    function test_buy_revertsWhenHookRevertsAfter() public {
        hooks.setRevertAfter(true);
        vm.prank(user);
        vm.expectRevert(MockSwapHook.HookReverted.selector);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);
    }

    function test_sell_invokesHooks() public {
        vm.prank(user);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);
        assertEq(hooks.beforeSwapCount(), 1);

        vm.startPrank(user);
        playerToken.approve(address(router), 1 ether);
        router.sell(address(playerToken), 1 ether, 0, block.timestamp + 1);
        vm.stopPrank();

        assertEq(hooks.beforeSwapCount(), 2);
        assertEq(hooks.afterSwapCount(), 2);
    }

    function test_buy_emitsBought() public {
        vm.expectEmit(true, true, false, true);
        emit Events.Bought(user, address(playerToken), 1 ether, 1 ether);

        vm.prank(user);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);
    }

    function test_buy_revertsExpired() public {
        vm.prank(user);
        vm.expectRevert(Errors.Expired.selector);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp - 1);
    }

    function test_buy_revertsZeroValue() public {
        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        router.buy{ value: 0 }(address(playerToken), 0, block.timestamp + 1);
    }

    function test_buy_revertsSlippage() public {
        vm.prank(user);
        vm.expectRevert(Errors.Slippage.selector);
        router.buy{ value: 1 ether }(address(playerToken), 1 ether + 1, block.timestamp + 1);
    }

    function test_sell_exactIn_oneToOne() public {
        vm.prank(user);
        router.buy{ value: 2 ether }(address(playerToken), 0, block.timestamp + 1);

        uint256 sellAmount = 1 ether;
        uint256 ethBefore = user.balance;

        vm.startPrank(user);
        playerToken.approve(address(router), sellAmount);
        uint256 ethOut = router.sell(address(playerToken), sellAmount, 0, block.timestamp + 1);
        vm.stopPrank();

        assertEq(ethOut, sellAmount);
        assertEq(user.balance, ethBefore + ethOut);
        assertEq(playerToken.balanceOf(user), 1 ether);
    }

    function test_sell_revertsWithoutApprove() public {
        vm.prank(user);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);

        vm.prank(user);
        vm.expectRevert(bytes("allowance"));
        router.sell(address(playerToken), 1 ether, 0, block.timestamp + 1);
    }

    function test_sell_revertsSlippage() public {
        vm.prank(user);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);

        vm.startPrank(user);
        playerToken.approve(address(router), 1 ether);
        vm.expectRevert(Errors.Slippage.selector);
        router.sell(address(playerToken), 1 ether, 1 ether + 1, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_sell_revertsZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        router.sell(address(playerToken), 0, 0, block.timestamp + 1);
    }

    function test_sell_revertsExpired() public {
        vm.prank(user);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);

        vm.startPrank(user);
        playerToken.approve(address(router), 1 ether);
        vm.expectRevert(Errors.Expired.selector);
        router.sell(address(playerToken), 1 ether, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    // --------------------------------------------
    //  buyWithToken / sellToToken (zRouter wings)
    // --------------------------------------------

    function test_buyWithToken_viaZRouter() public {
        uint256 amountIn = 1 ether;
        usdc.mint(user, amountIn);

        bytes memory zCall = abi.encodeCall(MockZRouter.swapToEth, (address(usdc), amountIn, address(router)));

        vm.startPrank(user);
        usdc.approve(address(router), amountIn);
        uint256 amountOut =
            router.buyWithToken(address(playerToken), address(usdc), amountIn, 0, block.timestamp + 1, zCall);
        vm.stopPrank();

        assertEq(amountOut, amountIn);
        assertEq(playerToken.balanceOf(user), amountIn);
        assertEq(usdc.balanceOf(user), 0);
        assertEq(address(router).balance, 0);
    }

    function test_buyWithToken_revertsPlayerAsInput() public {
        vm.expectRevert(Errors.InvalidPath.selector);
        router.buyWithToken(address(playerToken), address(playerToken), 1 ether, 0, block.timestamp + 1, hex"00");
    }

    function test_buyWithToken_revertsEthAsInput() public {
        vm.expectRevert(Errors.InvalidPath.selector);
        router.buyWithToken(address(playerToken), address(0), 1 ether, 0, block.timestamp + 1, hex"00");
    }

    function test_buyWithToken_revertsEmptyCalldata() public {
        vm.expectRevert(Errors.InvalidPath.selector);
        router.buyWithToken(address(playerToken), address(usdc), 1 ether, 0, block.timestamp + 1, "");
    }

    function test_buyWithToken_revertsMsgValue() public {
        bytes memory zCall = abi.encodeCall(MockZRouter.swapToEth, (address(usdc), 1 ether, address(router)));
        vm.expectRevert(Errors.InvalidMsgValue.selector);
        router.buyWithToken{ value: 1 wei }(
            address(playerToken), address(usdc), 1 ether, 0, block.timestamp + 1, zCall
        );
    }

    function test_buyWithToken_revertsWhenZRouterSendsNoEth() public {
        uint256 amountIn = 1 ether;
        usdc.mint(user, amountIn);
        // Valid call that does not send ETH back to the router.
        bytes memory zCall = abi.encodeWithSignature("nonexistent()");

        vm.startPrank(user);
        usdc.approve(address(router), amountIn);
        vm.expectRevert(Errors.ZRouterCallFailed.selector);
        router.buyWithToken(address(playerToken), address(usdc), amountIn, 0, block.timestamp + 1, zCall);
        vm.stopPrank();
    }

    function test_buyWithToken_revertsSlippage() public {
        uint256 amountIn = 1 ether;
        usdc.mint(user, amountIn);
        bytes memory zCall = abi.encodeCall(MockZRouter.swapToEth, (address(usdc), amountIn, address(router)));

        vm.startPrank(user);
        usdc.approve(address(router), amountIn);
        vm.expectRevert(Errors.Slippage.selector);
        router.buyWithToken(address(playerToken), address(usdc), amountIn, amountIn + 1, block.timestamp + 1, zCall);
        vm.stopPrank();
    }

    function test_sellToToken_viaZRouter() public {
        vm.prank(user);
        router.buy{ value: 2 ether }(address(playerToken), 0, block.timestamp + 1);

        bytes memory zCall = abi.encodeCall(MockZRouter.swapFromEth, (address(usdc), user));

        vm.startPrank(user);
        playerToken.approve(address(router), 2 ether);
        uint256 amountOut =
            router.sellToToken(address(playerToken), address(usdc), 2 ether, 0, block.timestamp + 1, zCall);
        vm.stopPrank();

        assertEq(amountOut, 2 ether);
        assertEq(usdc.balanceOf(user), 2 ether);
        assertEq(playerToken.balanceOf(user), 0);
    }

    function test_sellToToken_revertsPlayerAsOutput() public {
        vm.expectRevert(Errors.InvalidPath.selector);
        router.sellToToken(address(playerToken), address(playerToken), 1 ether, 0, block.timestamp + 1, hex"00");
    }

    function test_sellToToken_revertsEthAsOutput() public {
        vm.expectRevert(Errors.InvalidPath.selector);
        router.sellToToken(address(playerToken), address(0), 1 ether, 0, block.timestamp + 1, hex"00");
    }

    function test_sellToToken_revertsEmptyCalldata() public {
        vm.expectRevert(Errors.InvalidPath.selector);
        router.sellToToken(address(playerToken), address(usdc), 1 ether, 0, block.timestamp + 1, "");
    }

    function test_sellToToken_revertsSlippage() public {
        vm.prank(user);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);

        bytes memory zCall = abi.encodeCall(MockZRouter.swapFromEth, (address(usdc), user));

        vm.startPrank(user);
        playerToken.approve(address(router), 1 ether);
        vm.expectRevert(Errors.Slippage.selector);
        router.sellToToken(address(playerToken), address(usdc), 1 ether, 1 ether + 1, block.timestamp + 1, zCall);
        vm.stopPrank();
    }

    function test_sellToToken_refundsUnusedEth() public {
        vm.prank(user);
        router.buy{ value: 1 ether }(address(playerToken), 0, block.timestamp + 1);

        DustZRouter dust = new DustZRouter();
        ap.setName(Addresses.Z_ROUTER, address(dust));

        bytes memory zCall = abi.encodeCall(DustZRouter.swapKeepDust, (address(usdc), user, 0.1 ether));

        uint256 ethBefore = user.balance;
        vm.startPrank(user);
        playerToken.approve(address(router), 1 ether);
        uint256 amountOut =
            router.sellToToken(address(playerToken), address(usdc), 1 ether, 0, block.timestamp + 1, zCall);
        vm.stopPrank();

        assertEq(amountOut, 0.1 ether);
        assertEq(usdc.balanceOf(user), 0.1 ether);
        // Player→ETH produced 1 ETH; zRouter spent 0.1 and returned 0.9; TradeRouter refunds 0.9.
        assertEq(user.balance, ethBefore + 0.9 ether);
        assertEq(address(router).balance, 0);
    }

    function test_constructor_revertsZeroPoolManager() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new TradeRouter(address(ap), address(0));
    }
}

/// @dev Spends only `spend` of msg.value, mints that much tokenOut, returns the rest to caller.
contract DustZRouter {
    function swapKeepDust(address tokenOut, address to, uint256 spend) external payable {
        require(msg.value >= spend, "value");
        MockPlayerToken(tokenOut).mint(to, spend);
        uint256 leftover = msg.value - spend;
        if (leftover != 0) {
            (bool ok,) = msg.sender.call{ value: leftover }("");
            require(ok, "refund");
        }
    }
}
