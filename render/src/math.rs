use core::ops::{Add, Mul, Sub};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Vec2 {
    pub x: f32,
    pub y: f32,
}

impl Vec2 {
    pub const fn new(x: f32, y: f32) -> Self {
        Vec2 { x, y }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vec3 {
    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Vec3 { x, y, z }
    }

    pub fn dot(self, other: Vec3) -> f32 {
        self.x * other.x + self.y * other.y + self.z * other.z
    }

    pub fn cross(self, other: Vec3) -> Vec3 {
        Vec3 {
            x: self.y * other.z - self.z * other.y,
            y: self.z * other.x - self.x * other.z,
            z: self.x * other.y - self.y * other.x,
        }
    }

    pub fn length(self) -> f32 {
        libm::sqrtf(self.dot(self))
    }

    pub fn normalize(self) -> Vec3 {
        let len = self.length();
        if len > 0.0 {
            Vec3 {
                x: self.x / len,
                y: self.y / len,
                z: self.z / len,
            }
        } else {
            self
        }
    }
}

impl Sub for Vec3 {
    type Output = Vec3;
    fn sub(self, rhs: Vec3) -> Vec3 {
        Vec3 {
            x: self.x - rhs.x,
            y: self.y - rhs.y,
            z: self.z - rhs.z,
        }
    }
}

impl Add for Vec3 {
    type Output = Vec3;
    fn add(self, rhs: Vec3) -> Vec3 {
        Vec3 {
            x: self.x + rhs.x,
            y: self.y + rhs.y,
            z: self.z + rhs.z,
        }
    }
}

impl Mul<f32> for Vec3 {
    type Output = Vec3;
    fn mul(self, rhs: f32) -> Vec3 {
        Vec3 {
            x: self.x * rhs,
            y: self.y * rhs,
            z: self.z * rhs,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Vec4 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

impl Vec4 {
    pub const fn new(x: f32, y: f32, z: f32, w: f32) -> Self {
        Vec4 { x, y, z, w }
    }

    pub fn dot(self, other: Vec4) -> f32 {
        self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w
    }
}

impl Mul<f32> for Vec4 {
    type Output = Vec4;
    fn mul(self, rhs: f32) -> Vec4 {
        Vec4 {
            x: self.x * rhs,
            y: self.y * rhs,
            z: self.z * rhs,
            w: self.w * rhs,
        }
    }
}

impl Add for Vec4 {
    type Output = Vec4;
    fn add(self, rhs: Vec4) -> Vec4 {
        Vec4 {
            x: self.x + rhs.x,
            y: self.y + rhs.y,
            z: self.z + rhs.z,
            w: self.w + rhs.w,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Mat4 {
    pub cols: [Vec4; 4],
}

impl Mat4 {
    pub fn identity() -> Self {
        Mat4 {
            cols: [
                Vec4::new(1.0, 0.0, 0.0, 0.0),
                Vec4::new(0.0, 1.0, 0.0, 0.0),
                Vec4::new(0.0, 0.0, 1.0, 0.0),
                Vec4::new(0.0, 0.0, 0.0, 1.0),
            ],
        }
    }

    pub fn translate(x: f32, y: f32, z: f32) -> Self {
        let mut m = Mat4::identity();
        m.cols[3] = Vec4::new(x, y, z, 1.0);
        m
    }

    pub fn scale(sx: f32, sy: f32, sz: f32) -> Self {
        Mat4 {
            cols: [
                Vec4::new(sx, 0.0, 0.0, 0.0),
                Vec4::new(0.0, sy, 0.0, 0.0),
                Vec4::new(0.0, 0.0, sz, 0.0),
                Vec4::new(0.0, 0.0, 0.0, 1.0),
            ],
        }
    }

    pub fn rotate_z(radians: f32) -> Self {
        let c = libm::cosf(radians);
        let s = libm::sinf(radians);
        Mat4 {
            cols: [
                Vec4::new(c, s, 0.0, 0.0),
                Vec4::new(-s, c, 0.0, 0.0),
                Vec4::new(0.0, 0.0, 1.0, 0.0),
                Vec4::new(0.0, 0.0, 0.0, 1.0),
            ],
        }
    }

    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) -> Self {
        let rml = right - left;
        let tmb = top - bottom;
        let fmn = far - near;
        Mat4 {
            cols: [
                Vec4::new(2.0 / rml, 0.0, 0.0, 0.0),
                Vec4::new(0.0, 2.0 / tmb, 0.0, 0.0),
                Vec4::new(0.0, 0.0, -2.0 / fmn, 0.0),
                Vec4::new(
                    -(right + left) / rml,
                    -(top + bottom) / tmb,
                    -(far + near) / fmn,
                    1.0,
                ),
            ],
        }
    }

    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) -> Self {
        let f = 1.0 / libm::tanf(fov_y * 0.5);
        let fmn = far - near;
        Mat4 {
            cols: [
                Vec4::new(f / aspect, 0.0, 0.0, 0.0),
                Vec4::new(0.0, f, 0.0, 0.0),
                Vec4::new(0.0, 0.0, -(far + near) / fmn, -1.0),
                Vec4::new(0.0, 0.0, -2.0 * far * near / fmn, 0.0),
            ],
        }
    }

    pub fn transpose(&self) -> Self {
        Mat4 {
            cols: [
                Vec4::new(
                    self.cols[0].x,
                    self.cols[1].x,
                    self.cols[2].x,
                    self.cols[3].x,
                ),
                Vec4::new(
                    self.cols[0].y,
                    self.cols[1].y,
                    self.cols[2].y,
                    self.cols[3].y,
                ),
                Vec4::new(
                    self.cols[0].z,
                    self.cols[1].z,
                    self.cols[2].z,
                    self.cols[3].z,
                ),
                Vec4::new(
                    self.cols[0].w,
                    self.cols[1].w,
                    self.cols[2].w,
                    self.cols[3].w,
                ),
            ],
        }
    }

    pub fn inverse(&self) -> Option<Self> {
        let m = self;
        let inv: [f32; 16] = {
            let a = [
                [m.cols[0].x, m.cols[1].x, m.cols[2].x, m.cols[3].x],
                [m.cols[0].y, m.cols[1].y, m.cols[2].y, m.cols[3].y],
                [m.cols[0].z, m.cols[1].z, m.cols[2].z, m.cols[3].z],
                [m.cols[0].w, m.cols[1].w, m.cols[2].w, m.cols[3].w],
            ];

            let mut s = [0.0f32; 16];
            for i in 0..4 {
                s[i] = a[i][0];
                s[i + 4] = a[i][1];
                s[i + 8] = a[i][2];
                s[i + 12] = a[i][3];
            }

            let mut inv = [0.0f32; 16];
            inv[0] = s[5] * s[10] * s[15] - s[5] * s[11] * s[14] - s[9] * s[6] * s[15]
                + s[9] * s[7] * s[14]
                + s[13] * s[6] * s[11]
                - s[13] * s[7] * s[10];
            inv[4] = -s[4] * s[10] * s[15] + s[4] * s[11] * s[14] + s[8] * s[6] * s[15]
                - s[8] * s[7] * s[14]
                - s[12] * s[6] * s[11]
                + s[12] * s[7] * s[10];
            inv[8] = s[4] * s[9] * s[15] - s[4] * s[11] * s[13] - s[8] * s[5] * s[15]
                + s[8] * s[7] * s[13]
                + s[12] * s[5] * s[11]
                - s[12] * s[7] * s[9];
            inv[12] = -s[4] * s[9] * s[14] + s[4] * s[10] * s[13] + s[8] * s[5] * s[14]
                - s[8] * s[6] * s[13]
                - s[12] * s[5] * s[10]
                + s[12] * s[6] * s[9];
            inv[1] = -s[1] * s[10] * s[15] + s[1] * s[11] * s[14] + s[9] * s[2] * s[15]
                - s[9] * s[3] * s[14]
                - s[13] * s[2] * s[11]
                + s[13] * s[3] * s[10];
            inv[5] = s[0] * s[10] * s[15] - s[0] * s[11] * s[14] - s[8] * s[2] * s[15]
                + s[8] * s[3] * s[14]
                + s[12] * s[2] * s[11]
                - s[12] * s[3] * s[10];
            inv[9] = -s[0] * s[9] * s[15] + s[0] * s[11] * s[13] + s[8] * s[1] * s[15]
                - s[8] * s[3] * s[13]
                - s[12] * s[1] * s[11]
                + s[12] * s[3] * s[9];
            inv[13] = s[0] * s[9] * s[14] - s[0] * s[10] * s[13] - s[8] * s[1] * s[14]
                + s[8] * s[2] * s[13]
                + s[12] * s[1] * s[10]
                - s[12] * s[2] * s[9];
            inv[2] = s[1] * s[6] * s[15] - s[1] * s[7] * s[14] - s[5] * s[2] * s[15]
                + s[5] * s[3] * s[14]
                + s[13] * s[2] * s[7]
                - s[13] * s[3] * s[6];
            inv[6] = -s[0] * s[6] * s[15] + s[0] * s[7] * s[14] + s[4] * s[2] * s[15]
                - s[4] * s[3] * s[14]
                - s[12] * s[2] * s[7]
                + s[12] * s[3] * s[6];
            inv[10] = s[0] * s[5] * s[15] - s[0] * s[7] * s[13] - s[4] * s[1] * s[15]
                + s[4] * s[3] * s[13]
                + s[12] * s[1] * s[7]
                - s[12] * s[3] * s[5];
            inv[14] = -s[0] * s[5] * s[14] + s[0] * s[6] * s[13] + s[4] * s[1] * s[14]
                - s[4] * s[2] * s[13]
                - s[12] * s[1] * s[6]
                + s[12] * s[2] * s[5];
            inv[3] = -s[1] * s[6] * s[11] + s[1] * s[7] * s[10] + s[5] * s[2] * s[11]
                - s[5] * s[3] * s[10]
                - s[9] * s[2] * s[7]
                + s[9] * s[3] * s[6];
            inv[7] = s[0] * s[6] * s[11] - s[0] * s[7] * s[10] - s[4] * s[2] * s[11]
                + s[4] * s[3] * s[10]
                + s[8] * s[2] * s[7]
                - s[8] * s[3] * s[6];
            inv[11] = -s[0] * s[5] * s[11] + s[0] * s[7] * s[9] + s[4] * s[1] * s[11]
                - s[4] * s[3] * s[9]
                - s[8] * s[1] * s[7]
                + s[8] * s[3] * s[5];
            inv[15] = s[0] * s[5] * s[10] - s[0] * s[6] * s[9] - s[4] * s[1] * s[10]
                + s[4] * s[2] * s[9]
                + s[8] * s[1] * s[6]
                - s[8] * s[2] * s[5];

            let det = s[0] * inv[0] + s[1] * inv[4] + s[2] * inv[8] + s[3] * inv[12];
            if det.abs() < 1e-10 {
                return None;
            }
            let inv_det = 1.0 / det;
            for v in inv.iter_mut() {
                *v *= inv_det;
            }
            inv
        };

        Some(Mat4 {
            cols: [
                Vec4::new(inv[0], inv[1], inv[2], inv[3]),
                Vec4::new(inv[4], inv[5], inv[6], inv[7]),
                Vec4::new(inv[8], inv[9], inv[10], inv[11]),
                Vec4::new(inv[12], inv[13], inv[14], inv[15]),
            ],
        })
    }
}

impl Mul<Mat4> for Mat4 {
    type Output = Mat4;
    fn mul(self, rhs: Mat4) -> Mat4 {
        let a = self.transpose();
        Mat4 {
            cols: [
                Vec4::new(
                    a.cols[0].dot(rhs.cols[0]),
                    a.cols[1].dot(rhs.cols[0]),
                    a.cols[2].dot(rhs.cols[0]),
                    a.cols[3].dot(rhs.cols[0]),
                ),
                Vec4::new(
                    a.cols[0].dot(rhs.cols[1]),
                    a.cols[1].dot(rhs.cols[1]),
                    a.cols[2].dot(rhs.cols[1]),
                    a.cols[3].dot(rhs.cols[1]),
                ),
                Vec4::new(
                    a.cols[0].dot(rhs.cols[2]),
                    a.cols[1].dot(rhs.cols[2]),
                    a.cols[2].dot(rhs.cols[2]),
                    a.cols[3].dot(rhs.cols[2]),
                ),
                Vec4::new(
                    a.cols[0].dot(rhs.cols[3]),
                    a.cols[1].dot(rhs.cols[3]),
                    a.cols[2].dot(rhs.cols[3]),
                    a.cols[3].dot(rhs.cols[3]),
                ),
            ],
        }
    }
}

impl Mul<Vec4> for Mat4 {
    type Output = Vec4;
    fn mul(self, rhs: Vec4) -> Vec4 {
        Vec4::new(
            self.cols[0].x * rhs.x
                + self.cols[1].x * rhs.y
                + self.cols[2].x * rhs.z
                + self.cols[3].x * rhs.w,
            self.cols[0].y * rhs.x
                + self.cols[1].y * rhs.y
                + self.cols[2].y * rhs.z
                + self.cols[3].y * rhs.w,
            self.cols[0].z * rhs.x
                + self.cols[1].z * rhs.y
                + self.cols[2].z * rhs.z
                + self.cols[3].z * rhs.w,
            self.cols[0].w * rhs.x
                + self.cols[1].w * rhs.y
                + self.cols[2].w * rhs.z
                + self.cols[3].w * rhs.w,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_mul_vec4() {
        let v = Vec4::new(1.0, 2.0, 3.0, 1.0);
        let result = Mat4::identity() * v;
        assert!((result.x - 1.0).abs() < 0.001);
        assert!((result.y - 2.0).abs() < 0.001);
        assert!((result.z - 3.0).abs() < 0.001);
        assert!((result.w - 1.0).abs() < 0.001);
    }

    #[test]
    fn identity_mul_mat4() {
        let a = Mat4::identity();
        let b = Mat4::identity();
        let result = a * b;
        assert_eq!(result, Mat4::identity());
    }

    #[test]
    fn translate_moves_point() {
        let t = Mat4::translate(10.0, 20.0, 0.0);
        let v = Vec4::new(0.0, 0.0, 0.0, 1.0);
        let result = t * v;
        assert!((result.x - 10.0).abs() < 0.001);
        assert!((result.y - 20.0).abs() < 0.001);
        assert!((result.z - 0.0).abs() < 0.001);
        assert!((result.w - 1.0).abs() < 0.001);
    }

    #[test]
    fn translate_does_not_affect_direction() {
        let t = Mat4::translate(10.0, 20.0, 0.0);
        let v = Vec4::new(1.0, 0.0, 0.0, 0.0); // direction, w=0
        let result = t * v;
        assert!((result.x - 1.0).abs() < 0.001);
        assert!((result.y - 0.0).abs() < 0.001);
    }

    #[test]
    fn scale_doubles_point() {
        let s = Mat4::scale(2.0, 2.0, 2.0);
        let v = Vec4::new(1.0, 2.0, 3.0, 1.0);
        let result = s * v;
        assert!((result.x - 2.0).abs() < 0.001);
        assert!((result.y - 4.0).abs() < 0.001);
        assert!((result.z - 6.0).abs() < 0.001);
    }

    #[test]
    fn rotate_z_90_degrees() {
        let r = Mat4::rotate_z(core::f32::consts::FRAC_PI_2);
        let v = Vec4::new(1.0, 0.0, 0.0, 1.0);
        let result = r * v;
        assert!((result.x - 0.0).abs() < 0.01);
        assert!((result.y - 1.0).abs() < 0.01);
    }

    #[test]
    fn chain_transforms() {
        let t = Mat4::translate(5.0, 0.0, 0.0);
        let s = Mat4::scale(2.0, 1.0, 1.0);
        let combined = t * s; // scale then translate
        let v = Vec4::new(3.0, 0.0, 0.0, 1.0);
        let result = combined * v;
        assert!((result.x - 11.0).abs() < 0.01); // 3*2 + 5
    }

    #[test]
    fn inverse_of_identity() {
        let inv = Mat4::identity().inverse().unwrap();
        assert_eq!(inv, Mat4::identity());
    }

    #[test]
    fn inverse_of_translate() {
        let t = Mat4::translate(5.0, -3.0, 2.0);
        let inv = t.inverse().unwrap();
        let v = Vec4::new(10.0, 20.0, 30.0, 1.0);
        let result = inv * (t * v);
        assert!((result.x - 10.0).abs() < 0.01);
        assert!((result.y - 20.0).abs() < 0.01);
        assert!((result.z - 30.0).abs() < 0.01);
    }

    #[test]
    fn inverse_of_scale() {
        let s = Mat4::scale(2.0, 4.0, 8.0);
        let inv = s.inverse().unwrap();
        let v = Vec4::new(10.0, 20.0, 30.0, 1.0);
        let result = inv * (s * v);
        assert!((result.x - 10.0).abs() < 0.01);
        assert!((result.y - 20.0).abs() < 0.01);
        assert!((result.z - 30.0).abs() < 0.01);
    }

    #[test]
    fn orthographic_maps_ndc() {
        let proj = Mat4::orthographic(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0);
        let v = Vec4::new(0.0, 0.0, 0.0, 1.0);
        let result = proj * v;
        assert!((result.x).abs() < 0.01);
        assert!((result.y).abs() < 0.01);
        assert!((result.z).abs() < 0.01);
        assert!((result.w - 1.0).abs() < 0.01);
    }

    #[test]
    fn orthographic_top_left() {
        let proj = Mat4::orthographic(0.0, 100.0, 0.0, 100.0, -1.0, 1.0);
        let v = Vec4::new(0.0, 0.0, 0.0, 1.0);
        let result = proj * v;
        assert!((result.x - (-1.0)).abs() < 0.01); // left edge → -1
        assert!((result.y - (-1.0)).abs() < 0.01); // bottom edge → -1
    }

    #[test]
    fn orthographic_bottom_right() {
        let proj = Mat4::orthographic(0.0, 100.0, 0.0, 100.0, -1.0, 1.0);
        let v = Vec4::new(100.0, 100.0, 0.0, 1.0);
        let result = proj * v;
        assert!((result.x - 1.0).abs() < 0.01); // right edge → 1
        assert!((result.y - 1.0).abs() < 0.01); // top edge → 1
    }

    #[test]
    fn vec3_cross() {
        let a = Vec3::new(1.0, 0.0, 0.0);
        let b = Vec3::new(0.0, 1.0, 0.0);
        let c = a.cross(b);
        assert!((c.x - 0.0).abs() < 0.001);
        assert!((c.y - 0.0).abs() < 0.001);
        assert!((c.z - 1.0).abs() < 0.001);
    }

    #[test]
    fn vec3_normalize() {
        let v = Vec3::new(3.0, 0.0, 0.0);
        let n = v.normalize();
        assert!((n.x - 1.0).abs() < 0.001);
        assert!((n.y - 0.0).abs() < 0.001);
        assert!((n.z - 0.0).abs() < 0.001);
    }

    #[test]
    fn vec4_dot() {
        let a = Vec4::new(1.0, 2.0, 3.0, 4.0);
        let b = Vec4::new(2.0, 3.0, 4.0, 5.0);
        assert!((a.dot(b) - 40.0).abs() < 0.001);
    }
}
