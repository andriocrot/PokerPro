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
        for (uint256 i = 0; i < n; i++) {
            FeedbackRecord storage r = arr[offset + i];
            feedbackHashes[i] = r.feedbackHash;
            qualityBands[i] = r.qualityBand;
            anchoredAtBlocks[i] = r.anchoredAtBlock;
            anchoredBy[i] = r.anchoredBy;
        }
    }

    function averageQualityBand(bytes32 sessionId) external view returns (uint256 numerator, uint256 denominator) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        uint256 len = arr.length;
        if (len == 0) return (0, 0);
        uint256 sum = 0;
        for (uint256 i = 0; i < len; i++) sum += arr[i].qualityBand;
        return (sum, len);
    }

    function getSessionsByTraineeSlice(address trainee, uint256 offset, uint256 limit) external view returns (
        bytes32[] memory ids,
        uint8[] memory stakesTiers,
        uint256[] memory handCounts,
        bool[] memory closedFlags
    ) {
        bytes32[] storage traineeSessions = _sessionIdsByTrainee[trainee];
        uint256 total = traineeSessions.length;
        if (offset >= total) {
            ids = new bytes32[](0);
            stakesTiers = new uint8[](0);
            handCounts = new uint256[](0);
            closedFlags = new bool[](0);
            return (ids, stakesTiers, handCounts, closedFlags);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        stakesTiers = new uint8[](n);
        handCounts = new uint256[](n);
        closedFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 sid = traineeSessions[offset + i];
            SessionData storage s = _sessions[sid];
            ids[i] = sid;
            stakesTiers[i] = s.stakesTier;
            handCounts[i] = s.handCount;
            closedFlags[i] = s.closed;
        }
    }

    function getSessionSummariesBatch(bytes32[] calldata sessionIdsBatch) external view returns (
        address[] memory trainees,
        uint8[] memory stakesTiers,
        uint256[] memory openedAtBlocks,
        uint256[] memory handCounts,
        bool[] memory closedFlags
    ) {
        uint256 n = sessionIdsBatch.length;
        if (n > PKR_MAX_PAGE_SIZE) revert PKR_InvalidIndex();
        trainees = new address[](n);
        stakesTiers = new uint8[](n);
        openedAtBlocks = new uint256[](n);
        handCounts = new uint256[](n);
        closedFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            SessionData storage s = _sessions[sessionIdsBatch[i]];
            trainees[i] = s.trainee;
            stakesTiers[i] = s.stakesTier;
            openedAtBlocks[i] = s.openedAtBlock;
            handCounts[i] = s.handCount;
            closedFlags[i] = s.closed;
        }
    }

    function getConfig() external pure returns (
        uint256 maxSessions,
        uint256 maxHandsPerSession,
        uint256 maxBatchHands,
        uint256 stakesTierMax,
        uint256 qualityBandMax,
        uint256 trainingLevels,
        uint256 maxPageSize
    ) {
        return (
            PKR_MAX_SESSIONS,
            PKR_MAX_HANDS_PER_SESSION,
            PKR_MAX_BATCH_HANDS,
            PKR_STAKES_TIER_MAX,
            PKR_QUALITY_BAND_MAX,
            PKR_TRAINING_LEVELS,
            PKR_MAX_PAGE_SIZE
        );
    }

    function getRoles() external view returns (address trainerAddr, address aiOracleAddr, address vaultKeeperAddr, address vaultAddr) {
        return (trainer, aiOracle, vaultKeeper, vault);
    }

    function getDeployInfo() external view returns (uint256 blockNumber, bool paused) {
        return (deployBlock, trainerPaused);
    }

    function totalHandsRecorded() external view returns (uint256 total) {
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            total += _handsBySession[_sessionIds[i]].length;
        }
    }

    function totalFeedbackAnchored() external view returns (uint256 total) {
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            total += _feedbackBySession[_sessionIds[i]].length;
        }
    }

    function getLatestHand(bytes32 sessionId) external view returns (bytes32 handHash, uint256 recordedAtBlock) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        if (arr.length == 0) revert PKR_InvalidIndex();
        HandRecord storage r = arr[arr.length - 1];
        return (r.handHash, r.recordedAtBlock);
    }

    function getLatestFeedback(bytes32 sessionId) external view returns (
        bytes32 feedbackHash,
        uint8 qualityBand,
        uint256 anchoredAtBlock,
        address anchoredBy
    ) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (arr.length == 0) revert PKR_InvalidIndex();
        FeedbackRecord storage r = arr[arr.length - 1];
        return (r.feedbackHash, r.qualityBand, r.anchoredAtBlock, r.anchoredBy);
    }

    function computeFeedbackAnchor(bytes32 sessionId, bytes32 feedbackHash, uint8 qualityBand, uint256 atBlock) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(PKR_FEEDBACK_ANCHOR, sessionId, feedbackHash, qualityBand, atBlock));
    }

    function computeHandAnchor(bytes32 sessionId, bytes32 handHash, uint256 handIndex, uint256 atBlock) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(PKR_HAND_ANCHOR, sessionId, handHash, handIndex, atBlock));
    }

    function getSessionTrainee(bytes32 sessionId) external view returns (address) {
        return _sessions[sessionId].trainee;
    }

    function getSessionStakesTier(bytes32 sessionId) external view returns (uint8) {
        return _sessions[sessionId].stakesTier;
    }

    function getSessionOpenedAtBlock(bytes32 sessionId) external view returns (uint256) {
        return _sessions[sessionId].openedAtBlock;
    }

    function getSessionClosedAtBlock(bytes32 sessionId) external view returns (uint256) {
        return _sessions[sessionId].closedAtBlock;
    }

    function getSessionHandCount(bytes32 sessionId) external view returns (uint256) {
        return _sessions[sessionId].handCount;
    }

    function getTrainer() external view returns (address) {
        return trainer;
    }

    function getAIOracle() external view returns (address) {
        return aiOracle;
    }

    function getVaultKeeper() external view returns (address) {
        return vaultKeeper;
    }

    function getVault() external view returns (address) {
        return vault;
    }

    function getDeployBlock() external view returns (uint256) {
        return deployBlock;
    }

    function isTrainerPaused() external view returns (bool) {
        return trainerPaused;
    }

    function getDomainSalt() external pure returns (bytes32) {
        return PKR_DOMAIN_SALT;
    }

    function getFeedbackAnchorConstant() external pure returns (bytes32) {
        return PKR_FEEDBACK_ANCHOR;
    }

    function getHandAnchorConstant() external pure returns (bytes32) {
        return PKR_HAND_ANCHOR;
    }

    function getMaxSessions() external pure returns (uint256) {
        return PKR_MAX_SESSIONS;
    }

    function getMaxHandsPerSession() external pure returns (uint256) {
        return PKR_MAX_HANDS_PER_SESSION;
    }

    function getStakesTierMax() external pure returns (uint256) {
        return PKR_STAKES_TIER_MAX;
    }

    function getQualityBandMax() external pure returns (uint256) {
        return PKR_QUALITY_BAND_MAX;
    }

    function getTrainingLevelsMax() external pure returns (uint256) {
        return PKR_TRAINING_LEVELS;
    }

    function getMaxPageSize() external pure returns (uint256) {
        return PKR_MAX_PAGE_SIZE;
    }

    function sessionExists(bytes32 sessionId) external view returns (bool) {
        return _sessions[sessionId].openedAtBlock != 0;
    }

    function getSessionsOpenedAfterBlock(uint256 fromBlock) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_sessions[_sessionIds[i]].openedAtBlock >= fromBlock) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_sessions[_sessionIds[i]].openedAtBlock >= fromBlock) {
                ids[j] = _sessionIds[i];
                j++;
            }
        }
    }

    function getSessionsClosedAfterBlock(uint256 fromBlock) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            SessionData storage s = _sessions[_sessionIds[i]];
            if (s.closed && s.closedAtBlock >= fromBlock) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            SessionData storage s = _sessions[_sessionIds[i]];
            if (s.closed && s.closedAtBlock >= fromBlock) {
                ids[j] = _sessionIds[i];
                j++;
            }
        }
    }

    function getFeedbackAnchorsBatch(bytes32 sessionId, uint256[] calldata indices) external view returns (bytes32[] memory anchors) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        anchors = new bytes32[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] >= arr.length) revert PKR_InvalidIndex();
            FeedbackRecord storage r = arr[indices[i]];
            anchors[i] = _computeFeedbackAnchor(sessionId, r.feedbackHash, r.qualityBand, r.anchoredAtBlock);
        }
    }

    function getHandAnchorsBatch(bytes32 sessionId, uint256[] calldata indices) external view returns (bytes32[] memory anchors) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        anchors = new bytes32[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] >= arr.length) revert PKR_InvalidIndex();
            HandRecord storage r = arr[indices[i]];
            anchors[i] = _computeHandAnchor(sessionId, r.handHash, indices[i], r.recordedAtBlock);
        }
    }

    function qualityBandDistribution(bytes32 sessionId) external view returns (uint256[] memory counts) {
        counts = new uint256[](PKR_QUALITY_BAND_MAX + 1);
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        for (uint256 i = 0; i < arr.length; i++) {
            uint8 b = arr[i].qualityBand;
            if (b <= PKR_QUALITY_BAND_MAX) counts[b]++;
        }
    }

    function medianQualityBand(bytes32 sessionId) external view returns (uint8) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        uint256 len = arr.length;
        if (len == 0) return 0;
        uint256[] memory bands = new uint256[](len);
        for (uint256 i = 0; i < len; i++) bands[i] = arr[i].qualityBand;
        for (uint256 i = 0; i < len - 1; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                if (bands[j] < bands[i]) {
                    uint256 t = bands[i];
                    bands[i] = bands[j];
                    bands[j] = t;
                }
            }
        }
        if (len % 2 == 1) return uint8(bands[len / 2]);
        return uint8((bands[len / 2 - 1] + bands[len / 2]) / 2);
    }

    function getOpenSessionsCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (!_sessions[_sessionIds[i]].closed) count++;
        }
    }

    function getClosedSessionsCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_sessions[_sessionIds[i]].closed) count++;
        }
    }

    function getSessionsByStakesTier(uint8 tier) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_sessions[_sessionIds[i]].stakesTier == tier) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_sessions[_sessionIds[i]].stakesTier == tier) {
                ids[j] = _sessionIds[i];
                j++;
            }
        }
    }

    function emitAIOracleRefreshed() external onlyTrainer {
        emit AIOracleRefreshed(aiOracle, block.number);
    }

    // -------------------------------------------------------------------------
    // EXTENDED VIEWS — BATCH & AGGREGATES
    // -------------------------------------------------------------------------

    function getAverageQualityBandsBatch(bytes32[] calldata sessionIdsBatch) external view returns (uint256[] memory numerators, uint256[] memory denominators) {
        uint256 n = sessionIdsBatch.length;
        if (n > PKR_MAX_PAGE_SIZE) revert PKR_InvalidIndex();
        numerators = new uint256[](n);
        denominators = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            FeedbackRecord[] storage arr = _feedbackBySession[sessionIdsBatch[i]];
            uint256 len = arr.length;
            denominators[i] = len;
            if (len == 0) continue;
            uint256 sum = 0;
            for (uint256 j = 0; j < len; j++) sum += arr[j].qualityBand;
            numerators[i] = sum;
        }
    }

    function getHandCountsBatch(bytes32[] calldata sessionIdsBatch) external view returns (uint256[] memory counts) {
        counts = new uint256[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            counts[i] = _handsBySession[sessionIdsBatch[i]].length;
        }
    }

    function getFeedbackCountsBatch(bytes32[] calldata sessionIdsBatch) external view returns (uint256[] memory counts) {
        counts = new uint256[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            counts[i] = _feedbackBySession[sessionIdsBatch[i]].length;
        }
    }

    function getLatestHandsBatch(bytes32[] calldata sessionIdsBatch) external view returns (bytes32[] memory handHashes, uint256[] memory recordedAtBlocks) {
        uint256 n = sessionIdsBatch.length;
        if (n > PKR_MAX_PAGE_SIZE) revert PKR_InvalidIndex();
        handHashes = new bytes32[](n);
        recordedAtBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            HandRecord[] storage arr = _handsBySession[sessionIdsBatch[i]];
            if (arr.length == 0) {
                handHashes[i] = bytes32(0);
                recordedAtBlocks[i] = 0;
            } else {
                HandRecord storage r = arr[arr.length - 1];
                handHashes[i] = r.handHash;
                recordedAtBlocks[i] = r.recordedAtBlock;
            }
        }
    }

    function getLatestFeedbackBatch(bytes32[] calldata sessionIdsBatch) external view returns (
        bytes32[] memory feedbackHashes,
        uint8[] memory qualityBands,
        uint256[] memory anchoredAtBlocks
    ) {
        uint256 n = sessionIdsBatch.length;
        if (n > PKR_MAX_PAGE_SIZE) revert PKR_InvalidIndex();
        feedbackHashes = new bytes32[](n);
        qualityBands = new uint8[](n);
        anchoredAtBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            FeedbackRecord[] storage arr = _feedbackBySession[sessionIdsBatch[i]];
            if (arr.length == 0) {
                feedbackHashes[i] = bytes32(0);
                qualityBands[i] = 0;
                anchoredAtBlocks[i] = 0;
            } else {
                FeedbackRecord storage r = arr[arr.length - 1];
                feedbackHashes[i] = r.feedbackHash;
                qualityBands[i] = r.qualityBand;
                anchoredAtBlocks[i] = r.anchoredAtBlock;
            }
        }
    }

    function getSessionIdsPaginated(uint256 page, uint256 pageSize) external view returns (bytes32[] memory ids, uint256 total) {
        total = _sessionIds.length;
        uint256 offset = page * pageSize;
        if (offset >= total) return (new bytes32[](0), total);
        uint256 end = offset + pageSize;
        if (end > total) end = total;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _sessionIds[offset + i];
    }

    function getFirstNSessionIds(uint256 n) external view returns (bytes32[] memory ids) {
        uint256 total = _sessionIds.length;
        if (n > total) n = total;
        if (n == 0) return new bytes32[](0);
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _sessionIds[i];
    }

    function getLastNSessionIds(uint256 n) external view returns (bytes32[] memory ids) {
        uint256 total = _sessionIds.length;
        if (n > total) n = total;
        if (n == 0) return new bytes32[](0);
        ids = new bytes32[](n);
        uint256 start = total - n;
        for (uint256 i = 0; i < n; i++) ids[i] = _sessionIds[start + i];
    }

    function getTraineesWithSessions() external view returns (address[] memory trainees) {
        uint256 cap = _sessionIds.length;
        address[] memory temp = new address[](cap);
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            address t = _sessions[_sessionIds[i]].trainee;
            bool found = false;
            for (uint256 j = 0; j < count; j++) {
                if (temp[j] == t) { found = true; break; }
            }
            if (!found) {
                temp[count] = t;
                count++;
            }
        }
        trainees = new address[](count);
        for (uint256 i = 0; i < count; i++) trainees[i] = temp[i];
    }

    function getTrainingLevelsBatch(address[] calldata trainees) external view returns (uint8[] memory levels) {
        levels = new uint8[](trainees.length);
        for (uint256 i = 0; i < trainees.length; i++) {
            levels[i] = _trainingLevelReached[trainees[i]];
        }
    }

    function getSessionClosedAt(bytes32 sessionId) external view returns (uint256) {
        return _sessions[sessionId].closedAtBlock;
    }

    function getSessionOpenedAt(bytes32 sessionId) external view returns (uint256) {
        return _sessions[sessionId].openedAtBlock;
    }

    function getHandHashAt(bytes32 sessionId, uint256 index) external view returns (bytes32) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].handHash;
    }

    function getHandRecordedAtBlock(bytes32 sessionId, uint256 index) external view returns (uint256) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].recordedAtBlock;
    }

    function getFeedbackHashAt(bytes32 sessionId, uint256 index) external view returns (bytes32) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].feedbackHash;
    }

    function getFeedbackQualityBandAt(bytes32 sessionId, uint256 index) external view returns (uint8) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].qualityBand;
    }

    function getFeedbackAnchoredAtBlock(bytes32 sessionId, uint256 index) external view returns (uint256) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].anchoredAtBlock;
    }

    function getFeedbackAnchoredBy(bytes32 sessionId, uint256 index) external view returns (address) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].anchoredBy;
    }

    function getAllHandHashes(bytes32 sessionId) external view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](_handsBySession[sessionId].length);
        HandRecord[] storage arr = _handsBySession[sessionId];
        for (uint256 i = 0; i < arr.length; i++) hashes[i] = arr[i].handHash;
    }

    function getAllFeedbackHashes(bytes32 sessionId) external view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](_feedbackBySession[sessionId].length);
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        for (uint256 i = 0; i < arr.length; i++) hashes[i] = arr[i].feedbackHash;
    }

    function getFullSession(bytes32 sessionId) external view returns (
        address trainee_,
        uint8 stakesTier_,
        uint256 openedAtBlock_,
        uint256 closedAtBlock_,
        uint256 handCount_,
        bool closed_,
        bytes32[] memory handHashes_,
        bytes32[] memory feedbackHashes_
    ) {
        SessionData storage s = _sessions[sessionId];
        if (s.openedAtBlock == 0) revert PKR_SessionNotFound();
        trainee_ = s.trainee;
        stakesTier_ = s.stakesTier;
        openedAtBlock_ = s.openedAtBlock;
        closedAtBlock_ = s.closedAtBlock;
        handCount_ = s.handCount;
        closed_ = s.closed;
        HandRecord[] storage hands = _handsBySession[sessionId];
        handHashes_ = new bytes32[](hands.length);
        for (uint256 i = 0; i < hands.length; i++) handHashes_[i] = hands[i].handHash;
        FeedbackRecord[] storage feedbacks = _feedbackBySession[sessionId];
        feedbackHashes_ = new bytes32[](feedbacks.length);
        for (uint256 i = 0; i < feedbacks.length; i++) feedbackHashes_[i] = feedbacks[i].feedbackHash;
    }

    function getPKRFeedbackCacheBlocks() external pure returns (uint256) {
        return PKR_FEEDBACK_CACHE_BLOCKS;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function contractName() external pure returns (string memory) {
        return "PokerPro";
    }

    function totalSessions() external view returns (uint256) {
        return _sessionIds.length;
    }

    function sessionTrainee(bytes32 sessionId) external view returns (address) {
        return _sessions[sessionId].trainee;
    }

    function sessionStakesTier(bytes32 sessionId) external view returns (uint8) {
        return _sessions[sessionId].stakesTier;
    }

    function sessionOpenedBlock(bytes32 sessionId) external view returns (uint256) {
        return _sessions[sessionId].openedAtBlock;
    }

    function sessionClosedBlock(bytes32 sessionId) external view returns (uint256) {
        return _sessions[sessionId].closedAtBlock;
    }

    function sessionHandCount(bytes32 sessionId) external view returns (uint256) {
        return _sessions[sessionId].handCount;
    }

    function sessionIsClosed(bytes32 sessionId) external view returns (bool) {
        return _sessions[sessionId].closed;
    }

    function trainerAddress() external view returns (address) {
        return trainer;
    }

    function aiOracleAddress() external view returns (address) {
        return aiOracle;
    }

    function vaultKeeperAddress() external view returns (address) {
        return vaultKeeper;
    }

    function vaultAddress() external view returns (address) {
        return vault;
    }

    function deployBlockNumber() external view returns (uint256) {
        return deployBlock;
    }

    function paused() external view returns (bool) {
        return trainerPaused;
    }

    function domainSalt() external pure returns (bytes32) {
        return PKR_DOMAIN_SALT;
    }

    function feedbackAnchorSalt() external pure returns (bytes32) {
        return PKR_FEEDBACK_ANCHOR;
    }

    function handAnchorSalt() external pure returns (bytes32) {
        return PKR_HAND_ANCHOR;
    }

    function maxSessionsLimit() external pure returns (uint256) {
        return PKR_MAX_SESSIONS;
    }

    function maxHandsPerSessionLimit() external pure returns (uint256) {
        return PKR_MAX_HANDS_PER_SESSION;
    }

    function maxBatchHandsLimit() external pure returns (uint256) {
        return PKR_MAX_BATCH_HANDS;
    }

    function stakesTierMaximum() external pure returns (uint256) {
        return PKR_STAKES_TIER_MAX;
    }

    function qualityBandMaximum() external pure returns (uint256) {
        return PKR_QUALITY_BAND_MAX;
    }

    function trainingLevelsMaximum() external pure returns (uint256) {
        return PKR_TRAINING_LEVELS;
    }

    function maxPageSizeLimit() external pure returns (uint256) {
        return PKR_MAX_PAGE_SIZE;
    }

    function feedbackCacheBlocks() external pure returns (uint256) {
        return PKR_FEEDBACK_CACHE_BLOCKS;
    }

    function existsSession(bytes32 sessionId) external view returns (bool) {
        return _sessions[sessionId].openedAtBlock != 0;
    }

    function handsRecordedInSession(bytes32 sessionId) external view returns (uint256) {
        return _handsBySession[sessionId].length;
    }

    function feedbackAnchoredInSession(bytes32 sessionId) external view returns (uint256) {
        return _feedbackBySession[sessionId].length;
    }

    function traineeSessionCount(address trainee) external view returns (uint256) {
        return _sessionIdsByTrainee[trainee].length;
    }

    function traineeSessionAt(address trainee, uint256 index) external view returns (bytes32) {
        if (index >= _sessionIdsByTrainee[trainee].length) revert PKR_InvalidIndex();
        return _sessionIdsByTrainee[trainee][index];
    }

    function trainingLevelOf(address trainee) external view returns (uint8) {
        return _trainingLevelReached[trainee];
    }

    function getHandsRecordedAfterBlock(bytes32 sessionId, uint256 fromBlock) external view returns (
        uint256[] memory indices,
        bytes32[] memory handHashes,
        uint256[] memory recordedAtBlocks
    ) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        uint256 count = 0;
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].recordedAtBlock >= fromBlock) count++;
        }
        indices = new uint256[](count);
        handHashes = new bytes32[](count);
        recordedAtBlocks = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].recordedAtBlock >= fromBlock) {
                indices[j] = i;
                handHashes[j] = arr[i].handHash;
                recordedAtBlocks[j] = arr[i].recordedAtBlock;
                j++;
            }
        }
    }

    function getFeedbackAnchoredAfterBlock(bytes32 sessionId, uint256 fromBlock) external view returns (
        uint256[] memory indices,
        bytes32[] memory feedbackHashes,
        uint8[] memory qualityBands,
        uint256[] memory anchoredAtBlocks
    ) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        uint256 count = 0;
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].anchoredAtBlock >= fromBlock) count++;
        }
        indices = new uint256[](count);
        feedbackHashes = new bytes32[](count);
        qualityBands = new uint8[](count);
        anchoredAtBlocks = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].anchoredAtBlock >= fromBlock) {
                indices[j] = i;
                feedbackHashes[j] = arr[i].feedbackHash;
                qualityBands[j] = arr[i].qualityBand;
                anchoredAtBlocks[j] = arr[i].anchoredAtBlock;
                j++;
            }
        }
    }

    function getSessionsWithMinHands(uint256 minHands) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_handsBySession[_sessionIds[i]].length >= minHands) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_handsBySession[_sessionIds[i]].length >= minHands) {
                ids[j] = _sessionIds[i];
                j++;
            }
        }
    }

    function getSessionsWithMinFeedback(uint256 minFeedback) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_feedbackBySession[_sessionIds[i]].length >= minFeedback) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            if (_feedbackBySession[_sessionIds[i]].length >= minFeedback) {
                ids[j] = _sessionIds[i];
                j++;
            }
        }
    }

    function getTopSessionsByHandCount(uint256 limit) external view returns (bytes32[] memory ids, uint256[] memory counts) {
        uint256 n = _sessionIds.length;
        if (n == 0) {
            ids = new bytes32[](0);
            counts = new uint256[](0);
            return (ids, counts);
        }
        if (limit > n) limit = n;
        ids = new bytes32[](limit);
        counts = new uint256[](limit);
        uint256[] memory indices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) indices[i] = i;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                uint256 ci = _handsBySession[_sessionIds[indices[i]]].length;
                uint256 cj = _handsBySession[_sessionIds[indices[j]]].length;
                if (cj > ci) {
                    uint256 t = indices[i];
                    indices[i] = indices[j];
                    indices[j] = t;
                }
            }
        }
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = _sessionIds[indices[i]];
            counts[i] = _handsBySession[ids[i]].length;
        }
    }

    function getTopSessionsByFeedbackCount(uint256 limit) external view returns (bytes32[] memory ids, uint256[] memory counts) {
        uint256 n = _sessionIds.length;
        if (n == 0) {
            ids = new bytes32[](0);
            counts = new uint256[](0);
            return (ids, counts);
        }
        if (limit > n) limit = n;
        ids = new bytes32[](limit);
        counts = new uint256[](limit);
        uint256[] memory indices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) indices[i] = i;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                uint256 ci = _feedbackBySession[_sessionIds[indices[i]]].length;
                uint256 cj = _feedbackBySession[_sessionIds[indices[j]]].length;
                if (cj > ci) {
                    uint256 t = indices[i];
                    indices[i] = indices[j];
                    indices[j] = t;
                }
            }
        }
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = _sessionIds[indices[i]];
            counts[i] = _feedbackBySession[ids[i]].length;
        }
    }

    function getQualityBandDistributionsBatch(bytes32[] calldata sessionIdsBatch) external view returns (uint256[][] memory distributions) {
        uint256 n = sessionIdsBatch.length;
        if (n > PKR_MAX_PAGE_SIZE) revert PKR_InvalidIndex();
        distributions = new uint256[][](n);
        for (uint256 idx = 0; idx < n; idx++) {
            uint256[] memory counts = new uint256[](PKR_QUALITY_BAND_MAX + 1);
            FeedbackRecord[] storage arr = _feedbackBySession[sessionIdsBatch[idx]];
            for (uint256 i = 0; i < arr.length; i++) {
                uint8 b = arr[i].qualityBand;
                if (b <= PKR_QUALITY_BAND_MAX) counts[b]++;
            }
            distributions[idx] = counts;
        }
    }

    function getMedianQualityBandsBatch(bytes32[] calldata sessionIdsBatch) external view returns (uint8[] memory medians) {
        uint256 n = sessionIdsBatch.length;
        if (n > PKR_MAX_PAGE_SIZE) revert PKR_InvalidIndex();
        medians = new uint8[](n);
        for (uint256 idx = 0; idx < n; idx++) {
            FeedbackRecord[] storage arr = _feedbackBySession[sessionIdsBatch[idx]];
            uint256 len = arr.length;
            if (len == 0) {
                medians[idx] = 0;
                continue;
            }
            uint256[] memory bands = new uint256[](len);
            for (uint256 i = 0; i < len; i++) bands[i] = arr[i].qualityBand;
            for (uint256 i = 0; i < len - 1; i++) {
                for (uint256 j = i + 1; j < len; j++) {
                    if (bands[j] < bands[i]) {
                        uint256 t = bands[i];
                        bands[i] = bands[j];
                        bands[j] = t;
                    }
                }
            }
            if (len % 2 == 1) medians[idx] = uint8(bands[len / 2]);
            else medians[idx] = uint8((bands[len / 2 - 1] + bands[len / 2]) / 2);
        }
    }

    function getStakesTierDistribution() external view returns (uint256[] memory counts) {
        counts = new uint256[](PKR_STAKES_TIER_MAX + 1);
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            uint8 t = _sessions[_sessionIds[i]].stakesTier;
            if (t <= PKR_STAKES_TIER_MAX) counts[t]++;
        }
    }

    function getSessionBatchExists(bytes32[] calldata sessionIdsBatch) external view returns (bool[] memory exists) {
        exists = new bool[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            exists[i] = _sessions[sessionIdsBatch[i]].openedAtBlock != 0;
        }
    }

    function getSessionBatchClosed(bytes32[] calldata sessionIdsBatch) external view returns (bool[] memory closed) {
        closed = new bool[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            closed[i] = _sessions[sessionIdsBatch[i]].closed;
        }
    }

    function getSessionBatchTrainees(bytes32[] calldata sessionIdsBatch) external view returns (address[] memory trainees) {
        trainees = new address[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            trainees[i] = _sessions[sessionIdsBatch[i]].trainee;
        }
    }

    function getSessionBatchStakesTiers(bytes32[] calldata sessionIdsBatch) external view returns (uint8[] memory tiers) {
        tiers = new uint8[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            tiers[i] = _sessions[sessionIdsBatch[i]].stakesTier;
        }
    }

    function getSessionBatchOpenedBlocks(bytes32[] calldata sessionIdsBatch) external view returns (uint256[] memory blocks) {
        blocks = new uint256[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            blocks[i] = _sessions[sessionIdsBatch[i]].openedAtBlock;
        }
    }

    function getSessionBatchHandCounts(bytes32[] calldata sessionIdsBatch) external view returns (uint256[] memory counts) {
        counts = new uint256[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            counts[i] = _handsBySession[sessionIdsBatch[i]].length;
        }
    }

    function getSessionBatchFeedbackCounts(bytes32[] calldata sessionIdsBatch) external view returns (uint256[] memory counts) {
        counts = new uint256[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            counts[i] = _feedbackBySession[sessionIdsBatch[i]].length;
        }
    }

    function getSessionBatchClosedBlocks(bytes32[] calldata sessionIdsBatch) external view returns (uint256[] memory blocks) {
        blocks = new uint256[](sessionIdsBatch.length);
        for (uint256 i = 0; i < sessionIdsBatch.length; i++) {
            blocks[i] = _sessions[sessionIdsBatch[i]].closedAtBlock;
        }
    }

    function getHandRecordsFull(bytes32 sessionId) external view returns (
        bytes32[] memory handHashes,
        uint256[] memory recordedAtBlocks,
        bytes32[] memory handAnchors
    ) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        uint256 n = arr.length;
        handHashes = new bytes32[](n);
        recordedAtBlocks = new uint256[](n);
        handAnchors = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            handHashes[i] = arr[i].handHash;
            recordedAtBlocks[i] = arr[i].recordedAtBlock;
            handAnchors[i] = _computeHandAnchor(sessionId, arr[i].handHash, i, arr[i].recordedAtBlock);
        }
    }

    function getFeedbackRecordsFull(bytes32 sessionId) external view returns (
        bytes32[] memory feedbackHashes,
        uint8[] memory qualityBands,
        uint256[] memory anchoredAtBlocks,
        address[] memory anchoredBy,
        bytes32[] memory feedbackAnchors
    ) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        uint256 n = arr.length;
        feedbackHashes = new bytes32[](n);
        qualityBands = new uint8[](n);
        anchoredAtBlocks = new uint256[](n);
        anchoredBy = new address[](n);
        feedbackAnchors = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            feedbackHashes[i] = arr[i].feedbackHash;
            qualityBands[i] = arr[i].qualityBand;
            anchoredAtBlocks[i] = arr[i].anchoredAtBlock;
            anchoredBy[i] = arr[i].anchoredBy;
            feedbackAnchors[i] = _computeFeedbackAnchor(sessionId, arr[i].feedbackHash, arr[i].qualityBand, arr[i].anchoredAtBlock);
        }
    }

    function getGuidesSliceFull(uint256 offset, uint256 limit) external view returns (
        bytes32[] memory sessionIds,
        address[] memory trainees,
        uint8[] memory stakesTiers,
        uint256[] memory handCounts,
        uint256[] memory feedbackCounts,
        bool[] memory closedFlags
    ) {
        uint256 total = _sessionIds.length;
        if (offset >= total) {
            sessionIds = new bytes32[](0);
            trainees = new address[](0);
            stakesTiers = new uint8[](0);
            handCounts = new uint256[](0);
            feedbackCounts = new uint256[](0);
            closedFlags = new bool[](0);
            return (sessionIds, trainees, stakesTiers, handCounts, feedbackCounts, closedFlags);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        sessionIds = new bytes32[](n);
        trainees = new address[](n);
        stakesTiers = new uint8[](n);
        handCounts = new uint256[](n);
        feedbackCounts = new uint256[](n);
        closedFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 sid = _sessionIds[offset + i];
            SessionData storage s = _sessions[sid];
            sessionIds[i] = sid;
            trainees[i] = s.trainee;
            stakesTiers[i] = s.stakesTier;
            handCounts[i] = s.handCount;
            feedbackCounts[i] = _feedbackBySession[sid].length;
            closedFlags[i] = s.closed;
        }
    }

    function getTraineeStats(address trainee) external view returns (
        uint256 sessionCount_,
        uint256 totalHands_,
        uint256 totalFeedback_,
        uint8 levelReached_
    ) {
        bytes32[] storage sids = _sessionIdsByTrainee[trainee];
        sessionCount_ = sids.length;
        levelReached_ = _trainingLevelReached[trainee];
        for (uint256 i = 0; i < sids.length; i++) {
            totalHands_ += _handsBySession[sids[i]].length;
            totalFeedback_ += _feedbackBySession[sids[i]].length;
        }
    }

    function getSessionsByTraineeFull(address trainee) external view returns (
        bytes32[] memory ids,
        uint8[] memory stakesTiers,
        uint256[] memory openedAtBlocks,
        uint256[] memory closedAtBlocks,
        uint256[] memory handCounts,
        uint256[] memory feedbackCounts,
        bool[] memory closedFlags
    ) {
        bytes32[] storage sids = _sessionIdsByTrainee[trainee];
        uint256 n = sids.length;
        ids = new bytes32[](n);
        stakesTiers = new uint8[](n);
        openedAtBlocks = new uint256[](n);
        closedAtBlocks = new uint256[](n);
        handCounts = new uint256[](n);
        feedbackCounts = new uint256[](n);
        closedFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            SessionData storage s = _sessions[sids[i]];
            ids[i] = sids[i];
            stakesTiers[i] = s.stakesTier;
            openedAtBlocks[i] = s.openedAtBlock;
            closedAtBlocks[i] = s.closedAtBlock;
            handCounts[i] = s.handCount;
            feedbackCounts[i] = _feedbackBySession[sids[i]].length;
            closedFlags[i] = s.closed;
        }
    }

    function getContractInfo() external pure returns (
        string memory name,
        uint256 version_
    ) {
        return ("PokerPro", 1);
    }

    function supportsSession(bytes32 sessionId) external view returns (bool) {
        return _sessions[sessionId].openedAtBlock != 0;
    }

    function hasHands(bytes32 sessionId) external view returns (bool) {
        return _handsBySession[sessionId].length > 0;
    }

    function hasFeedback(bytes32 sessionId) external view returns (bool) {
        return _feedbackBySession[sessionId].length > 0;
    }

    function canReceiveEth() external pure returns (bool) {
        return true;
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function pkrMaxBatchHands() external pure returns (uint256) { return PKR_MAX_BATCH_HANDS; }
    function pkrFeedbackCacheBlocks() external pure returns (uint256) { return PKR_FEEDBACK_CACHE_BLOCKS; }
    function saltDomain() external pure returns (bytes32) { return PKR_DOMAIN_SALT; }
    function saltFeedbackAnchor() external pure returns (bytes32) { return PKR_FEEDBACK_ANCHOR; }
    function saltHandAnchor() external pure returns (bytes32) { return PKR_HAND_ANCHOR; }
    function roleTrainer() external view returns (address) { return trainer; }
    function roleAIOracle() external view returns (address) { return aiOracle; }
    function roleVaultKeeper() external view returns (address) { return vaultKeeper; }
    function roleVault() external view returns (address) { return vault; }
    function blockDeployed() external view returns (uint256) { return deployBlock; }
    function isPaused() external view returns (bool) { return trainerPaused; }
    function totalSessionCount() external view returns (uint256) { return _sessionIds.length; }
    function handCountForSession(bytes32 sessionId) external view returns (uint256) { return _handsBySession[sessionId].length; }
    function feedbackCountForSession(bytes32 sessionId) external view returns (uint256) { return _feedbackBySession[sessionId].length; }
    function traineeForSession(bytes32 sessionId) external view returns (address) { return _sessions[sessionId].trainee; }
    function stakesTierForSession(bytes32 sessionId) external view returns (uint8) { return _sessions[sessionId].stakesTier; }
    function openedBlockForSession(bytes32 sessionId) external view returns (uint256) { return _sessions[sessionId].openedAtBlock; }
    function closedBlockForSession(bytes32 sessionId) external view returns (uint256) { return _sessions[sessionId].closedAtBlock; }
    function closedForSession(bytes32 sessionId) external view returns (bool) { return _sessions[sessionId].closed; }
    function levelForTrainee(address trainee) external view returns (uint8) { return _trainingLevelReached[trainee]; }
    function sessionIdsForTraineeCount(address trainee) external view returns (uint256) { return _sessionIdsByTrainee[trainee].length; }
    function sessionIdForTraineeAt(address trainee, uint256 index) external view returns (bytes32) {
        if (index >= _sessionIdsByTrainee[trainee].length) revert PKR_InvalidIndex();
        return _sessionIdsByTrainee[trainee][index];
    }
    function handHashAt(bytes32 sessionId, uint256 index) external view returns (bytes32) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].handHash;
    }
    function handBlockAt(bytes32 sessionId, uint256 index) external view returns (uint256) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].recordedAtBlock;
    }
    function feedbackHashAt(bytes32 sessionId, uint256 index) external view returns (bytes32) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].feedbackHash;
    }
    function feedbackQualityAt(bytes32 sessionId, uint256 index) external view returns (uint8) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].qualityBand;
    }
    function feedbackBlockAt(bytes32 sessionId, uint256 index) external view returns (uint256) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].anchoredAtBlock;
    }
    function feedbackAnchoredByAt(bytes32 sessionId, uint256 index) external view returns (address) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        if (index >= arr.length) revert PKR_InvalidIndex();
        return arr[index].anchoredBy;
    }
    function computeFeedbackHash(bytes32 sessionId, bytes32 feedbackHash, uint8 qualityBand, uint256 atBlock) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(PKR_FEEDBACK_ANCHOR, sessionId, feedbackHash, qualityBand, atBlock));
    }
    function computeHandHash(bytes32 sessionId, bytes32 handHash, uint256 handIndex, uint256 atBlock) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(PKR_HAND_ANCHOR, sessionId, handHash, handIndex, atBlock));
    }

    function getSessionAtIndex(uint256 index) external view returns (bytes32) {
        if (index >= _sessionIds.length) revert PKR_InvalidIndex();
        return _sessionIds[index];
    }

    function getSessionsBetweenBlocks(uint256 fromBlock, uint256 toBlock) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            uint256 b = _sessions[_sessionIds[i]].openedAtBlock;
            if (b >= fromBlock && b <= toBlock) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            uint256 b = _sessions[_sessionIds[i]].openedAtBlock;
            if (b >= fromBlock && b <= toBlock) {
                ids[j] = _sessionIds[i];
                j++;
            }
        }
    }

    function getClosedSessionsBetweenBlocks(uint256 fromBlock, uint256 toBlock) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            SessionData storage s = _sessions[_sessionIds[i]];
            if (s.closed && s.closedAtBlock >= fromBlock && s.closedAtBlock <= toBlock) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            SessionData storage s = _sessions[_sessionIds[i]];
            if (s.closed && s.closedAtBlock >= fromBlock && s.closedAtBlock <= toBlock) {
                ids[j] = _sessionIds[i];
                j++;
            }
        }
    }

    function getDistinctTraineeCount() external view returns (uint256 count) {
        uint256 cap = _sessionIds.length;
        address[] memory seen = new address[](cap);
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            address t = _sessions[_sessionIds[i]].trainee;
            bool found = false;
            for (uint256 j = 0; j < count; j++) {
                if (seen[j] == t) { found = true; break; }
            }
            if (!found) {
                seen[count] = t;
                count++;
            }
        }
    }

    function getSessionsWithStakesTierBetween(uint8 tierLow, uint8 tierHigh) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            uint8 t = _sessions[_sessionIds[i]].stakesTier;
            if (t >= tierLow && t <= tierHigh) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            uint8 t = _sessions[_sessionIds[i]].stakesTier;
            if (t >= tierLow && t <= tierHigh) {
                ids[j] = _sessionIds[i];
                j++;
            }
        }
    }

    function getTotalHandsAcrossAllSessions() external view returns (uint256 total) {
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            total += _handsBySession[_sessionIds[i]].length;
        }
    }

    function getTotalFeedbackAcrossAllSessions() external view returns (uint256 total) {
        for (uint256 i = 0; i < _sessionIds.length; i++) {
            total += _feedbackBySession[_sessionIds[i]].length;
        }
    }

    function getSessionSummary(bytes32 sessionId) external view returns (
        address trainee_,
        uint8 stakesTier_,
        uint256 handCount_,
        uint256 feedbackCount_,
        bool closed_
    ) {
        SessionData storage s = _sessions[sessionId];
        if (s.openedAtBlock == 0) revert PKR_SessionNotFound();
        return (
            s.trainee,
            s.stakesTier,
            s.handCount,
            _feedbackBySession[sessionId].length,
            s.closed
        );
    }

    function getSessionSummariesForTrainee(address trainee) external view returns (
        bytes32[] memory ids,
        uint8[] memory stakesTiers,
        uint256[] memory handCounts,
        uint256[] memory feedbackCounts,
        bool[] memory closedFlags
    ) {
        bytes32[] storage sids = _sessionIdsByTrainee[trainee];
        uint256 n = sids.length;
        ids = new bytes32[](n);
        stakesTiers = new uint8[](n);
        handCounts = new uint256[](n);
        feedbackCounts = new uint256[](n);
        closedFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            SessionData storage s = _sessions[sids[i]];
            ids[i] = sids[i];
            stakesTiers[i] = s.stakesTier;
            handCounts[i] = s.handCount;
            feedbackCounts[i] = _feedbackBySession[sids[i]].length;
            closedFlags[i] = s.closed;
        }
    }

    function verifyAllFeedbackAnchorsForSession(bytes32 sessionId) external view returns (bytes32[] memory anchors) {
        FeedbackRecord[] storage arr = _feedbackBySession[sessionId];
        anchors = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            anchors[i] = _computeFeedbackAnchor(sessionId, arr[i].feedbackHash, arr[i].qualityBand, arr[i].anchoredAtBlock);
        }
    }

    function verifyAllHandAnchorsForSession(bytes32 sessionId) external view returns (bytes32[] memory anchors) {
        HandRecord[] storage arr = _handsBySession[sessionId];
        anchors = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            anchors[i] = _computeHandAnchor(sessionId, arr[i].handHash, i, arr[i].recordedAtBlock);
        }
    }

    function getConstants() external pure returns (
        uint256 maxSessions_,
        uint256 maxHandsPerSession_,
        uint256 maxBatchHands_,
        uint256 stakesTierMax_,
        uint256 qualityBandMax_,
        uint256 trainingLevels_,
        uint256 maxPageSize_,
        uint256 feedbackCacheBlocks_
    ) {
        return (
            PKR_MAX_SESSIONS,
            PKR_MAX_HANDS_PER_SESSION,
            PKR_MAX_BATCH_HANDS,
            PKR_STAKES_TIER_MAX,
            PKR_QUALITY_BAND_MAX,
            PKR_TRAINING_LEVELS,
            PKR_MAX_PAGE_SIZE,
            PKR_FEEDBACK_CACHE_BLOCKS
        );
    }

    function getRoleAddresses() external view returns (
        address trainer_,
        address aiOracle_,
        address vaultKeeper_,
        address vault_
    ) {
        return (trainer, aiOracle, vaultKeeper, vault);
    }

    function getSalts() external pure returns (
        bytes32 domainSalt_,
        bytes32 feedbackAnchor_,
        bytes32 handAnchor_
    ) {
        return (PKR_DOMAIN_SALT, PKR_FEEDBACK_ANCHOR, PKR_HAND_ANCHOR);
    }

    function sessionTraineeAddress(bytes32 sessionId) external view returns (address) { return _sessions[sessionId].trainee; }
    function sessionStakesTierValue(bytes32 sessionId) external view returns (uint8) { return _sessions[sessionId].stakesTier; }
    function sessionOpenedAt(bytes32 sessionId) external view returns (uint256) { return _sessions[sessionId].openedAtBlock; }
    function sessionClosedAt(bytes32 sessionId) external view returns (uint256) { return _sessions[sessionId].closedAtBlock; }
    function sessionNumberOfHands(bytes32 sessionId) external view returns (uint256) { return _sessions[sessionId].handCount; }
    function sessionIsClosedFlag(bytes32 sessionId) external view returns (bool) { return _sessions[sessionId].closed; }
    function trainerRole() external view returns (address) { return trainer; }
    function aiOracleRole() external view returns (address) { return aiOracle; }
    function vaultKeeperRole() external view returns (address) { return vaultKeeper; }
    function vaultRole() external view returns (address) { return vault; }
    function deployedAtBlock() external view returns (uint256) { return deployBlock; }
    function trainerPausedFlag() external view returns (bool) { return trainerPaused; }
    function totalSessionsCount() external view returns (uint256) { return _sessionIds.length; }
    function numberOfHandsInSession(bytes32 sessionId) external view returns (uint256) { return _handsBySession[sessionId].length; }
    function numberOfFeedbackInSession(bytes32 sessionId) external view returns (uint256) { return _feedbackBySession[sessionId].length; }
    function sessionBelongsToTrainee(bytes32 sessionId) external view returns (address) { return _sessions[sessionId].trainee; }
    function sessionStakesLevel(bytes32 sessionId) external view returns (uint8) { return _sessions[sessionId].stakesTier; }
    function sessionOpenBlock(bytes32 sessionId) external view returns (uint256) { return _sessions[sessionId].openedAtBlock; }
    function sessionCloseBlock(bytes32 sessionId) external view returns (uint256) { return _sessions[sessionId].closedAtBlock; }
    function sessionClosedFlag(bytes32 sessionId) external view returns (bool) { return _sessions[sessionId].closed; }
    function trainingLevelUnlocked(address trainee) external view returns (uint8) { return _trainingLevelReached[trainee]; }
    function countSessionsForTrainee(address trainee) external view returns (uint256) { return _sessionIdsByTrainee[trainee].length; }
    function sessionIdOfTrainee(address trainee, uint256 index) external view returns (bytes32) {
        if (index >= _sessionIdsByTrainee[trainee].length) revert PKR_InvalidIndex();
        return _sessionIdsByTrainee[trainee][index];
    }

    function maxSessionsConstant() external pure returns (uint256) { return PKR_MAX_SESSIONS; }
    function maxHandsPerSessionConstant() external pure returns (uint256) { return PKR_MAX_HANDS_PER_SESSION; }
    function maxBatchHandsConstant() external pure returns (uint256) { return PKR_MAX_BATCH_HANDS; }
    function stakesTierMaxConstant() external pure returns (uint256) { return PKR_STAKES_TIER_MAX; }
    function qualityBandMaxConstant() external pure returns (uint256) { return PKR_QUALITY_BAND_MAX; }
    function trainingLevelsConstant() external pure returns (uint256) { return PKR_TRAINING_LEVELS; }
    function maxPageSizeConstant() external pure returns (uint256) { return PKR_MAX_PAGE_SIZE; }
    function feedbackCacheBlocksConstant() external pure returns (uint256) { return PKR_FEEDBACK_CACHE_BLOCKS; }
    function domainSaltConstant() external pure returns (bytes32) { return PKR_DOMAIN_SALT; }
    function feedbackAnchorConstant() external pure returns (bytes32) { return PKR_FEEDBACK_ANCHOR; }
    function handAnchorConstant() external pure returns (bytes32) { return PKR_HAND_ANCHOR; }
    function trainerAddressImmutable() external view returns (address) { return trainer; }
    function aiOracleAddressImmutable() external view returns (address) { return aiOracle; }
    function vaultKeeperAddressImmutable() external view returns (address) { return vaultKeeper; }
    function vaultAddressState() external view returns (address) { return vault; }
    function deployBlockImmutable() external view returns (uint256) { return deployBlock; }
    function pausedState() external view returns (bool) { return trainerPaused; }
