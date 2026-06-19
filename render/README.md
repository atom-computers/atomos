# render

A hardware-agnostic rendering engine built on **matrix math**. No concepts of "mesh,"
"texture," or "shader" exist at this level — everything is a matrix operating on a matrix.

## Philosophy

The GPU and the CPU agree on one thing: matrices. A "mesh" is a `Spatial` region
where `x` indexes vertices and each element holds position data. A "texture" is a
`Spatial` region where `(x, y)` index texels and each element holds color data. Both
are just matrices. Rendering is projecting one matrix onto another.

This crate provides the math primitives to do that projection — software rasterization
on CPU, with a planned `GpuBackend` trait for hardware acceleration. The renderer does
not own the framebuffer or allocate memory — it operates on `Spatial` regions provided
by the kernel via the `Kernel` trait.

## Architecture

```
render/
└── src/
    ├── lib.rs            # re-exports, feature flags (cpu, gpu)
    ├── math.rs           # Vec2, Vec3, Vec4, Mat4, Quat, projection, inverse, dot, cross
    ├── rasterize.rs      # CPU triangle rasterizer with z-buffer, barycentric interpolation
    ├── blend.rs          # element-wise alpha blending of two Spatial regions
    └── region.rs         # RegionSurface: read/write Spatial regions via Kernel trait
```

### `math.rs` — Linear Algebra Primitives

```rust
pub struct Vec4 { pub x: f32, pub y: f32, pub z: f32, pub w: f32 }
pub struct Mat4 { pub cols: [[f32; 4]; 4] }

impl Mat4 {
    pub fn identity() -> Self;
    pub fn translate(x: f32, y: f32, z: f32) -> Self;
    pub fn scale(sx: f32, sy: f32, sz: f32) -> Self;
    pub fn rotate_x(angle: f32) -> Self;
    pub fn rotate_y(angle: f32) -> Self;
    pub fn rotate_z(angle: f32) -> Self;
    pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) -> Self;
    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) -> Self;
    pub fn inverse(&self) -> Option<Self>;
    pub fn transpose(&self) -> Self;
}

impl core::ops::Mul<Mat4> for Mat4 { ... }
impl core::ops::Mul<Vec4> for Mat4 { ... }
```

### `rasterize.rs` — CPU Triangle Rasterizer

Takes a matrix of vertices (a `Spatial` region where `x` = vertex index, each element
is `(position: Vec4, color: Vec4)`) and projects them through a `Mat4` transform onto a
pixel grid (another `Spatial` region with `format: U8x4`).

```rust
/// Project vertices → viewport → rasterize triangles → write pixels to target region.
pub fn rasterize(
    kernel: &dyn Kernel,
    vertices: RegionId,       // Spatial { x: N, y: 1, z: 1, t: 1, format: F32x4 }
    transform: Mat4,
    target: RegionId,         // Spatial { x: W, y: H, z: 1, t: frame, format: U8x4 }
    clear_color: Option<[u8; 4]>,
) -> Result<(), KernelError>;
```

Features:
- Barycentric coordinate interpolation for vertex attributes (color, depth)
- Z-buffer for per-pixel depth testing
- Back-face culling
- Viewport transform (NDC → pixel coordinates)

### `blend.rs` — Region Compositing

Element-wise alpha blending of one `Spatial` region onto another. Used by the
compositor to stack app surfaces.

```rust
/// Blend src region onto dst region with alpha compositing (src-over-dst).
pub fn blend(
    kernel: &dyn Kernel,
    src: RegionId,            // Spatial { format: U8x4 }
    dst: RegionId,            // Spatial { format: U8x4 } — written in place
) -> Result<(), KernelError>;
```

### `region.rs` — Kernel Region Abstraction

A thin wrapper around a `RegionId` + `Kernel` trait reference that provides typed
read/write for `Spatial` regions:

```rust
pub struct RegionSurface<'k> {
    kernel: &'k dyn Kernel,
    id: RegionId,
    info: Region,
}

impl RegionSurface<'_> {
    pub fn open(kernel: &dyn Kernel, id: RegionId) -> Result<Self, KernelError>;
    pub fn read_element(&self, x: u32, y: u32, z: u32, t: u32) -> Result<[u8; 4], KernelError>;
    pub fn write_element(&self, x: u32, y: u32, z: u32, t: u32, data: &[u8]) -> Result<(), KernelError>;
    pub fn read_region(&self, offset: usize, buf: &mut [u8]) -> Result<usize, KernelError>;
    pub fn write_region(&self, offset: usize, data: &[u8]) -> Result<(), KernelError>;
    pub fn pixel_offset(x: u32, y: u32, z: u32, t: u32) -> usize;
}
```

## GPU Backend (Planned)

An abstract trait for hardware-accelerated rasterization. The same `render/` API
calls dispatch to either the CPU rasterizer or a GPU backend at compile time via
feature flags.

```rust
pub trait GpuBackend {
    /// Upload vertex data from a Spatial region to GPU memory.
    fn upload_vertices(&mut self, region: RegionId) -> Result<GpuHandle, KernelError>;

    /// Upload pixel data from a Spatial region as a sample source.
    fn upload_samples(&mut self, region: RegionId) -> Result<GpuHandle, KernelError>;

    /// Apply a transform and write the result to a target Spatial region.
    fn apply_transform(
        &mut self,
        source: GpuHandle,
        transform: Mat4,
        target: RegionId,
    ) -> Result<(), KernelError>;

    /// Flush pending GPU operations to the target region.
    fn flush(&mut self);
}
```

Feature-gated implementations:
- `cpu` (default) — software rasterizer, works everywhere, no hardware deps
- `virgl` — virtio-gpu 3D passthrough in QEMU (via `virtio-gpu` with virglrenderer)
- `vulkan` — native GPU on real hardware

## Usage Example

```rust
use kernel_spec::{Kernel, RegionKind, ElementFormat, MemoryTier};
use render::{math, rasterize, RegionSurface};

// Create a framebuffer region (e.g., mapped to virtio-gpu by the kernel)
let fb = kernel.create_region(
    RegionKind::Spatial { x: 720, y: 1440, z: 1, t: 2, format: ElementFormat::U8x4 },
    size, MemoryTier::ShortTerm,
    Some("framebuffer"),
)?;

// Create a vertex region (a triangle)
let verts = kernel.create_region(
    RegionKind::Spatial { x: 3, y: 1, z: 1, t: 1, format: ElementFormat::F32x4 },
    size, MemoryTier::ShortTerm,
    Some("triangle-verts"),
)?;

// Write vertex data: each element is (x, y, z, w) packed as F32x4
kernel.write_region(verts, 0, &vertex_data)?;

// Project the triangle onto the framebuffer
let transform = math::Mat4::orthographic(0.0, 720.0, 1440.0, 0.0, -1.0, 1.0);
rasterize::rasterize(&kernel, verts, transform, fb, Some([0x27, 0x29, 0x2A, 0xFF]))?;

// The framebuffer now contains the rendered triangle. The hardware driver
// scans it out on the next frame.
```
