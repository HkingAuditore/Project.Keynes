// Build event:/Music/AgrarianAge/Suite (v3: Intro 16s + Loops A/B/C 52s = 172s) and the Stone->Agrarian
// transition in FMOD Studio 2.03.15.
var B = studio.system.require("fmod_lib/era_suite_builder.js");
// FMOD Studio's script console exposes no path to this file, so the folder that
// contains the repo has to be filled in here (forward slashes, no trailing slash).
var REPO_PARENT = "";
if (!REPO_PARENT) { throw new Error("set REPO_PARENT to the folder that contains the repo"); }
var DIR = REPO_PARENT + "/tmp/fmod_agrarian_age/audio/";
B.buildSuite({ folder: "AgrarianAge", audioDir: DIR, prefix: "stem_agr_", introSec: 16.0, loopSec: 52.0 });
B.buildTransition("era_stone_to_agrarian", DIR + "trans_stone_to_agrarian.wav");
studio.project.save();
console.log("=== Agrarian Age suite + transition built and saved ===");
