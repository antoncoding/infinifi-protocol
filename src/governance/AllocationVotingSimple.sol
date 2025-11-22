// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISemaphore} from "@interfaces/zk/ISemaphore.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Simple contract for Semaphore integration
contract AllocationVotingSimple is Ownable {
    
    ISemaphore semaphore;

    uint256 public whaleGroupId;
    uint256 public dolphinGroupId;
    uint256 public shrimpGroupId;

    constructor(address _semaphore, address _admin) Ownable(_admin) {
        semaphore = ISemaphore(_semaphore);

        whaleGroupId = ISemaphore(_semaphore).createGroup();
        dolphinGroupId = ISemaphore(_semaphore).createGroup();
        shrimpGroupId = ISemaphore(_semaphore).createGroup();
    }

    /// @notice add member to the group
    /// @dev only admin can call this function
    function addMember(uint256 groupId, uint256 identityCommitment) onlyOwner() external {
        semaphore.addMember(groupId, identityCommitment);
    }


    /// @notice vote
    function vote(
        uint256 merkleTreeDepth,
        uint256 merkleTreeRoot,
        uint256 nullifier,
        uint256 message,
        uint256 groupId,
        uint256[8] calldata points
    ) external {
        ISemaphore.SemaphoreProof memory proof = ISemaphore.SemaphoreProof(
            merkleTreeDepth,
            merkleTreeRoot,
            nullifier,
            message,
            groupId,
            points
        );

        semaphore.validateProof(groupId, proof);
    }

}
