from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "packages/butler/init.lua").read_text()
start = source.index("function remuda._butler_sessions()")
end = source.index("\nend\n\nremuda.tool{", start) + len("\nend")
production = source[start:end].rstrip()
expected = "local bus = remuda._butler_bus\n" + production.replace(
    "function remuda._butler_sessions()",
    "remuda._butler_sessions = function()",
    1,
) + "\n"
patch = (root / "tests/session_tree_patch.lua").read_text()
assert patch == expected, "private hot-patch fixture drifted from production renderer"
print("session-tree hot-patch fixture matches production renderer")
