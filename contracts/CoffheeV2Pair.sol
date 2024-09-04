// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.8.19;

import './CoffheeV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/ICoffheeV2Factory.sol';
import './interfaces/ICoffheeV2Callee.sol';

import "@fhenixprotocol/contracts/FHE.sol";
import {Permissioned, Permission} from "@fhenixprotocol/contracts/access/Permissioned.sol";
import { FHE } from "@fhenixprotocol/contracts/FHE.sol";
import { FHERC20 } from "./FHERC20.sol";
import { IFHERC20 } from "./interfaces/IFHERC20.sol";

//This is based on the Uniswap V2
interface IMigrator {
    // Return the desired amount of liquidity token that the migrator wants.
    function desiredLiquidity() external view returns (uint256);
}

contract CoffheeV2Pair is CoffheeV2ERC20, Permissioned, FHERC20 {
    using SafeMathCoffhee  for uint;
    using UQ112x112 for uint224;

    euint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    euint112 private reserve0;           // uses single storage slot, accessible via getReserves
    euint112 private reserve1;           // uses single storage slot, accessible via getReserves
    euint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    euint public price0CumulativeLast;
    euint public price1CumulativeLast;
    euint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    euint32 public swapFee = 25; // uses 0.25% default
    euint32 public devFee = 5; // uses 0.05% default from swap fee

    euint private unlocked = 1;

    modifier lock() {
        require(unlocked == 1, 'CoffheeV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (euint112 _reserve0, euint112 _reserve1, euint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, euint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'CoffheeV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, euint amount0, euint amount1);
    event Burn(address indexed sender, euint amount0, euint amount1, address indexed to);
    event Swap(
        address indexed sender,
        euint amount0In,
        euint amount1In,
        euint amount0Out,
        euint amount1Out,
        address indexed to
    );
    event Sync(euint112 reserve0, euint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'CoffheeV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    function setSwapFee(uint32 _swapFee) external {
        require(_swapFee > 0, "CoffheeV2: lower then 0");
        require(msg.sender == factory, 'CoffheeV2: FORBIDDEN');
        require(_swapFee <= 1000, 'CoffheeV2: FORBIDDEN_FEE');
        swapFee = _swapFee;
    }
    
    function setDevFee(uint32 _devFee) external {
        require(_devFee > 0, "CoffheeV2: lower then 0");
        require(msg.sender == factory, 'CoffheeV2: FORBIDDEN');
        require(_devFee <= 500, 'CoffheeV2: FORBIDDEN_FEE');
        devFee = _devFee;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(euint balance0, euint balance1, euint112 _reserve0, euint112 _reserve1) private {
        require(balance0 <= euint112(-1) && balance1 <= euint112(-1), 'CoffheeV2: OVERFLOW');
        euint32 blockTimestamp = euint32(block.timestamp % 2**32);
        euint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += euint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += euint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = euint112(balance0);
        reserve1 = euint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/5th of the growth in sqrt(k)
    function _mintFee(euint112 _reserve0, euint112 _reserve1) private returns (bool feeOn) {
        address feeTo = ICoffheeV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        euint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                euint rootK = Math.sqrt(euint(_reserve0).mul(_reserve1));
                euint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    euint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    euint denominator = rootK.mul(devFee).add(rootKLast);
                    euint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (// https://eips.ethereum.org/EIPS/eip-173
    // https://github.com/0xcert/ethereum-erc721/blob/master/src/contracts/ownership/ownable.sol (this example)
    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol
    // https://github.com/FriendlyUser/solidity-smart-contracts//blob/v0.2.0/contracts/other/CredVert/Ownable.sol
    // SPDX-License-Identifier: MIT
    pragma solidity >=0.5.0 <0.9.0;
    
    /**
     * @dev The contract has an owner address, and provides basic authorization control which
     * simplifies the implementation of user permissions. This contract is based on the source code at:
     * https://github.com/OpenZeppelin/openzeppelin-solidity/blob/master/contracts/ownership/Ownable.sol
     */
    contract Ownable
    {
    
      /**
       * @dev Error constants.
       */
      string public constant NOT_CURRENT_OWNER = "018001";
      string public constant CANNOT_TRANSFER_TO_ZERO_ADDRESS = "018002";
    
      /**
       * @dev Current owner address.
       */
      address public owner;
    
      /**
       * @dev An event which is triggered when the owner is changed.
       * @param previousOwner The address of the previous owner.
       * @param newOwner The address of the new owner.
       */
      event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
      );
    
      /**
       * @dev The constructor sets the original `owner` of the contract to the sender account.
       */
      constructor()
        public
      {
        owner = msg.sender;
      }
    
      /**
       * @dev Throws if called by any account other than the owner.
       */
      modifier onlyOwner()
      {
        require(msg.sender == owner, NOT_CURRENT_OWNER);
        _;
      }
    
      /**
       * @dev Allows the current owner to transfer control of the contract to a newOwner.
       * @param _newOwner The address to transfer ownership to.
       */
      function transferOwnership(
        address _newOwner
      )
        public
        onlyOwner
      {
        require(_newOwner != address(0), CANNOT_TRANSFER_TO_ZERO_ADDRESS);
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
      }
    
    }uint liquidity) {
        (euint112 _reserve0, euint112 _reserve1,) = getReserves(); // gas savings
        euint balance0 = IERC20Jackrabbit(token0).balanceOf(address(this));
        euint balance1 = IERC20Jackrabbit(token1).balanceOf(address(this));
        euint amount0 = balance0.sub(_reserve0);
        euint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            address migrator = ICoffheeV2Factory(factory).migrator();
            if (msg.sender == migrator) {
                liquidity = IMigrator(migrator).desiredLiquidity();
                require(liquidity > 0 && liquidity != uint256(-1), "Bad desired liquidity");
            } else {
                require(migrator == address(0), "Must not have migrator");
                liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
                _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
            }
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'CoffheeV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        inEuint balance0 = IERC20Coffhee(_token0).balanceOf(address(this));
        inEuint balance1 = IERC20Coffhee(_token1).balanceOf(address(this));
        inEuint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        inEuint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'CoffheeV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20Coffhee(_token0).balanceOf(address(this));
        balance1 = IERC20Coffhee(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'CoffheeV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (euint112 _reserve0, euint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'CoffheeV2: INSUFFICIENT_LIQUIDITY');

        euint balance0;
        euint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'CoffheeV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) ICoffheeV2Callee(to).CoffheeV2Call(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20Coffhee(_token0).balanceOf(address(this));
        balance1 = IERC20Coffhee(_token1).balanceOf(address(this));
        }
        euint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        euint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'CoffheeV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        euint _swapFee = swapFee;
        euint balance0Adjusted = balance0.mul(10000).sub(amount0In.mul(_swapFee));
        euint balance1Adjusted = balance1.mul(10000).sub(amount1In.mul(_swapFee));

        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(10000**2), 'CoffheeV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20Coffhee(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20Coffhee(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20Coffhee(token0).balanceOf(address(this)), IERC20Coffhee(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
