// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721, IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title VotingEscrow (xBDX)
/// @notice veNFT — lock sBDX to receive xBDX NFT with decaying voting power
/// @author Cloned from Velodrome Finance v1 VotingEscrow
///         https://github.com/velodrome-finance/v1/blob/master/contracts/VotingEscrow.sol
/// @dev Adapted: sBDX as locked token, OZ v5 imports, no art proxy, pragma ^0.8.20
contract VotingEscrow is IERC721, IERC721Metadata, IVotes {
    enum DepositType {
        DEPOSIT_FOR_TYPE,
        CREATE_LOCK_TYPE,
        INCREASE_LOCK_AMOUNT,
        INCREASE_UNLOCK_TIME,
        MERGE_TYPE
    }

    struct LockedBalance {
        int128 amount;
        uint end;
    }

    struct Point {
        int128 bias;
        int128 slope;
        uint ts;
        uint blk;
    }

    struct Checkpoint {
        uint timestamp;
        uint[] tokenIds;
    }

    event Deposit(address indexed provider, uint tokenId, uint value, uint indexed locktime, DepositType deposit_type, uint ts);
    event Withdraw(address indexed provider, uint tokenId, uint value, uint ts);
    event Supply(uint prevSupply, uint supply);

    address public immutable token;
    address public voter;
    address public team;

    mapping(uint => Point) public point_history;

    mapping(bytes4 => bool) internal supportedInterfaces;
    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant ERC721_INTERFACE_ID = 0x80ac58cd;
    bytes4 internal constant ERC721_METADATA_INTERFACE_ID = 0x5b5e139f;

    uint internal tokenId;

    constructor(address token_addr) {
        token = token_addr;
        voter = msg.sender;
        team = msg.sender;

        point_history[0].blk = block.number;
        point_history[0].ts = block.timestamp;

        supportedInterfaces[ERC165_INTERFACE_ID] = true;
        supportedInterfaces[ERC721_INTERFACE_ID] = true;
        supportedInterfaces[ERC721_METADATA_INTERFACE_ID] = true;

        emit Transfer(address(0), address(this), tokenId);
        emit Transfer(address(this), address(0), tokenId);
    }

    uint8 internal constant _not_entered = 1;
    uint8 internal constant _entered = 2;
    uint8 internal _entered_state = 1;
    modifier nonreentrant() {
        require(_entered_state == _not_entered);
        _entered_state = _entered;
        _;
        _entered_state = _not_entered;
    }

    string constant public name = "xBDX";
    string constant public symbol = "xBDX";
    string constant public version = "1.0.0";
    uint8 constant public decimals = 18;

    function setTeam(address _team) external { require(msg.sender == team); team = _team; }

    function tokenURI(uint _tokenId) external view returns (string memory) {
        require(idToOwner[_tokenId] != address(0), "Query for nonexistent token");
        return "";
    }

    mapping(uint => address) internal idToOwner;
    mapping(address => uint) internal ownerToNFTokenCount;

    function ownerOf(uint _tokenId) public view returns (address) { return idToOwner[_tokenId]; }
    function _balance(address _owner) internal view returns (uint) { return ownerToNFTokenCount[_owner]; }
    function balanceOf(address _owner) external view returns (uint) { return _balance(_owner); }

    mapping(uint => address) internal idToApprovals;
    mapping(address => mapping(address => bool)) internal ownerToOperators;
    mapping(uint => uint) public ownership_change;

    function getApproved(uint _tokenId) external view returns (address) { return idToApprovals[_tokenId]; }
    function isApprovedForAll(address _owner, address _operator) external view returns (bool) { return (ownerToOperators[_owner])[_operator]; }

    function approve(address _approved, uint _tokenId) public {
        address owner = idToOwner[_tokenId];
        require(owner != address(0));
        require(_approved != owner);
        bool senderIsOwner = (idToOwner[_tokenId] == msg.sender);
        bool senderIsApprovedForAll = (ownerToOperators[owner])[msg.sender];
        require(senderIsOwner || senderIsApprovedForAll);
        idToApprovals[_tokenId] = _approved;
        emit Approval(owner, _approved, _tokenId);
    }

    function setApprovalForAll(address _operator, bool _approved) external {
        require(_operator != msg.sender, "operator is sender");
        ownerToOperators[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    function _clearApproval(address _owner, uint _tokenId) internal {
        assert(idToOwner[_tokenId] == _owner);
        if (idToApprovals[_tokenId] != address(0)) { idToApprovals[_tokenId] = address(0); }
    }

    function _isApprovedOrOwner(address _spender, uint _tokenId) internal view returns (bool) {
        address owner = idToOwner[_tokenId];
        bool spenderIsOwner = owner == _spender;
        bool spenderIsApproved = _spender == idToApprovals[_tokenId];
        bool spenderIsApprovedForAll = (ownerToOperators[owner])[_spender];
        return spenderIsOwner || spenderIsApproved || spenderIsApprovedForAll;
    }

    function isApprovedOrOwner(address _spender, uint _tokenId) external view returns (bool) { return _isApprovedOrOwner(_spender, _tokenId); }

    function _transferFrom(address _from, address _to, uint _tokenId, address _sender) internal {
        require(attachments[_tokenId] == 0 && !voted[_tokenId], "attached");
        require(_isApprovedOrOwner(_sender, _tokenId));
        _clearApproval(_from, _tokenId);
        _removeTokenFrom(_from, _tokenId);
        _moveTokenDelegates(delegates(_from), delegates(_to), _tokenId);
        _addTokenTo(_to, _tokenId);
        ownership_change[_tokenId] = block.number;
        emit Transfer(_from, _to, _tokenId);
    }

    function transferFrom(address _from, address _to, uint _tokenId) external { _transferFrom(_from, _to, _tokenId, msg.sender); }

    function safeTransferFrom(address _from, address _to, uint _tokenId) external { safeTransferFrom(_from, _to, _tokenId, ""); }

    function _isContract(address account) internal view returns (bool) {
        uint size;
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    function safeTransferFrom(address _from, address _to, uint _tokenId, bytes memory _data) public {
        _transferFrom(_from, _to, _tokenId, msg.sender);
        if (_isContract(_to)) {
            try IERC721Receiver(_to).onERC721Received(msg.sender, _from, _tokenId, _data) returns (bytes4 response) {
                if (response != IERC721Receiver(_to).onERC721Received.selector) { revert("ERC721: ERC721Receiver rejected tokens"); }
            } catch (bytes memory reason) {
                if (reason.length == 0) { revert("ERC721: transfer to non ERC721Receiver implementer"); }
                else { assembly { revert(add(32, reason), mload(reason)) } }
            }
        }
    }

    function supportsInterface(bytes4 _interfaceID) external view returns (bool) { return supportedInterfaces[_interfaceID]; }

    mapping(address => mapping(uint => uint)) internal ownerToNFTokenIdList;
    mapping(uint => uint) internal tokenToOwnerIndex;

    function tokenOfOwnerByIndex(address _owner, uint _tokenIndex) external view returns (uint) { return ownerToNFTokenIdList[_owner][_tokenIndex]; }

    function _addTokenToOwnerList(address _to, uint _tokenId) internal {
        uint current_count = _balance(_to);
        ownerToNFTokenIdList[_to][current_count] = _tokenId;
        tokenToOwnerIndex[_tokenId] = current_count;
    }

    function _addTokenTo(address _to, uint _tokenId) internal {
        assert(idToOwner[_tokenId] == address(0));
        idToOwner[_tokenId] = _to;
        _addTokenToOwnerList(_to, _tokenId);
        ownerToNFTokenCount[_to] += 1;
    }

    function _mint(address _to, uint _tokenId) internal returns (bool) {
        assert(_to != address(0));
        _moveTokenDelegates(address(0), delegates(_to), _tokenId);
        _addTokenTo(_to, _tokenId);
        emit Transfer(address(0), _to, _tokenId);
        return true;
    }

    function _removeTokenFromOwnerList(address _from, uint _tokenId) internal {
        uint current_count = _balance(_from) - 1;
        uint current_index = tokenToOwnerIndex[_tokenId];
        if (current_count == current_index) {
            ownerToNFTokenIdList[_from][current_count] = 0;
            tokenToOwnerIndex[_tokenId] = 0;
        } else {
            uint lastTokenId = ownerToNFTokenIdList[_from][current_count];
            ownerToNFTokenIdList[_from][current_index] = lastTokenId;
            tokenToOwnerIndex[lastTokenId] = current_index;
            ownerToNFTokenIdList[_from][current_count] = 0;
            tokenToOwnerIndex[_tokenId] = 0;
        }
    }

    function _removeTokenFrom(address _from, uint _tokenId) internal {
        assert(idToOwner[_tokenId] == _from);
        idToOwner[_tokenId] = address(0);
        _removeTokenFromOwnerList(_from, _tokenId);
        ownerToNFTokenCount[_from] -= 1;
    }

    function _burn(uint _tokenId) internal {
        require(_isApprovedOrOwner(msg.sender, _tokenId), "caller is not owner nor approved");
        address owner = ownerOf(_tokenId);
        approve(address(0), _tokenId);
        _moveTokenDelegates(delegates(owner), address(0), _tokenId);
        _removeTokenFrom(msg.sender, _tokenId);
        emit Transfer(owner, address(0), _tokenId);
    }

    mapping(uint => uint) public user_point_epoch;
    mapping(uint => Point[1000000000]) public user_point_history;
    mapping(uint => LockedBalance) public locked;
    uint public epoch;
    mapping(uint => int128) public slope_changes;
    uint public supply;

    uint internal constant WEEK = 1 weeks;
    uint internal constant MAXTIME = 4 * 365 * 86400;
    int128 internal constant iMAXTIME = 4 * 365 * 86400;
    uint internal constant MULTIPLIER = 1 ether;

    function get_last_user_slope(uint _tokenId) external view returns (int128) {
        uint uepoch = user_point_epoch[_tokenId];
        return user_point_history[_tokenId][uepoch].slope;
    }

    function user_point_history__ts(uint _tokenId, uint _idx) external view returns (uint) { return user_point_history[_tokenId][_idx].ts; }
    function locked__end(uint _tokenId) external view returns (uint) { return locked[_tokenId].end; }

    function _checkpoint(uint _tokenId, LockedBalance memory old_locked, LockedBalance memory new_locked) internal {
        Point memory u_old;
        Point memory u_new;
        int128 old_dslope = 0;
        int128 new_dslope = 0;
        uint _epoch = epoch;

        if (_tokenId != 0) {
            if (old_locked.end > block.timestamp && old_locked.amount > 0) {
                u_old.slope = old_locked.amount / iMAXTIME;
                u_old.bias = u_old.slope * int128(int256(old_locked.end - block.timestamp));
            }
            if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                u_new.slope = new_locked.amount / iMAXTIME;
                u_new.bias = u_new.slope * int128(int256(new_locked.end - block.timestamp));
            }
            old_dslope = slope_changes[old_locked.end];
            if (new_locked.end != 0) {
                if (new_locked.end == old_locked.end) { new_dslope = old_dslope; }
                else { new_dslope = slope_changes[new_locked.end]; }
            }
        }

        Point memory last_point = Point({bias: 0, slope: 0, ts: block.timestamp, blk: block.number});
        if (_epoch > 0) { last_point = point_history[_epoch]; }
        uint last_checkpoint = last_point.ts;
        Point memory initial_last_point = last_point;
        uint block_slope = 0;
        if (block.timestamp > last_point.ts) {
            block_slope = (MULTIPLIER * (block.number - last_point.blk)) / (block.timestamp - last_point.ts);
        }

        {
            uint t_i = (last_checkpoint / WEEK) * WEEK;
            for (uint i = 0; i < 255; ++i) {
                t_i += WEEK;
                int128 d_slope = 0;
                if (t_i > block.timestamp) { t_i = block.timestamp; }
                else { d_slope = slope_changes[t_i]; }
                last_point.bias -= last_point.slope * int128(int256(t_i - last_checkpoint));
                last_point.slope += d_slope;
                if (last_point.bias < 0) { last_point.bias = 0; }
                if (last_point.slope < 0) { last_point.slope = 0; }
                last_checkpoint = t_i;
                last_point.ts = t_i;
                last_point.blk = initial_last_point.blk + (block_slope * (t_i - initial_last_point.ts)) / MULTIPLIER;
                _epoch += 1;
                if (t_i == block.timestamp) { last_point.blk = block.number; break; }
                else { point_history[_epoch] = last_point; }
            }
        }

        epoch = _epoch;

        if (_tokenId != 0) {
            last_point.slope += (u_new.slope - u_old.slope);
            last_point.bias += (u_new.bias - u_old.bias);
            if (last_point.slope < 0) { last_point.slope = 0; }
            if (last_point.bias < 0) { last_point.bias = 0; }
        }

        point_history[_epoch] = last_point;

        if (_tokenId != 0) {
            if (old_locked.end > block.timestamp) {
                old_dslope += u_old.slope;
                if (new_locked.end == old_locked.end) { old_dslope -= u_new.slope; }
                slope_changes[old_locked.end] = old_dslope;
            }
            if (new_locked.end > block.timestamp) {
                if (new_locked.end > old_locked.end) {
                    new_dslope -= u_new.slope;
                    slope_changes[new_locked.end] = new_dslope;
                }
            }
            uint user_epoch = user_point_epoch[_tokenId] + 1;
            user_point_epoch[_tokenId] = user_epoch;
            u_new.ts = block.timestamp;
            u_new.blk = block.number;
            user_point_history[_tokenId][user_epoch] = u_new;
        }
    }

    function _deposit_for(uint _tokenId, uint _value, uint unlock_time, LockedBalance memory locked_balance, DepositType deposit_type) internal {
        LockedBalance memory _locked = locked_balance;
        uint supply_before = supply;
        supply = supply_before + _value;
        LockedBalance memory old_locked;
        (old_locked.amount, old_locked.end) = (_locked.amount, _locked.end);
        _locked.amount += int128(int256(_value));
        if (unlock_time != 0) { _locked.end = unlock_time; }
        locked[_tokenId] = _locked;
        _checkpoint(_tokenId, old_locked, _locked);
        address from = msg.sender;
        if (_value != 0 && deposit_type != DepositType.MERGE_TYPE) {
            assert(IERC20(token).transferFrom(from, address(this), _value));
        }
        emit Deposit(from, _tokenId, _value, _locked.end, deposit_type, block.timestamp);
        emit Supply(supply_before, supply_before + _value);
    }

    function block_number() external view returns (uint) { return block.number; }
    function checkpoint() external { _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0)); }

    function deposit_for(uint _tokenId, uint _value) external nonreentrant {
        LockedBalance memory _locked = locked[_tokenId];
        require(_value > 0);
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > block.timestamp, "Cannot add to expired lock. Withdraw");
        _deposit_for(_tokenId, _value, 0, _locked, DepositType.DEPOSIT_FOR_TYPE);
    }

    function _create_lock(uint _value, uint _lock_duration, address _to) internal returns (uint) {
        uint unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK;
        require(_value > 0);
        require(unlock_time > block.timestamp, "Can only lock until time in the future");
        require(unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 4 years max");
        ++tokenId;
        uint _tokenId = tokenId;
        _mint(_to, _tokenId);
        _deposit_for(_tokenId, _value, unlock_time, locked[_tokenId], DepositType.CREATE_LOCK_TYPE);
        return _tokenId;
    }

    function create_lock(uint _value, uint _lock_duration) external nonreentrant returns (uint) { return _create_lock(_value, _lock_duration, msg.sender); }
    function create_lock_for(uint _value, uint _lock_duration, address _to) external nonreentrant returns (uint) { return _create_lock(_value, _lock_duration, _to); }

    function increase_amount(uint _tokenId, uint _value) external nonreentrant {
        assert(_isApprovedOrOwner(msg.sender, _tokenId));
        LockedBalance memory _locked = locked[_tokenId];
        assert(_value > 0);
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > block.timestamp, "Cannot add to expired lock. Withdraw");
        _deposit_for(_tokenId, _value, 0, _locked, DepositType.INCREASE_LOCK_AMOUNT);
    }

    function increase_unlock_time(uint _tokenId, uint _lock_duration) external nonreentrant {
        assert(_isApprovedOrOwner(msg.sender, _tokenId));
        LockedBalance memory _locked = locked[_tokenId];
        uint unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK;
        require(_locked.end > block.timestamp, "Lock expired");
        require(_locked.amount > 0, "Nothing is locked");
        require(unlock_time > _locked.end, "Can only increase lock duration");
        require(unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 4 years max");
        _deposit_for(_tokenId, 0, unlock_time, _locked, DepositType.INCREASE_UNLOCK_TIME);
    }

    function withdraw(uint _tokenId) external nonreentrant {
        assert(_isApprovedOrOwner(msg.sender, _tokenId));
        require(attachments[_tokenId] == 0 && !voted[_tokenId], "attached");
        LockedBalance memory _locked = locked[_tokenId];
        require(block.timestamp >= _locked.end, "The lock didn't expire");
        uint value = uint(int256(_locked.amount));
        locked[_tokenId] = LockedBalance(0, 0);
        uint supply_before = supply;
        supply = supply_before - value;
        _checkpoint(_tokenId, _locked, LockedBalance(0, 0));
        assert(IERC20(token).transfer(msg.sender, value));
        _burn(_tokenId);
        emit Withdraw(msg.sender, _tokenId, value, block.timestamp);
        emit Supply(supply_before, supply_before - value);
    }

    function _find_block_epoch(uint _block, uint max_epoch) internal view returns (uint) {
        uint _min = 0;
        uint _max = max_epoch;
        for (uint i = 0; i < 128; ++i) {
            if (_min >= _max) { break; }
            uint _mid = (_min + _max + 1) / 2;
            if (point_history[_mid].blk <= _block) { _min = _mid; }
            else { _max = _mid - 1; }
        }
        return _min;
    }

    /// @dev Binary-search `user_point_history[_tokenId]` for the latest entry whose ts <= _t,
    ///      then linearly extrapolate. The original Curve/Velodrome v1 implementation always
    ///      started from the LATEST user point, which is mathematically wrong as soon as the
    ///      lock is ever modified (deposit_for, increase_amount, increase_unlock_time, merge):
    ///      every modification writes a new point with a different slope, so extrapolating from
    ///      "today's" slope into the past would over-credit or under-credit any historical query
    ///      (governance snapshots, gauge epoch snapshots, etc.). Aerodrome/Velodrome v2 fixed
    ///      this the same way.
    function _balanceOfNFT(uint _tokenId, uint _t) internal view returns (uint) {
        uint _epoch = user_point_epoch[_tokenId];
        if (_epoch == 0) return 0;
        // Binary search: largest k in [1, _epoch] with user_point_history[_tokenId][k].ts <= _t.
        uint _min = 1;
        uint _max = _epoch;
        for (uint i = 0; i < 128; ++i) {
            if (_min >= _max) break;
            uint _mid = (_min + _max + 1) / 2;
            if (user_point_history[_tokenId][_mid].ts <= _t) { _min = _mid; }
            else { _max = _mid - 1; }
        }
        Point memory upoint = user_point_history[_tokenId][_min];
        if (upoint.ts > _t) return 0; // _t precedes the very first checkpoint
        int128 bias = upoint.bias - upoint.slope * int128(int256(_t) - int256(upoint.ts));
        if (bias < 0) bias = 0;
        return uint(int256(bias));
    }

    function balanceOfNFT(uint _tokenId) external view returns (uint) {
        if (ownership_change[_tokenId] == block.number) return 0;
        return _balanceOfNFT(_tokenId, block.timestamp);
    }

    function balanceOfNFTAt(uint _tokenId, uint _t) external view returns (uint) { return _balanceOfNFT(_tokenId, _t); }

    function _balanceOfAtNFT(uint _tokenId, uint _block) internal view returns (uint) {
        assert(_block <= block.number);
        uint _min = 0;
        uint _max = user_point_epoch[_tokenId];
        for (uint i = 0; i < 128; ++i) {
            if (_min >= _max) { break; }
            uint _mid = (_min + _max + 1) / 2;
            if (user_point_history[_tokenId][_mid].blk <= _block) { _min = _mid; }
            else { _max = _mid - 1; }
        }
        Point memory upoint = user_point_history[_tokenId][_min];
        uint max_epoch = epoch;
        uint _epoch = _find_block_epoch(_block, max_epoch);
        Point memory point_0 = point_history[_epoch];
        uint d_block = 0;
        uint d_t = 0;
        if (_epoch < max_epoch) {
            Point memory point_1 = point_history[_epoch + 1];
            d_block = point_1.blk - point_0.blk;
            d_t = point_1.ts - point_0.ts;
        } else {
            d_block = block.number - point_0.blk;
            d_t = block.timestamp - point_0.ts;
        }
        uint block_time = point_0.ts;
        if (d_block != 0) { block_time += (d_t * (_block - point_0.blk)) / d_block; }
        upoint.bias -= upoint.slope * int128(int256(block_time - upoint.ts));
        if (upoint.bias >= 0) { return uint(uint128(upoint.bias)); }
        else { return 0; }
    }

    function balanceOfAtNFT(uint _tokenId, uint _block) external view returns (uint) { return _balanceOfAtNFT(_tokenId, _block); }

    function totalSupplyAt(uint _block) external view returns (uint) {
        assert(_block <= block.number);
        uint _epoch = epoch;
        uint target_epoch = _find_block_epoch(_block, _epoch);
        Point memory point = point_history[target_epoch];
        uint dt = 0;
        if (target_epoch < _epoch) {
            Point memory point_next = point_history[target_epoch + 1];
            if (point.blk != point_next.blk) {
                dt = ((_block - point.blk) * (point_next.ts - point.ts)) / (point_next.blk - point.blk);
            }
        } else {
            if (point.blk != block.number) {
                dt = ((_block - point.blk) * (block.timestamp - point.ts)) / (block.number - point.blk);
            }
        }
        return _supply_at(point, point.ts + dt);
    }

    function _supply_at(Point memory point, uint t) internal view returns (uint) {
        Point memory last_point = point;
        uint t_i = (last_point.ts / WEEK) * WEEK;
        for (uint i = 0; i < 255; ++i) {
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > t) { t_i = t; }
            else { d_slope = slope_changes[t_i]; }
            last_point.bias -= last_point.slope * int128(int256(t_i - last_point.ts));
            if (t_i == t) { break; }
            last_point.slope += d_slope;
            last_point.ts = t_i;
        }
        if (last_point.bias < 0) { last_point.bias = 0; }
        return uint(uint128(last_point.bias));
    }

    function totalSupply() external view returns (uint) { return totalSupplyAtT(block.timestamp); }

    /// @dev Binary-search `point_history` for the latest global checkpoint whose ts <= t, then
    ///      forward-walk via `_supply_at`. Same fix rationale as `_balanceOfNFT`: starting from
    ///      `point_history[epoch]` (latest) and "extrapolating" to a smaller timestamp `t` would
    ///      apply today's slope to the past instead of the slope that was actually in force then,
    ///      giving wrong values for `getPastTotalSupply` (governance quorum, gauge denominator).
    function totalSupplyAtT(uint t) public view returns (uint) {
        uint _epoch = epoch;
        if (_epoch == 0) return 0;
        uint _min = 0;
        uint _max = _epoch;
        for (uint i = 0; i < 128; ++i) {
            if (_min >= _max) break;
            uint _mid = (_min + _max + 1) / 2;
            if (point_history[_mid].ts <= t) { _min = _mid; }
            else { _max = _mid - 1; }
        }
        Point memory point = point_history[_min];
        if (point.ts > t) return 0; // t precedes genesis
        return _supply_at(point, t);
    }

    mapping(uint => uint) public attachments;
    mapping(uint => bool) public voted;

    function setVoter(address _voter) external { require(msg.sender == voter); voter = _voter; }
    function voting(uint _tokenId) external { require(msg.sender == voter); voted[_tokenId] = true; }
    function abstain(uint _tokenId) external { require(msg.sender == voter); voted[_tokenId] = false; }
    function attach(uint _tokenId) external { require(msg.sender == voter); attachments[_tokenId] = attachments[_tokenId] + 1; }
    function detach(uint _tokenId) external { require(msg.sender == voter); attachments[_tokenId] = attachments[_tokenId] - 1; }

    function merge(uint _from, uint _to) external {
        require(attachments[_from] == 0 && !voted[_from], "attached");
        require(_from != _to);
        require(_isApprovedOrOwner(msg.sender, _from));
        require(_isApprovedOrOwner(msg.sender, _to));
        LockedBalance memory _locked0 = locked[_from];
        LockedBalance memory _locked1 = locked[_to];
        uint value0 = uint(int256(_locked0.amount));
        uint end = _locked0.end >= _locked1.end ? _locked0.end : _locked1.end;
        locked[_from] = LockedBalance(0, 0);
        _checkpoint(_from, _locked0, LockedBalance(0, 0));
        _burn(_from);
        _deposit_for(_to, value0, end, _locked1, DepositType.MERGE_TYPE);
    }

    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    mapping(address => address) private _delegates;
    uint public constant MAX_DELEGATES = 1024;

    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
    mapping(address => uint32) public numCheckpoints;
    mapping(address => uint) public nonces;

    function delegates(address delegator) public view returns (address) {
        address current = _delegates[delegator];
        return current == address(0) ? delegator : current;
    }

    function getVotes(address account) external view returns (uint) {
        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) { return 0; }
        uint[] storage _tokenIds = checkpoints[account][nCheckpoints - 1].tokenIds;
        uint votes = 0;
        for (uint i = 0; i < _tokenIds.length; i++) {
            uint tId = _tokenIds[i];
            votes = votes + _balanceOfNFT(tId, block.timestamp);
        }
        return votes;
    }

    function getPastVotesIndex(address account, uint timestamp) public view returns (uint32) {
        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) { return 0; }
        if (checkpoints[account][nCheckpoints - 1].timestamp <= timestamp) { return (nCheckpoints - 1); }
        if (checkpoints[account][0].timestamp > timestamp) { return 0; }
        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2;
            Checkpoint storage cp = checkpoints[account][center];
            if (cp.timestamp == timestamp) { return center; }
            else if (cp.timestamp < timestamp) { lower = center; }
            else { upper = center - 1; }
        }
        return lower;
    }

    function getPastVotes(address account, uint256 timestamp) public view returns (uint) {
        uint32 _checkIndex = getPastVotesIndex(account, timestamp);
        uint[] storage _tokenIds = checkpoints[account][_checkIndex].tokenIds;
        uint votes = 0;
        for (uint i = 0; i < _tokenIds.length; i++) {
            uint tId = _tokenIds[i];
            votes = votes + _balanceOfNFT(tId, timestamp);
        }
        return votes;
    }

    function getPastTotalSupply(uint256 timestamp) external view returns (uint) { return totalSupplyAtT(timestamp); }

    function _moveTokenDelegates(address srcRep, address dstRep, uint _tokenId) internal {
        if (srcRep != dstRep && _tokenId > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint[] storage srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].tokenIds : checkpoints[srcRep][0].tokenIds;
                uint32 nextSrcRepNum = _findWhatCheckpointToWrite(srcRep);
                uint[] storage srcRepNew = checkpoints[srcRep][nextSrcRepNum].tokenIds;
                for (uint i = 0; i < srcRepOld.length; i++) {
                    uint tId = srcRepOld[i];
                    if (tId != _tokenId) { srcRepNew.push(tId); }
                }
                numCheckpoints[srcRep] = srcRepNum + 1;
            }
            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint[] storage dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].tokenIds : checkpoints[dstRep][0].tokenIds;
                uint32 nextDstRepNum = _findWhatCheckpointToWrite(dstRep);
                uint[] storage dstRepNew = checkpoints[dstRep][nextDstRepNum].tokenIds;
                require(dstRepOld.length + 1 <= MAX_DELEGATES, "dstRep would have too many tokenIds");
                for (uint i = 0; i < dstRepOld.length; i++) { dstRepNew.push(dstRepOld[i]); }
                dstRepNew.push(_tokenId);
                numCheckpoints[dstRep] = dstRepNum + 1;
            }
        }
    }

    function _findWhatCheckpointToWrite(address account) internal view returns (uint32) {
        uint _timestamp = block.timestamp;
        uint32 _nCheckPoints = numCheckpoints[account];
        if (_nCheckPoints > 0 && checkpoints[account][_nCheckPoints - 1].timestamp == _timestamp) { return _nCheckPoints - 1; }
        else { return _nCheckPoints; }
    }

    function _moveAllDelegates(address owner, address srcRep, address dstRep) internal {
        if (srcRep != dstRep) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint[] storage srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].tokenIds : checkpoints[srcRep][0].tokenIds;
                uint32 nextSrcRepNum = _findWhatCheckpointToWrite(srcRep);
                uint[] storage srcRepNew = checkpoints[srcRep][nextSrcRepNum].tokenIds;
                for (uint i = 0; i < srcRepOld.length; i++) {
                    uint tId = srcRepOld[i];
                    if (idToOwner[tId] != owner) { srcRepNew.push(tId); }
                }
                numCheckpoints[srcRep] = srcRepNum + 1;
            }
            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint[] storage dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].tokenIds : checkpoints[dstRep][0].tokenIds;
                uint32 nextDstRepNum = _findWhatCheckpointToWrite(dstRep);
                uint[] storage dstRepNew = checkpoints[dstRep][nextDstRepNum].tokenIds;
                uint ownerTokenCount = ownerToNFTokenCount[owner];
                require(dstRepOld.length + ownerTokenCount <= MAX_DELEGATES, "dstRep would have too many tokenIds");
                for (uint i = 0; i < dstRepOld.length; i++) { dstRepNew.push(dstRepOld[i]); }
                for (uint i = 0; i < ownerTokenCount; i++) { dstRepNew.push(ownerToNFTokenIdList[owner][i]); }
                numCheckpoints[dstRep] = dstRepNum + 1;
            }
        }
    }

    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = delegates(delegator);
        _delegates[delegator] = delegatee;
        emit DelegateChanged(delegator, currentDelegate, delegatee);
        _moveAllDelegates(delegator, currentDelegate, delegatee);
    }

    function delegate(address delegatee) public {
        if (delegatee == address(0)) delegatee = msg.sender;
        return _delegate(msg.sender, delegatee);
    }

    function delegateBySig(address delegatee, uint nonce, uint expiry, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, address(this)));
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "VotingEscrow::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "VotingEscrow::delegateBySig: invalid nonce");
        require(block.timestamp <= expiry, "VotingEscrow::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }
}
