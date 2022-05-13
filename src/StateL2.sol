// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./interfaces/IERC20.sol";
import "./test/Console.sol";

// Optimizes heavily to reduce calldata
contract StateL2 {
    struct PartialReceipt {
        uint64 bIndex;
        uint128 amount;
        uint32 expiresBy;
        bytes aSignature;
        bytes bSignature;
    }

    struct Account {
        // Current account balance
        uint128 balance;
        // This is the latest of all update time 
        uint32 withdrawAfter;
    }

    struct Record {
        // Latest update amount
        uint128 amount;
        // Latest sequence no.
        uint16 seqNo;
        // Time after which update corresponding to this record will finalise
        uint32 fixedAfter;
        // Flag of whether `a` was slashed for overspending
        bool slashed;
    }

    mapping(uint64 => address) public addresses;
    mapping(address => uint64) public addressesReverse;

    mapping(address => Account) accounts;
    mapping(bytes32 => Record) public records;
    mapping(address => uint256) public slashAmounts;
    mapping(address => uint256) public securityDeposits;

    // slashing amount = 1 Unit
    uint256 constant slashValue = 1e18;
    uint32 constant bufferPeriod = uint32(7 days);
    address immutable token;

    uint64 public userCount;
    uint256 reserves;

    uint256 constant ECDSA_SIGNATURE_LENGTH = 65;

    constructor(address _token) {
        token = _token;
    }

    function recordKey(address aAddress, address bAddress)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(aAddress, bAddress));
    }

    function register(address user) public {
        if (addressesReverse[user] != 0) {
            // already registered
            revert();
        }

        uint64 c = userCount;
        c += 1;
        addresses[c] = user;
        addressesReverse[user] = c;
        userCount = c;
    }

    function getTokenBalance(address user) internal view returns(uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, user));
        if (!success || data.length != 32){
            // revert with balance error
            revert();
        }
        return abi.decode(data, (uint256));
    }

    function getUpdateAtIndex(uint256 i) internal pure returns (PartialReceipt memory r){
        // 8 bytes
        uint64 bIndex;
        // 16 bytes
        uint128 amount;
        // 4 bytes
        uint32 expiresBy;
        // 65 bytes
        bytes memory aSignature = new bytes(65);
        // 65 bytes
        bytes memory bSignature = new bytes(65);

        uint256 offset = 14 + (i * 158);
        assembly {
            bIndex := shr(192, calldataload(offset))

            offset := add(offset, 8)
            amount := shr(128, calldataload(offset))

            // expiresBy 
            offset := add(offset, 16)
            expiresBy := shr(224, calldataload(offset))

            // aSignature
            offset := add(offset, 4)
            mstore(add(aSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,96), calldataload(offset))

            // bSignature
            offset := add(offset, 1)
            mstore(add(bSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,96), calldataload(offset))

        }

        r = PartialReceipt({
            bIndex: bIndex,
            amount: amount,
            expiresBy: expiresBy,
            aSignature: aSignature,
            bSignature: bSignature
        });
    }

    function receiptHash(
        address aAddress,
        address bAddress,
        uint128 amount,
        uint16 seqNo,
        uint32 expiresBy
    ) internal pure returns (bytes32){
        return keccak256(
            abi.encodePacked(
                aAddress,
                bAddress,
                amount,
                seqNo,
                expiresBy
            )
        );
    }

    function ecdsaRecover(bytes32 msgHash, bytes memory signature) internal pure returns (address signer) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (signature.length != ECDSA_SIGNATURE_LENGTH) {
            // Malformed ecdsa signature
            revert();
        }

        assembly {
            let offset := 32
            // r = encodedSignature[0:32]
            r := mload(offset)
            // s = encodedSignature[32:64]
            offset := add(offset, 32)
            s := mload(offset)
            // v = uint8(encodedSignature[64:64])
            offset := add(offset, 32)
            v := shr(248, mload(offset))
        }

        signer = ecrecover(msgHash, v, r, s);

        if (signer == address(0)) {
            // Invalid ecdsa signature
            revert();
        }
    }
    
    function post() external {
        uint64 aIndex;
        uint16 count;

        assembly {
            aIndex := shr(192, calldataload(4))
            count := shr(240, calldataload(add(4, 8)))
        }
        
        // a should have registered
        address aAddress = addresses[aIndex];
        if (aAddress == address(0)) {
            revert();
        }

        for (uint256 i = 0; i < count; i++) {
            PartialReceipt memory pR = getUpdateAtIndex(i);
            // console.logBytes(pR.aSignature);
            // console.logBytes(pR.bSignature);

            address bAddress = addresses[pR.bIndex];
            if (bAddress == address(0)){
                revert();
            }

            bytes32 rKey = recordKey(
                aAddress,
                bAddress
            );   
            Record memory record = records[rKey];

            // update record
            record.seqNo += 1;
            record.amount = pR.amount;
            record.fixedAfter = uint32(block.timestamp) + bufferPeriod;

            // validate signatures & expiresBy
            bytes32 rHash = receiptHash(aAddress, bAddress, pR.amount, record.seqNo, pR.expiresBy);
            if (
                ecdsaRecover(rHash, pR.aSignature) != aAddress ||
                ecdsaRecover(rHash, pR.bSignature) != bAddress ||
                pR.expiresBy <= block.timestamp
            ) {
                revert();
            }

            // update account objects
            Account memory aAccount = accounts[aAddress];
            if (aAccount.balance < pR.amount){
                // slashing of A
                pR.amount = aAccount.balance;
                aAccount.balance = 0;
                record.slashed = true;
            }else {
                aAccount.balance -= pR.amount;
                record.slashed = false;
            }
            Account memory bAccount = accounts[bAddress];
            bAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
            bAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
            bAccount.balance += pR.amount;
            
            accounts[aAddress] = aAccount;
            accounts[bAddress] = bAccount;

            // Check whether to slash `a`
            if (record.slashed) {
                slashAmounts[aAddress] += slashValue;
            }

            // store updated record    
            records[rKey] = record;
        }   

        // emit event     
    }

    function correctUpdate() external {
        uint64 aIndex;
        uint64 bIndex;
        uint128 newAmount;
        bytes memory aSignature = new bytes(65);
        bytes memory bSignature = new bytes(65);

        assembly {
            let offset := 4
            aIndex := shr(192, calldataload(offset))
            offset := add(offset, 8)
            bIndex := shr(192, calldataload(offset))
            offset := add(offset, 8)
            newAmount := shr(128, calldataload(offset))
            offset := add(offset, 16)
            
            // aSignature
            mstore(add(aSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,96), calldataload(offset))
            offset := add(offset, 1)

            // bSignature
            mstore(add(bSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,96), calldataload(offset))
        }

        address aAddress = addresses[aIndex];
        address bAddress = addresses[bIndex];

        bytes32 rKey = recordKey(aAddress, bAddress);
        Record memory record = records[rKey];

        // validate signatures
        // TODO: remove expiresBy
        bytes32 rHash = receiptHash(aAddress, bAddress, newAmount, record.seqNo, 0);
        if (
            ecdsaRecover(rHash, aSignature) != aAddress ||
            ecdsaRecover(rHash, bSignature) != bAddress ||
            // amount of latest `receipt` is always greater
            record.amount >= newAmount || 
            // cannot correct update after `fixedPeriod`
            record.fixedAfter <= block.timestamp
        ){
            revert();
        }

        // update account objects
        uint128 amountDiff = newAmount - record.amount;
        Account memory aAccount = accounts[aAddress];
        bool slashed;
        if (aAccount.balance < amountDiff) {
            amountDiff = aAccount.balance;
            aAccount.balance = 0;
            slashed = true;
        }else {
            aAccount.balance -= amountDiff;
        }
        Account memory bAccount = accounts[bAddress];
        bAccount.balance += amountDiff;
        aAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
        bAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
        accounts[aAddress] = aAccount;
        accounts[bAddress] = bAccount;

        // check whether `a` should be slashed
        // Note we are assumming that slash value is constant
        // irrespective of `amount` overcommitted, which is why 
        // `a` cannot be slashed twice for smae sequence no. 
        // If we switch to slashing being proportional
        // to `amount` then we will have to accomodate
        // for `amountDiff` here by scaling previous
        // slash amount.
        if (!record.slashed && slashed){
            slashAmounts[aAddress] += slashValue;
        }


        record.slashed = record.slashed || slashed;
        record.amount = newAmount;
        record.fixedAfter = uint32(block.timestamp) + bufferPeriod;
        records[rKey] = record;
    }
}