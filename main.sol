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

    function anchorAIFeedback(bytes32 sessionId, bytes32 feedbackHash, uint8 qualityBand) external onlyAIOracle whenNotPaused nonReentrant {
        if (sessionId == bytes32(0)) revert PKR_ZeroSession();
        if (_sessions[sessionId].openedAtBlock == 0) revert PKR_SessionNotFound();
        if (_sessions[sessionId].closed) revert PKR_SessionClosed();
        if (qualityBand > PKR_QUALITY_BAND_MAX) revert PKR_InvalidQualityBand();

        _feedbackBySession[sessionId].push(FeedbackRecord({
            feedbackHash: feedbackHash,
            qualityBand: qualityBand,
            anchoredAtBlock: block.number,
            anchoredBy: msg.sender
        }));

        emit AIFeedbackAnchored(sessionId, feedbackHash, qualityBand, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // WRITES — VAULT
    // -------------------------------------------------------------------------

    function setVault(address newVault) external onlyVaultKeeper nonReentrant {
        if (newVault == address(0)) revert PKR_ZeroAddress();
        vault = newVault;
    }

    function sweepToVault() external onlyVaultKeeper nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        address dest = vault;
        (bool ok,) = dest.call{ value: balance }("");
        if (!ok) revert PKR_TransferFailed();
        emit VaultSweep(dest, balance, block.number);
    }

    receive() external payable {}

    // -------------------------------------------------------------------------
    // VIEWS
    // -------------------------------------------------------------------------

    function getSession(bytes32 sessionId) external view returns (
        address trainee,
        uint8 stakesTier,
        uint256 openedAtBlock,
        uint256 closedAtBlock,
        uint256 handCount,
        bool closed
    ) {
        SessionData storage s = _sessions[sessionId];
        return (s.trainee, s.stakesTier, s.openedAtBlock, s.closedAtBlock, s.handCount, s.closed);
    }

    function sessionIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _sessionIds.length) revert PKR_InvalidIndex();
        return _sessionIds[index];
    }

    function handCount(bytes32 sessionId) external view returns (uint256) {
        return _handsBySession[sessionId].length;
    }

    function getHand(bytes32 sessionId, uint256 index) external view returns (bytes32 handHash, uint256 recordedAtBlock) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        HandRecord storage r = arr[index];
        return (r.handHash, r.recordedAtBlock);
    }

    function feedbackCount(bytes32 sessionId) external view returns (uint256) {
        return _feedbackBySession[sessionId].length;
    }

    function getFeedback(bytes32 sessionId, uint256 index) external view returns (
        bytes32 feedbackHash,
        uint8 qualityBand,
        uint256 anchoredAtBlock,
        address anchoredBy
    ) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        FeedbackRecord storage r = arr[index];
        return (r.feedbackHash, r.qualityBand, r.anchoredAtBlock, r.anchoredBy);
    }

    function sessionCountForTrainee(address trainee) external view returns (uint256) {
        return _sessionIdsByTrainee[trainee].length;
    }

    function sessionIdForTrainee(address trainee, uint256 index) external view returns (bytes32) {
        if (index >= _sessionIdsByTrainee[trainee].length) revert PKR_InvalidIndex();
        return _sessionIdsByTrainee[trainee][index];
    }

    function trainingLevelReached(address trainee) external view returns (uint8) {
        return _trainingLevelReached[trainee];
    }

    function isSessionClosed(bytes32 sessionId) external view returns (bool) {
        return _sessions[sessionId].closed;
    }

    function isSessionOpen(bytes32 sessionId) external view returns (bool) {
        SessionData storage s = _sessions[sessionId];
        return s.openedAtBlock != 0 && !s.closed;
    }

    // -------------------------------------------------------------------------
    // INTERNAL HELPERS
    // -------------------------------------------------------------------------

    function _computeFeedbackAnchor(bytes32 sessionId, bytes32 feedbackHash, uint8 qualityBand, uint256 atBlock) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PKR_FEEDBACK_ANCHOR, sessionId, feedbackHash, qualityBand, atBlock));
    }

    function _computeHandAnchor(bytes32 sessionId, bytes32 handHash, uint256 handIndex, uint256 atBlock) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PKR_HAND_ANCHOR, sessionId, handHash, handIndex, atBlock));
    }

    // -------------------------------------------------------------------------
    // VIEWS — VERIFICATION (AI POKER TRAINING)
    // -------------------------------------------------------------------------

    function verifyFeedbackAnchor(bytes32 sessionId, uint256 feedbackIndex) external view returns (bytes32 computed) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (feedbackIndex >= arr.length) revert PKR_InvalidIndex();
        FeedbackRecord storage r = arr[feedbackIndex];
        return _computeFeedbackAnchor(sessionId, r.feedbackHash, r.qualityBand, r.anchoredAtBlock);
    }

    function verifyHandAnchor(bytes32 sessionId, uint256 handIndex) external view returns (bytes32 computed) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        if (handIndex >= arr.length) revert PKR_InvalidIndex();
        HandRecord storage r = arr[handIndex];
        return _computeHandAnchor(sessionId, r.handHash, handIndex, r.recordedAtBlock);
    }

    // -------------------------------------------------------------------------
    // VIEWS — PAGINATION & BATCH
    // -------------------------------------------------------------------------

    function getSessionIdsSlice(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 total = _sessionIds.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _sessionIds[offset + i];
    }

    function getHandsSlice(bytes32 sessionId, uint256 offset, uint256 limit) external view returns (
        bytes32[] memory handHashes,
        uint256[] memory recordedAtBlocks
    ) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        uint256 total = arr.length;
        if (offset >= total) {
            handHashes = new bytes32[](0);
            recordedAtBlocks = new uint256[](0);
            return (handHashes, recordedAtBlocks);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        handHashes = new bytes32[](n);
        recordedAtBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            HandRecord storage r = arr[offset + i];
            handHashes[i] = r.handHash;
            recordedAtBlocks[i] = r.recordedAtBlock;
        }
    }

    function getFeedbackSlice(bytes32 sessionId, uint256 offset, uint256 limit) external view returns (
        bytes32[] memory feedbackHashes,
        uint8[] memory qualityBands,
        uint256[] memory anchoredAtBlocks,
        address[] memory anchoredBy
    ) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        uint256 total = arr.length;
        if (offset >= total) {
            feedbackHashes = new bytes32[](0);
            qualityBands = new uint8[](0);
            anchoredAtBlocks = new uint256[](0);
            anchoredBy = new address[](0);
            return (feedbackHashes, qualityBands, anchoredAtBlocks, anchoredBy);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        feedbackHashes = new bytes32[](n);
        qualityBands = new uint8[](n);
        anchoredAtBlocks = new uint256[](n);
        anchoredBy = new address[](n);
