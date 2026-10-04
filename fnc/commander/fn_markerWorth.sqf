// MARKER STRATEGIC WORTH - the ONE derivation of "how important does this mission think this
// marker is, judging it by itself and by its neighbours".
//
// This arithmetic already existed, inline, inside MISSION_CORE_fnc_providerBudget. It is EXTRACTED
// here rather than copied, so the counter-attack budget and the two request channels can never
// drift apart about a marker's worth. That is not hypothetical caution: MISSION_CORE_fnc_providerCanAfford
// exists purely because this question used to be answered in several places with several different
// answers, and fn_markerHasReinforceNeed.sqf exists to stop providerBudget answering it twice.
//
// THE TWO TERMS ARE COMPUTED OVER DIFFERENT REFERENCE MARKERS. That is the whole reason this
// function takes two of them instead of one:
//   _cVal  - self-value of the SUBJECT marker. In providerBudget the subject is the CONTESTED
//            marker (saving a factory is worth double what saving an outpost is). In a supply or
//            ammo request the subject is the REQUESTING marker itself.
//   _asset - surroundings of the SELF marker: sitting beside something valuable means more at
//            stake. In providerBudget self is the PROVIDER. In a request self is the REQUESTER.
// Scoring both terms off one marker would compute _asset around the wrong location and silently
// retune every counter-attack on the map, so the roles stay explicit and separate.
//
// usage - MISSION_CORE_fnc_markerWorth:
//   _selfLoc     CACHED_POSITIONS row for the marker whose SURROUNDINGS are scored
//   _subjectLoc  optional CACHED_POSITIONS row whose own tier sets _cVal; defaults to _selfLoc
//   _side        optional side; defaults to _selfLoc select 4
// returns: [_cVal, _asset, _cVal * _asset]   // worth spans 1.0 - 4.0
MISSION_CORE_fnc_markerWorth = {
    // PERMANENT RULE (live crash, fixed here): the optional args are probed with isNil, NEVER with
    // a typed sentinel. `_side` arrives from providerBudget as a SIDE (EAST / WEST) - it is the
    // value stored in CACHED_POSITIONS select 4, not a number. A numeric probe such as
    // `if (_side < 0)` is therefore a RUNTIME type error, not a false test:
    //   Error <: Type Side, expected Number, Not a Number
    // and it fires on the counter-attack path, so providerBudget throws and the contested zone
    // silently receives no reinforcement at all. Only `<`, `>`, `<=` and `>=` are numeric in SQF
    // and type-check their operands; `==` / `!=` do not, which is why the row filter below may
    // compare a Side to a Side but nothing here may order-compare one against a number.
    params ["_selfLoc", "_subjectLoc", "_side"];
    if (isNil "_selfLoc" || { count _selfLoc < 8 }) exitWith { [1, 1, 1] };
    if (isNil "_subjectLoc" || { count _subjectLoc == 0 }) then { _subjectLoc = _selfLoc; };
    if (isNil "_side") then { _side = _selfLoc select 4; };

    private _assetRange = ["neighborAssetRange", 800] call MISSION_CORE_fnc_tune;
    private _tier0K = ["neighborAssetTier0Influence", 2.0] call MISSION_CORE_fnc_tune;
    private _tier1K = ["neighborAssetTier1Influence", 1.35] call MISSION_CORE_fnc_tune;

    // ---- TERM 1: the subject's own tier value. Lifelines are worth double. ----
    private _sTier = ([_subjectLoc] call MISSION_CORE_fnc_getMarkerDetermination) select 0;
    private _cVal = if (_sTier <= 1) then { 2.0 } else { 1.0 };

    // ---- TERM 2: the self marker's surroundings ----
    // Graded on the NEAREST tier 0 marker, falling back to the nearest tier 1. Deliberately NOT a
    // sum over every neighbour: a provider is never influenced twice, so this cannot stack.
    private _selfName = _selfLoc select 0;
    private _selfPos = _selfLoc select 1;
    private _near0 = 1e10;
    private _near1 = 1e10;
    {
        private _o = _x;
        if ((_o select 4) != _side) then { continue; };
        if ((_o select 0) == _selfName) then { continue; };
        private _d = ((_o select 1) distance _selfPos) max 0.001;
        // DISTANCE BEFORE TIER, on purpose. MISSION_CORE_fnc_getMarkerDetermination scans the whole
        // marker table internally, and _near0/_near1 are only ever consumed through the
        // `if (_near0 < _assetRange)` test below - so a candidate already beyond range cannot change
        // the outcome and never needs its tier computed at all. Testing distance first turns a
        // full-table tier scan per candidate into a couple of float ops for almost every marker,
        // which is what makes this affordable to call once per marker per request sweep.
        if (_d >= _assetRange) then { continue; };
        private _oTier = ([_o] call MISSION_CORE_fnc_getMarkerDetermination) select 0;
        if (_oTier == 0) then { _near0 = _near0 min _d; }
        else {
            if (_oTier == 1) then { _near1 = _near1 min _d; };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;

    private _asset = 1.0;
    if (_near0 < _assetRange) then {
        // Critical (tier 0) nearby - very high influence, falling off to none at the range edge.
        _asset = 1 + ((_tier0K - 1) * (1 - (_near0 / _assetRange)));
    } else {
        if (_near1 < _assetRange) then {
            _asset = 1 + ((_tier1K - 1) * (1 - (_near1 / _assetRange)));
        };
    };

    [_cVal, _asset, _cVal * _asset]
};