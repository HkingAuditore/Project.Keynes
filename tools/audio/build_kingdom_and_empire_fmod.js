// Build Kingdom (Intro 16s + 3x50s = 166s) and Empire (Intro 15s + 3x50s = 165s) suites plus their
// transitions in FMOD Studio 2.03.15 (v3 audio pipeline).
var B = studio.system.require("fmod_lib/era_suite_builder.js");
var KNG = "D:/Godot/ProjectKeynes/tmp/fmod_kingdom_age/audio/";
var EMP = "D:/Godot/ProjectKeynes/tmp/fmod_empire_age/audio/";
B.buildSuite({ folder: "KingdomAge", audioDir: KNG, prefix: "stem_kng_", introSec: 16.0, loopSec: 50.0, loopCount: 3, fiveStem: true });
B.buildTransition("era_agrarian_to_kingdom", KNG + "trans_agrarian_to_kingdom.wav");
B.buildSuite({ folder: "EmpireAge", audioDir: EMP, prefix: "stem_emp_", introSec: 15.0, loopSec: 50.0, loopCount: 3, fiveStem: true });
B.buildTransition("era_kingdom_to_empire", EMP + "trans_kingdom_to_empire.wav");
studio.project.save();
console.log("=== Kingdom & Empire suites + transitions built and saved ===");
