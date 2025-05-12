// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
contract Rlp is ERC20{
    address public pool;
    constructor(string memory name , string memory symbol) ERC20(name, symbol){
        pool = msg.sender;
    }
    modifier onlyPool() { 
        require(msg.sender == pool, "Only pool can call");
        _;
    }

    function mint(address to, uint256 amount) external onlyPool  {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}
contract perp is AutomationCompatibleInterface, Ownable{
    uint256 public lastTimeStamp;
    uint256 public interval;
    uint256 public counter;

    uint256 public constant MAX_LOSS_PERCENT = 80;
    address constant CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    uint256 public constant DEAD_SHARES = 1000;

    address[] public traders;
    AggregatorV3Interface public immutable priceFeed;
    IERC20 public immutable token;    
    Rlp public immutable lpToken;
    uint256 public totalLiquidity;
    struct Position {
        bool isLong;
        uint256 size;
        uint256 entryPrice;
        uint256 marginEth;

    }

    mapping(address => Position) public positions;
    mapping(address => uint256) public collateral;

    uint256 public constant leverage = 10;

    event PositionOpened(address indexed user, bool isLong, uint256 sizeUsd, uint256 entryPrice);
    event PositionClosed(address indexed user, int256 pnlUsd, uint256 closePrice);
    event MarginDeposited(address indexed user, uint256 amount);
    event MarginWithdrawn(address indexed user, uint256 amount);
    event liquidityAdded(address indexed user, uint256 amount);
    event liquidityRemoved(address indexed user, uint256 amount);

    constructor(address _token,uint256 _interval) Ownable(msg.sender){
        priceFeed = AggregatorV3Interface(CHAINLINK_ETH_USD);
        token = IERC20(_token);
        lpToken = new Rlp("Rlp", "RLP");
        interval = _interval;
        lastTimeStamp = block.timestamp;
        counter = 0;
    }

    function addLiquidity(uint256 amount) payable external returns (uint256 lpAmount){
        require(amount > 0, "Cannot deposit zero");
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        uint256 supply = lpToken.totalSupply();
         if (supply == 0 || totalLiquidity == 0) {
            require(amount>DEAD_SHARES);
            lpAmount = amount;
            lpToken.mint(address(0),DEAD_SHARES);
            lpAmount -= DEAD_SHARES;
        } else {
            lpAmount = (amount * supply) / totalLiquidity;
        }
        totalLiquidity += amount;
        lpToken.mint(msg.sender,lpAmount);
        emit liquidityAdded(msg.sender,amount);
    }

    function RemoveLiquidity(uint256 lpAmount) external {
        require(lpAmount > 0, "Invalid amount");
        uint256 share = (lpAmount * totalLiquidity) / (lpToken.totalSupply());

        totalLiquidity -= share;
        lpToken.burn(msg.sender, lpAmount);
        require(token.transfer(msg.sender, share));
        emit liquidityRemoved(msg.sender,lpAmount);
    }

    function openPosition(bool isLong, uint256 size) external{
        require(size>0,"invalid size");
        require(positions[msg.sender].size ==0 ,"close existing positions");

        uint256 price = getLatestPrice();
        uint256 requiredMarginEth = (size * 1e18)/leverage/price;

        require(collateral[msg.sender] >= requiredMarginEth, "Not enough margin");

          positions[msg.sender] = Position({
            isLong: isLong,
            size: size,
            entryPrice: price,
            marginEth: requiredMarginEth
        });

        collateral[msg.sender] -= requiredMarginEth;
        traders.push(msg.sender);
        emit PositionOpened(msg.sender, isLong, size, price);
    }
    
    function closePosition() external {
        Position memory pos = positions[msg.sender];
        require(pos.size > 0, "No open position");
        uint256 currentPrice = getLatestPrice();
        int256 pnl = _calculatePnL(pos,currentPrice);
        int256 pnlEth = (pnl * 1e18) / int256(currentPrice);
        uint256 finalMargin;
        if(pnl>=0){
            finalMargin= pos.marginEth+uint256(pnlEth);
        }
        else{
            uint256 lossEth = uint256(-pnlEth);
            require(pos.marginEth > lossEth, "Position liquidated");
            finalMargin = pos.marginEth - lossEth;
        }
        collateral[msg.sender] += finalMargin;
        delete positions[msg.sender];
       _removeTrader(msg.sender);
        emit PositionClosed(msg.sender, pnl, currentPrice);

    }

    function depositMargin() external payable {
        require(msg.value > 0, "Zero deposit");
        collateral[msg.sender] += msg.value;
        emit MarginDeposited(msg.sender, msg.value);
    }

    function withdrawMargin(uint256 amount) external {
        require(collateral[msg.sender] >= amount, "Insufficient collateral");
        collateral[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
        emit MarginWithdrawn(msg.sender, amount);
    }

    function checkUpkeep(bytes calldata /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
       if (block.timestamp - lastTimeStamp < interval) {
        return (false, "");
        }
        uint256 price = getLatestPrice();
        uint256 len = traders.length;

        for (uint256 i = 0; i < len; i++) {
            address trader = traders[i];
            Position memory pos = positions[trader];

            int256 pnl = _calculatePnL(pos, price);
            if (_lossPercentage(pos, pnl) >= MAX_LOSS_PERCENT) {
                upkeepNeeded = true;
                performData = abi.encode(trader);
                return (true, performData);
            }
        }
    }

    function performUpkeep(bytes calldata performData) external override {
        address trader = abi.decode(performData, (address));
        Position memory pos = positions[trader];

        uint256 price = getLatestPrice();
        int256 pnl = _calculatePnL(pos, price);
        uint256 lossPct = _lossPercentage(pos, pnl);
        require(lossPct >= MAX_LOSS_PERCENT, "Not enough loss");
        uint256 lossEth = (uint256(-pnl) * 1e18) / price;
        if (pos.marginEth > lossEth) {
        collateral[trader] += pos.marginEth - lossEth;
         }
        delete positions[trader];
        _removeTrader(trader);
    }

    function _removeTrader(address trader) internal {
        uint256 len = traders.length;
        for (uint256 i = 0; i < len; i++) {
            if (traders[i] == trader) {
                traders[i] = traders[len - 1]; // move last to deleted slot
                traders.pop(); // remove last
                break;
            }
        }
    }

    function _lossPercentage(Position memory pos, int256 pnl) internal pure returns (uint256) {
        if (pnl >= 0) return 0;
        uint256 loss = uint256(-pnl);
        uint256 marginUsd = (pos.marginEth * pos.entryPrice) / 1e18; // Margin in USD
        return (loss * 100) / marginUsd;
    }

    function _calculatePnL(Position memory pos, uint256 currentPrice) internal pure returns (int256) {
        if (pos.isLong) {
            return int256(pos.size)*(int256(currentPrice)-int256(pos.entryPrice))/int256(pos.entryPrice);
        } else {
            return  int256(pos.size) * (int256(pos.entryPrice) - int256(currentPrice)) / int256(pos.entryPrice);
        }
    }

    function getLatestPrice() public view returns(uint256 ){
        (,int256 answer,,,)= priceFeed.latestRoundData();
        require(answer > 0, "Invalid price");
        return uint256(answer) * 1e10;
    }

    function getCollateral(address user) external view returns (uint256) {
        return collateral[user];
    }

    function getPosition(address user) external view returns (Position memory) {
        return positions[user];
    }
}