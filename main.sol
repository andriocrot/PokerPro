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
    // -------------------------------------------------------------------------

    address public immutable trainer;
    address public immutable aiOracle;
    address public immutable vaultKeeper;
    uint256 public immutable deployBlock;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct SessionData {
        address trainee;
        uint8 stakesTier;
        uint256 openedAtBlock;
        uint256 closedAtBlock;
        uint256 handCount;
        bool closed;
    }

    struct HandRecord {
        bytes32 handHash;
        uint256 recordedAtBlock;
    }

    struct FeedbackRecord {
        bytes32 feedbackHash;
        uint8 qualityBand;
        uint256 anchoredAtBlock;
        address anchoredBy;
    }

    mapping(bytes32 => SessionData) private _sessions;
    bytes32[] private _sessionIds;
    uint256 public sessionCount;

    mapping(bytes32 => HandRecord[]) private _handsBySession;
    mapping(bytes32 => FeedbackRecord[]) private _feedbackBySession;
    mapping(address => bytes32[]) private _sessionIdsByTrainee;
    mapping(address => uint8) private _trainingLevelReached;

    address public vault;
    bool public trainerPaused;
    uint256 private _reentrancyLock;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        trainer = address(0x7E3aC9f1B2d4E6f8A0c2E4a6B8d0F2a4C6e8);
        aiOracle = address(0x8F4bD0e2A3c5E7f9B1d3F5a7C9e1B3d5F7a);
        vaultKeeper = address(0x9A5cE1f3B4d6F8a0C2e4A6b8D0f2A4c6E8);
        vault = address(0xB0d6F2a4C8e0B2d4F6a8C0e2A4c6E8f0B2);
        deployBlock = block.number;
        if (trainer == address(0) || aiOracle == address(0) || vaultKeeper == address(0)) revert PKR_ZeroAddress();
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyTrainer() {
        if (msg.sender != trainer) revert PKR_NotTrainer();
        _;
    }

    modifier onlyAIOracle() {
        if (msg.sender != aiOracle) revert PKR_NotAIOracle();
        _;
    }

    modifier onlyVaultKeeper() {
        if (msg.sender != vaultKeeper) revert PKR_NotVaultKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (trainerPaused) revert PKR_TrainerPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert PKR_ReentrantCall();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    // -------------------------------------------------------------------------
    // WRITES — TRAINER
    // -------------------------------------------------------------------------

    function openSession(bytes32 sessionId, address trainee, uint8 stakesTier) external onlyTrainer whenNotPaused nonReentrant {
        if (sessionId == bytes32(0)) revert PKR_ZeroSession();
        if (trainee == address(0)) revert PKR_ZeroAddress();
        if (_sessions[sessionId].openedAtBlock != 0) revert PKR_SessionAlreadyOpen();
        if (sessionCount >= PKR_MAX_SESSIONS) revert PKR_MaxSessionsReached();
        if (stakesTier > PKR_STAKES_TIER_MAX) revert PKR_InvalidStakesTier();

        _sessionIds.push(sessionId);
        sessionCount++;

        _sessions[sessionId] = SessionData({
            trainee: trainee,
            stakesTier: stakesTier,
            openedAtBlock: block.number,
            closedAtBlock: 0,
            handCount: 0,
            closed: false
        });
        _sessionIdsByTrainee[trainee].push(sessionId);

        emit SessionOpened(sessionId, trainee, stakesTier, block.number);
    }

    function closeSession(bytes32 sessionId) external onlyTrainer nonReentrant {
        if (sessionId == bytes32(0)) revert PKR_ZeroSession();
        SessionData storage s = _sessions[sessionId];
        if (s.openedAtBlock == 0) revert PKR_SessionNotFound();
        if (s.closed) revert PKR_SessionClosed();

        s.closed = true;
        s.closedAtBlock = block.number;
        uint256 handsPlayed = _handsBySession[sessionId].length;
        s.handCount = handsPlayed;

        emit SessionClosed(sessionId, handsPlayed, block.number);
    }

    function setTrainerPaused(bool paused) external onlyTrainer nonReentrant {
        trainerPaused = paused;
        emit TrainerPauseToggled(paused, msg.sender, block.number);
    }

    function setStakesTier(bytes32 sessionId, uint8 newTier) external onlyTrainer whenNotPaused nonReentrant {
        if (sessionId == bytes32(0)) revert PKR_ZeroSession();
        if (newTier > PKR_STAKES_TIER_MAX) revert PKR_InvalidStakesTier();
        SessionData storage s = _sessions[sessionId];
        if (s.openedAtBlock == 0) revert PKR_SessionNotFound();
        if (s.closed) revert PKR_SessionClosed();

        uint8 previousTier = s.stakesTier;
        s.stakesTier = newTier;
        emit StakesTierSet(sessionId, previousTier, newTier, block.number);
    }

    function unlockTrainingLevel(address trainee, uint8 level) external onlyTrainer nonReentrant {
        if (trainee == address(0)) revert PKR_ZeroAddress();
        if (level > PKR_TRAINING_LEVELS) return;
        if (_trainingLevelReached[trainee] >= level) return;
        _trainingLevelReached[trainee] = level;
        emit TrainingLevelUnlocked(trainee, level, block.number);
    }

    // -------------------------------------------------------------------------
    // WRITES — AI ORACLE
    // -------------------------------------------------------------------------

    function recordHand(bytes32 sessionId, bytes32 handHash) external onlyAIOracle whenNotPaused nonReentrant {
        if (sessionId == bytes32(0)) revert PKR_ZeroSession();
        SessionData storage s = _sessions[sessionId];
        if (s.openedAtBlock == 0) revert PKR_SessionNotFound();
        if (s.closed) revert PKR_SessionClosed();

        HandRecord[] storage hands = _handsBySession[sessionId];
        if (hands.length >= PKR_MAX_HANDS_PER_SESSION) revert PKR_MaxHandsPerSession();

        hands.push(HandRecord({ handHash: handHash, recordedAtBlock: block.number }));
        s.handCount = hands.length;

        emit HandRecorded(sessionId, handHash, hands.length - 1, block.number);
    }

    function batchRecordHands(bytes32 sessionId, bytes32[] calldata handHashes) external onlyAIOracle whenNotPaused nonReentrant {
        if (sessionId == bytes32(0)) revert PKR_ZeroSession();
        SessionData storage s = _sessions[sessionId];
        if (s.openedAtBlock == 0) revert PKR_SessionNotFound();
        if (s.closed) revert PKR_SessionClosed();

        uint256 len = handHashes.length;
        if (len == 0) revert PKR_EmptyBatch();
        if (len > PKR_MAX_BATCH_HANDS) revert PKR_BatchLengthMismatch();

        HandRecord[] storage hands = _handsBySession[sessionId];
        if (hands.length + len > PKR_MAX_HANDS_PER_SESSION) revert PKR_MaxHandsPerSession();

        for (uint256 i = 0; i < len; i++) {
            hands.push(HandRecord({ handHash: handHashes[i], recordedAtBlock: block.number }));
            emit HandRecorded(sessionId, handHashes[i], hands.length - 1, block.number);
        }
        s.handCount = hands.length;
        emit BatchHandsRecorded(sessionId, len, block.number);
    }

