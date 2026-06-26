use crate::{Access, RegionId, TrustDomain};

#[derive(Clone, Copy)]
pub enum MappingType {
    Code,
    Data,
    Guard,
}

pub struct Mapping {
    pub va: u64,
    pub pa: u64,
    pub pages: usize,
    pub map_type: MappingType,
    pub access: Access,
    pub mte_tag: Option<u8>,
}

pub struct AddressSpace {
    pub ttbr0: u64,
    pub domain: TrustDomain,
    pub mappings: alloc::vec::Vec<(RegionId, Access)>,
    pub mte_tags: alloc::vec::Vec<(RegionId, u8)>,
}
