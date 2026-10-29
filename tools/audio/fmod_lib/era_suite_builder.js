// Shared FMOD Studio 2.03.15 builder for Project.Keynes era music suites (v3 audio pipeline).
//
// v3 stems are exact-sum layers. Legacy eras use Base_Core + Pop_Rhythm + Pop_Chorus; Kingdom and Empire use
// Base_Core + Pulse + Theme + Color + Impact == the composed master at unity gain.
// So every music layer tops out at 0 dB (no +1 dB boosts that over-drive the reconstructed mix), and the
// camera-zoom EQ is gentle so zooming out never turns the score dull. Ambience beds are pre-levelled by the
// generator to about -28 LUFS (music is -18 LUFS), so they sit under the score at 0 dB.

var POP_RHYTHM_CURVE = [[0.00, -80.0], [0.18, -80.0], [0.30, -12.0], [0.42, -3.0], [0.50, 0.0], [1.00, 0.0]];
var POP_RHYTHM_ZOOM_CURVE = [[0.00, 0.0], [0.60, 0.0], [1.00, -3.0]];
var POP_CHORUS_CURVE = [[0.00, -80.0], [0.52, -80.0], [0.64, -12.0], [0.76, -3.0], [0.85, 0.0], [1.00, 0.0]];
var LEGACY_TENSION_RHYTHM_CURVE = [[0.00, -6.0], [0.30, -3.0], [0.65, -1.0], [1.00, 0.0]];
var LEGACY_TENSION_CHORUS_CURVE = [[0.00, 0.0], [0.50, -1.0], [1.00, -3.0]];
var FIVE_POP_PULSE_CURVE = [[0.00, -12.0], [0.18, -9.0], [0.38, -3.0], [0.62, 0.0], [1.00, 0.0]];
var FIVE_POP_THEME_CURVE = [[0.00, -9.0], [0.20, -6.0], [0.45, -2.0], [0.70, 0.0], [1.00, 0.0]];
var TENSION_PULSE_CURVE = [[0.00, -6.0], [0.35, -3.0], [0.70, -1.0], [1.00, 0.0]];
var TENSION_IMPACT_CURVE = [[0.00, -80.0], [0.25, -36.0], [0.55, -12.0], [0.82, -3.0], [1.00, 0.0]];
var WAR_PULSE_CURVE = [[0.00, 0.0], [0.30, 0.0], [0.65, -1.0], [1.00, -2.0]];
var WAR_IMPACT_CURVE = [[0.00, -80.0], [0.20, -30.0], [0.50, -9.0], [0.80, -2.0], [1.00, 0.0]];
var CEREMONY_COLOR_CURVE = [[0.00, -80.0], [0.20, -30.0], [0.50, -9.0], [0.78, -2.0], [1.00, 0.0]];
var CEREMONY_THEME_CURVE = [[0.00, -3.0], [0.50, -1.0], [1.00, 0.0]];
var ZOOM_CLOSE_CURVE = [[0.00, 0.0], [0.25, -4.0], [0.42, -14.0], [0.50, -80.0], [1.00, -80.0]];
var ZOOM_FAR_CURVE = [[0.00, -80.0], [0.50, -80.0], [0.60, -14.0], [0.80, -4.0], [1.00, 0.0]];
var EQ_HIGH_CURVE = [[0.00, 1.0], [0.50, 0.0], [1.00, -3.0]];
var EQ_LOW_CURVE = [[0.00, 0.0], [0.50, 0.0], [1.00, 1.0]];

function project() {
    return studio.project;
}

function musicRootFolder() {
    var proto = project().lookup("event:/Music/Prototype");
    if (!proto) throw new Error("Cannot find event:/Music/Prototype");
    return proto.folder;
}

function musicBank() {
    var bank = project().lookup("bank:/Music");
    if (!bank) throw new Error("Cannot find bank:/Music");
    return bank;
}

function getOrCreateFolder(name) {
    var folder = project().lookup("event:/Music/" + name);
    if (!folder) {
        folder = project().create("EventFolder");
        folder.name = name;
        folder.folder = musicRootFolder();
    }
    return folder;
}

function addOrGetParam(evObj, def) {
    var preset = project().lookup("parameter:/" + def.name);
    var proxy = preset ? evObj.addGameParameter(preset) : evObj.addGameParameter(def);
    return proxy.preset ? (proxy.preset.parameter ? proxy.preset.parameter : proxy.preset) : proxy;
}

function automatePoints(automatable, propName, paramObj, points) {
    var automator = automatable.addAutomator(propName);
    var curve = automator.addAutomationCurve(paramObj);
    for (var i = 0; i < points.length; i++) {
        curve.addAutomationPoint(points[i][0], points[i][1]);
    }
    return curve;
}

