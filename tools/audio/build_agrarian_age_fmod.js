// Build event:/Music/AgrarianAge/Suite (v3: Intro 16s + Loops A/B/C 52s = 172s) and the Stone->Agrarian
// transition in FMOD Studio 2.03.15.
var B = studio.system.require("fmod_lib/era_suite_builder.js");
var DIR = "D:/Godot/ProjectKeynes/tmp/fmod_agrarian_age/audio/";
B.buildSuite({ folder: "AgrarianAge", audioDir: DIR, prefix: "stem_agr_", introSec: 16.0, loopSec: 52.0 });
B.buildTransition("era_stone_to_agrarian", DIR + "trans_stone_to_agrarian.wav");
studio.project.save();
console.log("=== Agrarian Age suite + transition built and saved ===");
