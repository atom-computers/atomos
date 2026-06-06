import texture from "./texture.js";

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

import {
  createProgram,
  getUniformLocations,
  getAttribLocations,
} from './webgl.js'
import { createAnchorManager } from './anchor.js'

const { PI, sin, cos } = Math

// Shader sources will be injected by build
const GLOBE_VERT = "attribute vec2 aPosition;\n\nvoid main() {\n  gl_Position = vec4(aPosition, 0.0, 1.0);\n}\n"
const GLOBE_FRAG = "precision mediump float;\nuniform vec2 uResolution;\nuniform vec2 offset;\nuniform vec2 rotation;        // (phi, theta)\nuniform float dots;\nuniform float scale;\nuniform vec3 baseColor;\nuniform vec3 glowColor;\nuniform vec4 renderParams;    // (dotsBrightness, diffuse, dark, opacity)\nuniform float mapBaseBrightness;\nuniform sampler2D uTexture;\n\nconst float sqrt5 = 2.236068;\nconst float PI = 3.141593;\nconst float kTau = 6.283185;\nconst float kPhi = 1.618034;\nconst float r = 0.8;\n\nfloat byDots;\n\nmat3 rotate(float theta, float phi) {\n  float cx = cos(theta);\n  float cy = cos(phi);\n  float sx = sin(theta);\n  float sy = sin(phi);\n  return mat3(\n    cy, sy * sx, -sy * cx,\n    0.0, cx, sx,\n    sy, cy * -sx, cy * cx\n  );\n}\n\nvec3 nearestFibonacciLattice(vec3 p, out float m) {\n  p = p.xzy;\n\n  float k = max(2.0, floor(log2(sqrt5 * dots * PI * (1.0 - p.z * p.z)) * 0.72021));\n\n  vec2 f = floor(pow(kPhi, k) / sqrt5 * vec2(1.0, kPhi) + 0.5);\n  vec2 br1 = fract((f + 1.0) * (kPhi - 1.0)) * kTau - 3.883222;\n  vec2 br2 = -2.0 * f;\n  vec2 sp = vec2(atan(p.y, p.x), p.z - 1.0);\n  vec2 c = floor(vec2(br2.y * sp.x - br1.y * (sp.y * dots + 1.0), -br2.x * sp.x + br1.x * (sp.y * dots + 1.0)) / (br1.x * br2.y - br2.x * br1.y));\n\n  float mindist = PI;\n  vec3 minip;\n  for (float s = 0.0; s < 4.0; s += 1.0) {\n    vec2 o = vec2(mod(s, 2.0), floor(s * 0.5));\n    float idx = dot(f, c + o);\n    if (idx > dots) continue;\n\n    float a = idx, b = 0.0;\n    if (a >= 16384.0) a -= 16384.0, b += 0.868872;\n    if (a >= 8192.0) a -= 8192.0, b += 0.934436;\n    if (a >= 4096.0) a -= 4096.0, b += 0.467218;\n    if (a >= 2048.0) a -= 2048.0, b += 0.733609;\n    if (a >= 1024.0) a -= 1024.0, b += 0.866804;\n    if (a >= 512.0) a -= 512.0, b += 0.433402;\n    if (a >= 256.0) a -= 256.0, b += 0.216701;\n    if (a >= 128.0) a -= 128.0, b += 0.108351;\n    if (a >= 64.0) a -= 64.0, b += 0.554175;\n    if (a >= 32.0) a -= 32.0, b += 0.777088;\n    if (a >= 16.0) a -= 16.0, b += 0.888544;\n    if (a >= 8.0) a -= 8.0, b += 0.944272;\n    if (a >= 4.0) a -= 4.0, b += 0.472136;\n    if (a >= 2.0) a -= 2.0, b += 0.236068;\n    if (a >= 1.0) a -= 1.0, b += 0.618034;\n\n    float theta = fract(b) * kTau;\n\n    float cosphi = 1.0 - 2.0 * idx * byDots;\n    float sinphi = sqrt(1.0 - cosphi * cosphi);\n    vec3 sample = vec3(cos(theta) * sinphi, sin(theta) * sinphi, cosphi);\n\n    float dist = length(p - sample);\n\n    if (dist < mindist) {\n      mindist = dist;\n      minip = sample;\n    }\n  }\n\n  m = mindist;\n  return minip.xzy;\n}\n\nvoid main() {\n  byDots = 1.0 / dots;\n\n  vec2 invResolution = 1.0 / uResolution;\n\n  vec2 uv = ((gl_FragCoord.xy * invResolution) * 2.0 - 1.0) / scale - offset * vec2(1.0, -1.0) * invResolution;\n  uv.x *= uResolution.x * invResolution.y;\n\n  float l = dot(uv, uv);\n  float glowFactor = 0.0;\n\n  vec4 color = vec4(0.0);\n\n  if (l <= r*r) {\n    float dis;\n    vec4 layer = vec4(0.0);\n    vec3 p = normalize(vec3(uv, sqrt(r*r - l)));\n    mat3 rot = rotate(rotation.y, rotation.x);\n    float dotNL = p.z;\n\n    vec3 gP = nearestFibonacciLattice(p * rot, dis);\n\n    float gPhi = asin(gP.y);\n    float gTheta = acos(-gP.x / cos(gPhi));\n    if (gP.z < 0.0) gTheta = -gTheta;\n\n    float mapColor = max(texture2D(uTexture, vec2(((gTheta * 0.5) / PI), -(gPhi / PI + 0.5))).x, mapBaseBrightness);\n\n    float sample = mapColor\n      * smoothstep(0.008, 0.0, dis) // v\n      * pow(dotNL, renderParams.y) // lighting\n      * renderParams.x;\n    layer += vec4(baseColor\n      * (mix((1.0 - sample) * pow(dotNL, 0.4), sample, renderParams.z) + 0.1) // colorFactor, dark\n      + pow(1.0 - dotNL, 4.0) * glowColor // glow\n    , 1.0);\n\n    color += layer * (1.0 + renderParams.w) * 0.5;\n\n    glowFactor = (1.0 - l) * (1.0 - l) * smoothstep(0.0, 1.0, 0.2 / (l - r*r));\n  } else {\n    float outD = sqrt(0.2 / (l - r*r));\n    glowFactor = smoothstep(0.5, 1.0, outD / (outD + 1.0));\n  }\n\n  gl_FragColor = color + vec4(glowFactor * glowColor, glowFactor);\n}\n"
const MARKER_VERT = "// Marker shaders\n\nvarying vec2 vUV;\nvarying vec3 vMarkerColor;\nvarying float vHasColor;\n\n\n// Vertex shader\nattribute vec2 aPosition;\nattribute vec3 aMarkerPos;\nattribute float aMarkerSize;\nattribute vec3 aMarkerColor;\nattribute float aHasColor;\n\nuniform float phi;\nuniform float theta;\nuniform vec2 uResolution;\nuniform float scale;\nuniform vec2 offset;\nuniform float markerElevation;\n\nvoid main() {\n  float cx = cos(theta), sx = sin(theta);\n  float cy = cos(phi), sy = sin(phi);\n  vec3 p = aMarkerPos * (0.8 + markerElevation);\n  vec3 rp = vec3(\n    cy * p.x + sy * p.z,\n    sy * sx * p.x + cx * p.y - cy * sx * p.z,\n    -sy * cx * p.x + sx * p.y + cy * cx * p.z\n  );\n\n  if (rp.z < 0.0 && length(rp.xy) < 0.8) {\n    gl_Position = vec4(2.0, 2.0, 0.0, 1.0);\n    return;\n  }\n\n  float ia = uResolution.y / uResolution.x;\n  vec2 pos = (rp.xy + aPosition * aMarkerSize * 2.0) * vec2(ia, 1.0) * scale + offset * vec2(1.0, -1.0) * scale / uResolution;\n  gl_Position = vec4(pos, 0.0, 1.0);\n\n  vUV = aPosition;\n  vMarkerColor = aMarkerColor;\n  vHasColor = aHasColor;\n}\n\n"
const MARKER_FRAG = "precision mediump float;\n// Marker shaders\n\nvarying vec2 vUV;\nvarying vec3 vMarkerColor;\nvarying float vHasColor;\n\n\n\nuniform vec3 markerColor;\n\nvoid main() {\n  if (length(vUV) > 0.25) discard;\n  vec3 col = (vHasColor > 0.5 ? vMarkerColor : markerColor);\n  gl_FragColor = vec4(col, 1.0);\n}\n"
const ARC_VERT = "// Combined arc shaders for consistent varying renaming\n\nconst float GLOBE_R = 0.8;\n\n// Shared varyings between vertex and fragment\nvarying vec3 vArcColor;\nvarying float vHasColor;\nvarying float vDepth;\nvarying float vRadialDist;\n\n\n// Vertex shader\n// Attributes in data layout order\nattribute vec2 aPosition;\nattribute vec3 aArcFrom;\nattribute vec3 aArcTo;\nattribute float aArcHeight;\nattribute float aArcWidth;\nattribute vec3 aArcColor;\nattribute float aHasColor;\n\n// Uniforms\nuniform float phi;\nuniform float theta;\nuniform vec2 uResolution;\nuniform float scale;\nuniform vec2 offset;\nuniform float markerElevation;\n\nmat3 rotate(float theta, float phi) {\n  float cx = cos(theta);\n  float cy = cos(phi);\n  float sx = sin(theta);\n  float sy = sin(phi);\n  return mat3(\n    cy, sy * sx, -sy * cx,\n    0.0, cx, sx,\n    sy, cy * -sx, cy * cx\n  );\n}\n\nvec3 bezierPoint(vec3 p0, vec3 p1, vec3 p2, float t) {\n  float u = 1.0 - t;\n  return u * u * p0 + 2.0 * u * t * p1 + t * t * p2;\n}\n\nvec3 bezierTangent(vec3 p0, vec3 p1, vec3 p2, float t) {\n  float u = 1.0 - t;\n  return 2.0 * u * (p1 - p0) + 2.0 * t * (p2 - p1);\n}\n\nvoid main() {\n  mat3 rot = rotate(theta, phi);\n\n  float endpointR = GLOBE_R + markerElevation;\n  vec3 from = aArcFrom * endpointR;\n  vec3 to = aArcTo * endpointR;\n\n  vec3 midSum = aArcFrom + aArcTo;\n  float midLen = length(midSum);\n  vec3 midDir = midLen > 0.001 ? midSum / midLen : vec3(0.0, 1.0, 0.0);\n  vec3 mid = midDir * (GLOBE_R + aArcHeight);\n\n  float t = aPosition.x;\n  vec3 arcPoint = bezierPoint(from, mid, to, t);\n\n  vec3 rotatedPoint = rot * arcPoint;\n\n  // Simple screen-space perpendicular for ribbon width\n  // Project tangent to screen space and rotate 90 degrees\n  vec3 rawTangent = bezierTangent(from, mid, to, t);\n  vec3 rotatedTangent = rot * rawTangent;\n\n  // Screen-space tangent (just xy components)\n  vec2 screenTangent = rotatedTangent.xy;\n  float screenTangentLen = length(screenTangent);\n\n  // Perpendicular in screen space (rotate 90 degrees)\n  vec2 screenPerp = screenTangentLen > 0.001\n    ? vec2(-screenTangent.y, screenTangent.x) / screenTangentLen\n    : vec2(1.0, 0.0);\n\n  float aspect = uResolution.x / uResolution.y;\n  vec2 baseScreenPos = rotatedPoint.xy * vec2(1.0 / aspect, 1.0) * scale + offset * vec2(1.0, -1.0) * scale / uResolution;\n\n  // Offset in screen space\n  vec2 screenPos = baseScreenPos + screenPerp * aArcWidth * aPosition.y * scale;\n\n  gl_Position = vec4(screenPos, 0.0, 1.0);\n\n  vArcColor = aArcColor;\n  vHasColor = aHasColor;\n  vDepth = rotatedPoint.z;\n  vRadialDist = length(rotatedPoint.xy);\n}\n\n"
const ARC_FRAG = "precision mediump float;\n// Combined arc shaders for consistent varying renaming\n\nconst float GLOBE_R = 0.8;\n\n// Shared varyings between vertex and fragment\nvarying vec3 vArcColor;\nvarying float vHasColor;\nvarying float vDepth;\nvarying float vRadialDist;\n\n\n\nuniform vec3 arcColor;\n\nvoid main() {\n  // Discard fragments behind the globe AND within the sphere's projected area\n  if (vDepth < 0.0 && vRadialDist < GLOBE_R) discard;\n\n  vec3 col = vHasColor > 0.5 ? vArcColor : arcColor;\n  gl_FragColor = vec4(col, 1.0);\n}\n"