function addStem(ev, audioDir, trackName, fileName) {
    var af = project().importAudioFile(audioDir + fileName);
    if (!af) throw new Error("Failed to import " + audioDir + fileName);
    var trk = ev.addGroupTrack(trackName);
    var snd = trk.addSound(ev.timeline, "SingleSound", 0, af.length);
    if (!snd) throw new Error("Failed to addSound for " + fileName);
    snd.audioFile = af;
    snd.looping = false;
    trk.mixerGroup.volume = 0.0;
    console.log("  Added [" + trackName + "] <- " + fileName + " (" + af.length.toFixed(2) + "s)");
    return trk;
}

function addRoleStem(ev, audioDir, trackName, fileName, popParam, tensionParam, warParam, ceremonyParam) {
    var trk = addStem(ev, audioDir, trackName, fileName);
    if (trackName === "Pulse") {
        automatePoints(trk.mixerGroup, "volume", popParam, FIVE_POP_PULSE_CURVE);
        automatePoints(trk.mixerGroup, "volume", tensionParam, TENSION_PULSE_CURVE);
        automatePoints(trk.mixerGroup, "volume", warParam, WAR_PULSE_CURVE);
    } else if (trackName === "Theme") {
        automatePoints(trk.mixerGroup, "volume", popParam, FIVE_POP_THEME_CURVE);
        automatePoints(trk.mixerGroup, "volume", ceremonyParam, CEREMONY_THEME_CURVE);
    } else if (trackName === "Color") {
        automatePoints(trk.mixerGroup, "volume", ceremonyParam, CEREMONY_COLOR_CURVE);
        try {
            var reverb = trk.mixerGroup.effectChain.addEffect("SFXReverbEffect");
            if (reverb) {
                reverb.decayTime = 2600;
                reverb.earlyDelay = 18;
                reverb.lateDelay = 58;
                reverb.HFDecayRatio = 58;
                reverb.wetLevel = -18;
                reverb.dryLevel = -80;
            }
        } catch (eColorReverb) {
            console.log("  Color reverb note: " + eColorReverb);
        }
    } else if (trackName === "Impact") {
        automatePoints(trk.mixerGroup, "volume", tensionParam, TENSION_IMPACT_CURVE);
        automatePoints(trk.mixerGroup, "volume", warParam, WAR_IMPACT_CURVE);
        automatePoints(trk.mixerGroup, "volume", ceremonyParam, CEREMONY_COLOR_CURVE);
        try {
            var impactReverb = trk.mixerGroup.effectChain.addEffect("SFXReverbEffect");
            if (impactReverb) {
                impactReverb.decayTime = 1800;
                impactReverb.earlyDelay = 10;
                impactReverb.lateDelay = 42;
                impactReverb.HFDecayRatio = 48;
                impactReverb.wetLevel = -21;
                impactReverb.dryLevel = -80;
            }
        } catch (eImpactReverb) {
            console.log("  Impact reverb note: " + eImpactReverb);
        }
    }
    return trk;
}

