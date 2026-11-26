import argparse
import difflib
from pathlib import Path
import re
import sys


def body(source, name):
    match = re.search(r"\b" + name + r"\([^)]*\)\s*\{", source)
    if not match:
        raise ValueError(f"missing function {name}")
    start = match.end()
    depth = 1
    end = start
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end - 1]


def normalise(path, prefix):
    return normalise_source(path.read_text(), prefix)


def normalise_source(source, prefix):
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    constants = re.findall(r"^#define (PACING_\w+)\s+(\S+)", source, re.M)
    result = [f"{name}={value.replace('OPENGL_', '')}\n" for name, value in constants
              if name not in {"PACING_SPIN_MS", "PACING_DISPLAY_CHECK_FRAMES"}]
    for name in ("schedule", "ready"):
        code = body(source, prefix + "pacing_" + name)
        code = code.replace("context->pacing_", "pacing->")
        code = code.replace("vice_directx_now_ms", "now_ms")
        code = re.sub(r"\b(?:double|int)\s+\w+\s*;", "", code)
        code = re.sub(r"\b(?:double|int)\s+", "", code)
        code = re.sub(r"\s+", "", code)
        result.append(f"{name}:\n")
        result.extend(part + "\n" for part in re.findall(r"[^;{}]*[;{}]|[^;{}]+$", code))
    return result


def main():
    parser = argparse.ArgumentParser()
    root = Path(__file__).resolve().parent.parent
    parser.add_argument("--gl", type=Path, default=root / "opengl_pacing.c")
    parser.add_argument("--dx", type=Path, default=root / "directx_renderer_impl.cc")
    parser.add_argument("--show", action="store_true")
    args = parser.parse_args()
    history = []
    for path in (args.dx, args.gl):
        match = re.search(r"#define (?:OPENGL_)?PACING_HISTORY_BLOCKS\s+(\d+)", path.with_suffix(".h").read_text())
        if not match:
            raise ValueError(f"missing history capacity: {path}")
        history.append(int(match[1]))
    if history[0] != history[1]:
        raise ValueError(f"history capacity drift: {history}")
    gl = args.gl.read_text()
    for original, changed in [("0.002", "0.003"), ("PACING_MARGIN_MS            2.0", "PACING_MARGIN_MS            3.0"),
                              ("queued + 1 >= capacity", "queued + 2 >= capacity"),
                              ("completed_ms + draw_ms", "completed_ms - draw_ms")]:
        if original not in gl or normalise_source(gl, "opengl_") == normalise_source(gl.replace(original, changed), "opengl_"):
            raise ValueError(f"drift detector failed counter-test: {original}")
    difference = "".join(difflib.unified_diff(normalise(args.dx, ""), normalise(args.gl, "opengl_"),
                                            fromfile="DirectX", tofile="OpenGL", n=2))
    if args.show:
        print(difference, end="")
    elif difference != (root / "tests/pacing.expected.diff").read_text():
        print(difference, end="", file=sys.stderr)
        return 1
    else:
        print("pacing: normalized DirectX/OpenGL drift matches expected seam")
    return 0


if __name__ == "__main__":
    sys.exit(main())
