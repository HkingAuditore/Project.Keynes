Resolve the text conflicts in this pending Project Keynes merge. Follow `AGENTS.md`.

{files}

Inspect the base, PR, and incoming versions. Keep the intent of both sides and make only changes needed to resolve the listed conflicts. Resolve each listed file in the working tree and remove all conflict markers. The factory stages the resolutions. Leave changes under `Project/project-keynes/addons/dots_ext/bin/` to a person.

Leave the merge pending for the factory to check and commit. Do not run Git commands that write to the index, commit, abort the merge, switch branches, or push.

Return only a JSON array, without a Markdown fence, with one entry for every listed path. Use the exact repository-relative path, set the action to "keep" for a resolved file or "delete" for a file removed from disk, and explain the decision in "reason".

[{"path":"example.gd","action":"keep","reason":"Combined the two checks for the shared animation."}]
