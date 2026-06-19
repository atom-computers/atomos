-- Counter: producer/consumer reactive dataflow
-- Demonstrates: regions, processes, when-blocks, Raw regions, kill

region shared: region[len: 16byte] of Raw @ ShortTerm;
region tick:   region[len: 1byte] of Raw @ ShortTerm;

process producer:
    reads  tick @ ReadOnly;
    writes shared;
    private counter: u32 = 0;

    when tick changes:
        counter := counter + 1;
        shared[0..4] := counter.to_le_bytes();

        if counter >= 100:
            kill self;
            return;
        end
end

process consumer:
    reads  shared @ ReadOnly;
    writes tick;

    when shared changes:
        let value = u32_from_le_bytes(shared[0..4]);
        tick[0] := 1u8;
end