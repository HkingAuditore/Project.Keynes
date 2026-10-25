// Route the seven gameplay event cues through the shared SFX bus.
var P = studio.project;
var sfx = P.lookup("bus:/SFX");
if (!sfx) throw new Error("Cannot find bus:/SFX");
var names = ["tech_research", "territory_expand", "ideology_draw", "ideology_use",
    "building_complete", "population_grow", "trade"];
for (var i = 0; i < names.length; i++) {
    var ev = P.lookup("event:/UI/Event/" + names[i]);
    if (!ev) throw new Error("Cannot find event:/UI/Event/" + names[i]);
    ev.masterTrack.mixerGroup.output = sfx;
    console.log("Routed event:/UI/Event/" + names[i] + " -> bus:/SFX");
}
P.save();
console.log("=== Core event cues routed to SFX ===");
