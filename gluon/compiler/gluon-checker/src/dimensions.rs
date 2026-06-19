use std::collections::HashMap;
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub struct Dimension {
    units: HashMap<String, i32>,
}

impl Dimension {
    pub fn dimensionless() -> Self {
        Dimension { units: HashMap::new() }
    }

    pub fn from_unit(unit: &str) -> Self {
        let mut units = HashMap::new();
        match unit {
            "px" | "px²" => { units.insert("px".to_string(), if unit.ends_with("²") { 2 } else { 1 }); }
            "ms" | "ms²" => { units.insert("ms".to_string(), if unit.ends_with("²") { 2 } else { 1 }); }
            "s" | "s²" => { units.insert("s".to_string(), if unit.ends_with("²") { 2 } else { 1 }); }
            "byte" => { units.insert("byte".to_string(), 1); }
            "qubit" => { units.insert("qubit".to_string(), 1); }
            "frame" | "frames" => { units.insert("frame".to_string(), 1); }
            "layer" => { units.insert("layer".to_string(), 1); }
            "channel" | "channels" => { units.insert("channel".to_string(), 1); }
            "deg" | "°" => { units.insert("deg".to_string(), 1); }
            "µm" => { units.insert("µm".to_string(), 1); }
            "Hz" => {
                units.insert("s".to_string(), -1);
            }
            _ => {}
        }
        Dimension { units }
    }

    pub fn is_dimensionless(&self) -> bool {
        self.units.is_empty() || self.units.values().all(|&v| v == 0)
    }

    pub fn error() -> Self {
        let mut units = HashMap::new();
        units.insert("*error*".to_string(), 1);
        Dimension { units }
    }

    pub fn is_error(&self) -> bool {
        self.units.contains_key("*error*")
    }

    pub fn mul_dims(left: &Dimension, right: &Dimension) -> Result<Dimension, ()> {
        if left.is_error() || right.is_error() {
            return Ok(Dimension::error());
        }
        let mut result = left.units.clone();
        for (unit, power) in &right.units {
            let entry = result.entry(unit.clone()).or_insert(0);
            *entry += power;
            if *entry == 0 {
                result.remove(unit);
            }
        }
        Ok(Dimension { units: result })
    }

    pub fn div_dims(left: &Dimension, right: &Dimension) -> Result<Dimension, ()> {
        if left.is_error() || right.is_error() {
            return Ok(Dimension::error());
        }
        let mut result = left.units.clone();
        for (unit, power) in &right.units {
            let entry = result.entry(unit.clone()).or_insert(0);
            *entry -= power;
            if *entry == 0 {
                result.remove(unit);
            }
        }
        Ok(Dimension { units: result })
    }

    pub fn to_string(&self) -> String {
        if self.is_dimensionless() {
            return "dimensionless".to_string();
        }
        let mut parts: Vec<(String, i32)> = self.units.iter().map(|(u, p)| (u.clone(), *p)).collect();
        parts.sort_by(|a, b| {
            let cmp = b.1.abs().cmp(&a.1.abs());
            if cmp == std::cmp::Ordering::Equal { a.0.cmp(&b.0) } else { cmp }
        });
        parts.iter().map(|(u, p)| {
            if *p == 1 { u.clone() }
            else if *p == -1 { format!("1/{}", u) }
            else if *p > 1 { format!("{}^{}", u, p) }
            else { format!("1/{}^{}", u, p.abs()) }
        }).collect::<Vec<_>>().join("·")
    }

    pub fn unit_to_dimension(&self, unit: &str) -> Dimension {
        Dimension::from_unit(unit)
    }
}

impl fmt::Display for Dimension {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_dimensionless() {
            write!(f, "dimensionless")
        } else if self.is_error() {
            write!(f, "<dimension error>")
        } else {
            write!(f, "{}", self.to_string())
        }
    }
}

pub struct DimensionChecker {
    known_units: HashMap<String, Dimension>,
}

impl DimensionChecker {
    pub fn new() -> Self {
        let mut known_units = HashMap::new();
        known_units.insert("px".to_string(), Dimension::from_unit("px"));
        known_units.insert("ms".to_string(), Dimension::from_unit("ms"));
        known_units.insert("s".to_string(), Dimension::from_unit("s"));
        known_units.insert("byte".to_string(), Dimension::from_unit("byte"));
        known_units.insert("qubit".to_string(), Dimension::from_unit("qubit"));
        known_units.insert("frame".to_string(), Dimension::from_unit("frame"));
        known_units.insert("frames".to_string(), Dimension::from_unit("frames"));
        known_units.insert("layer".to_string(), Dimension::from_unit("layer"));
        known_units.insert("channel".to_string(), Dimension::from_unit("channel"));
        known_units.insert("deg".to_string(), Dimension::from_unit("deg"));
        known_units.insert("°".to_string(), Dimension::from_unit("°"));
        known_units.insert("µm".to_string(), Dimension::from_unit("µm"));
        known_units.insert("Hz".to_string(), Dimension::from_unit("Hz"));
        DimensionChecker { known_units }
    }

    pub fn check_dimensional_compatibility(&self, left: &Dimension, right: &Dimension) -> Result<(), String> {
        if left.is_error() || right.is_error() {
            return Ok(());
        }
        if left == right || (left.is_dimensionless() && right.is_dimensionless()) {
            Ok(())
        } else {
            Err(format!("incompatible dimensions: {} vs {}", left, right))
        }
    }

    pub fn unit_to_dimension(&self, unit: &str) -> Dimension {
        self.known_units.get(unit).cloned().unwrap_or_else(|| Dimension::from_unit(unit))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dimensionless() {
        let d = Dimension::dimensionless();
        assert!(d.is_dimensionless());
    }

    #[test]
    fn test_px_dimension() {
        let d = Dimension::from_unit("px");
        assert!(!d.is_dimensionless());
        assert_eq!(d.units.get("px"), Some(&1));
    }

    #[test]
    fn test_multiply_same_units() {
        let px = Dimension::from_unit("px");
        let result = Dimension::mul_dims(&px, &px).unwrap();
        assert_eq!(result.units.get("px"), Some(&2));
    }

    #[test]
    fn test_divide_same_units() {
        let px = Dimension::from_unit("px");
        let result = Dimension::div_dims(&px, &px).unwrap();
        assert!(result.is_dimensionless());
    }

    #[test]
    fn test_compatible_dimensions() {
        let px = Dimension::from_unit("px");
        let checker = DimensionChecker::new();
        assert!(checker.check_dimensional_compatibility(&px, &px).is_ok());
    }

    #[test]
    fn test_incompatible_dimensions() {
        let px = Dimension::from_unit("px");
        let ms = Dimension::from_unit("ms");
        let checker = DimensionChecker::new();
        assert!(checker.check_dimensional_compatibility(&px, &ms).is_err());
    }

    #[test]
    fn test_velocity_dimension() {
        let px = Dimension::from_unit("px");
        let ms = Dimension::from_unit("ms");
        let velocity = Dimension::div_dims(&px, &ms).unwrap();
        assert_eq!(velocity.units.get("px"), Some(&1));
        assert_eq!(velocity.units.get("ms"), Some(&-1));
    }

    #[test]
    fn test_area_dimension() {
        let px = Dimension::from_unit("px");
        let area = Dimension::mul_dims(&px, &px).unwrap();
        assert_eq!(area.units.get("px"), Some(&2));
    }
}