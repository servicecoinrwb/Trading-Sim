// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TradingGame (Base Ready)
 * @dev A smart contract for a trading simulation game, configured for Base blockchain.
 * To deploy on Base:
 * 1. Compile with Solidity ^0.8.20.
 * 2. Deploy to Base Mainnet or Base Sepolia (for testing).
 * 3. Set the oracle address to a trusted price feed provider. For Base, find Chainlink addresses at:
 * https://docs.chain.link/data-feeds/price-feeds/addresses?network=base
 */
contract TradingGame {

    // --- State Variables ---

    address public owner;
    address public oracle;

    uint256 private constant INITIAL_BALANCE = 10000 * 10**18; // 10,000 virtual USD with 18 decimals

    struct Trade {
        uint256 id;
        bool isActive;
        bool isLong; // true for long, false for short
        uint256 entryPrice;
        uint256 takeProfit;
        uint256 stopLoss;
        uint256 margin; // The amount of virtual balance used
        uint256 leverage;
        bool manualCloseRequested; // NEW: Flag for manual closure
    }

    mapping(address => uint256) public virtualBalances;
    mapping(address => Trade) public activeTrades;
    
    uint256 public tradeCounter;

    // --- Events ---

    event TradeOpened(address indexed player, uint256 tradeId, bool isLong, uint256 entryPrice, uint256 leverage);
    event TradeClosed(address indexed player, uint256 tradeId, string reason);
    event TradeResolved(address indexed player, uint256 tradeId, int256 pnl, uint256 newBalance);

    // --- Modifiers ---

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function.");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "Only the oracle can call this function.");
        _;
    }

    // --- Functions ---

    constructor() {
        owner = msg.sender;
        oracle = msg.sender; // Owner is the oracle by default, can be changed
    }

    /**
     * @dev Allows a new player to register and get an initial virtual balance.
     */
    function register() public {
        require(virtualBalances[msg.sender] == 0, "Player already registered.");
        virtualBalances[msg.sender] = INITIAL_BALANCE;
    }

    /**
     * @dev Sets a new address for the price oracle.
     */
    function setOracle(address _newOracle) public onlyOwner {
        oracle = _newOracle;
    }

    /**
     * @dev Allows a player to open a new trade if they don't have one already.
     */
    function openTrade(bool _isLong, uint256 _margin, uint256 _leverage, uint256 _entryPrice, uint256 _takeProfit, uint256 _stopLoss) public {
        require(virtualBalances[msg.sender] > 0, "Player not registered.");
        require(!activeTrades[msg.sender].isActive, "Player already has an active trade.");
        require(_margin > 0 && _margin <= virtualBalances[msg.sender], "Insufficient margin.");
        require(_leverage > 0 && _leverage <= 500, "Invalid leverage.");

        tradeCounter++;
        activeTrades[msg.sender] = Trade({
            id: tradeCounter,
            isActive: true,
            isLong: _isLong,
            entryPrice: _entryPrice,
            takeProfit: _takeProfit,
            stopLoss: _stopLoss,
            margin: _margin,
            leverage: _leverage,
            manualCloseRequested: false // Initialize as false
        });

        emit TradeOpened(msg.sender, tradeCounter, _isLong, _entryPrice, _leverage);
    }
    
    /**
     * @dev NEW: Allows a player to request to close their active trade.
     * The oracle will finalize the closure at the next price update.
     */
    function closeTrade() public {
        Trade storage trade = activeTrades[msg.sender];
        require(trade.isActive, "No active trade to close.");
        require(!trade.manualCloseRequested, "Close already requested.");

        trade.manualCloseRequested = true;
        emit TradeClosed(msg.sender, trade.id, "Manual close requested");
    }

    /**
     * @dev Called by the oracle to update the price and resolve any trades that have hit SL/TP or requested manual close.
     */
    function resolveTrade(address _player, uint256 _currentPrice) public onlyOracle {
        Trade storage trade = activeTrades[_player];
        require(trade.isActive, "No active trade for this player.");

        uint256 exitPrice = 0;
        string memory reason = "";

        if (trade.isLong) {
            if (_currentPrice >= trade.takeProfit) {
                exitPrice = trade.takeProfit;
                reason = "Take Profit";
            } else if (_currentPrice <= trade.stopLoss) {
                exitPrice = trade.stopLoss;
                reason = "Stop Loss";
            }
        } else { // Short
            if (_currentPrice <= trade.takeProfit) {
                exitPrice = trade.takeProfit;
                reason = "Take Profit";
            } else if (_currentPrice >= trade.stopLoss) {
                exitPrice = trade.stopLoss;
                reason = "Stop Loss";
            }
        }

        // A manual close request overrides and closes at the current price
        if (trade.manualCloseRequested) {
            exitPrice = _currentPrice;
            reason = "Manual Close";
        }

        if (exitPrice > 0) {
            // Calculate PnL with 18 decimals of precision
            int256 priceDifference = int256(exitPrice) - int256(trade.entryPrice);
            if (!trade.isLong) {
                priceDifference = -priceDifference;
            }
            
            // PnL = (priceDifference / entryPrice) * margin * leverage
            int256 pnl = (priceDifference * 10**18 / int256(trade.entryPrice)) * int256(trade.margin) * int256(trade.leverage) / 10**18;

            if (pnl > 0) {
                virtualBalances[_player] += uint256(pnl);
            } else {
                uint256 loss = uint256(-pnl);
                if (loss > virtualBalances[_player]) {
                    virtualBalances[_player] = 0;
                } else {
                    virtualBalances[_player] -= loss;
                }
            }
            
            delete activeTrades[_player];
            emit TradeResolved(_player, trade.id, pnl, virtualBalances[_player]);
        }
    }
}

