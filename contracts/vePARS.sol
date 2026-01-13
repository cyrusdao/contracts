// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20, SafeERC20} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard} from "@luxfi/standard/utils/Utils.sol";
import {Ownable} from "@luxfi/standard/access/Access.sol";

/**
 * @title vePARS
 * @notice Vote-escrowed PARS - Curve-style voting escrow for PARS token
 *
 * Users lock PARS for up to 4 years to receive vePARS voting power.
 * Voting power decays linearly over the lock period.
 *
 * Features:
 * - Lock PARS for 1 week to 4 years
 * - Voting power = locked_amount * (time_remaining / max_time)
 * - Extend lock duration or increase locked amount
 * - Used for: PIP voting, gauge weight voting, fee distribution
 * - Non-transferable (soul-bound voting power)
 */
contract vePARS is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    uint256 public constant WEEK = 7 * 86400;
    uint256 public constant MAXTIME = 4 * 365 * 86400; // 4 years
    uint256 public constant MULTIPLIER = 10 ** 18;

    // ═══════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    struct LockedBalance {
        int128 amount;      // Locked PARS amount
        uint256 end;        // Lock end timestamp (rounded to week)
    }

    struct Point {
        int128 bias;        // Voting power bias
        int128 slope;       // Voting power decay slope
        uint256 ts;         // Timestamp
        uint256 blk;        // Block number
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice PARS token
    IERC20 public immutable pars;

    /// @notice Token name (for display)
    string public constant name = "Vote-escrowed PARS";
    string public constant symbol = "vePARS";
    uint8 public constant decimals = 18;

    /// @notice Total locked PARS
    uint256 public supply;

    /// @notice User locked balances
    mapping(address => LockedBalance) public locked;

    /// @notice Global point history
    uint256 public epoch;
    mapping(uint256 => Point) public pointHistory;

    /// @notice User point history: user => epoch => point
    mapping(address => mapping(uint256 => Point)) public userPointHistory;
    mapping(address => uint256) public userPointEpoch;

    /// @notice Slope changes at specific timestamps
    mapping(uint256 => int128) public slopeChanges;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 indexed locktime,
        int128 depositType,
        uint256 ts
    );
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error LockExpired();
    error NoExistingLock();
    error LockNotExpired();
    error NothingLocked();
    error InvalidLockTime();
    error CannotDecreaseLock();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address _pars, address _owner) Ownable(_owner) {
        pars = IERC20(_pars);

        // Initialize point history
        pointHistory[0] = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LOCK FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new lock
     * @param _value Amount of PARS to lock
     * @param _unlockTime Lock end time (rounded down to week)
     */
    function createLock(uint256 _value, uint256 _unlockTime) external nonReentrant {
        _unlockTime = (_unlockTime / WEEK) * WEEK; // Round down to week

        LockedBalance storage _locked = locked[msg.sender];
        if (_locked.amount != 0) revert NoExistingLock();
        if (_value == 0) revert NothingLocked();
        if (_unlockTime <= block.timestamp) revert InvalidLockTime();
        if (_unlockTime > block.timestamp + MAXTIME) revert InvalidLockTime();

        _depositFor(msg.sender, _value, _unlockTime, _locked, 1);
    }

    /**
     * @notice Increase locked amount
     * @param _value Additional PARS to lock
     */
    function increaseAmount(uint256 _value) external nonReentrant {
        LockedBalance storage _locked = locked[msg.sender];
        if (_locked.amount == 0) revert NoExistingLock();
        if (_locked.end <= block.timestamp) revert LockExpired();
        if (_value == 0) revert NothingLocked();

        _depositFor(msg.sender, _value, 0, _locked, 2);
    }

    /**
     * @notice Extend lock time
     * @param _unlockTime New lock end time
     */
    function increaseUnlockTime(uint256 _unlockTime) external nonReentrant {
        _unlockTime = (_unlockTime / WEEK) * WEEK;

        LockedBalance storage _locked = locked[msg.sender];
        if (_locked.amount == 0) revert NoExistingLock();
        if (_locked.end <= block.timestamp) revert LockExpired();
        if (_unlockTime <= _locked.end) revert CannotDecreaseLock();
        if (_unlockTime > block.timestamp + MAXTIME) revert InvalidLockTime();

        _depositFor(msg.sender, 0, _unlockTime, _locked, 3);
    }

    /**
     * @notice Withdraw all PARS after lock expires
     */
    function withdraw() external nonReentrant {
        LockedBalance storage _locked = locked[msg.sender];
        if (block.timestamp < _locked.end) revert LockNotExpired();

        uint256 value = uint256(int256(_locked.amount));
        if (value == 0) revert NothingLocked();

        LockedBalance memory oldLocked = _locked;
        _locked.end = 0;
        _locked.amount = 0;

        uint256 supplyBefore = supply;
        supply = supplyBefore - value;

        // Update point history
        _checkpoint(msg.sender, oldLocked, _locked);

        pars.safeTransfer(msg.sender, value);

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(supplyBefore, supply);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current voting power for user
     */
    function balanceOf(address addr) external view returns (uint256) {
        return _balanceOf(addr, block.timestamp);
    }

    /**
     * @notice Get voting power at specific timestamp
     */
    function balanceOfAt(address addr, uint256 _t) external view returns (uint256) {
        return _balanceOf(addr, _t);
    }

    /**
     * @notice Get total voting power
     */
    function totalSupply() external view returns (uint256) {
        return _totalSupply(block.timestamp);
    }

    /**
     * @notice Get total voting power at specific timestamp
     */
    function totalSupplyAt(uint256 _t) external view returns (uint256) {
        return _totalSupply(_t);
    }

    /**
     * @notice Get lock details for user
     */
    function getLocked(address addr) external view returns (int128 amount, uint256 end) {
        LockedBalance storage _locked = locked[addr];
        return (_locked.amount, _locked.end);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Internal deposit logic
     */
    function _depositFor(
        address _addr,
        uint256 _value,
        uint256 _unlockTime,
        LockedBalance storage _locked,
        int128 _type
    ) internal {
        uint256 supplyBefore = supply;
        supply = supplyBefore + _value;

        LockedBalance memory oldLocked = LockedBalance({
            amount: _locked.amount,
            end: _locked.end
        });

        // Adding to existing lock or creating new one
        _locked.amount += int128(int256(_value));
        if (_unlockTime != 0) {
            _locked.end = _unlockTime;
        }

        // Update point history
        _checkpoint(_addr, oldLocked, _locked);

        if (_value != 0) {
            pars.safeTransferFrom(msg.sender, address(this), _value);
        }

        emit Deposit(_addr, _value, _locked.end, _type, block.timestamp);
        emit Supply(supplyBefore, supply);
    }

    /**
     * @notice Record global and user checkpoints
     */
    function _checkpoint(
        address _addr,
        LockedBalance memory _oldLocked,
        LockedBalance storage _newLocked
    ) internal {
        Point memory uOld;
        Point memory uNew;
        int128 oldDSlope = 0;
        int128 newDSlope = 0;
        uint256 _epoch = epoch;

        if (_addr != address(0)) {
            // Calculate slopes and biases
            if (_oldLocked.end > block.timestamp && _oldLocked.amount > 0) {
                uOld.slope = _oldLocked.amount / int128(int256(MAXTIME));
                uOld.bias = uOld.slope * int128(int256(_oldLocked.end - block.timestamp));
            }
            if (_newLocked.end > block.timestamp && _newLocked.amount > 0) {
                uNew.slope = _newLocked.amount / int128(int256(MAXTIME));
                uNew.bias = uNew.slope * int128(int256(_newLocked.end - block.timestamp));
            }

            // Schedule slope changes
            oldDSlope = slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                if (_newLocked.end == _oldLocked.end) {
                    newDSlope = oldDSlope;
                } else {
                    newDSlope = slopeChanges[_newLocked.end];
                }
            }
        }

        Point memory lastPoint = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });

        if (_epoch > 0) {
            lastPoint = pointHistory[_epoch];
        }

        uint256 lastCheckpoint = lastPoint.ts;
        Point memory initialLastPoint = lastPoint;
        uint256 blockSlope = 0;

        if (block.timestamp > lastPoint.ts) {
            blockSlope = (MULTIPLIER * (block.number - lastPoint.blk)) / (block.timestamp - lastPoint.ts);
        }

        // Go through weeks to fill history
        uint256 tI = (lastCheckpoint / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; i++) {
            tI += WEEK;
            int128 dSlope = 0;
            if (tI > block.timestamp) {
                tI = block.timestamp;
            } else {
                dSlope = slopeChanges[tI];
            }
            lastPoint.bias -= lastPoint.slope * int128(int256(tI - lastCheckpoint));
            lastPoint.slope += dSlope;
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            lastCheckpoint = tI;
            lastPoint.ts = tI;
            lastPoint.blk = initialLastPoint.blk + (blockSlope * (tI - initialLastPoint.ts)) / MULTIPLIER;
            _epoch += 1;
            if (tI == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            } else {
                pointHistory[_epoch] = lastPoint;
            }
        }

        epoch = _epoch;
        if (_addr != address(0)) {
            lastPoint.slope += (uNew.slope - uOld.slope);
            lastPoint.bias += (uNew.bias - uOld.bias);
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        pointHistory[_epoch] = lastPoint;

        if (_addr != address(0)) {
            // Schedule future slope changes
            if (_oldLocked.end > block.timestamp) {
                oldDSlope += uOld.slope;
                if (_newLocked.end == _oldLocked.end) {
                    oldDSlope -= uNew.slope;
                }
                slopeChanges[_oldLocked.end] = oldDSlope;
            }
            if (_newLocked.end > block.timestamp) {
                if (_newLocked.end > _oldLocked.end) {
                    newDSlope -= uNew.slope;
                    slopeChanges[_newLocked.end] = newDSlope;
                }
            }

            // Record user point
            uint256 userEpoch = userPointEpoch[_addr] + 1;
            userPointEpoch[_addr] = userEpoch;
            uNew.ts = block.timestamp;
            uNew.blk = block.number;
            userPointHistory[_addr][userEpoch] = uNew;
        }
    }

    /**
     * @notice Get voting power at timestamp
     */
    function _balanceOf(address addr, uint256 _t) internal view returns (uint256) {
        uint256 _epoch = userPointEpoch[addr];
        if (_epoch == 0) {
            return 0;
        }

        Point memory lastPoint = userPointHistory[addr][_epoch];
        lastPoint.bias -= lastPoint.slope * int128(int256(_t - lastPoint.ts));
        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(int256(lastPoint.bias));
    }

    /**
     * @notice Get total supply at timestamp
     */
    function _totalSupply(uint256 _t) internal view returns (uint256) {
        uint256 _epoch = epoch;
        Point memory lastPoint = pointHistory[_epoch];
        return _supplyAt(lastPoint, _t);
    }

    /**
     * @notice Calculate supply from point at timestamp
     */
    function _supplyAt(Point memory point, uint256 _t) internal view returns (uint256) {
        Point memory lastPoint = point;
        uint256 tI = (lastPoint.ts / WEEK) * WEEK;

        for (uint256 i = 0; i < 255; i++) {
            tI += WEEK;
            int128 dSlope = 0;
            if (tI > _t) {
                tI = _t;
            } else {
                dSlope = slopeChanges[tI];
            }
            lastPoint.bias -= lastPoint.slope * int128(int256(tI - lastPoint.ts));
            if (tI == _t) {
                break;
            }
            lastPoint.slope += dSlope;
            lastPoint.ts = tI;
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(int256(lastPoint.bias));
    }
}