const GLOBE_R = 0.8

/**
 * Convert lat/lon to 3D position on unit sphere
 * @param {[number, number]} location - [latitude, longitude] in degrees
 * @returns {[number, number, number]} - [x, y, z]
 */
function latLonTo3D([lat, lon]) {
  const latRad = (lat * PI) / 180
  const lonRad = (lon * PI) / 180 - PI
  const cosLat = cos(latRad)
  return [-cosLat * cos(lonRad), sin(latRad), cosLat * sin(lonRad)]
}


/**
 * Create COBE globe
 * @param {HTMLCanvasElement} canvas
 * @param {Object} opts
 * @returns {{ destroy: () => void, update: (state: Partial<COBEOptions>) => void }}
 */
export default (canvas, opts) => {
  const contextOpts = {
    alpha: true,
    stencil: false,
    antialias: true,
    depth: false,
    preserveDrawingBuffer: false,
    ...opts.context,
  }

  let gl = canvas.getContext('webgl2', contextOpts)
  const webgl2 = !!gl
  if (!gl) gl = canvas.getContext('webgl', contextOpts)

  if (!gl) return { destroy: () => {}, update: () => {} }

  const instExt = webgl2 ? null : gl.getExtension('ANGLE_instanced_arrays')

  // Device pixel ratio
  const dpr = opts.devicePixelRatio || 1
  canvas.width = opts.width * dpr
  canvas.height = opts.height * dpr

  // State
  let phi = opts.phi || 0
  let theta = opts.theta || 0
  let markers = opts.markers || []
  let arcs = opts.arcs || []

  // Options with defaults (mutable for dynamic updates)
  let mapSamples = opts.mapSamples || 10000
  let mapBrightness = opts.mapBrightness || 1
  let mapBaseBrightness = opts.mapBaseBrightness || 0
  let baseColor = opts.baseColor || [1, 1, 1]
  let markerColor = opts.markerColor || [1, 0.5, 0]
  let glowColor = opts.glowColor || [1, 1, 1]
  let arcColor = opts.arcColor || [0.3, 0.6, 1]
  let arcWidth = opts.arcWidth ?? 1
  let arcHeight = opts.arcHeight ?? 0.2
  let diffuse = opts.diffuse || 1
  let dark = opts.dark || 0
  let opacity = opts.opacity ?? 1
  let offsetOpt = opts.offset || [0, 0]
  let scaleOpt = opts.scale || 1
  let markerElevation = opts.markerElevation ?? 0.05

  // Create shader programs
  const globeProgram = createProgram(gl, GLOBE_VERT, GLOBE_FRAG)
  const markerProgram = createProgram(gl, MARKER_VERT, MARKER_FRAG)
  const arcProgram = createProgram(gl, ARC_VERT, ARC_FRAG)

  if (!globeProgram) return { destroy: () => {}, update: () => {} }

  // Buffers
  const quadBuffer = gl.createBuffer()
  gl.bindBuffer(gl.ARRAY_BUFFER, quadBuffer)
  gl.bufferData(
    gl.ARRAY_BUFFER,
    new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
    gl.STATIC_DRAW,
  )

  const arcSegmentBuffer = gl.createBuffer()
  const arcSegmentCount = 66 // (32 + 1) * 2
  gl.bindBuffer(gl.ARRAY_BUFFER, arcSegmentBuffer)
  const vertices = []
  for (let i = 0; i <= 32; i++) {
    const t = i / 32
    vertices.push(t, -1, t, 1)
  }
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(vertices), gl.STATIC_DRAW)

  // Instance buffers
  const markerInstanceBuffer = gl.createBuffer()
  const arcInstanceBuffer = gl.createBuffer()

  // Globe uniforms
  const globeUniforms = getUniformLocations(gl, globeProgram, [
    GLOBE_F_uResolution,
    GLOBE_F_rotation,
    GLOBE_F_dots,
    GLOBE_F_scale,
    GLOBE_F_offset,
    GLOBE_F_baseColor,
    GLOBE_F_glowColor,
    GLOBE_F_renderParams,
    GLOBE_F_mapBaseBrightness,
    GLOBE_F_uTexture,
  ])

  // Marker uniforms
  const markerUniforms = getUniformLocations(gl, markerProgram, [
    MARKER_phi,
    MARKER_theta,
    MARKER_uResolution,
    MARKER_scale,
    MARKER_offset,
    MARKER_markerColor,
    MARKER_markerElevation,
  ])

  // Marker attributes
  const markerAttribs = getAttribLocations(gl, markerProgram, [
    MARKER_aPosition,
    MARKER_aMarkerPos,
    MARKER_aMarkerSize,
    MARKER_aMarkerColor,
    MARKER_aHasColor,
  ])

  // Arc uniforms
  const arcUniforms = getUniformLocations(gl, arcProgram, [
    ARC_phi,
    ARC_theta,
    ARC_uResolution,
    ARC_scale,
    ARC_offset,
    ARC_arcColor,
    ARC_markerElevation,
  ])

  // Arc attributes
  const arcAttribs = getAttribLocations(gl, arcProgram, [
    ARC_aPosition,
    ARC_aArcFrom,
    ARC_aArcTo,
    ARC_aArcHeight,
    ARC_aArcWidth,
    ARC_aArcColor,
    ARC_aHasColor,
  ])

  // Globe attribute
  const globePositionAttrib = gl.getAttribLocation(
    globeProgram,
    GLOBE_V_aPosition,
  )

  // Load texture
  const texture = gl.createTexture()
  gl.bindTexture(gl.TEXTURE_2D, texture)
  gl.texImage2D(
    gl.TEXTURE_2D,
    0,
    gl.RGB,
    1,
    1,
    0,
    gl.RGB,
    gl.UNSIGNED_BYTE,
    new Uint8Array([0, 0, 0]),
  )
  // Set filtering for placeholder (no mipmaps)
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)

  const image = new Image()
  image.onload = () => {
    gl.bindTexture(gl.TEXTURE_2D, texture)
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, image)
    gl.generateMipmap(gl.TEXTURE_2D)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.activeTexture(gl.TEXTURE0)
    gl.bindTexture(gl.TEXTURE_2D, texture)
    // Re-render so the land texture is visible immediately
    update({})
  }
  image.src = texture

  /**
   * Update marker instance data
   */
  function updateMarkers(newMarkers) {
    markers = newMarkers

    // 8 floats per marker: x, y, z, size, r, g, b, hasColor
    const markerData = new Float32Array(markers.length * 8)

    markers.forEach((m, i) => {
      markerData.set(
        [
          ...latLonTo3D(m.location),
          m.size,
          ...(m.color || [0, 0, 0]),
          m.color ? 1 : 0,
        ],
        i * 8,
      )
    })

    gl.bindBuffer(gl.ARRAY_BUFFER, markerInstanceBuffer)
    gl.bufferData(gl.ARRAY_BUFFER, markerData, gl.DYNAMIC_DRAW)
  }

  /**
   * Update arc instance data
   */
  // Track valid arc count (arcs with resolved endpoints)
  let validArcCount = 0

  function updateArcs(newArcs) {
    arcs = newArcs
    validArcCount = arcs.length

    // 12 floats per arc: from(3), to(3), height, width, color(3), hasColor
    const arcData = new Float32Array(arcs.length * 12)

    arcs.forEach((arc, i) => {
      arcData.set(
        [
          ...latLonTo3D(arc.from),
          ...latLonTo3D(arc.to),
          arcHeight + markerElevation,
          arcWidth * 0.005,
          ...(arc.color || [0, 0, 0]),
          arc.color ? 1 : 0,
        ],
        i * 12,
      )
    })

    gl.bindBuffer(gl.ARRAY_BUFFER, arcInstanceBuffer)
    gl.bufferData(gl.ARRAY_BUFFER, arcData, gl.DYNAMIC_DRAW)
  }

  /**
   * Apply rotation to a 3D point (same rotation as marker/arc shaders)
   * Uses rot * p (matrix times column vector) for world-to-view transformation
   * @param {[number, number, number]} p
   * @param {number} theta
   * @param {number} phi
   * @returns {[number, number, number]}
   */
  function applyRotation(p) {
    const cx = Math.cos(theta)
    const cy = Math.cos(phi)
    const sx = Math.sin(theta)
    const sy = Math.sin(phi)

    const aspect = canvas.width / canvas.height

    // Rotated coordinates
    const rx = cy * p[0] + sy * p[2]
    const ry = sy * sx * p[0] + cx * p[1] - cy * sx * p[2]
    const rz = -sy * cx * p[0] + sx * p[1] + cy * cx * p[2]

    return [
      ((rx / aspect) * scaleOpt + offsetOpt[0] * scaleOpt * dpr / canvas.width + 1) / 2,
      (-ry * scaleOpt + offsetOpt[1] * scaleOpt * dpr / canvas.height + 1) / 2,
      rz >= 0 || rx * rx + ry * ry >= 0.64, // visible if in front OR outside globe silhouette
    ]
  }

  /**
   * Project a location to screen coordinates
   */
  function project(location) {
    const pos3D = latLonTo3D(location)
    const r = GLOBE_R + markerElevation
    const elevatedPos = [pos3D[0] * r, pos3D[1] * r, pos3D[2] * r]

    const rotated = applyRotation(elevatedPos)
    return { x: rotated[0], y: rotated[1], visible: rotated[2] }
  }

  /**
   * Project arc midpoint to screen coordinates
   */
  function projectArcMidpoint(arc) {
    const fromDir = latLonTo3D(arc.from)
    const toDir = latLonTo3D(arc.to)

    const midSum = [
      fromDir[0] + toDir[0],
      fromDir[1] + toDir[1],
      fromDir[2] + toDir[2],
    ]
    const len = (midSum[0] ** 2 + midSum[1] ** 2 + midSum[2] ** 2) ** 0.5
    if (len < 0.001) return null

    // Bezier at t=0.5: 0.25*(from+to) + 0.5*mid, simplified
    const s =
      0.25 * (GLOBE_R + markerElevation) +
      (0.5 * (GLOBE_R + arcHeight + markerElevation)) / len
    const rotated = applyRotation([midSum[0] * s, midSum[1] * s, midSum[2] * s])
    return { x: rotated[0], y: rotated[1], visible: rotated[2] }
  }

  /**
   * Set up instanced attribute
   */
  function setupInstancedAttribute(attrib, size, stride, offset, divisor) {
    if (attrib < 0) return
    gl.enableVertexAttribArray(attrib)
    gl.vertexAttribPointer(attrib, size, gl.FLOAT, false, stride, offset)

    if (webgl2) {
      gl.vertexAttribDivisor(attrib, divisor)
    } else if (instExt) {
      instExt.vertexAttribDivisorANGLE(attrib, divisor)
    }
  }

  /**
   * Draw instanced
   */
  function drawInstanced(count) {
    if (webgl2) {
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, count)
    } else if (instExt) {
      instExt.drawArraysInstancedANGLE(gl.TRIANGLES, 0, 6, count)
    } else {
      // Fallback: draw one at a time (slow)
      for (let i = 0; i < count; i++) {
        gl.drawArrays(gl.TRIANGLES, 0, 6)
      }
    }
  }

  const UNDEFINED = undefined

  // Anchor elements
  const wrapper = document.createElement('div')
  wrapper.style.cssText = 'position:relative;width:100%;height:100%'
  canvas.parentElement?.insertBefore(wrapper, canvas)
  wrapper.append(canvas)
  const anchorManager = createAnchorManager(wrapper)

  /**
   * Update state and trigger a re-render
   * @param {Object} state - State updates to apply
   */
  function update(state) {
    // Update state from provided values
    if (state.phi != UNDEFINED) phi = state.phi
    if (state.theta != UNDEFINED) theta = state.theta
    if (state.markers) updateMarkers(state.markers)
    if (state.arcs) updateArcs(state.arcs)

    if (state.width && state.height) {
      canvas.width = state.width * dpr
      canvas.height = state.height * dpr
    }

    // Update appearance options
    if (state.mapSamples != UNDEFINED) mapSamples = state.mapSamples
    if (state.mapBrightness != UNDEFINED) mapBrightness = state.mapBrightness
    if (state.mapBaseBrightness != UNDEFINED)
      mapBaseBrightness = state.mapBaseBrightness
    if (state.baseColor != UNDEFINED) baseColor = state.baseColor
    if (state.markerColor != UNDEFINED) markerColor = state.markerColor
    if (state.glowColor != UNDEFINED) glowColor = state.glowColor
    if (state.arcColor != UNDEFINED) arcColor = state.arcColor
    if (state.arcWidth != UNDEFINED) arcWidth = state.arcWidth
    if (state.arcHeight != UNDEFINED) arcHeight = state.arcHeight
    if (state.diffuse != UNDEFINED) diffuse = state.diffuse
    if (state.dark != UNDEFINED) dark = state.dark
    if (state.opacity != UNDEFINED) opacity = state.opacity
    if (state.offset != UNDEFINED) offsetOpt = state.offset
    if (state.scale != UNDEFINED) scaleOpt = state.scale
    if (state.markerElevation != UNDEFINED)
      markerElevation = state.markerElevation

    // Update anchor positions
    anchorManager.m(markers, project)
    anchorManager.a(arcs, projectArcMidpoint)
    anchorManager.s()

    // Set viewport
    gl.viewport(0, 0, canvas.width, canvas.height)
    gl.clearColor(0, 0, 0, 0)
    gl.clear(gl.COLOR_BUFFER_BIT)

    // Enable blending for transparency
    gl.enable(gl.BLEND)
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

    // === Pass 1: Globe ===
    gl.useProgram(globeProgram)

    // Bind quad buffer
    gl.bindBuffer(gl.ARRAY_BUFFER, quadBuffer)
    gl.enableVertexAttribArray(globePositionAttrib)
    gl.vertexAttribPointer(globePositionAttrib, 2, gl.FLOAT, false, 0, 0)
    // Reset divisor to 0 for non-instanced draw (may have been set by previous frame's instanced draws)
    if (webgl2) {
      gl.vertexAttribDivisor(globePositionAttrib, 0)
    } else if (instExt) {
      instExt.vertexAttribDivisorANGLE(globePositionAttrib, 0)
    }

    // Set uniforms
    gl.uniform2f(
      globeUniforms[GLOBE_F_uResolution],
      canvas.width,
      canvas.height,
    )
    gl.uniform2f(globeUniforms[GLOBE_F_rotation], phi, theta)
    gl.uniform1f(globeUniforms[GLOBE_F_dots], mapSamples)
    gl.uniform1f(globeUniforms[GLOBE_F_scale], scaleOpt)
    gl.uniform2f(
      globeUniforms[GLOBE_F_offset],
      offsetOpt[0] * dpr,
      offsetOpt[1] * dpr,
    )
    gl.uniform3fv(globeUniforms[GLOBE_F_baseColor], baseColor)
    gl.uniform3fv(globeUniforms[GLOBE_F_glowColor], glowColor)
    gl.uniform4f(
      globeUniforms[GLOBE_F_renderParams],
      mapBrightness,
      diffuse,
      dark,
      opacity,
    )
    gl.uniform1f(globeUniforms[GLOBE_F_mapBaseBrightness], mapBaseBrightness)
    gl.uniform1i(globeUniforms[GLOBE_F_uTexture], 0)

    // Bind texture to unit 0
    gl.activeTexture(gl.TEXTURE0)
    gl.bindTexture(gl.TEXTURE_2D, texture)

    gl.drawArrays(gl.TRIANGLES, 0, 6)

    // === Pass 2: Arcs ===
    if (arcProgram && validArcCount > 0) {
      gl.useProgram(arcProgram)

      // Bind arc segment buffer for position (t, offset pairs along curve)
      gl.bindBuffer(gl.ARRAY_BUFFER, arcSegmentBuffer)
      if (arcAttribs[ARC_aPosition] >= 0) {
        gl.enableVertexAttribArray(arcAttribs[ARC_aPosition])
        gl.vertexAttribPointer(
          arcAttribs[ARC_aPosition],
          2,
          gl.FLOAT,
          false,
          0,
          0,
        )
        if (webgl2) gl.vertexAttribDivisor(arcAttribs[ARC_aPosition], 0)
        else if (instExt)
          instExt.vertexAttribDivisorANGLE(arcAttribs[ARC_aPosition], 0)
      }

      // Bind instance buffer
      gl.bindBuffer(gl.ARRAY_BUFFER, arcInstanceBuffer)
      const arcStride = 12 * 4 // 12 floats * 4 bytes

      setupInstancedAttribute(arcAttribs[ARC_aArcFrom], 3, arcStride, 0, 1)
      setupInstancedAttribute(arcAttribs[ARC_aArcTo], 3, arcStride, 12, 1)
      setupInstancedAttribute(arcAttribs[ARC_aArcHeight], 1, arcStride, 24, 1)
      setupInstancedAttribute(arcAttribs[ARC_aArcWidth], 1, arcStride, 28, 1)
      setupInstancedAttribute(arcAttribs[ARC_aArcColor], 3, arcStride, 32, 1)
      setupInstancedAttribute(arcAttribs[ARC_aHasColor], 1, arcStride, 44, 1)

      // Set uniforms
      gl.uniform1f(arcUniforms[ARC_phi], phi)
      gl.uniform1f(arcUniforms[ARC_theta], theta)
      gl.uniform2f(arcUniforms[ARC_uResolution], canvas.width, canvas.height)
      gl.uniform1f(arcUniforms[ARC_scale], scaleOpt)
      gl.uniform2f(
        arcUniforms[ARC_offset],
        offsetOpt[0] * dpr,
        offsetOpt[1] * dpr,
      )
      gl.uniform3fv(arcUniforms[ARC_arcColor], arcColor)
      gl.uniform1f(arcUniforms[ARC_markerElevation], markerElevation)

      // Draw arcs using TRIANGLE_STRIP
      if (webgl2) {
        gl.drawArraysInstanced(
          gl.TRIANGLE_STRIP,
          0,
          arcSegmentCount,
          validArcCount,
        )
      } else if (instExt) {
        instExt.drawArraysInstancedANGLE(
          gl.TRIANGLE_STRIP,
          0,
          arcSegmentCount,
          validArcCount,
        )
      } else {
        // Fallback: draw one arc at a time
        for (let i = 0; i < validArcCount; i++) {
          gl.drawArrays(gl.TRIANGLE_STRIP, 0, arcSegmentCount)
        }
      }
    }

    // === Pass 3: Markers ===
    if (markerProgram && markers.length > 0) {
      gl.useProgram(markerProgram)

      // Bind quad buffer for position
      gl.bindBuffer(gl.ARRAY_BUFFER, quadBuffer)
      if (markerAttribs[MARKER_aPosition] >= 0) {
        gl.enableVertexAttribArray(markerAttribs[MARKER_aPosition])
        gl.vertexAttribPointer(
          markerAttribs[MARKER_aPosition],
          2,
          gl.FLOAT,
          false,
          0,
          0,
        )
        if (webgl2) gl.vertexAttribDivisor(markerAttribs[MARKER_aPosition], 0)
        else if (instExt)
          instExt.vertexAttribDivisorANGLE(markerAttribs[MARKER_aPosition], 0)
      }

      // Bind instance buffer
      gl.bindBuffer(gl.ARRAY_BUFFER, markerInstanceBuffer)
      const markerStride = 8 * 4 // 8 floats * 4 bytes

      setupInstancedAttribute(
        markerAttribs[MARKER_aMarkerPos],
        3,
        markerStride,
        0,
        1,
      )
      setupInstancedAttribute(
        markerAttribs[MARKER_aMarkerSize],
        1,
        markerStride,
        12,
        1,
      )
      setupInstancedAttribute(
        markerAttribs[MARKER_aMarkerColor],
        3,
        markerStride,
        16,
        1,
      )
      setupInstancedAttribute(
        markerAttribs[MARKER_aHasColor],
        1,
        markerStride,
        28,
        1,
      )

      // Set uniforms
      gl.uniform1f(markerUniforms[MARKER_phi], phi)
      gl.uniform1f(markerUniforms[MARKER_theta], theta)
      gl.uniform2f(
        markerUniforms[MARKER_uResolution],
        canvas.width,
        canvas.height,
      )
      gl.uniform1f(markerUniforms[MARKER_scale], scaleOpt)
      gl.uniform2f(
        markerUniforms[MARKER_offset],
        offsetOpt[0] * dpr,
        offsetOpt[1] * dpr,
      )
      gl.uniform3fv(markerUniforms[MARKER_markerColor], markerColor)
      gl.uniform1f(markerUniforms[MARKER_markerElevation], markerElevation)

      drawInstanced(markers.length)
    }
  }

  // Initialize
  update({ markers, arcs })

  // Return public API
  return {
    update,
    destroy: () => {
      // Clean up WebGL resources
      gl.deleteBuffer(quadBuffer)
      gl.deleteBuffer(arcSegmentBuffer)
      gl.deleteBuffer(markerInstanceBuffer)
      gl.deleteBuffer(arcInstanceBuffer)
      gl.deleteProgram(globeProgram)
      if (markerProgram) gl.deleteProgram(markerProgram)
      if (arcProgram) gl.deleteProgram(arcProgram)

      // Clean up anchor elements
      anchorManager.r()
    },
  }
}
