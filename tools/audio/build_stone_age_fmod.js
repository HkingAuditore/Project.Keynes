// Build event:/Music/StoneAge/Suite (v3: Intro 18s + Loops A/B/C 54s = 180s) in FMOD Studio 2.03.15.
// FMOD Studio's script console exposes no path to this file, so the folder that
// contains the repo has to be filled in here (forward slashes, no trailing slash).
var REPO_PARENT = "";
if (!REPO_PARENT) { throw new Error("set REPO_PARENT to the folder that contains the repo"); }
var B = studio.system.require("fmod_lib/era_suite_builder.js");
B.buildSuite({
    folder: "StoneAge",
    audioDir: REPO_PARENT + "/tmp/fmod_stone_age/audio/",
    prefix: "stem_",
    introSec: 18.0,
    loopSec: 54.0
});
studio.project.save();
console.log("=== Stone Age suite built and saved ===");
