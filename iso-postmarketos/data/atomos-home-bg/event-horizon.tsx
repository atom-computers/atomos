// Canonical React source for the AtomOS home-background animation.
//
// This file is the single source of truth for the WebGL black-hole /
// accretion-disk shader rendered behind the overview-chat-ui surface.
//
// At build time it would normally be bundled by the consumer's React
// toolchain (Next.js, Vite, etc.). Inside the AtomOS rootfs we ship a
// hand-derived vanilla JS port at `event-horizon.js` so the WebKitGTK
// webview can load it without a Node bundler at boot. Keep the two
// files in lock-step: any change here must be mirrored into
// `event-horizon.js` (only the React/JSX scaffolding differs; the
// WebGL pipeline, shader strings, event handlers, and runtime-message
// API are identical).

"use client";

import { useEffect, useRef } from "react";

const VERT_SRC = [
  "attribute vec2 a_pos;",
  "void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }",
].join("\n");

const FRAG_SRC = `
precision highp float;
uniform float u_time;
uniform vec2 u_res;
uniform float u_rotationSpeed;
uniform float u_diskIntensity;
uniform float u_starsOnly;
uniform float u_tilt;
uniform float u_rotate;
uniform vec2 u_bhCenter;
uniform float u_bhScale;
uniform float u_chromatic;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;
const float RS = 1.0;
const float ISCO = 3.0;
const float DISK_IN = 2.2;
const float DISK_OUT = 14.0;

float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float gNoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(
        mix(hash(i), hash(i + vec2(1, 0)), u.x),
        mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x),
        u.y
    );
}

float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    mat2 rot = mat2(0.866, 0.5, -0.5, 0.866);
    for (int i = 0; i < 4; i++) {
        v += a * gNoise(p);
        p = rot * p * 2.03 + vec2(47.0, 13.0);
        a *= 0.49;
    }
    return v;
}
float fbmLite(vec2 p) {
    float v = 0.5 * gNoise(p);
    p = mat2(0.866, 0.5, -0.5, 0.866) * p * 2.03 + vec2(47.0, 13.0);
    v += 0.25 * gNoise(p);
    return v;
}

vec3 starField(vec3 rd) {
    float u = atan(rd.z, rd.x) / TAU + 0.5;
    float v = asin(clamp(rd.y, -0.999, 0.999)) / PI + 0.5;
    vec3 col = vec3(0.0);

    {
        vec2 cell = floor(vec2(u, v) * 55.0);
        vec2 f = fract(vec2(u, v) * 55.0);
        vec2 r = vec2(hash(cell), hash(cell + 127.1));
        float d = length(f - r);
        float b = pow(r.x, 10.0) * exp(-d * d * 500.0);
        col += mix(vec3(1.0, 0.65, 0.35), vec3(0.55, 0.75, 1.0), r.y) * b * 4.0;
    }
    {
        vec2 cell = floor(vec2(u, v) * 170.0);
        vec2 f = fract(vec2(u, v) * 170.0);
        vec2 r = vec2(hash(cell + 43.0), hash(cell + 91.0));
        float d = length(f - r);
        float b = pow(r.x, 18.0) * exp(-d * d * 1000.0);
        col += vec3(0.85, 0.88, 1.0) * b * 2.0;
    }
    float n = fbmLite(vec2(u, v) * 3.0) * fbmLite(vec2(u, v) * 5.5 + 10.0);
    col += vec3(0.10, 0.04, 0.14) * pow(n, 3.0);

    return col;
}

vec3 bbColor(float t) {
    t = clamp(t, 0.0, 2.5);
    vec3 lo = vec3(1.0, 0.18, 0.0);
    vec3 mi = vec3(1.0, 0.55, 0.12);
    vec3 hi = vec3(1.0, 0.93, 0.82);
    vec3 hot = vec3(0.65, 0.82, 1.0);
    vec3 c = mix(lo, mi, smoothstep(0.0, 0.3, t));
    c = mix(c, hi, smoothstep(0.3, 0.8, t));
    return mix(c, hot, smoothstep(0.8, 1.8, t));
}

vec4 shadeDisk(vec3 hit, vec3 vel, float time) {
    float r = length(hit.xz);
    if (r < DISK_IN * 0.5 || r > DISK_OUT * 1.05) return vec4(0.0);

    float xr = ISCO / r;
    float tProfile = pow(ISCO / r, 0.75) * pow(max(0.001, 1.0 - sqrt(xr)), 0.25);

    float gRedshift = sqrt(max(0.01, 1.0 - RS / r));
    tProfile *= gRedshift;

    float phi = atan(hit.z, hit.x);
    float lr = log2(max(r, 0.1));

    float keplerOmega = sqrt(0.5 * RS / (r * r * r));
    float baseOmega = 0.04;
    float omega = max(keplerOmega, baseOmega) * 10.0;
    float rotAngle = time * omega;
    float ca = cos(rotAngle), sa = sin(rotAngle);
    vec2 rotXZ = vec2(hit.x * ca - hit.z * sa, hit.x * sa + hit.z * ca);

    float turb = fbm(rotXZ * 1.2 + vec2(lr * 3.0));
    turb = 0.25 + 0.75 * turb;

    float timeShift = time * 0.15;
    float detail = gNoise(rotXZ * 3.5 + vec2(100.0 + timeShift, timeShift * 0.7));
    turb *= 0.7 + 0.3 * detail;

    float ringPhase1 = sin(r * 10.0 + rotAngle * r * 0.3) * 0.5 + 0.5;
    float ringPhase2 = sin(r * 20.0 - rotAngle * r * 0.15) * 0.5 + 0.5;
    float rings = ringPhase1 * 0.55 + ringPhase2 * 0.45;
    rings = 0.5 + 0.5 * rings;
    turb *= rings;

    float orbSpeed = sqrt(0.5 * RS / max(r, DISK_IN));
    vec3 orbDir = normalize(vec3(-hit.z, 0.0, hit.x));
    float dopplerFactor = 1.0 + 2.0 * dot(normalize(vel), orbDir) * orbSpeed;
    dopplerFactor = max(0.15, dopplerFactor);
    float dopplerBoost = dopplerFactor * dopplerFactor * dopplerFactor;

    float I = tProfile * turb * 6.0;

    float innerFade = smoothstep(DISK_IN * 0.7, DISK_IN * 1.2, r);
    float iscoFade = 0.35 + 0.65 * smoothstep(ISCO * 0.85, ISCO * 1.2, r);
    float outerFade = 1.0 - smoothstep(DISK_OUT * 0.55, DISK_OUT, r);
    I *= innerFade * iscoFade * outerFade;

    float colorTemp = tProfile * pow(dopplerFactor, 1.8) * 1.2;
    vec3 col = bbColor(colorTemp) * I * dopplerBoost;

    if (u_chromatic > 0.01) {
        float spectralR = (r - DISK_IN) / (DISK_OUT - DISK_IN);
        float ringP = ringPhase1;
        float hue = spectralR * 0.8 + ringP * 0.4;

        vec3 spectrum;
        spectrum.r = (1.0 - smoothstep(0.0, 0.35, hue))
                   + smoothstep(0.25, 0.45, hue) * (1.0 - smoothstep(0.55, 0.7, hue)) * 0.7
                   + smoothstep(0.85, 1.1, hue) * 0.4;
        spectrum.g = smoothstep(0.15, 0.4, hue) * (1.0 - smoothstep(0.7, 0.95, hue));
        spectrum.b = smoothstep(0.5, 0.8, hue)
                   + smoothstep(0.85, 1.1, hue) * 0.3;
        spectrum = max(spectrum, 0.05);

        float luma = dot(col, vec3(0.3, 0.5, 0.2));
        vec3 chromaCol = spectrum * luma * 2.0;

        col = mix(col, chromaCol, u_chromatic * 0.75);
    }

    float alpha = clamp(I * 1.3, 0.0, 0.96);
    return vec4(col, alpha);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 ctr = (u_bhScale > 0.0 ? u_bhCenter : vec2(0.5)) * u_res;
    float sc = u_bhScale > 0.0 ? u_bhScale : 1.0;
    vec2 uv = (fc - ctr) * sc / u_res.x;

    float camR = 28.0;
    float orbit = u_time * 0.055 * u_rotationSpeed;
    float tilt = 0.25 + u_tilt;

    vec3 eye = vec3(
        camR * cos(orbit) * cos(tilt),
        camR * sin(tilt),
        camR * sin(orbit) * cos(tilt)
    );

    vec3 fwd = normalize(-eye);
    vec3 rt = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
    vec3 up = cross(rt, fwd);

    float cr = cos(u_rotate), sr = sin(u_rotate);
    vec3 rr = cr * rt + sr * up;
    vec3 ru = -sr * rt + cr * up;

    vec3 rd = normalize(fwd + uv.x * rr + uv.y * ru);

    if (u_starsOnly > 0.5) {
        vec3 s = starField(rd);
        gl_FragColor = vec4(pow(s, vec3(0.45)), 1.0);
        return;
    }

    vec3 pos = eye;
    vec3 vel = rd;

    vec3 Lvec = cross(pos, vel);
    float L2 = dot(Lvec, Lvec);

    vec4 diskAccum = vec4(0.0);
    vec3 glow = vec3(0.0);
    bool absorbed = false;
    int diskCrossings = 0;
    float minR = 1000.0;

    float gravCoeff = -1.5 * RS * L2;

    for (int i = 0; i < 200; i++) {
        float r = length(pos);

        float h = 0.16 * clamp(r - 0.4 * RS, 0.06, 3.5);

        float invR2 = 1.0 / (r * r);
        float invR5 = invR2 * invR2 / r;
        vec3 acc = (gravCoeff * invR5) * pos;

        vec3 p1 = pos + vel * h + 0.5 * acc * h * h;
        float r1 = length(p1);
        float invR12 = 1.0 / (r1 * r1);
        float invR15 = invR12 * invR12 / r1;
        vec3 acc1 = (gravCoeff * invR15) * p1;
        vec3 v1 = vel + 0.5 * (acc + acc1) * h;

        minR = min(minR, r1);

        if (pos.y * p1.y < 0.0 && diskAccum.a < 0.97) {
            float t = pos.y / (pos.y - p1.y);
            vec3 hit = mix(pos, p1, t);
            vec4 dc = shadeDisk(hit, vel, u_time * u_rotationSpeed);
            dc.rgb *= u_diskIntensity;
            if (diskCrossings >= 2) {
                dc.rgb *= 0.15;
                dc.a *= 0.15;
            }
            diskAccum.rgb += dc.rgb * dc.a * (1.0 - diskAccum.a);
            diskAccum.a += dc.a * (1.0 - diskAccum.a);
            float diskBright = dot(dc.rgb, vec3(0.3, 0.5, 0.2)) * dc.a;
            glow += dc.rgb * 0.04 * max(diskBright - 0.3, 0.0);
            diskCrossings++;
        }

        if (r1 < 6.0) {
            float pDist = abs(r1 - 1.5 * RS);
            float psGlow = 1.0 / (1.0 + pDist * pDist * 20.0) * h * 0.001 / max(r1 * r1, 0.2);
            glow += vec3(0.8, 0.6, 0.35) * psGlow;

            float hzGlow = exp(-(r1 - RS) * 3.5) * h * 0.003;
            glow += vec3(0.5, 0.25, 0.08) * max(hzGlow, 0.0);
        }

        if (r1 < RS * 0.35) { absorbed = true; break; }
        if (r1 > 25.0 && r1 > r) break;
        if (r1 > 55.0) break;

        pos = p1;
        vel = v1;
    }

    vec3 col = vec3(0.0);
    if (!absorbed) {
        col = starField(normalize(vel));
    }
    col = col * (1.0 - diskAccum.a) + diskAccum.rgb;

    float ringDist = abs(minR - 1.5 * RS);
    float chromo = u_chromatic;

    float baseChroma = 0.1 + 0.5 * chromo;
    float spread = 0.08 + 0.18 * chromo;
    float falloff = 20.0 + 15.0 * (1.0 - chromo);
    float rRing = exp(-(ringDist + spread) * (ringDist + spread) * falloff);
    float bRing = exp(-(ringDist - spread) * (ringDist - spread) * falloff);
    col.r += rRing * 0.3 * baseChroma;
    col.b += bRing * 0.35 * baseChroma;

    col += glow;

    col *= 1.4;
    vec3 a = col * (col + 0.0245786) - 0.000090537;
    vec3 b = col * (0.983729 * col + 0.4329510) + 0.238081;
    col = a / b;

    col = smoothstep(0.0, 1.0, col);
    col = pow(max(col, 0.0), vec3(0.92));

    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
`;

