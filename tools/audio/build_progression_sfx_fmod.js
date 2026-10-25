// Refresh progression one-shots while retaining existing event GUIDs and music.
var P = studio.project;
var folder = P.lookup("event:/UI/Event/tech_research").folder;
var bank = P.lookup("bank:/UI");
var sfx = P.lookup("bus:/SFX");
if (!bank || !sfx) throw new Error("Missing UI bank or SFX bus");
var root = P.filePath.replace(/\\/g, "/").replace(/\/[^\/]+$/, "");
var names = ["tech_start", "tech_research", "tech_cancel", "ideology_draw",
    "ideology_reroll", "ideology_reveal", "ideology_choose", "ideology_use",
    "ideology_unequip", "ideology_promote"];
for (var i = 0; i < names.length; i++) {
    var name = names[i];
    var af = P.importAudioFile(root + "/Assets/UI/progression/" + name + ".wav");
    if (!af) throw new Error("Missing generated audio: " + name);
    var ev = P.lookup("event:/UI/Event/" + name);
    if (!ev) {
        ev = P.workspace.addEvent(name, false);
        ev.folder = folder;
    }
    var tracks = ev.groupTracks;
    for (var j = tracks.length - 1; j >= 0; j--) P.deleteObject(tracks[j]);
    var track = ev.addGroupTrack("Generated one-shot");
    var sound = track.addSound(ev.timeline, "SingleSound", 0, af.length);
    sound.audioFile = af;
    sound.looping = false;
    track.mixerGroup.volume = 0;
    ev.masterTrack.mixerGroup.volume = 0;
    ev.masterTrack.mixerGroup.output = sfx;
    ev.relationships.banks.add(bank);
    console.log("Progression cue " + name + " " + af.length.toFixed(3) + "s");
}
P.save();
console.log("PROGRESSION_SFX_FMOD_OK=true");