// cfg: { folder, audioDir, prefix (file prefix incl. trailing underscore), introSec, loopSec, loopCount, fiveStem }
function buildSuite(cfg) {
    var P = project();
    var eventPath = "event:/Music/" + cfg.folder + "/Suite";
    var existing = P.lookup(eventPath);
    if (existing) {
        console.log("Removing existing " + eventPath + " for clean rebuild...");
        P.deleteObject(existing);
    }
    var ev = P.workspace.addEvent("Suite", false);
    ev.folder = getOrCreateFolder(cfg.folder);
    console.log("Created event: " + ev.getPath());

    var popParam = addOrGetParam(ev, { name: "Population", type: P.parameterType.User, min: 0.0, max: 1.0 });
    var zoomParam = addOrGetParam(ev, { name: "CameraZoom", type: P.parameterType.User, min: 0.0, max: 1.0 });
    var loopCount = cfg.loopCount || 3;
    var sectionParam = addOrGetParam(ev, { name: "LoopSection", type: P.parameterType.UserDiscrete, min: 0, max: loopCount });
    var tensionParam = addOrGetParam(ev, { name: "Tension", type: P.parameterType.User, min: 0.0, max: 1.0 });
    var warParam = addOrGetParam(ev, { name: "War", type: P.parameterType.User, min: 0.0, max: 1.0 });
    var ceremonyParam = addOrGetParam(ev, { name: "Ceremony", type: P.parameterType.User, min: 0.0, max: 1.0 });
    try {
        popParam.initialValue = 0.0;
        popParam.seekSpeed = 0.35;
        zoomParam.initialValue = 0.5;
        zoomParam.seekSpeed = 0.65;
        sectionParam.initialValue = 0;
        // Quantize loop selection over a short musical hand-off. Runtime calls
        // that do not explicitly request a seek then change at the next region
        // boundary instead of hard-cutting the active phrase.
        sectionParam.seekSpeed = 0.85;
        tensionParam.initialValue = 0.0;
        warParam.initialValue = 0.0;
        ceremonyParam.initialValue = 0.0;
    } catch (eParam) {
        console.log("  parameter property note: " + eParam);
    }

    addStem(ev, cfg.audioDir, "Base_Core", cfg.prefix + "base_core.wav");

    if (cfg.fiveStem) {
        addRoleStem(ev, cfg.audioDir, "Pulse", cfg.prefix + "pulse.wav", popParam, tensionParam, warParam, ceremonyParam);
        addRoleStem(ev, cfg.audioDir, "Theme", cfg.prefix + "theme.wav", popParam, tensionParam, warParam, ceremonyParam);
        addRoleStem(ev, cfg.audioDir, "Color", cfg.prefix + "color.wav", popParam, tensionParam, warParam, ceremonyParam);
        addRoleStem(ev, cfg.audioDir, "Impact", cfg.prefix + "impact.wav", popParam, tensionParam, warParam, ceremonyParam);
    } else {
        var trkRhythm = addStem(ev, cfg.audioDir, "Pop_Rhythm", cfg.prefix + "pop_rhythm.wav");
        automatePoints(trkRhythm.mixerGroup, "volume", popParam, POP_RHYTHM_CURVE);
        automatePoints(trkRhythm.mixerGroup, "volume", zoomParam, POP_RHYTHM_ZOOM_CURVE);
        automatePoints(trkRhythm.mixerGroup, "volume", tensionParam, LEGACY_TENSION_RHYTHM_CURVE);

        var trkChorus = addStem(ev, cfg.audioDir, "Pop_Chorus", cfg.prefix + "pop_chorus.wav");
        automatePoints(trkChorus.mixerGroup, "volume", popParam, POP_CHORUS_CURVE);
        automatePoints(trkChorus.mixerGroup, "volume", tensionParam, LEGACY_TENSION_CHORUS_CURVE);
    }

    var trkClose = addStem(ev, cfg.audioDir, "Zoom_Close", cfg.prefix + "zoom_close.wav");
    automatePoints(trkClose.mixerGroup, "volume", zoomParam, ZOOM_CLOSE_CURVE);

    var trkFar = addStem(ev, cfg.audioDir, "Zoom_Far", cfg.prefix + "zoom_far.wav");
    automatePoints(trkFar.mixerGroup, "volume", zoomParam, ZOOM_FAR_CURVE);

    try {
        var comp = ev.masterTrack.mixerGroup.effectChain.addEffect("CompressorEffect");
        if (comp) {
            comp.threshold = -18;
            comp.ratio = 1.5;
            comp.attackTime = 30;
        }
        var eq = ev.masterTrack.mixerGroup.effectChain.addEffect("ThreeEQEffect");
        if (eq) {
            automatePoints(eq, "highGain", zoomParam, EQ_HIGH_CURVE);
            automatePoints(eq, "lowGain", zoomParam, EQ_LOW_CURVE);
        }
    } catch (eEq) {
        console.log("  ThreeEQEffect note: " + eEq);
    }

    var loopA = cfg.introSec;
    var loopB = cfg.introSec + cfg.loopSec;
    var loopC = cfg.introSec + 2.0 * cfg.loopSec;

    var mt = ev.addMarkerTrack();
    mt.addNamedMarker("Intro_Start", 0.0);
    mt.addNamedMarker("Loop_A_Start", loopA);
    mt.addNamedMarker("Loop_B_Start", loopB);
    mt.addNamedMarker("Loop_C_Start", loopC);
    var regFull = mt.addRegion(loopA, loopCount * cfg.loopSec, "Loop_All_ABC", P.regionLoopMode.Looping);
    regFull.addParameterCondition(sectionParam, 0, 0);

    var mtSub = ev.addMarkerTrack();
    for (var i = 0; i < loopCount; i++) {
        var start = loopA + i * cfg.loopSec;
        var label = i < 3 ? ["Loop_A_Only", "Loop_B_Only", "Loop_C_Only"][i] : "Loop_" + (i + 1) + "_Only";
        mtSub.addRegion(start, cfg.loopSec, label, P.regionLoopMode.Looping).addParameterCondition(sectionParam, i + 1, i + 1);
    }

    ev.relationships.banks.add(musicBank());
    return ev;
}

function buildTransition(eventName, audioPath) {
    var P = project();
    var fullPath = "event:/Music/Transition/" + eventName;
    var existing = P.lookup(fullPath);
    if (existing) {
        console.log("Removing existing " + fullPath + " for clean rebuild...");
        P.deleteObject(existing);
    }
    var ev = P.workspace.addEvent(eventName, false);
    ev.folder = getOrCreateFolder("Transition");
    var af = P.importAudioFile(audioPath);
    if (!af) throw new Error("Failed to import " + audioPath);
    var trk = ev.addGroupTrack("Era_Transition_Fanfare");
    var snd = trk.addSound(ev.timeline, "SingleSound", 0, af.length);
    snd.audioFile = af;
    snd.looping = false;
    trk.mixerGroup.volume = 0.0;
    ev.relationships.banks.add(musicBank());
    console.log("Created transition event: " + ev.getPath() + " (" + af.length.toFixed(2) + "s)");
    return ev;
}

module.exports = {
    buildSuite: buildSuite,
    buildTransition: buildTransition,
};
