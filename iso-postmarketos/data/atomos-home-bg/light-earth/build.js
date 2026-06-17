const fs = require("fs");
const path = require("path");
const esbuild = require("esbuild");

// Helper to read shaders
const readShaderFile = (filename) => {
  return fs.readFileSync(path.join(__dirname, "cobe", filename), "utf8");
};

// Clean single shader
const cleanShader = (source, fnName, isFrag = false) => {
  let cleaned = source.replace(/export\s+void\s+\w+\(\);\s*/g, "");
  cleaned = cleaned.replace(new RegExp("void\\s+" + fnName + "\\s*\\(\\)", "g"), "void main()");
  if (isFrag && !cleaned.includes("precision ")) {
    cleaned = "precision mediump float;\n" + cleaned;
  }
  return cleaned;
};

// Split multi-shader files
const splitGlslx = (source) => {
  const parts = source.split(/\/\/ Fragment shader/i);
  let vertPart = parts[0];
  let fragPart = parts[1];

  const vertIndex = vertPart.indexOf("// Vertex shader");
  let header = "";
  if (vertIndex !== -1) {
    header = vertPart.substring(0, vertIndex);
    vertPart = vertPart.substring(vertIndex);
  }

  let vert = header + "\n" + vertPart;
  let frag = header + "\n" + fragPart;

  vert = cleanShader(vert, "vertex", false);
  frag = cleanShader(frag, "fragment", true);

  return { vert, frag };
};

const compileCobeIndex = () => {
  console.log("Compiling shaders...");
  const globeVert = cleanShader(readShaderFile("globe.vert.glslx"), "vertex", false);
  const globeFrag = cleanShader(readShaderFile("globe.frag.glslx"), "fragment", true);

  const marker = splitGlslx(readShaderFile("marker.glslx"));
  const arc = splitGlslx(readShaderFile("arc.glslx"));

  console.log("Reading cobe/index.js...");
  let cobeIndex = fs.readFileSync(path.join(__dirname, "cobe", "index.js"), "utf8");

  // Injections
  cobeIndex = cobeIndex.replace("const GLOBE_VERT = __GLOBE_VERT__", `const GLOBE_VERT = ${JSON.stringify(globeVert)}`);
  cobeIndex = cobeIndex.replace("const GLOBE_FRAG = __GLOBE_FRAG__", `const GLOBE_FRAG = ${JSON.stringify(globeFrag)}`);
  cobeIndex = cobeIndex.replace("const MARKER_VERT = __MARKER_VERT__", `const MARKER_VERT = ${JSON.stringify(marker.vert)}`);
  cobeIndex = cobeIndex.replace("const MARKER_FRAG = __MARKER_FRAG__", `const MARKER_FRAG = ${JSON.stringify(marker.frag)}`);
  cobeIndex = cobeIndex.replace("const ARC_VERT = __ARC_VERT__", `const ARC_VERT = ${JSON.stringify(arc.vert)}`);
  cobeIndex = cobeIndex.replace("const ARC_FRAG = __ARC_FRAG__", `const ARC_FRAG = ${JSON.stringify(arc.frag)}`);
  cobeIndex = cobeIndex.replace("image.src = __TEXTURE__", "image.src = texture");

  // Prepend mapping constants and imports
  const header = `import texture from "./texture.js";

const GLOBE_F_uResolution = "uResolution";
const GLOBE_F_rotation = "rotation";
const GLOBE_F_dots = "dots";
const GLOBE_F_scale = "scale";
const GLOBE_F_offset = "offset";
const GLOBE_F_baseColor = "baseColor";
const GLOBE_F_glowColor = "glowColor";
const GLOBE_F_renderParams = "renderParams";
const GLOBE_F_mapBaseBrightness = "mapBaseBrightness";
const GLOBE_F_uTexture = "uTexture";

const GLOBE_V_aPosition = "aPosition";

const MARKER_phi = "phi";
const MARKER_theta = "theta";
const MARKER_uResolution = "uResolution";
const MARKER_scale = "scale";
const MARKER_offset = "offset";
const MARKER_markerColor = "markerColor";
const MARKER_markerElevation = "markerElevation";

const MARKER_aPosition = "aPosition";
const MARKER_aMarkerPos = "aMarkerPos";
const MARKER_aMarkerSize = "aMarkerSize";
const MARKER_aMarkerColor = "aMarkerColor";
const MARKER_aHasColor = "aHasColor";

const ARC_phi = "phi";
const ARC_theta = "theta";
const ARC_uResolution = "uResolution";
const ARC_scale = "scale";
const ARC_offset = "offset";
const ARC_arcColor = "arcColor";
const ARC_markerElevation = "markerElevation";

const ARC_aPosition = "aPosition";
const ARC_aArcFrom = "aArcFrom";
const ARC_aArcTo = "aArcTo";
const ARC_aArcHeight = "aArcHeight";
const ARC_aArcWidth = "aArcWidth";
const ARC_aArcColor = "aArcColor";
const ARC_aHasColor = "aHasColor";

`;

  fs.writeFileSync(path.join(__dirname, "cobe", "index.compiled.js"), header + cobeIndex, "utf8");
  console.log("cobe/index.compiled.js written successfully.");
};

// esbuild plugin to resolve cobe import
const cobeResolvePlugin = {
  name: "cobe-resolve",
  setup(build) {
    build.onResolve({ filter: /^\.\/cobe\/index$/ }, (args) => {
      return { path: path.join(__dirname, "cobe", "index.compiled.js") };
    });
  },
};

const buildBundle = async () => {
  compileCobeIndex();

  console.log("Bundling with esbuild...");
  try {
    await esbuild.build({
      entryPoints: ["main.tsx"],
      bundle: true,
      minify: true,
      sourcemap: true,
      format: "iife",
      jsx: "automatic",
      outfile: "index.js",
      plugins: [cobeResolvePlugin],
    });
    console.log("Build completed successfully. index.js and index.js.map created.");
  } catch (err) {
    console.error("Esbuild compilation failed:", err);
    process.exit(1);
  }
};

buildBundle();
