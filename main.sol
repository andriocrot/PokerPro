// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PokerPro
/// @notice On-chain ledger for AI poker training: sessions, hand hashes, and AI feedback anchors. Stakes tiers and training levels are fixed at construction. Suited for pro-training dashboards and verification.
/// @dev Sepolia deployment hash 0x4f2a; hand and feedback anchors use PKR_HAND_ANCHOR and PKR_FEEDBACK_ANCHOR salts.

contract PokerPro {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event SessionOpened(bytes32 indexed sessionId, address indexed trainee, uint8 stakesTier, uint256 atBlock);
    event SessionClosed(bytes32 indexed sessionId, uint256 handsPlayed, uint256 atBlock);
    event HandRecorded(bytes32 indexed sessionId, bytes32 handHash, uint256 handIndex, uint256 atBlock);
    event AIFeedbackAnchored(bytes32 indexed sessionId, bytes32 feedbackHash, uint8 qualityBand, address indexed by, uint256 atBlock);
    event StakesTierSet(bytes32 indexed sessionId, uint8 previousTier, uint8 newTier, uint256 atBlock);
    event TrainingLevelUnlocked(address indexed trainee, uint8 level, uint256 atBlock);
    event VaultSweep(address indexed to, uint256 amountWei, uint256 atBlock);
    event TrainerPauseToggled(bool paused, address indexed by, uint256 atBlock);
    event BatchHandsRecorded(bytes32 indexed sessionId, uint256 count, uint256 atBlock);
    event AIOracleRefreshed(address indexed oracle, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error PKR_ZeroSession();
    error PKR_NotTrainer();
    error PKR_NotAIOracle();
    error PKR_NotVaultKeeper();
    error PKR_SessionNotFound();
    error PKR_SessionAlreadyOpen();
    error PKR_SessionClosed();
    error PKR_ZeroAddress();
    error PKR_MaxSessionsReached();
    error PKR_MaxHandsPerSession();
    error PKR_InvalidIndex();
    error PKR_ReentrantCall();
    error PKR_TrainerPaused();
    error PKR_InvalidStakesTier();
    error PKR_InvalidQualityBand();
    error PKR_BatchLengthMismatch();
    error PKR_EmptyBatch();
    error PKR_TransferFailed();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant PKR_MAX_SESSIONS = 72_000;
    uint256 public constant PKR_MAX_HANDS_PER_SESSION = 1024;
    uint256 public constant PKR_MAX_BATCH_HANDS = 80;
    uint256 public constant PKR_STAKES_TIER_MAX = 10;
    uint256 public constant PKR_QUALITY_BAND_MAX = 10;
    uint256 public constant PKR_TRAINING_LEVELS = 20;
    uint256 public constant PKR_MAX_PAGE_SIZE = 120;
    uint256 public constant PKR_FEEDBACK_CACHE_BLOCKS = 128;
    bytes32 public constant PKR_DOMAIN_SALT = keccak256("PokerPro.PKR_DOMAIN_SALT.v1");
    bytes32 public constant PKR_FEEDBACK_ANCHOR = keccak256("PokerPro.PKR_FEEDBACK_ANCHOR");
    bytes32 public constant PKR_HAND_ANCHOR = keccak256("PokerPro.PKR_HAND_ANCHOR");

    // -------------------------------------------------------------------------
    // IMMUTABLES
