// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {ISemaphore} from "@interfaces/zk/ISemaphore.sol";
import {EpochLib} from "@libraries/EpochLib.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";


/// @notice AllocationVotingPrivateGroups voting contract
/// In this contract, verified users in a semaphore group can cast a vote

/// Liquid farm & Illiquid farm votes are treated separately: liquid votes are used
/// to rebalance capital to the desired allocation (vote result) at every epoch, while illiquid votes
/// are only deciding where funds are allocated on a given week (in an additive manner, there is no
/// rebalancing between farms on the illiquid side).
/// Votes on a given epoch are only applying on the next epoch, leaving users with a full epoch
/// to cast their votes. Votes should be performed every week, or they will be considered outdated.
/// This means that a farm with 0 votes on a given epoch will not persist its weight on the next
/// epoch, its weight will become 0 on the next epoch.
contract AllocationVotingPrivateGroups is Ownable {
    using EpochLib for uint256;
    using FixedPointMathLib for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    error InvalidAsset(address _asset);
    error AlreadyVoted(address _user, uint32 _unwindingEpochs);
    error NoVotingPower(address _user, uint32 _unwindingEpochs);
    error UnknownFarm(address farm, bool liquid);
    error InvalidWeights(uint256 _expectedPower, uint256 _actualPower);
    error InvalidTargetBucket(address _farm, uint256 _maturity, uint256 _userUnbondingTimestamp);

    event FarmVoteRegistered(
        uint256 indexed timestamp,
        uint256 indexed epoch,
        uint256 indexed nullifier,
        uint32 unwindingEpochs,
        AllocationVote[] liquidVotes,
        AllocationVote[] illiquidVotes,
        uint256 userWeight
    );

    struct AllocationVote {
        address farm;
        uint96 weight;
    }

    struct FarmWeightData {
        // epoch of the last vote
        uint32 epoch;
        // weight returned if the current epoch is exactly equal to `epoch`
        uint112 currentWeight;
        // weight updated on votes, committed to the `currentWeight` when a vote is cast
        // on an epoch that is later than the stored epoch.
        uint112 nextWeight;
    }

    // semaphore address
    ISemaphore public immutable semaphore;

    IERC20 public immutable lockedToken;

    mapping(address farm => FarmWeightData) public farmWeightData;
    mapping(address user => mapping(uint32 unwindingEpochs => uint32 epoch)) public lastVoteEpoch;
    mapping(uint256 commitment => address user) public semaphoreCommitmentToUser;

    /// @dev weight of each Semaphore Group
    mapping(uint256 groupId => uint256 weight) public groupWeights;

    EnumerableSet.UintSet private groupIds;

    constructor(address _semaphore, address _votoCoordinator, address _lockedToken) Ownable(_votoCoordinator) {
        semaphore = ISemaphore(_semaphore);
        lockedToken = IERC20(_lockedToken);
    }

    /// @notice Returns the weight of the farm for the given epoch
    /// @param _farm The address of the farm
    /// @return uint256 The weight of the farm for the given epoch
    function getVote(address _farm) external view returns (uint256) {
        return _getFarmWeight(farmWeightData[_farm], uint32(block.timestamp.epoch()));
    }

    /// @notice Returns the vote weights for the given farm type (liquid or illiquid)
    /// @return uint256[] farms percentage
    /// @return uint256 total power
    function getVoteWeights(address[] calldata _farms) external view returns (uint256[] memory, uint256) {
        (uint256[] memory weights, uint256 totalPower) = _getVoteWeights(_farms);
        return (weights, totalPower);
    }

    /// @notice Casts a vote for the given farm
    /// @param _asset to which asset do these farms belong to
    /// @param _unwindingEpochs The number of epochs to unwind of the user
    /// @param _liquidVotes The liquid votes
    /// @param _illiquidVotes The illiquid votes
    /// @param _proof ISemaphore Proof 
    /// _proof.merkleTreeDepth;
    /// _proof.merkleTreeRoot;  Semaphore merkleTreeRoot
    /// _proof.nullifier;       Identity + Scope, to prevent double voting. Can be used as identifier for "voter"
    /// _proof.message:         Hash of the liquidVotes and illiquidVote result
    /// _proof.scope:           Should be the same as epoch
    /// _proof.points;          Proofs
    function vote(
        address _asset,
        uint256 _groupId,
        uint32 _unwindingEpochs,
        AllocationVote[] calldata _liquidVotes,
        AllocationVote[] calldata _illiquidVotes,
        ISemaphore.SemaphoreProof calldata _proof
    ) external {
        uint32 epoch = uint32(block.timestamp.epoch());

        require(epoch == _proof.scope, "Wong Epoch");

        // Check: No double voting: Checked with ISemaphore.validateProof
        semaphore.validateProof(_groupId, _proof);
      
        // Check: Get Voting weight
        uint256 weight = groupWeights[_groupId];
        require(weight > 0, "Invalid Group");

      	// Update votes
        if (_illiquidVotes.length > 0) {
            _storeUserVotes(_asset, _unwindingEpochs, epoch, weight, _illiquidVotes, false);
        }
        if (_liquidVotes.length > 0) {
            _storeUserVotes(_asset, _unwindingEpochs, epoch, weight, _liquidVotes, true);
        }

        // Check: Verify the hash of the vote is the message signed by the voter
        // bytes32 voteHash = keccak256(
        //     abi.encode(
        //         keccak256(abi.encodePacked(_liquidVotes)),
        //         keccak256(abi.encodePacked(_illiquidVotes))
        //     )
        //     );

        // require(voteHash == _proof.message, "Hash mismatch");

        emit FarmVoteRegistered(block.timestamp, epoch, _proof.nullifier, _unwindingEpochs, _liquidVotes, _illiquidVotes, weight);
    }


    /**
     * Owner can create group with weights
     */
    function createGroupWithWeight(uint256 weight) onlyOwner external {
        uint256 groupId = semaphore.createGroup();

        groupWeights[groupId] = weight;

        groupIds.add(groupId);
    }

    function getGroupIds() external view returns (uint256[] memory){
        return groupIds.values();
    }

    /// @notice Join a group
    /// @dev user must have at least x token 
    function addMember(uint256 groupId, uint256 identityCommitment) external {

        uint256 balance = lockedToken.balanceOf(msg.sender);
        uint256 limit = groupWeights[groupId] / 1e12;
        require(limit > 0 && balance > limit, "Not enough token");

        semaphoreCommitmentToUser[identityCommitment] = msg.sender;

        semaphore.addMember(groupId, identityCommitment);
    }

    /// @notice Anyone can remove a member if they no longer have enough balance
    function removeMember(uint256 groupId, uint256 identityCommitment, address user, uint256[] calldata merkleProofSiblings) external {

        require(semaphoreCommitmentToUser[identityCommitment] == user, "user commitment mismatch");

        uint256 balance = lockedToken.balanceOf(user);
        uint256 limit = groupWeights[groupId] / 1e12;
        require(balance < limit, "valid vote");

        semaphore.removeMember(groupId, identityCommitment, merkleProofSiblings);
    }

    /// -----------------------------------------------------------------------------------------------
    /// Internal helpers
    /// -----------------------------------------------------------------------------------------------

    /// @notice Returns the weight of the farm for the given epoch
    /// @param _data The farm weight data
    /// @param _epoch The epoch of the vote
    /// @return uint256 The weight of the farm for the given epoch
    function _getFarmWeight(FarmWeightData memory _data, uint32 _epoch) internal pure returns (uint256) {
        // if last vote was in current epoch, return the currentWeight
        if (_data.epoch == _epoch) {
            return _data.currentWeight;
        }
        // if last vote was in previous epoch, return the nextWeight
        if (_data.epoch == _epoch - 1) {
            return _data.nextWeight;
        }
        // otherwise, return 0 (do not persist votes if they are older than 1 epoch ago)
        return 0;
    }

    /// @notice Stores the user's votes for the given farms
    /// @param _unwindingEpochs The number of epochs to unwind of the user
    /// @param _epoch The epoch of the vote
    /// @param _userWeight The weight of the user
    /// @param _votes The votes to store
    /// @param _liquid Whether the farms are liquid or illiquid
    function _storeUserVotes(
        address _asset,
        uint32 _unwindingEpochs,
        uint32 _epoch,
        uint256 _userWeight,
        AllocationVote[] calldata _votes,
        bool _liquid
    ) internal {
        uint256 weightAllocated = 0;

        for (uint256 i = 0; i < _votes.length; i++) {
            address farm = _votes[i].farm;
            if (_liquid) {
                _validateAssetAndType(_asset, farm, FarmTypes.LIQUID);
            } else {
                _validateAssetAndType(_asset, farm, FarmTypes.MATURITY);
                _validateFarmBucket(farm, _unwindingEpochs);
            }

            FarmWeightData memory data = farmWeightData[farm];
            if (data.epoch != _epoch) {
                // roll over pending weight votes that are in "nextWeight" into "currentWeight"
                // when a new epoch starts and a vote is cast
                if (data.epoch == _epoch - 1) {
                    data = FarmWeightData({epoch: _epoch, currentWeight: data.nextWeight, nextWeight: 0});
                } else {
                    data = FarmWeightData({epoch: _epoch, currentWeight: 0, nextWeight: 0});
                }
            }

            data.nextWeight += uint112(_userWeight.mulWadDown(_votes[i].weight));
            farmWeightData[farm] = data;
            weightAllocated += _votes[i].weight;
        }

        // user must allocate all of their voting power when casting a vote
        // or not vote for a particular farm type at all
        // for example, user can choose to vote only for liquid farms, or only for maturity farms
        require(
            weightAllocated == FixedPointMathLib.WAD || weightAllocated == 0,
            InvalidWeights(FixedPointMathLib.WAD, weightAllocated)
        );
    }

    function _getVoteWeights(address[] memory _farms) internal view returns (uint256[] memory, uint256) {
        uint32 epoch = uint32(block.timestamp.epoch());
        uint256[] memory weights = new uint256[](_farms.length);

        uint256 totalPower = 0;

        for (uint256 i = 0; i < _farms.length; i++) {
            weights[i] = _getFarmWeight(farmWeightData[_farms[i]], epoch);
            totalPower += weights[i];
        }

        return (weights, totalPower);
    }

    function _validateAssetAndType(address _asset, address _farm, uint256 _type) internal view {
        // No validation
        // return true;

        // FarmRegistry _farmRegistry = FarmRegistry(farmRegistry);
        // require(_farmRegistry.isFarmOfType(_farm, uint256(_type)), UnknownFarm(_farm, true));
        // require(_farmRegistry.isFarmOfAsset(_farm, _asset), InvalidAsset(_asset));
    }

    function _validateFarmBucket(address _farm, uint32 _unwindingEpochs) internal view {
        // uint256 maturity = IMaturityFarm(_farm).maturity();
        // uint256 userUnwindingTimestamp = (block.timestamp.nextEpoch() + _unwindingEpochs).epochToTimestamp();
        // require(maturity <= userUnwindingTimestamp, InvalidTargetBucket(_farm, maturity, userUnwindingTimestamp));
    }
}