function compileShader(gl: WebGLRenderingContext, type: number, src: string) {
  const s = gl.createShader(type);
  if (!s) throw new Error("createShader failed");
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
    console.error("Shader compile error:", gl.getShaderInfoLog(s));
  }
  return s;
}

export function EventHorizonBackground({ className }: { className?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const prefersReduced =
      typeof window !== "undefined" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const gl = canvas.getContext("webgl", {
      alpha: false,
      antialias: false,
      preserveDrawingBuffer: false,
    });
    if (!gl) return;

    const canvasEl = canvas;
    const glCtx = gl;

    const vert = compileShader(glCtx, glCtx.VERTEX_SHADER, VERT_SRC);
    const frag = compileShader(glCtx, glCtx.FRAGMENT_SHADER, FRAG_SRC);
    const prog = glCtx.createProgram();
    if (!prog) return;
    glCtx.attachShader(prog, vert);
    glCtx.attachShader(prog, frag);
    glCtx.linkProgram(prog);
    if (!glCtx.getProgramParameter(prog, glCtx.LINK_STATUS)) {
      console.error("Program link error:", glCtx.getProgramInfoLog(prog));
      return;
    }
    glCtx.useProgram(prog);

    const buf = glCtx.createBuffer();
    glCtx.bindBuffer(glCtx.ARRAY_BUFFER, buf);
    glCtx.bufferData(
      glCtx.ARRAY_BUFFER,
      new Float32Array([-1, -1, 3, -1, -1, 3]),
      glCtx.STATIC_DRAW
    );
    const aPos = glCtx.getAttribLocation(prog, "a_pos");
    glCtx.enableVertexAttribArray(aPos);
    glCtx.vertexAttribPointer(aPos, 2, glCtx.FLOAT, false, 0, 0);

    const uTime = glCtx.getUniformLocation(prog, "u_time");
    const uRes = glCtx.getUniformLocation(prog, "u_res");
    const uRotationSpeed = glCtx.getUniformLocation(prog, "u_rotationSpeed");
    const uDiskIntensity = glCtx.getUniformLocation(prog, "u_diskIntensity");
    const uStarsOnly = glCtx.getUniformLocation(prog, "u_starsOnly");
    const uTilt = glCtx.getUniformLocation(prog, "u_tilt");
    const uRotate = glCtx.getUniformLocation(prog, "u_rotate");
    const uBhCenter = glCtx.getUniformLocation(prog, "u_bhCenter");
    const uBhScale = glCtx.getUniformLocation(prog, "u_bhScale");
    const uChromatic = glCtx.getUniformLocation(prog, "u_chromatic");

    let rotationSpeedVal = 0.3;
    let diskIntensityVal = 1.0;
    let starsOnlyVal = 0.0;
    let tiltVal = -0.2;
    let rotateVal = 0.0;
    let bhCenterX = 0.0;
    let bhCenterY = 0.0;
    let bhScaleVal = 0.0;
    let chromaticVal = 0.0;

    let mouseDown = false;
    let lastMX = 0;
    let lastMY = 0;

    const onMouseDown = (e: MouseEvent) => {
      mouseDown = true;
      lastMX = e.clientX;
      lastMY = e.clientY;
    };
    const onMouseMove = (e: MouseEvent) => {
      if (mouseDown) {
        tiltVal += (e.clientY - lastMY) * 0.003;
        rotateVal += (e.clientX - lastMX) * 0.003;
        tiltVal = Math.max(-0.8, Math.min(0.8, tiltVal));
        lastMX = e.clientX;
        lastMY = e.clientY;
      }
    };
    const onMouseUp = () => {
      mouseDown = false;
    };
    const onTouchStart = (e: TouchEvent) => {
      e.preventDefault();
      mouseDown = true;
      lastMX = e.touches[0].clientX;
      lastMY = e.touches[0].clientY;
    };
    const onTouchMove = (e: TouchEvent) => {
      e.preventDefault();
      if (mouseDown) {
        tiltVal += (e.touches[0].clientY - lastMY) * 0.003;
        rotateVal += (e.touches[0].clientX - lastMX) * 0.003;
        tiltVal = Math.max(-0.8, Math.min(0.8, tiltVal));
        lastMX = e.touches[0].clientX;
        lastMY = e.touches[0].clientY;
      }
    };
    const onTouchEnd = () => {
      mouseDown = false;
    };

    canvasEl.addEventListener("mousedown", onMouseDown);
    canvasEl.addEventListener("mousemove", onMouseMove);
    canvasEl.addEventListener("mouseup", onMouseUp);
    canvasEl.addEventListener("touchstart", onTouchStart, { passive: false });
    canvasEl.addEventListener("touchmove", onTouchMove, { passive: false });
    canvasEl.addEventListener("touchend", onTouchEnd);

    const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    let needsResize = true;
    let running = true;
    let raf = 0;

    function resize() {
      needsResize = false;
      const w = Math.round(canvasEl.clientWidth * dpr);
      const h = Math.round(canvasEl.clientHeight * dpr);
      if (canvasEl.width !== w || canvasEl.height !== h) {
        canvasEl.width = w;
        canvasEl.height = h;
        glCtx.viewport(0, 0, w, h);
        glCtx.uniform2f(uRes, canvasEl.width, canvasEl.height);
      }
    }

    function render(now: number) {
      if (!running) return;
      if (needsResize) resize();
      const t = prefersReduced ? 0.0 : now * 0.001;
      glCtx.uniform1f(uTime, t);
      glCtx.uniform1f(uRotationSpeed, rotationSpeedVal);
      glCtx.uniform1f(uDiskIntensity, diskIntensityVal);
      glCtx.uniform1f(uStarsOnly, starsOnlyVal);
      glCtx.uniform1f(uTilt, tiltVal);
      glCtx.uniform1f(uRotate, rotateVal);
      glCtx.uniform2f(uBhCenter, bhCenterX, bhCenterY);
      glCtx.uniform1f(uBhScale, bhScaleVal);
      glCtx.uniform1f(uChromatic, chromaticVal);
      glCtx.drawArrays(glCtx.TRIANGLES, 0, 3);
      raf = requestAnimationFrame(render);
    }

    const onWinResize = () => {
      needsResize = true;
    };
    window.addEventListener("resize", onWinResize);

    const onVis = () => {
      if (document.hidden) {
        running = false;
      } else {
        running = true;
        raf = requestAnimationFrame(render);
      }
    };
    document.addEventListener("visibilitychange", onVis);

    const onMessage = (e: MessageEvent) => {
      if (e.data && e.data.type === "param") {
        switch (e.data.name) {
          case "ROTATION_SPEED":
            rotationSpeedVal = e.data.value;
            break;
          case "DISK_INTENSITY":
            diskIntensityVal = e.data.value;
            break;
          case "STARS_ONLY":
            starsOnlyVal = e.data.value;
            break;
          case "TILT":
            tiltVal = e.data.value;
            break;
          case "ROTATE":
            rotateVal = e.data.value;
            break;
          case "BH_CENTER_X":
            bhCenterX = e.data.value;
            break;
          case "BH_CENTER_Y":
            bhCenterY = e.data.value;
            break;
          case "BH_SCALE":
            bhScaleVal = e.data.value;
            break;
          case "CHROMATIC":
            chromaticVal = e.data.value;
            break;
        }
      }
    };
    window.addEventListener("message", onMessage);

    resize();
    raf = requestAnimationFrame(render);

    return () => {
      running = false;
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", onWinResize);
      document.removeEventListener("visibilitychange", onVis);
      window.removeEventListener("message", onMessage);
      canvasEl.removeEventListener("mousedown", onMouseDown);
      canvasEl.removeEventListener("mousemove", onMouseMove);
      canvasEl.removeEventListener("mouseup", onMouseUp);
      canvasEl.removeEventListener("touchstart", onTouchStart);
      canvasEl.removeEventListener("touchmove", onTouchMove);
      canvasEl.removeEventListener("touchend", onTouchEnd);
    };
  }, []);

  return (
    <div className={`relative h-full w-full overflow-hidden bg-[#0a0a0a] ${className ?? ""}`}>
      <canvas
        ref={canvasRef}
        className="block h-full w-full"
        aria-hidden
      />
      {/* <div
        className="pointer-events-none absolute left-6 top-5 z-10 font-mono text-[11px] uppercase tracking-[0.15em] text-[rgba(200,149,108,0.5)]"
        aria-hidden
      >
        Event Horizon
      </div> */}
    </div>
  );
}
