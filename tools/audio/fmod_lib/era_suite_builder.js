// Shared FMOD Studio 2.03.15 builder for Project.Keynes era music suites (v3 audio pipeline).
//
// v3 stems are exact-sum layers: Base_Core + Pop_Rhythm + Pop_Chorus == the composed master at unity gain.
// So every music layer tops out at 0 dB (no +1 dB boosts that over-drive the reconstructed mix), and the
// camera-zoom EQ is gentle so zooming out never turns the score dull. Ambience beds are pre-levelled by the
// generator to about -28 LUFS (music is -18 LUFS), so they sit under the score at 0 dB.

var POP_RHYTHM_CURVE = [[0.00, -80.0], [0.18, -80.0], [0.30, -12.0], [0.42, -3.0], [0.50, 0.0], [1.00, 0.0]];
var POP_RHYTHM_ZOOM_CURVE = [[0.00, 0.0], [0.60, 0.0], [1.00, -3.0]];
var POP_CHORUS_CURVE = [[0.00, -80.0], [0.52, -80.0], [0.64, -12.0], [0.76, -3.0], [0.85, 0.0], [1.00, 0.0]];
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

// cfg: { folder, audioDir, prefix (file prefix incl. trailing underscore), introSec, loopSec }
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
    var sectionParam = addOrGetParam(ev, { name: "LoopSection", type: P.parameterType.UserDiscrete, min: 0, max: 3 });
    try {
        popParam.initialValue = 0.0;
        popParam.seekSpeed = 0.35;
        zoomParam.initialValue = 0.5;
        zoomParam.seekSpeed = 0.65;
        sectionParam.initialValue = 0;
    } catch (eParam) {
        console.log("  parameter property note: " + eParam);
    }

    addStem(ev, cfg.audioDir, "Base_Core", cfg.prefix + "base_core.wav");

    var trkRhythm = addStem(ev, cfg.audioDir, "Pop_Rhythm", cfg.prefix + "pop_rhythm.wav");
    automatePoints(trkRhythm.mixerGroup, "volume", popParam, POP_RHYTHM_CURVE);
    automatePoints(trkRhythm.mixerGroup, "volume", zoomParam, POP_RHYTHM_ZOOM_CURVE);

    var trkChorus = addStem(ev, cfg.audioDir, "Pop_Chorus", cfg.prefix + "pop_chorus.wav");
    automatePoints(trkChorus.mixerGroup, "volume", popParam, POP_CHORUS_CURVE);

    var trkClose = addStem(ev, cfg.audioDir, "Zoom_Close", cfg.prefix + "zoom_close.wav");
    automatePoints(trkClose.mixerGroup, "volume", zoomParam, ZOOM_CLOSE_CURVE);

    var trkFar = addStem(ev, cfg.audioDir, "Zoom_Far", cfg.prefix + "zoom_far.wav");
    automatePoints(trkFar.mixerGroup, "volume", zoomParam, ZOOM_FAR_CURVE);

    try {
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
    var regFull = mt.addRegion(loopA, 3.0 * cfg.loopSec, "Loop_All_ABC", P.regionLoopMode.Looping);
    regFull.addParameterCondition(sectionParam, 0, 0);

    var mtSub = ev.addMarkerTrack();
    mtSub.addRegion(loopA, cfg.loopSec, "Loop_A_Only", P.regionLoopMode.Looping).addParameterCondition(sectionParam, 1, 1);
    mtSub.addRegion(loopB, cfg.loopSec, "Loop_B_Only", P.regionLoopMode.Looping).addParameterCondition(sectionParam, 2, 2);
    mtSub.addRegion(loopC, cfg.loopSec, "Loop_C_Only", P.regionLoopMode.Looping).addParameterCondition(sectionParam, 3, 3);

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
