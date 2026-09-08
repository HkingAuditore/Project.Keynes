import io

path = r"D:\Godot\ProjectKeynes\Project.Keynes\gdext\src\world_ext_climate.cpp"
with io.open(path, "r", encoding="utf-8", newline="") as f:
    lines = f.read().split("\n")

# body of run_climate_feedback_pass_thread: signature line .. closing brace
sig = "double DCWorldExt::run_climate_feedback_pass_thread(Dictionary knobs, int n_tasks) {"
start = next(i for i, l in enumerate(lines) if l.startswith(sig))
# find the closing "}" at column 0 after start
end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")

new_body = """double DCWorldExt::run_climate_feedback_pass_thread(Dictionary knobs, int n_tasks) {
    // S3\uff1a\u8fd9\u91cc\u539f\u672c\u662f feedback \u7684\u7b2c\u4e8c\u4efd\u5b9e\u73b0\uff08prelude \u5168\u91cf\u590d\u5236 + \u4e3b\u5faa\u73af\u8d70
    // pk::parallel_for_range\uff09\u3002\u4e0e run_albedo_pass_thread / run_climate_pass_a_thread \u540c\u7406\uff1a
    // N=2400 \u65f6\u8fd9\u4e2a\u5faa\u73af\u662f\u5fae\u79d2\u7ea7\uff0c\u5e76\u884c\u6536\u76ca\u4e0d\u8db3\u4ee5\u6362\u4e00\u4efd\u5fc5\u987b\u6c38\u4e45\u624b\u5de5\u540c\u6b65\u7684
    // \u526f\u672c\uff1b\u800c parity_hash \u662f\u9010\u4f4d\u5f52\u7ea6 \u2014\u2014 \u540c\u5f62\u7684 float \u5faa\u73af\u5728\u4e0d\u540c\u5411\u91cf\u5316\u4e0b\u4f1a\u5dee 1 ULP\u3002
    (void)n_tasks;
    return run_climate_feedback_pass(knobs);
}"""

lines[start:end + 1] = new_body.split("\n")

with io.open(path, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(lines))

print("replaced lines", start + 1, "..", end + 1)
