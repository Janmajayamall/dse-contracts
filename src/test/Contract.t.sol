// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "ds-test/test.sol";
import "./../State.sol";
import "./TestToken.sol";
import "./Vm.sol";
import "./Console.sol";

contract ContractTest is DSTest {
    State state;
    TestToken token;
    Vm vm;

    uint32 constant expiresBy = uint32(7 days);

    uint256 constant aPvKey = 0x084154b85f5eec02a721fcfe220e4e871a2c35593c2a46292ad53b8f793c8360;
    uint256 constant bPvKey = 0x831d7480b61ee56526758a07481b2a9118b31d0344555e60c1b834a74e67c2d9;
    uint256 constant cPvKey = 0xde852a66883fca2228e9204dab49836a36140b461971e2054336168ffaf1b5e9;
    uint256 constant dPvKey = 0xacc1d30d4404e1b3718806a041041d64ebab8d54dd251b381bfbbe61dac0c598;

    address aAddress;
    address bAddress;
    address cAddress;
    address dAddress;

    function setUp() public {
        vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        // set addresses
        aAddress = vm.addr(aPvKey);
        bAddress = vm.addr(bPvKey);
        cAddress = vm.addr(cPvKey);
        dAddress = vm.addr(dPvKey); 

        console.log(aAddress, "aAddress");
        console.log(bAddress, "bAddress");
        console.log(cAddress, "cAddress");
        console.log(dAddress, "dAddress");

        token = new TestToken(
            "TestToken",
            "TT",
            18
        );

        // mint tokens to `this`
        token.mint(address(this), type(uint256).max);
        state = new State(address(token));
    }

    function createReceipt(address a, address b, uint128 amount, uint16 seqNo) internal view returns (State.Receipt memory r) {
        r = State.Receipt({
            aAddress: a,
            bAddress: b,
            amount: amount,
            seqNo: seqNo,
            expiresBy: uint32(block.timestamp) + expiresBy
        });
    }

    function fundAccount(address to, uint256 amount) internal {
        // transfer token to `state`
        token.transfer(address(state), amount);
        
        // fund `to`'s account in `state`
        state.fundAccount(to);
    }

    function signMsg(bytes32 msgHash, uint256 pvKey) internal returns (bytes memory signature){
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pvKey, msgHash);
        signature = abi.encodePacked(r, s, v);
    }

    function receiptHash(State.Receipt memory receipt) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    receipt.aAddress,
                    receipt.bAddress,
                    receipt.seqNo,
                    receipt.amount,
                    receipt.expiresBy
                )
            );
    }

    function offChainTransferUpdate(uint128 incAmount, State.Receipt memory prevReceipt, bool incSeqNo, uint256 aPv, uint256 bPv) internal returns (State.Update memory update) {
        prevReceipt.amount += incAmount;
        prevReceipt.expiresBy = uint32(block.timestamp) + expiresBy;

        if (incSeqNo){
            prevReceipt.seqNo += 1;
        }

        bytes32 rHash = receiptHash(prevReceipt);

        // sign the hash
        bytes memory aSignature = signMsg(rHash, aPv);
        bytes memory bSignature = signMsg(rHash, bPv);

        update = State.Update({
            receipt: prevReceipt,
            aSignature: aSignature,
            bSignature: bSignature
        });
    }

    function printBalances() internal view {
        console.log("A balance", state.getAccount(aAddress).balance);
        console.log("B balance", state.getAccount(bAddress).balance);
        console.log("C balance", state.getAccount(cAddress).balance);
        console.log("D balance", state.getAccount(dAddress).balance);
    }

    function testExample() public {
        console.log("Balances Before");
        printBalances();

        // A is the service provider to B, C, D
        fundAccount(aAddress, 50 * 10 ** 18);
        
        // intial receipt
        State.Receipt memory rB = createReceipt(aAddress, bAddress, 0, 1);
        State.Receipt memory rC = createReceipt(aAddress, cAddress, 0, 1);
        State.Receipt memory rD = createReceipt(aAddress, dAddress, 0, 1);

        State.Update memory uB = offChainTransferUpdate(5 * 10 ** 18, rB, false, aPvKey, bPvKey);
        State.Update memory uC = offChainTransferUpdate(7 * 10 ** 18, rC, false, aPvKey, cPvKey);
        State.Update memory uD = offChainTransferUpdate(8 * 10 ** 18, rD, false, aPvKey, dPvKey);

        State.Update[] memory updates = new State.Update[](2);
        updates[0] = uB;
        updates[1] = uC;
        // updates[2] = uD;

        state.post(updates);
        console.log("State was updated");

        console.log("Balances Before");
        printBalances();
    }
}
