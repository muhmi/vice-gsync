import { spawnSync } from "bun";

const [binary, data] = process.argv.slice(2);
if (!binary || !data) throw new Error("usage: metal_fallback.ts BINARY INSTALLED_DATA");
for (const failure of ["device", "queue", "shader", "pipeline"]) {
  const result = spawnSync([binary, "-default", "-limitcycles", "1000000"], {
    env: { ...process.env, VICE_DATADIR: data, VICE_METAL_INIT_FAILURE: failure,
      VICE_RENDERER_FIXTURE: "1" },
    timeout: 15000,
  });
  const output = result.stdout.toString() + result.stderr.toString();
  if (result.exitCode !== 1 || !output.includes("OpenGL fixture: exact RGBA pixels passed") ||
      !output.includes("using GTK3 backend 'OpenGL'") ||
      (output.match(/Metal initialization failed:.*using OpenGL/g) ?? []).length !== 1) {
    console.error(output);
    throw new Error(`${failure}: fallback/fixture failed (exit ${result.exitCode})`);
  }
  console.log(`${failure}: one fallback diagnostic, existing GL upload/draw exact RGBA passed`);
}
