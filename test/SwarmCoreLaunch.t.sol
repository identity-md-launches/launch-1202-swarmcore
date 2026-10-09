// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SwarmCoreToken} from "../src/SwarmCoreToken.sol";
import {LaunchLiquidity} from "../src/LaunchLiquidity.sol";
import {PoolInitializationGuard} from "../src/PoolInitializationGuard.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Plays the launch factory: deploys the token (and so receives the supply), moves the
/// swarm share, opens the pool and seeds it from inside an unlock callback.
contract FactoryStandIn is IUnlockCallback {
    IPoolManager private manager;

    function deployToken() external returns (SwarmCoreToken) {
        return new SwarmCoreToken();
    }

    function deployGuard(IPoolManager manager_, bytes32 salt) external returns (PoolInitializationGuard) {
        return new PoolInitializationGuard{salt: salt}(address(manager_));
    }

    function move(SwarmCoreToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function initialize(IPoolManager manager_, PoolKey calldata key, uint160 price) external {
        manager_.initialize(key, price);
    }

    function seed(IPoolManager manager_, LaunchLiquidity.Seed calldata seed_) external {
        manager = manager_;
        manager_.unlock(abi.encode(seed_));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        LaunchLiquidity.settleSeed(manager, data);
        return "";
    }
}

/// @notice A plain ERC-20 standing in for the IMD pair token.
contract PairToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice An ordinary trader with no special standing.
contract Trader is IUnlockCallback {
    IPoolManager private immutable manager;
    PoolKey private key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key_, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amountSpecified)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        LaunchLiquidity.settle(manager, key.currency0, delta.amount0());
        LaunchLiquidity.settle(manager, key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

/// @notice The launch as the factory performs it, against a real Uniswap v4 PoolManager, with this
/// launch's terms: 10% to the distributor, 88% single-sided into a 1.25% / 60-spacing pool against
/// IMD opening at a 2,500 IMD cap, 2% to the requester.
contract SwarmCoreLaunchTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 8_800;
    uint256 constant MARKET_CAP = 2_500 ether;
    uint24 constant FEE = 12_500;
    int24 constant SPACING = 60;
    address constant REQUESTER = 0x6bF192eBEf135E0F645e99d59d9BF44E7711606c;

    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);

    PoolManager manager;
    FactoryStandIn factory;
    SwarmCoreToken token;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new FactoryStandIn();
        token = factory.deployToken();
    }

    function test_factoryHoldsTheWholeSupply() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The pair token sorts below the token.
    function test_launchAndTradeWithPairAsCurrency0() public {
        _launchAndTrade(address(0x0000000000000000000000000000000000001111));
    }

    /// @dev The pair token sorts above the token.
    function test_launchAndTradeWithPairAsCurrency1() public {
        _launchAndTrade(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF));
    }

    /// @dev The pair token at the real IMD address on Ethereum.
    function test_launchAndTradeAtImdAddress() public {
        _launchAndTrade(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    }

    function test_guardRefusesInitializationByAnyoneButTheLauncher() public {
        PoolKey memory key = _key(_etchPair(address(0x1111)), _guard());
        (uint160 price,,,) = _seedTerms(key);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(key.hooks),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(PoolInitializationGuard.NotLauncher.selector, address(this)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, price);

        factory.initialize(manager, key, price);
        (uint160 opened,,,) = _slot0(key);
        assertEq(opened, price);
    }

    function test_guardRefusesDirectCalls() public {
        PoolInitializationGuard guard = PoolInitializationGuard(address(_guard()));
        PoolKey memory key;
        vm.expectRevert(PoolInitializationGuard.NotPoolManager.selector);
        guard.beforeInitialize(address(factory), key, 0);
    }

    function test_seedFailsWithoutTheFunds() public {
        PoolKey memory key = _key(_etchPair(address(0x1111)), IHooks(address(0)));
        (uint160 price, int24 lower, int24 upper, uint128 liquidity) = _seedTerms(key);
        factory.initialize(manager, key, price);
        // The factory gives away 95% first, so it cannot pay for an 88% seed.
        factory.move(token, CLAIMANT, (SUPPLY * 9_500) / 10_000);
        vm.expectRevert();
        factory.seed(manager, LaunchLiquidity.Seed(key, lower, upper, liquidity));
    }

    function _launchAndTrade(address pairAt) private {
        address pair = _etchPair(pairAt);
        factory.move(token, DISTRIBUTOR, (SUPPLY * SWARM_BPS) / 10_000);

        PoolKey memory key = _key(pair, _guard());
        (uint160 price, int24 lower, int24 upper, uint128 liquidity) = _seedTerms(key);
        factory.initialize(manager, key, price);

        uint256 before = token.balanceOf(address(factory));
        factory.seed(manager, LaunchLiquidity.Seed(key, lower, upper, liquidity));
        uint256 taken = before - token.balanceOf(address(factory));
        uint256 allowed = (SUPPLY * POOL_BPS) / 10_000;
        assertGt(taken, (allowed * 9_999) / 10_000, "the seed took too little");
        assertLe(taken, allowed, "the seed took more than the pool share");
        assertEq(PairToken(pair).balanceOf(address(factory)), 0, "the seed was not single-sided");

        uint256 remainder = token.balanceOf(address(factory));
        factory.move(token, REQUESTER, remainder);
        assertEq(token.balanceOf(REQUESTER), remainder);
        assertEq(token.balanceOf(address(factory)), 0);

        Trader trader = new Trader(manager);
        PairToken(pair).mint(address(trader), 10 ether);
        bool pairIsZero = Currency.unwrap(key.currency0) == pair;

        trader.swap(key, pairIsZero, -0.01 ether);
        uint256 bought = token.balanceOf(address(trader));
        // 0.01 IMD at 2.5e-6 IMD per CORE is about 4,000 CORE before the 1.25% fee.
        assertGt(bought, 3_900 ether, "the buy returned too little");
        assertLt(bought, 4_000 ether, "the buy returned too much");

        trader.swap(key, !pairIsZero, -int256(bought));
        assertEq(token.balanceOf(address(trader)), 0, "the trader could not sell");
        assertGt(PairToken(pair).balanceOf(address(trader)), 9.99 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _etchPair(address at) private returns (address) {
        vm.etch(at, address(new PairToken()).code);
        return at;
    }

    function _guard() private returns (IHooks) {
        bytes32 initCode =
            keccak256(abi.encodePacked(type(PoolInitializationGuard).creationCode, abi.encode(address(manager))));
        for (uint256 i; i < 1_000_000; ++i) {
            address predicted = vm.computeCreate2Address(bytes32(i), initCode, address(factory));
            if (HookFlags.matches(predicted, HookFlags.BEFORE_INITIALIZE)) {
                return IHooks(address(factory.deployGuard(manager, bytes32(i))));
            }
        }
        revert("no guard salt found");
    }

    function _key(address pair, IHooks hooks) private view returns (PoolKey memory) {
        (Currency c0, Currency c1) = address(token) < pair
            ? (Currency.wrap(address(token)), Currency.wrap(pair))
            : (Currency.wrap(pair), Currency.wrap(address(token)));
        return PoolKey(c0, c1, FEE, SPACING, hooks);
    }

    /// @dev The opening price for a 2,500 IMD cap and a single-sided range holding only the token.
    function _seedTerms(PoolKey memory key)
        private
        view
        returns (uint160 price, int24 lower, int24 upper, uint128 liquidity)
    {
        uint256 amount = (SUPPLY * POOL_BPS) / 10_000;
        bool tokenIsZero = Currency.unwrap(key.currency0) == address(token);
        // v4 prices are currency1 per currency0, scaled by 2**192 before the square root.
        uint256 ratioX192 =
            tokenIsZero ? FullMath.mulDiv(MARKET_CAP, 1 << 192, SUPPLY) : FullMath.mulDiv(SUPPLY, 1 << 192, MARKET_CAP);
        price = uint160(_sqrt(ratioX192));
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        int24 floored = (tick / SPACING) * SPACING;
        if (tick < 0 && tick % SPACING != 0) floored -= SPACING;
        if (tokenIsZero) {
            lower = floored + SPACING;
            upper = TickMath.maxUsableTick(SPACING);
            uint160 a = TickMath.getSqrtPriceAtTick(lower);
            uint160 b = TickMath.getSqrtPriceAtTick(upper);
            liquidity = uint128(FullMath.mulDiv(amount, FullMath.mulDiv(a, b, 1 << 96), b - a));
        } else {
            lower = TickMath.minUsableTick(SPACING);
            upper = floored;
            uint160 a = TickMath.getSqrtPriceAtTick(lower);
            uint160 b = TickMath.getSqrtPriceAtTick(upper);
            liquidity = uint128(FullMath.mulDiv(amount, 1 << 96, b - a));
        }
    }

    function _slot0(PoolKey memory key) private view returns (uint160, int24, uint24, uint24) {
        bytes32 id = keccak256(abi.encode(key));
        bytes32 slot = keccak256(abi.encode(id, uint256(6)));
        uint256 word = uint256(manager.extsload(slot));
        return (uint160(word), int24(int256(word >> 160)), 0, 0);
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}
