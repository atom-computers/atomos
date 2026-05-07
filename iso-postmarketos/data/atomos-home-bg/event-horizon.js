/*
 * AtomOS home-background animation: WebGL black-hole / accretion-disk
 * shader. Runtime entry point loaded by `index.html` inside the
 * WebKitGTK webview that `atomos-home-bg` puts on the `bottom`
 * layer-shell layer.
 *
 * This file is HAND-DERIVED from `event-horizon.tsx` (the canonical
 * React source-of-truth shipped alongside it). The React file uses
 * `useEffect` + a JSX `<canvas>` ref; here we attach to a `<canvas>`
 * already present in the DOM (`<canvas id="event-horizon">`). The
 * vertex/fragment shaders, uniform set, parameter defaults, the
 * `postMessage` runtime-tweak API, the pointer/touch handlers, the
 * resize/visibility/reduced-motion logic, and the DPR cap are all
 * identical. Keep them in lock-step.
 *
 * Why ship a hand-port instead of a bundled .tsx? The rootfs has no
 * Node/React toolchain at boot. WebKitGTK loads `file://` content
 * directly, so the asset has to already be vanilla JS the browser
 * can execute on its own. The tsx is preserved for future bundled
 * deployments (Next.js/Vite consumers can import it as-is).
 */
