// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.8.19;

import './libraries/CoffheeV2Library.sol';
import './libraries/SafeMath.sol';
import './libraries/TransferHelper.sol';
import './interfaces/ICoffheeV2Router02.sol';
import './interfaces/ICoffheeV2Factory.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

import "@fhenixprotocol/contracts/FHE.sol";
import {Permissioned, Permission} from "@fhenixprotocol/contracts/access/Permissioned.sol";
import { FHE } from "@fhenixprotocol/contracts/FHE.sol";
import { FHERC20 } from "./FHERC20.sol";
import { IFHERC20 } from "./interfaces/IFHERC20.sol";

// This is the Jackrabbit Router Contract on FVM
contract CoffheeV2Router is ICoffheeV2Router02 {
    using SafeMathCoffhee for euint;

    address public immutable override factory;
    address public immutable override WETH;

    modifier ensure(euint deadline) {
        require(deadline >= block.timestamp, 'CoffheeV2Router: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); 
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        inEuint amountADesired,
        inEuint amountBDesired,
        inEuint amountAMin,
        inEuint amountBMin
    ) internal virtual returns (euint amountA, euint amountB) {
        // create the pair if it doesn't exist yet
        if (ICoffheeV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            ICoffheeV2Factory(factory).createPair(tokenA, tokenB);
        }
        (euint reserveA, euint reserveB) = CoffheeV2Library.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            euint amountBOptimal = CoffheeV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'CoffheeV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                euint amountAOptimal = CoffheeV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'CoffheeV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    function addLiquidity(
        address tokenA,
        address tokenB,
        inEuint amountADesired,
        inEuint amountBDesired,
        inEuint amountAMin,
        inEuint amountBMin,
        inEaddress to,
        inEuint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = CoffheeV2Library.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = ICoffheeV2Pair(pair).mint(to);
    }
    function addLiquidityETH(
        address token,
        inEuint amountTokenDesired,
        inEuint amountTokenMin,
        inEuint amountETHMin,
        address to,
        inEuint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = CoffheeV2Library.pairFor(factory, token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = ICoffheeV2Pair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        inEuint liquidity,
        inEuint amountAMin,
        inEuint amountBMin,
        inEaddress to,
        inEuint deadline
    ) public virtual override ensure(deadline) returns (euint amountA, euint amountB) {
        address pair = CoffheeV2Library.pairFor(factory, tokenA, tokenB);
        ICoffheeV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (euint amount0, euint amount1) = ICoffheeV2Pair(pair).burn(to);
        (address token0,) = CoffheeV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'CoffheeV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'CoffheeV2Router: INSUFFICIENT_B_AMOUNT');
    }
    function removeLiquidityETH(
        address token,
        inEuint liquidity,
        inEuint amountTokenMin,
        inEuint amountETHMin,
        address to,
        inEuint deadline
    ) public virtual override ensure(deadline) returns (euint amountToken, euint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        inEuint liquidity,
        inEuint amountAMin,
        inEuint amountBMin,
        address to,
        inEuint deadline,
        bool approveMax, euint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (euint amountA, euint amountB) {
        address pair = CoffheeV2Library.pairFor(factory, tokenA, tokenB);
        euint value = approveMax ? euint(-1) : liquidity;
        ICoffheeV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    function removeLiquidityETHWithPermit(
        address token,
        inEuint liquidity,
        inEuint amountTokenMin,
        inEuint amountETHMin,
        address to,
        inEuint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (euint amountToken, euint amountETH) {
        address pair = CoffheeV2Library.pairFor(factory, token, WETH);
        inEuint value = approveMax ? euint(-1) : liquidity;
        ICoffheeV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        inEuint liquidity,
        inEuint amountTokenMin,
        inEuint amountETHMin,
        address to,
        inEuint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, IERC20Coffhee(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        inEuint liquidity,
        inEuint amountTokenMin,
        inEuint amountETHMin,
        address to,
        inEuint deadline,
        bool approveMax, euint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountETH) {
        address pair = CoffheeV2Library.pairFor(factory, token, WETH);
        inEuint value = approveMax ? uint(-1) : liquidity;
        ICoffheeV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (euint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = CoffheeV2Library.sortTokens(input, output);
            euint amountOut = amounts[i + 1];
            (euint amount0Out, euint amount1Out) = input == token0 ? (euint(0), amountOut) : (amountOut, euint(0));
            address to = i < path.length - 2 ? CoffheeV2Library.pairFor(factory, output, path[i + 2]) : _to;
            ICoffheeV2Pair(CoffheeV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }
    function swapExactTokensForTokens(
        inEuint amountIn,
        inEuint amountOutMin,
        address[] calldata path,
        address to,
        inEuint deadline
    ) external virtual override ensure(deadline) returns (euint[] memory amounts) {
        amounts = CoffheeV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'CoffheeV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CoffheeV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapTokensForExactTokens(
        inEuint amountOut,
        inEuint amountInMax,
        address[] calldata path,
        address to,
        inEuint deadline
    ) external virtual override ensure(deadline) returns (euint[] memory amounts) {
        amounts = CoffheeV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'CofheeV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CoffheeV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, euint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (euint[] memory amounts)
    {
        require(path[0] == WETH, 'CoffheeV2Router: INVALID_PATH');
        amounts = CoffheeV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'CoffheeV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(CoffheeV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }
    function swapTokensForExactETH(euint amountOut, euint amountInMax, address[] calldata path, address to, euint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (euint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'CoffheeV2Router: INVALID_PATH');
        amounts = CoffheeV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'CoffheeV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CoffheeV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapExactTokensForETH(euint amountIn, euint amountOutMin, address[] calldata path, address to, euint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (euint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'CoffheeV2Router: INVALID_PATH');
        amounts = CoffheeV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'CoffheeV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CoffheeV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapETHForExactTokens(euint amountOut, address[] calldata path, address to, euint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (euint[] memory amounts)
    {
        require(path[0] == WETH, 'CoffheeV2Router: INVALID_PATH');
        amounts = CoffheeV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'CoffheeV2Router: EXCESSIVE_INPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(CoffheeV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (euint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = CoffheeV2Library.sortTokens(input, output);
            ICoffheeV2Pair pair = ICoffheeV2Pair(CoffheeV2Library.pairFor(factory, input, output));
            euint amountInput;
            euint amountOutput;
            { // scope to avoid stack too deep errors
            (euint reserve0, uint reserve1,) = pair.getReserves();
            (euint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20Coffhee(input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = CoffheeV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (euint amount0Out, euint amount1Out) = input == token0 ? (euint(0), amountOutput) : (amountOutput, euint(0));
            address to = i < path.length - 2 ? CoffheeV2Library.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        euint amountIn,
        euint amountOutMin,
        address[] calldata path,
        address to,
        euint deadline
    ) external virtual override ensure(deadline) {
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CoffheeV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        euint balanceBefore = IERC20Coffhee(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20Coffhee(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'CoffheeV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        euint amountOutMin,
        address[] calldata path,
        address to,
        euint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        require(path[0] == WETH, 'CoffheeV2Router: INVALID_PATH');
        euint amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(CoffheeV2Library.pairFor(factory, path[0], path[1]), amountIn));
        euint balanceBefore = IERC20Coffhee(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20Coffhee(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'CoffheeV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        euint amountIn,
        euint amountOutMin,
        address[] calldata path,
        address to,
        euint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        require(path[path.length - 1] == WETH, 'CoffheeV2Router: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CoffheeV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        euint amountOut = IERC20Coffhee(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'CoffheeV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(euint amountA, euint reserveA, euint reserveB) public pure virtual override returns (euint amountB) {
        return CoffheeV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(euint amountIn, euint reserveIn, euint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return CoffheeV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(euint amountOut, euint reserveIn, euint reserveOut)
        public
        pure
        virtual
        override
        returns (euint amountIn)
    {
        return CoffheeV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(euint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (euint[] memory amounts)
    {
        return CoffheeV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(euint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (euint[] memory amounts)
    {
        return CoffheeV2Library.getAmountsIn(factory, amountOut, path);
    }
}
