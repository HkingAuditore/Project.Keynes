// Build event:/Music/StoneAge/Suite (v3: Intro 18s + Loops A/B/C 54s = 180s) in FMOD Studio 2.03.15.
var B = studio.system.require("fmod_lib/era_suite_builder.js");
B.buildSuite({
    folder: "StoneAge",
    audioDir: "D:/Godot/ProjectKeynes/tmp/fmod_stone_age/audio/",
    prefix: "stem_",
    introSec: 18.0,
    loopSec: 54.0
});
studio.project.save();
console.log("=== Stone Age suite built and saved ===");