(function () {
  "use strict";

  var VERT_SRC = [
    "attribute vec2 a_pos;",
    "void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }"
  ].join("\n");

  var FRAG_SRC = [
    "precision highp float;",
    "uniform float u_time;",
    "uniform vec2 u_res;",
    "uniform float u_rotationSpeed;",
    "uniform float u_diskIntensity;",
    "uniform float u_starsOnly;",
    "uniform float u_tilt;",
    "uniform float u_rotate;",
    "uniform vec2 u_bhCenter;",
    "uniform float u_bhScale;",
    "uniform float u_chromatic;",
    "",
    "const float PI = 3.14159265359;",
    "const float TAU = 6.28318530718;",
    "const float RS = 1.0;",
    "const float ISCO = 3.0;",
    "const float DISK_IN = 2.2;",
    "const float DISK_OUT = 14.0;",
    "",
    "float hash(vec2 p) {",
    "    vec3 p3 = fract(vec3(p.xyx) * 0.1031);",
    "    p3 += dot(p3, p3.yzx + 33.33);",
    "    return fract((p3.x + p3.y) * p3.z);",
    "}",
    "",
    "float gNoise(vec2 p) {",
    "    vec2 i = floor(p), f = fract(p);",
    "    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);",
    "    return mix(",
    "        mix(hash(i), hash(i + vec2(1, 0)), u.x),",
    "        mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x),",
    "        u.y",
    "    );",
    "}",
    "",
    "float fbm(vec2 p) {",
    "    float v = 0.0, a = 0.5;",
    "    mat2 rot = mat2(0.866, 0.5, -0.5, 0.866);",
    "    for (int i = 0; i < 4; i++) {",
    "        v += a * gNoise(p);",
    "        p = rot * p * 2.03 + vec2(47.0, 13.0);",
    "        a *= 0.49;",
    "    }",
    "    return v;",
    "}",
    "float fbmLite(vec2 p) {",
    "    float v = 0.5 * gNoise(p);",
    "    p = mat2(0.866, 0.5, -0.5, 0.866) * p * 2.03 + vec2(47.0, 13.0);",
    "    v += 0.25 * gNoise(p);",
    "    return v;",
    "}",
    "",
    "vec3 starField(vec3 rd) {",
    "    float u = atan(rd.z, rd.x) / TAU + 0.5;",
    "    float v = asin(clamp(rd.y, -0.999, 0.999)) / PI + 0.5;",
    "    vec3 col = vec3(0.0);",
    "",
    "    {",
    "        vec2 cell = floor(vec2(u, v) * 55.0);",
    "        vec2 f = fract(vec2(u, v) * 55.0);",
    "        vec2 r = vec2(hash(cell), hash(cell + 127.1));",
    "        float d = length(f - r);",
    "        float b = pow(r.x, 10.0) * exp(-d * d * 500.0);",
    "        col += mix(vec3(1.0, 0.65, 0.35), vec3(0.55, 0.75, 1.0), r.y) * b * 4.0;",
    "    }",
    "    {",
    "        vec2 cell = floor(vec2(u, v) * 170.0);",
    "        vec2 f = fract(vec2(u, v) * 170.0);",
    "        vec2 r = vec2(hash(cell + 43.0), hash(cell + 91.0));",
    "        float d = length(f - r);",
    "        float b = pow(r.x, 18.0) * exp(-d * d * 1000.0);",
    "        col += vec3(0.85, 0.88, 1.0) * b * 2.0;",
    "    }",
    "    float n = fbmLite(vec2(u, v) * 3.0) * fbmLite(vec2(u, v) * 5.5 + 10.0);",
    "    col += vec3(0.10, 0.04, 0.14) * pow(n, 3.0);",
    "",
    "    return col;",
    "}",
    "",
    "vec3 bbColor(float t) {",
    "    t = clamp(t, 0.0, 2.5);",
    "    vec3 lo = vec3(1.0, 0.18, 0.0);",
    "    vec3 mi = vec3(1.0, 0.55, 0.12);",
    "    vec3 hi = vec3(1.0, 0.93, 0.82);",
    "    vec3 hot = vec3(0.65, 0.82, 1.0);",
    "    vec3 c = mix(lo, mi, smoothstep(0.0, 0.3, t));",
    "    c = mix(c, hi, smoothstep(0.3, 0.8, t));",
    "    return mix(c, hot, smoothstep(0.8, 1.8, t));",
    "}",
    "",
    "vec4 shadeDisk(vec3 hit, vec3 vel, float time) {",
    "    float r = length(hit.xz);",
    "    if (r < DISK_IN * 0.5 || r > DISK_OUT * 1.05) return vec4(0.0);",
    "",
    "    float xr = ISCO / r;",
    "    float tProfile = pow(ISCO / r, 0.75) * pow(max(0.001, 1.0 - sqrt(xr)), 0.25);",
    "",
    "    float gRedshift = sqrt(max(0.01, 1.0 - RS / r));",
    "    tProfile *= gRedshift;",
    "",
    "    float phi = atan(hit.z, hit.x);",
    "    float lr = log2(max(r, 0.1));",
    "",
    "    float keplerOmega = sqrt(0.5 * RS / (r * r * r));",
    "    float baseOmega = 0.04;",
    "    float omega = max(keplerOmega, baseOmega) * 10.0;",
    "    float rotAngle = time * omega;",
    "    float ca = cos(rotAngle), sa = sin(rotAngle);",
    "    vec2 rotXZ = vec2(hit.x * ca - hit.z * sa, hit.x * sa + hit.z * ca);",
    "",
    "    float turb = fbm(rotXZ * 1.2 + vec2(lr * 3.0));",
    "    turb = 0.25 + 0.75 * turb;",
    "",
    "    float timeShift = time * 0.15;",
    "    float detail = gNoise(rotXZ * 3.5 + vec2(100.0 + timeShift, timeShift * 0.7));",
    "    turb *= 0.7 + 0.3 * detail;",
    "",
    "    float ringPhase1 = sin(r * 10.0 + rotAngle * r * 0.3) * 0.5 + 0.5;",
    "    float ringPhase2 = sin(r * 20.0 - rotAngle * r * 0.15) * 0.5 + 0.5;",
    "    float rings = ringPhase1 * 0.55 + ringPhase2 * 0.45;",
    "    rings = 0.5 + 0.5 * rings;",
    "    turb *= rings;",
    "",
    "    float orbSpeed = sqrt(0.5 * RS / max(r, DISK_IN));",
    "    vec3 orbDir = normalize(vec3(-hit.z, 0.0, hit.x));",
    "    float dopplerFactor = 1.0 + 2.0 * dot(normalize(vel), orbDir) * orbSpeed;",
    "    dopplerFactor = max(0.15, dopplerFactor);",
    "    float dopplerBoost = dopplerFactor * dopplerFactor * dopplerFactor;",
    "",
    "    float I = tProfile * turb * 6.0;",
    "",
    "    float innerFade = smoothstep(DISK_IN * 0.7, DISK_IN * 1.2, r);",
    "    float iscoFade = 0.35 + 0.65 * smoothstep(ISCO * 0.85, ISCO * 1.2, r);",
    "    float outerFade = 1.0 - smoothstep(DISK_OUT * 0.55, DISK_OUT, r);",
    "    I *= innerFade * iscoFade * outerFade;",
    "",
    "    float colorTemp = tProfile * pow(dopplerFactor, 1.8) * 1.2;",
    "    vec3 col = bbColor(colorTemp) * I * dopplerBoost;",
    "",
    "    if (u_chromatic > 0.01) {",
    "        float spectralR = (r - DISK_IN) / (DISK_OUT - DISK_IN);",
    "        float ringP = ringPhase1;",
    "        float hue = spectralR * 0.8 + ringP * 0.4;",
    "",
    "        vec3 spectrum;",
    "        spectrum.r = (1.0 - smoothstep(0.0, 0.35, hue))",
    "                   + smoothstep(0.25, 0.45, hue) * (1.0 - smoothstep(0.55, 0.7, hue)) * 0.7",
    "                   + smoothstep(0.85, 1.1, hue) * 0.4;",
    "        spectrum.g = smoothstep(0.15, 0.4, hue) * (1.0 - smoothstep(0.7, 0.95, hue));",
    "        spectrum.b = smoothstep(0.5, 0.8, hue)",
    "                   + smoothstep(0.85, 1.1, hue) * 0.3;",
    "        spectrum = max(spectrum, 0.05);",
    "",
    "        float luma = dot(col, vec3(0.3, 0.5, 0.2));",
    "        vec3 chromaCol = spectrum * luma * 2.0;",
    "",
    "        col = mix(col, chromaCol, u_chromatic * 0.75);",
    "    }",
    "",
    "    float alpha = clamp(I * 1.3, 0.0, 0.96);",
    "    return vec4(col, alpha);",
    "}",
    "",
    "void main() {",
    "    vec2 fc = gl_FragCoord.xy;",
    "    vec2 ctr = (u_bhScale > 0.0 ? u_bhCenter : vec2(0.5)) * u_res;",
    "    float sc = u_bhScale > 0.0 ? u_bhScale : 1.0;",
    "    vec2 uv = (fc - ctr) * sc / u_res.x;",
    "",
    "    float camR = 28.0;",
    "    float orbit = u_time * 0.055 * u_rotationSpeed;",
    "    float tilt = 0.25 + u_tilt;",
    "",
    "    vec3 eye = vec3(",
    "        camR * cos(orbit) * cos(tilt),",
    "        camR * sin(tilt),",
    "        camR * sin(orbit) * cos(tilt)",
    "    );",
    "",
    "    vec3 fwd = normalize(-eye);",
    "    vec3 rt = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));",
    "    vec3 up = cross(rt, fwd);",
    "",
    "    float cr = cos(u_rotate), sr = sin(u_rotate);",
    "    vec3 rr = cr * rt + sr * up;",
    "    vec3 ru = -sr * rt + cr * up;",
    "",
    "    vec3 rd = normalize(fwd + uv.x * rr + uv.y * ru);",
    "",
    "    if (u_starsOnly > 0.5) {",
    "        vec3 s = starField(rd);",
    "        gl_FragColor = vec4(pow(s, vec3(0.45)), 1.0);",
    "        return;",
    "    }",
    "",
    "    vec3 pos = eye;",
    "    vec3 vel = rd;",
    "",
    "    vec3 Lvec = cross(pos, vel);",
    "    float L2 = dot(Lvec, Lvec);",
    "",
    "    vec4 diskAccum = vec4(0.0);",
    "    vec3 glow = vec3(0.0);",
    "    bool absorbed = false;",
    "    int diskCrossings = 0;",
    "    float minR = 1000.0;",
    "",
    "    float gravCoeff = -1.5 * RS * L2;",
    "",
    "    for (int i = 0; i < 200; i++) {",
    "        float r = length(pos);",
    "",
    "        float h = 0.16 * clamp(r - 0.4 * RS, 0.06, 3.5);",
    "",
    "        float invR2 = 1.0 / (r * r);",
    "        float invR5 = invR2 * invR2 / r;",
    "        vec3 acc = (gravCoeff * invR5) * pos;",
    "",
    "        vec3 p1 = pos + vel * h + 0.5 * acc * h * h;",
    "        float r1 = length(p1);",
    "        float invR12 = 1.0 / (r1 * r1);",
    "        float invR15 = invR12 * invR12 / r1;",
    "        vec3 acc1 = (gravCoeff * invR15) * p1;",
    "        vec3 v1 = vel + 0.5 * (acc + acc1) * h;",
    "",
    "        minR = min(minR, r1);",
    "",
    "        if (pos.y * p1.y < 0.0 && diskAccum.a < 0.97) {",
    "            float t = pos.y / (pos.y - p1.y);",
    "            vec3 hit = mix(pos, p1, t);",
    "            vec4 dc = shadeDisk(hit, vel, u_time * u_rotationSpeed);",
    "            dc.rgb *= u_diskIntensity;",
    "            if (diskCrossings >= 2) {",
    "                dc.rgb *= 0.15;",
    "                dc.a *= 0.15;",
    "            }",
    "            diskAccum.rgb += dc.rgb * dc.a * (1.0 - diskAccum.a);",
    "            diskAccum.a += dc.a * (1.0 - diskAccum.a);",
    "            float diskBright = dot(dc.rgb, vec3(0.3, 0.5, 0.2)) * dc.a;",
    "            glow += dc.rgb * 0.04 * max(diskBright - 0.3, 0.0);",
    "            diskCrossings++;",
    "        }",
    "",
    "        if (r1 < 6.0) {",
    "            float pDist = abs(r1 - 1.5 * RS);",
    "            float psGlow = 1.0 / (1.0 + pDist * pDist * 20.0) * h * 0.001 / max(r1 * r1, 0.2);",
    "            glow += vec3(0.8, 0.6, 0.35) * psGlow;",
    "",
    "            float hzGlow = exp(-(r1 - RS) * 3.5) * h * 0.003;",
    "            glow += vec3(0.5, 0.25, 0.08) * max(hzGlow, 0.0);",
    "        }",
    "",
    "        if (r1 < RS * 0.35) { absorbed = true; break; }",
    "        if (r1 > 25.0 && r1 > r) break;",
    "        if (r1 > 55.0) break;",
    "",
    "        pos = p1;",
    "        vel = v1;",
    "    }",
    "",
    "    vec3 col = vec3(0.0);",
    "    if (!absorbed) {",
    "        col = starField(normalize(vel));",
    "    }",
    "    col = col * (1.0 - diskAccum.a) + diskAccum.rgb;",
    "",
    "    float ringDist = abs(minR - 1.5 * RS);",
    "    float chromo = u_chromatic;",
    "",
    "    float baseChroma = 0.1 + 0.5 * chromo;",
    "    float spread = 0.08 + 0.18 * chromo;",
    "    float falloff = 20.0 + 15.0 * (1.0 - chromo);",
    "    float rRing = exp(-(ringDist + spread) * (ringDist + spread) * falloff);",
    "    float bRing = exp(-(ringDist - spread) * (ringDist - spread) * falloff);",
    "    col.r += rRing * 0.3 * baseChroma;",
    "    col.b += bRing * 0.35 * baseChroma;",
    "",
    "    col += glow;",
    "",
    "    col *= 1.4;",
    "    vec3 a = col * (col + 0.0245786) - 0.000090537;",
    "    vec3 b = col * (0.983729 * col + 0.4329510) + 0.238081;",
    "    col = a / b;",
    "",
    "    col = smoothstep(0.0, 1.0, col);",
    "    col = pow(max(col, 0.0), vec3(0.92));",
    "",
    "    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);",
    "}"
  ].join("\n");

  // ----------------------------------------------------------------
  // On-device diagnostics.
  //
  // Every failure path the script can hit (canvas missing, WebGL
  // unavailable, shader compile error, program link error) is logged
  // both to console (which webkit2gtk-6.0's
  // `enable_write_console_messages_to_stdout=true` forwards into the
  // launcher's `/run/user/<uid>/atomos-home-bg.log`) and into a small
  // status banner attached to <body>.
  //
  // The banner gives the user something visible on the actual phone /
  // QEMU screen — without it, every failure looks identical (just the
  // dark `#0a0a0a` CSS base showing through), making it impossible to
  // distinguish "JS didn't load" from "WebGL refused" from "shader
  // failed to compile" without an SSH log dive. Banner is suppressed
  // via `?diag=0` in the URL (or `<html data-diag="off">`) for a
  // perfectly clean wallpaper once the device is known healthy.
  // ----------------------------------------------------------------
  function diagDisabled() {
    try {
      if (
        typeof location !== "undefined" &&
        /(^|[?&])diag=0(&|$)/.test(location.search || "")
      ) return true;
    } catch (_) {}
    if (
      document.documentElement &&
      document.documentElement.getAttribute("data-diag") === "off"
    ) return true;
    return false;
  }

  function reportFailure(stage, detail) {
    var label = "event-horizon: " + stage;
    if (detail) label += " — " + detail;
    try { console.warn(label); } catch (_) {}
    if (diagDisabled() || !document.body) return;
    var el = document.getElementById("event-horizon-diag");
    if (!el) {
      el = document.createElement("div");
      el.id = "event-horizon-diag";
      el.setAttribute("role", "status");
      el.setAttribute("aria-live", "polite");
      el.style.cssText = [
        "position:fixed",
        "left:8px",
        "bottom:8px",
        "max-width:calc(100% - 16px)",
        "padding:6px 10px",
        "border-radius:6px",
        "background:rgba(20,20,20,0.85)",
        "color:#ffb4a8",
        "font:12px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace",
        "letter-spacing:0.02em",
        "white-space:pre-wrap",
        "z-index:2147483647",
        "pointer-events:none",
        "user-select:none"
      ].join(";");
      document.body.appendChild(el);
    }
    el.textContent = label;
  }

  function reportOk(detail) {
    try { console.log("event-horizon: " + (detail || "ready")); } catch (_) {}
    var el = document.getElementById("event-horizon-diag");
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }

  function compileShader(gl, type, src, kind) {
    var s = gl.createShader(type);
    if (!s) throw new Error("createShader failed (" + kind + ")");
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      var info = gl.getShaderInfoLog(s) || "(no info log)";
      console.error("event-horizon: " + kind + " shader compile error:", info);
      throw new Error(kind + " shader compile error: " + info);
    }
    return s;
  }

  function init() {
    var canvas = document.getElementById("event-horizon");
    if (!canvas || !(canvas instanceof HTMLCanvasElement)) {
      reportFailure(
        "canvas missing",
        "expected <canvas id=\"event-horizon\"> in document"
      );
      return;
    }

    var prefersReduced =
      typeof window !== "undefined" &&
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    var gl = null;
    try {
      gl = canvas.getContext("webgl", {
        alpha: false,
        antialias: false,
        preserveDrawingBuffer: false
      });
    } catch (e) {
      reportFailure("WebGL context creation threw", String(e));
      return;
    }
    if (!gl) {
      // No WebGL: most common cause on AtomOS is webkit2gtk-6.0 deciding
      // GL is "not good enough" because the launcher has
      // `LIBGL_ALWAYS_SOFTWARE=1` and `WEBKIT_DISABLE_DMABUF_RENDERER=1`.
      // The fix is to (a) make sure the deployed binary explicitly
      // sets `enable-webgl=true` + `hardware-acceleration-policy=ALWAYS`
      // on the WebView, and (b) re-deploy the binary via
      // `ATOMOS_HOME_BG_CONTENT_ONLY=0 hotfix-home-bg.sh ...`. See the
      // `atomos-home-bg` README "WebGL on minimal images" section.
      reportFailure(
        "WebGL unavailable",
        "getContext('webgl') returned null — check WebKit settings + GL stack"
      );
      return;
    }

    var vert, frag, prog;
    try {
      vert = compileShader(gl, gl.VERTEX_SHADER, VERT_SRC, "vertex");
      frag = compileShader(gl, gl.FRAGMENT_SHADER, FRAG_SRC, "fragment");
    } catch (e) {
      reportFailure("shader compile failed", String(e && e.message ? e.message : e));
      return;
    }
    prog = gl.createProgram();
    if (!prog) {
      reportFailure("program create failed", "gl.createProgram() returned null");
      return;
    }
    gl.attachShader(prog, vert);
    gl.attachShader(prog, frag);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      var linkInfo = gl.getProgramInfoLog(prog) || "(no info log)";
      reportFailure("program link error", linkInfo);
      return;
    }
    gl.useProgram(prog);

    var buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 3, -1, -1, 3]),
      gl.STATIC_DRAW
    );
    var aPos = gl.getAttribLocation(prog, "a_pos");
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

    var uTime = gl.getUniformLocation(prog, "u_time");
    var uRes = gl.getUniformLocation(prog, "u_res");
    var uRotationSpeed = gl.getUniformLocation(prog, "u_rotationSpeed");
    var uDiskIntensity = gl.getUniformLocation(prog, "u_diskIntensity");
    var uStarsOnly = gl.getUniformLocation(prog, "u_starsOnly");
    var uTilt = gl.getUniformLocation(prog, "u_tilt");
    var uRotate = gl.getUniformLocation(prog, "u_rotate");
    var uBhCenter = gl.getUniformLocation(prog, "u_bhCenter");
    var uBhScale = gl.getUniformLocation(prog, "u_bhScale");
    var uChromatic = gl.getUniformLocation(prog, "u_chromatic");

    // Defaults match the React source — keep in sync.
    var rotationSpeedVal = 0.3;
    var diskIntensityVal = 1.0;
    var starsOnlyVal = 0.0;
    var tiltVal = -0.2;
    var rotateVal = 0.0;
    var bhCenterX = 0.0;
    var bhCenterY = 0.0;
    var bhScaleVal = 0.0;
    var chromaticVal = 0.0;

    var mouseDown = false;
    var lastMX = 0;
    var lastMY = 0;

    function onMouseDown(e) {
      mouseDown = true;
      lastMX = e.clientX;
      lastMY = e.clientY;
    }
    function onMouseMove(e) {
      if (mouseDown) {
        tiltVal += (e.clientY - lastMY) * 0.003;
        rotateVal += (e.clientX - lastMX) * 0.003;
        tiltVal = Math.max(-0.8, Math.min(0.8, tiltVal));
        lastMX = e.clientX;
        lastMY = e.clientY;
      }
    }
    function onMouseUp() {
      mouseDown = false;
    }
    function onTouchStart(e) {
      e.preventDefault();
      mouseDown = true;
      lastMX = e.touches[0].clientX;
      lastMY = e.touches[0].clientY;
    }
    function onTouchMove(e) {
      e.preventDefault();
      if (mouseDown) {
        tiltVal += (e.touches[0].clientY - lastMY) * 0.003;
        rotateVal += (e.touches[0].clientX - lastMX) * 0.003;
        tiltVal = Math.max(-0.8, Math.min(0.8, tiltVal));
        lastMX = e.touches[0].clientX;
        lastMY = e.touches[0].clientY;
      }
    }
    function onTouchEnd() {
      mouseDown = false;
    }

    canvas.addEventListener("mousedown", onMouseDown);
    canvas.addEventListener("mousemove", onMouseMove);
    canvas.addEventListener("mouseup", onMouseUp);
    canvas.addEventListener("touchstart", onTouchStart, { passive: false });
    canvas.addEventListener("touchmove", onTouchMove, { passive: false });
    canvas.addEventListener("touchend", onTouchEnd);

    // Cap DPR at 1.5 — same as React source. Phone GPUs (Mali/Adreno
    // mid-range) struggle with the 200-iteration ray-march at native DPR.
    var dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    var needsResize = true;
    var running = true;
    var raf = 0;

    function resize() {
      needsResize = false;
      var w = Math.round(canvas.clientWidth * dpr);
      var h = Math.round(canvas.clientHeight * dpr);
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
        gl.viewport(0, 0, w, h);
        gl.uniform2f(uRes, canvas.width, canvas.height);
      }
    }

    var firstFramePainted = false;
    function render(now) {
      if (!running) return;
      if (needsResize) resize();
      var t = prefersReduced ? 0.0 : now * 0.001;
      gl.uniform1f(uTime, t);
      gl.uniform1f(uRotationSpeed, rotationSpeedVal);
      gl.uniform1f(uDiskIntensity, diskIntensityVal);
      gl.uniform1f(uStarsOnly, starsOnlyVal);
      gl.uniform1f(uTilt, tiltVal);
      gl.uniform1f(uRotate, rotateVal);
      gl.uniform2f(uBhCenter, bhCenterX, bhCenterY);
      gl.uniform1f(uBhScale, bhScaleVal);
      gl.uniform1f(uChromatic, chromaticVal);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      if (!firstFramePainted) {
        firstFramePainted = true;
        // Clear any stale failure banner from a previous reload.
        reportOk("rendering (" + canvas.width + "x" + canvas.height + ")");
      }
      raf = requestAnimationFrame(render);
    }

    function onWinResize() {
      needsResize = true;
    }
    window.addEventListener("resize", onWinResize);

    function onVis() {
      if (document.hidden) {
        running = false;
      } else {
        running = true;
        raf = requestAnimationFrame(render);
      }
    }
    document.addEventListener("visibilitychange", onVis);

    // Runtime parameter API: external surfaces (overview-chat-ui,
    // settings panel, etc.) can post `{ type: "param", name, value }`
    // messages to tune the shader without restarting the webview.
    function onMessage(e) {
      if (e.data && e.data.type === "param") {
        switch (e.data.name) {
          case "ROTATION_SPEED": rotationSpeedVal = e.data.value; break;
          case "DISK_INTENSITY": diskIntensityVal = e.data.value; break;
          case "STARS_ONLY":     starsOnlyVal     = e.data.value; break;
          case "TILT":           tiltVal          = e.data.value; break;
          case "ROTATE":         rotateVal        = e.data.value; break;
          case "BH_CENTER_X":    bhCenterX        = e.data.value; break;
          case "BH_CENTER_Y":    bhCenterY        = e.data.value; break;
          case "BH_SCALE":       bhScaleVal       = e.data.value; break;
          case "CHROMATIC":      chromaticVal     = e.data.value; break;
        }
      }
    }
    window.addEventListener("message", onMessage);

    resize();
    raf = requestAnimationFrame(render);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
