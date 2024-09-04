// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.8.19;

import './interfaces/ICoffheeV2Factory.sol';
import './CoffheeV2Pair.sol';

// Coffhee Factory Contract- on Fhenix
contract CoffheeV2Factory is ICoffheeV2Factory {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(CoffheeV2Pair).creationCode));
    address public override feeTo;
    address public override feeToSetter;
    address public override migrator;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external override view returns (uint) {
        return allPairs.length;
    }

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(CoffheeV2Pair).creationCode);
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, 'CoffheeV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'CoffheeV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'CoffheeV2: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(CoffheeV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        CoffheeV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, 'CoffheeV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setMigrator(address _migrator) external override {
        require(msg.sender == feeToSetter, 'CoffheeV2: FORBIDDEN');
        migrator = _migrator;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, 'CoffheeV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function setDevFee(address _pair, uint8 _devFee) external {
        require(msg.sender == feeToSetter, 'JackrabbitV2: FORBIDDEN');
        require(_devFee > 0, 'JackrabbitV2: FORBIDDEN_FEE');
        JackrabbitV2Pair(_pair).setDevFee(_devFee);
    }
    
    function setSwapFee(address _pair, uint32 _swapFee) external {
        require(msg.sender == feeToSetter, 'JackrabbitV2: FORBIDDEN');
        JackrabbitV2Pair(_pair).setSwapFee(_swapFee);
    }

}
